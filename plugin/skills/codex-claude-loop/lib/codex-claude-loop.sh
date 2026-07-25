#!/usr/bin/env bash
# codex-claude-loop.sh — a gated plan -> approve -> implement -> review loop around Codex CLI.
#
#   Claude plans (brief) -> Codex plans (persistent thread) -> Claude APPROVES the plan
#   -> Codex implements (SAME thread) -> Claude REVIEWS the diff vs the plan -> release.
#
#   Implementation is the single writer and is serialized by a lock, so the read-only
#   phases (planning the next brief, reviewing the previous diff) can safely overlap it.
#   The overlapping itself is something the orchestrator does; this file makes it safe.
#
# Substrate: pure bash around `codex exec` + `codex exec resume` (persistent threads)
# + `--output-schema` (parseable verdict gates). No framework, no MCP, no daemon.
#
# The ORCHESTRATOR (Claude, in the session that loaded this skill) owns the two judgment
# gates: cl_gate_plan (read the plan, then cl_record_verdict <slug> plan approve) and
# cl_review_human (read the diff, then cl_record_verdict <slug> review approve). For
# fully-autonomous runs, cl_codex_gate stands in a Codex reviewer that emits the same
# verdict JSON.
#
# Requires: codex-cli >= 0.144, jq, git. Bash 3.2 safe (macOS default bash).

# strict mode only when dispatched (sourcing shells — incl. zsh — must not be poisoned)

# ------------------------------------------------------------------ config ----
# Default target repo: the git root of the current directory, else $PWD.
CL_REPO="${CL_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
CL_STATE="${CL_STATE:-$HOME/.codex-claude-loop/$(basename "$CL_REPO")}"
CL_SKILL_DIR="${CL_SKILL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)}"
CL_VERDICT_SCHEMA="${CL_VERDICT_SCHEMA:-$CL_SKILL_DIR/schemas/verdict.schema.json}"
CL_SANDBOX="${CL_SANDBOX:-workspace-write}"     # read-only|workspace-write|danger-full-access
# Plan/review phases default to read-only. Some hosts cannot run ANY sandboxed shell
# (seen live: bwrap fails "loopback RTM_NEWADDR" inside a VM; symlinks pointing outside
# the allowed roots also trip it) — set these to danger-full-access there; the prompts
# still forbid writes in those phases.
CL_PLAN_SANDBOX="${CL_PLAN_SANDBOX:-read-only}"
CL_REVIEW_SANDBOX="${CL_REVIEW_SANDBOX:-read-only}"
CL_IMPL_MODEL="${CL_IMPL_MODEL:-}"              # empty = codex config default
CL_PLAN_MODEL="${CL_PLAN_MODEL:-}"
CL_REVIEW_MODEL="${CL_REVIEW_MODEL:-}"
CL_LOCK="${CL_LOCK:-$CL_STATE/impl.lock.d}"     # serializes the single writer

# State is owner-only. `chmod` the directory rather than `umask` the shell: this file is
# sourced into interactive shells, and a umask would follow the user out of the harness.
mkdir -p "$CL_STATE" && chmod 700 "$CL_STATE" 2>/dev/null

# Bash-3.2 safe (macOS default bash rejects printf %(..)T)
_cl_log() { printf '[codex-loop %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
# The flag helpers below expand to ZERO words or to a flag pair, so their call sites are
# deliberately unquoted. Quoting them passes an empty argument and codex rejects it, so
# the SC2046 warnings on those lines are intentional throughout this file.
_cl_model_flag() { [ -n "$1" ] && printf -- '-m %s' "$1"; }
# Extra writable roots for the sandbox (single path). Needed when CL_REPO is a LINKED
# WORKTREE: commits write refs/objects into the parent repo's .git, outside the
# workspace — seen live as `cannot lock ref`.
_cl_writable_flag() { [ -n "$CL_WRITABLE_ROOTS" ] && printf -- '-c sandbox_workspace_write.writable_roots=["%s"]' "$CL_WRITABLE_ROOTS"; }
# CL_NET=1 grants the sandbox network access (npm installs, a DB on loopback) — needed
# for test gates that talk to a local service.
_cl_net_flag() { [ -n "$CL_NET" ] && printf -- '-c sandbox_workspace_write.network_access=true'; }

# ------------------------------------------------- codex-cli compatibility ----
# The CLI moves. This harness depends on four capabilities: `exec --json`, `exec -o`,
# `exec resume`, and `exec --output-schema`. Every phase declares what it needs through
# _cl_require, so a moved flag produces a refusal with an instruction instead of a lane
# that dies silently into its log. Families this harness has been exercised against:
CL_CODEX_TESTED="${CL_CODEX_TESTED:-0.144 0.145}"

_cl_codex_version() { codex --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1; }
_cl_codex_family()  { local v="${1:-$(_cl_codex_version)}"; printf '%s' "$v" | cut -d. -f1,2; }
_cl_family_tested() { case " $CL_CODEX_TESTED " in *" ${1:-none} "*) return 0 ;; esac; return 1; }

# `codex exec --help` memoized for the life of the process. Not cached to disk: a stale
# capability answer is exactly the failure the probes exist to prevent, and cl_doctor
# busts the memo so "upgrade codex, re-run doctor" always tells the truth.
_cl_exec_help() {
  [ -n "${_CL_HELP:-}" ] || _CL_HELP="$(codex exec --help 2>&1)"
  printf '%s' "$_CL_HELP"
}
# ANY of the given spellings counts, so a renamed flag is not read as a lost capability.
# Deliberately not a pipeline: `grep -q` closes the pipe on its first match, and under
# `set -o pipefail` (which the dispatcher sets) the SIGPIPE'd writer turns a HIT into a MISS.
_cl_has_flag() {
  local help pat
  help="$(_cl_exec_help)" || return 1
  for pat in "$@"; do
    case "$help" in *"$pat"*) return 0 ;; esac
  done
  return 1
}
_cl_capable() {   # <capability>
  case "$1" in
    json)   _cl_has_flag --json ;;
    out)    _cl_has_flag "-o," "--output-last-message" ;;
    schema) _cl_has_flag --output-schema ;;
    resume) codex exec resume --help >/dev/null 2>&1 ;;
    *)      return 1 ;;
  esac
}
_cl_cap_desc() {  # <capability> -> what its loss costs, in the user's terms
  case "$1" in
    json)   printf 'codex exec --json (the event stream that carries the thread id)' ;;
    out)    printf 'codex exec -o (writing the phase output to a file)' ;;
    schema) printf 'codex exec --output-schema (a machine-checkable verdict). Use cl_review_human and judge it yourself' ;;
    resume) printf 'codex exec resume (persistent threads). Implementing from a cold prompt is not this loop' ;;
  esac
}
_cl_require() {   # <context> <capability>...  rc 2 when one is missing
  local ctx="$1" cap; shift
  for cap in "$@"; do
    _cl_capable "$cap" && continue
    _cl_log "$ctx REFUSED: this codex has no $(_cl_cap_desc "$cap"). Run cl_doctor."
    return 2
  done
  return 0
}
_cl_compat_check() {   # warns once per shell; never blocks
  [ -n "${_CL_COMPAT_DONE:-}" ] && return 0
  _CL_COMPAT_DONE=1
  local fam; fam="$(_cl_codex_family)"
  [ -z "$fam" ] && { _cl_log "compat: cannot read 'codex --version' — run cl_doctor"; return 0; }
  _cl_family_tested "$fam" && return 0
  _cl_log "compat: codex $fam is outside the tested set ($CL_CODEX_TESTED) — run cl_doctor;"
  _cl_log "compat: if a phase dies within seconds, the CLI's flags moved"
}

# Capture the codex thread id from a --json event stream. One jq program emits
# "<shape>\t<id>": `canonical` is the 0.144/0.145 event, `drifted` is a renamed event or
# key, and the caller announces anything non-canonical so schema drift shows up in the log
# instead of silently resuming the wrong thread.
_cl_grab_session() {  # <jsonl-file>  -> prints id, rc 1 when missing
  local json hit id shape
  # grep -a '^{' first: codex interleaves non-JSON stderr lines (ANSI ERROR spam) into
  # the jsonl and jq aborts at the first invalid line — seen live. The head bound keeps
  # this O(1) on a chatty stream; the thread event is always at the top.
  json="$(head -n 500 "$1" 2>/dev/null | grep -a '^{')"
  [ -n "$json" ] || return 1

  hit="$(printf '%s\n' "$json" | jq -r '
      select((.type // "") | test("thread\\.started|session\\.created|session_configured|thread_started"))
      | (if .type == "thread.started" and (.thread_id // "") != "" then "canonical" else "drifted" end)
        + "\t"
        + (.thread_id // .session_id // .conversation_id // .thread.id // .session.id // "")
      | select(endswith("\t") | not)' 2>/dev/null | head -1)"

  if [ -z "$hit" ]; then
    # last resort: any line carrying an id at all
    id="$(printf '%s\n' "$json" | jq -r '(.thread_id // .session_id // .conversation_id // empty)' 2>/dev/null | head -1)"
    case "$id" in ""|null) return 1 ;; esac
    _cl_log "compat: thread id scavenged from an unrecognised stream — verify the next resume lands"
    printf '%s\n' "$id"; return 0
  fi

  shape="${hit%%	*}"; id="${hit#*	}"
  [ "$shape" = canonical ] || _cl_log "compat: thread id came from a DRIFTED event shape — codex $(_cl_codex_version)"
  printf '%s\n' "$id"
}

# ------------------------------------------------------------- state readers ----
_cl_session() {   # <slug> -> thread id, rc 1 + explains when absent
  local s; s="$(cat "$CL_STATE/$1.session" 2>/dev/null)"
  [ -n "$s" ] || { _cl_log "$1: no stored thread id — re-run cl_plan (never resume --last: another thread may be newer)"; return 1; }
  printf '%s\n' "$s"
}
_cl_base() {      # <slug> -> base sha recorded by cl_impl, rc 1 when impl never ran
  local b; b="$(cat "$CL_STATE/$1.base.sha" 2>/dev/null)"
  [ -n "$b" ] || return 1
  printf '%s\n' "$b"
}
_cl_plan_sha() { shasum -a 256 "$CL_STATE/$1.plan.md" 2>/dev/null | awk '{print $1}'; }

cl_verdict() { jq -r '.verdict' "$CL_STATE/$1.${2:-review}.verdict" 2>/dev/null; }

# The one answer to "is this plan approved?". An approval describes the plan text that
# was read, so a plan.md that has changed since invalidates it — enforced here rather
# than by remembering to delete the verdict at every site that can touch a plan.
cl_plan_approved() {  # <slug>
  local v="$CL_STATE/$1.plan.verdict" recorded now
  [ -f "$v" ] || return 1
  [ "$(cl_verdict "$1" plan)" = approve ] || return 1
  recorded="$(jq -r '.plan_sha256 // empty' "$v" 2>/dev/null)"
  now="$(_cl_plan_sha "$1")"
  if [ -n "$recorded" ] && [ -n "$now" ] && [ "$recorded" != "$now" ]; then
    _cl_log "$1: the approved plan has CHANGED on disk since it was approved — re-read it and re-approve"
    return 1
  fi
  return 0
}

# ------------------------------------------------------------- codex drivers ----
# Every `codex exec` in this file goes through one of these two, so the flag contract
# lives in one place.
#
#   codex-cli 0.144.5: `codex exec resume <id> -C <dir> -s <sandbox> -o <out>` is INVALID.
#   The resume subcommand accepts only -c/-m/--enable etc.; global flags (-C/-s/-o) must
#   come BEFORE `resume`, and the session carries its original cwd+sandbox anyway. Flags
#   after `resume` fail with "unexpected argument" and the lane dies silently in its log
#   — discovered live (cost: 3 lanes x 5h). ALWAYS tail the log within a minute.
_cl_codex_resume() {  # <slug> <label> <prompt>   — caller holds the writer lock
  local slug="$1" label="$2" prompt="$3" sess
  _cl_require "${label}[$slug]" resume json out || return 2
  sess="$(_cl_session "$slug")" || return 2
  codex exec $(_cl_model_flag "$CL_IMPL_MODEL") $(_cl_writable_flag) $(_cl_net_flag) \
    -C "$CL_REPO" -s "$CL_SANDBOX" --json -o "$CL_STATE/${slug}.${label}.md" \
    resume "$sess" "$prompt" > "$CL_STATE/${slug}.${label}.jsonl" 2>&1
}

# The review instruction both gates share. They differ only in their tail, so they cannot
# drift apart: whatever the autonomous gate is told to inspect, the human gate is too.
_cl_review_prompt() {  # <slug> <base>
  cat <<EOF
Adversarially review ALL changes since $2 STRICTLY against the approved plan at
$CL_STATE/$1.plan.md. Inspect the real diff yourself: git log --oneline $2..HEAD,
git diff $2 (covers committed + working tree), git status --short (untracked files count
too — a new-files-only implementation is NOT an empty change). Read any file you need.
Flag: correctness/safety holes, plan deviations, fake-success/silent-degrade, secret
leaks, cross-tenant reads.
EOF
}

# ------------------------------------------------------------------ doctor ----
_cl_doctor_cap() {   # <capability> <label>
  if _cl_capable "$1"; then printf '  ok   codex  %s\n' "$2"; return 0; fi
  printf '  MISS codex  %s — this codex cannot run the loop as written\n' "$2"
  return 1
}
# cl_doctor — verify the substrate before trusting the loop.
cl_doctor() {
  local ok=0 bin ver fam
  unset _CL_HELP           # never answer from a memo the user is trying to refresh
  for bin in codex jq git; do
    if command -v "$bin" >/dev/null 2>&1; then printf '  ok   %-6s %s\n' "$bin" "$(command -v "$bin")"
    else printf '  MISS %-6s not on PATH\n' "$bin"; ok=1; fi
  done
  ver="$(_cl_codex_version)"; fam="$(_cl_codex_family "$ver")"
  printf '  codex version: %s\n' "${ver:-?}"
  if _cl_family_tested "$fam"; then printf '  ok   compat  %s is a tested family\n' "$fam"
  else printf '  warn compat  %s is outside the tested set (%s) — the probes below are what matter\n' "${fam:-unknown}" "$CL_CODEX_TESTED"; fi
  _cl_doctor_cap json   'exec --json'          || ok=1
  _cl_doctor_cap out    'exec -o'              || ok=1
  _cl_doctor_cap schema 'exec --output-schema' || ok=1
  _cl_doctor_cap resume 'exec resume'          || ok=1
  printf '  repo:   %s\n' "$CL_REPO"
  printf '  state:  %s\n' "$CL_STATE"
  printf '  schema: %s\n' "$CL_VERDICT_SCHEMA"
  [ -f "$CL_VERDICT_SCHEMA" ] || { printf '  MISS verdict schema is not at that path\n'; ok=1; }
  git -C "$CL_REPO" rev-parse HEAD >/dev/null 2>&1 || { printf '  MISS repo is not a git worktree\n'; ok=1; }
  return $ok
}

# ------------------------------------------------------ 1. Codex plans ---------
# cl_plan <slug> <brief_file>
#   Opens a fresh persistent Codex thread, hands it the brief, and has Codex author a
#   detailed execution plan (prose) that the SAME thread will later implement. Stores the
#   thread id so implementation resumes with full context.
cl_plan() {
  local slug="$1" brief="$2"
  [ -n "$slug" ] && [ -f "${brief:-}" ] || { _cl_log "usage: cl_plan <slug> <brief.md>"; return 2; }
  local out="$CL_STATE/${slug}.plan.md" jl="$CL_STATE/${slug}.plan.jsonl"
  _cl_compat_check
  _cl_require "plan[$slug]" json out || return 2
  _cl_log "plan[$slug]: codex authoring execution plan from $brief"
  codex exec $(_cl_model_flag "$CL_PLAN_MODEL") -C "$CL_REPO" -s "$CL_PLAN_SANDBOX" --json \
    -o "$out" - > "$jl" 2>&1 <<EOF
You are the IMPLEMENTER on a locked engineering loop. Read the brief below and
author a DETAILED execution plan you will implement next in THIS same thread.
Cover: exact files to add/change, contracts/interfaces, migrations, the test
plan, failure modes, and any open questions. Do NOT write code yet — plan only.
Be concrete and honest about risk. End with a line: READY: yes  (or READY: no + why).

===== BRIEF =====
$(cat "$brief")
EOF
  [ $? -eq 0 ] || { _cl_log "plan[$slug] FAILED (see $jl)"; return 1; }
  local sid
  sid="$(_cl_grab_session "$jl")" || { _cl_log "plan[$slug] FAILED: no thread id in $jl — thread not resumable, aborting"; return 1; }
  printf '%s\n' "$sid" > "$CL_STATE/${slug}.session"
  # a fresh plan invalidates any earlier approvals for this slug
  rm -f "$CL_STATE/${slug}.plan.verdict" "$CL_STATE/${slug}.review.verdict"
  _cl_log "plan[$slug]: plan -> $out ; thread $sid (stale verdicts cleared)"
  printf '%s\n' "$out"
}

# ------------------------------------------- 2. The orchestrator approves the plan --
# cl_gate_plan <slug>   (ORCHESTRATOR judgment — Claude reads & decides)
#   Prints the plan for Claude to read. Claude writes the verdict by calling
#   cl_record_verdict <slug> plan approve|revise "notes". Returns 0 if approved.
cl_gate_plan() {
  local slug="$1"
  cat "$CL_STATE/${slug}.plan.md"
  cl_plan_approved "$slug"
}
cl_record_verdict() {  # <slug> <phase:plan|review> <approve|revise> [notes]
  local slug="$1" phase="$2" verdict="$3" notes="${4:-}"
  case "$phase"   in plan|review) ;; *) _cl_log "record_verdict: bad phase '$phase'"; return 2 ;; esac
  case "$verdict" in approve|revise) ;; *) _cl_log "record_verdict: bad verdict '$verdict'"; return 2 ;; esac
  # plan_sha256 binds the approval to the plan text that was read (see cl_plan_approved)
  jq -n --arg v "$verdict" --arg s "$notes" --arg p "$(_cl_plan_sha "$slug")" \
        --arg b "$(_cl_base "$slug" || true)" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{verdict:$v, summary:$s, blocking:[], plan_sha256:$p, base_sha:$b, at:$t}' \
    > "$CL_STATE/${slug}.${phase}.verdict"
}

# --------------------------------------------- 3. Codex implements the plan ----
# cl_impl <slug>
#   Resumes the SAME thread (plan context intact) and implements the approved plan.
#   Serialized by CL_LOCK so only one writer touches the tree at a time.
cl_impl() {
  # NOTE two local statements: zsh expands a whole `local` line BEFORE assigning, so
  # ${slug} on the same line as slug="$1" is EMPTY under zsh (bash is fine). Cost
  # discovered live: impl logs landed in a slugless ".impl.jsonl".
  local slug="$1"
  local base rc
  cl_plan_approved "$slug" || { _cl_log "impl[$slug] REFUSED: plan not approved (cl_record_verdict $slug plan approve first)"; return 2; }
  _cl_compat_check
  # refuse before taking the lock or recording a base sha, not halfway through
  _cl_require "impl[$slug]" resume json out || return 2
  _cl_session "$slug" >/dev/null || return 2
  _cl_lock_acquire || return 2    # one writer only (mkdir lock; macOS has no flock)
  _cl_log "impl[$slug]: implementing approved plan (writer lock held)"
  if ! git -C "$CL_REPO" diff --quiet 2>/dev/null; then
    _cl_log "impl[$slug]: WARNING dirty baseline — review will include pre-existing changes"
  fi
  base="$(git -C "$CL_REPO" rev-parse HEAD)" || { _cl_lock_release; _cl_log "impl[$slug] FAILED: cannot resolve HEAD"; return 2; }
  echo "$base" > "$CL_STATE/${slug}.base.sha"
  _cl_codex_resume "$slug" impl \
    "Implement the plan you authored earlier in this thread (the approved plan). \
Make the code changes and run the relevant tests. Report exactly what changed \
and any deviations from the plan with their justification."
  rc=$?
  _cl_lock_release
  [ $rc -eq 0 ] && _cl_log "impl[$slug]: done (base $base)" || _cl_log "impl[$slug] FAILED ($CL_STATE/${slug}.impl.jsonl)"
  return $rc
}

# cl_revise <slug> "<blocking items>"  — send the review back into the SAME thread.
cl_revise() {
  local slug="$1" notes="$2" rc
  [ -n "$notes" ] || { _cl_log "usage: cl_revise <slug> \"<blocking items>\""; return 2; }
  _cl_compat_check
  _cl_require "revise[$slug]" resume json out || return 2
  _cl_session "$slug" >/dev/null || return 2
  _cl_lock_acquire || return 2
  _cl_log "revise[$slug]: sending blocking items back to the implementer thread"
  _cl_codex_resume "$slug" revise \
    "Review of your implementation found BLOCKING items. Fix every one of them, re-run \
the relevant tests, and report what changed. Do not argue — fix, or explain concretely \
why the finding is wrong.

===== BLOCKING =====
$notes"
  rc=$?
  _cl_lock_release
  # the tree moved: the previous review verdict no longer describes it
  rm -f "$CL_STATE/${slug}.review.verdict"
  [ $rc -eq 0 ] && _cl_log "revise[$slug]: done — re-review required" || _cl_log "revise[$slug] FAILED"
  return $rc
}

# ---------------------------------------- 4. The orchestrator reviews the diff -------
# cl_review_human <slug>   — rich human-readable review Claude reads.
#   NOTE codex-cli 0.144.2: `codex review --base <sha> "<prompt>"` is INVALID (--base
#   cannot combine with a prompt). Use `codex exec` and let the reviewer run `git diff`.
cl_review_human() {
  local slug="$1" base
  base="$(_cl_base "$slug")" || { _cl_log "review[$slug] REFUSED: no base sha — implementation never ran, so there is nothing to review against the plan"; return 2; }
  _cl_compat_check
  codex exec $(_cl_model_flag "$CL_REVIEW_MODEL") -C "$CL_REPO" -s "$CL_REVIEW_SANDBOX" - <<EOF
$(_cl_review_prompt "$slug" "$base")
Severity-ranked findings with file:line + a concrete fix each; end with a verdict:
approve or revise.
EOF
}

# cl_codex_gate <slug>   — AUTONOMOUS fallback reviewer -> parseable verdict JSON.
#   Use only when no orchestrator/human is available to judge.
cl_codex_gate() {  # rc: 0 approve · 1 revise · 2 infra failure
  local slug="$1" base tmp v nblock
  local jl="$CL_STATE/${slug}.review.jsonl"
  base="$(_cl_base "$slug")" || { _cl_log "gate[$slug]: no base sha (did impl run?)"; return 2; }
  _cl_compat_check
  _cl_require "gate[$slug]" schema json out || return 2
  tmp="$(mktemp "$CL_STATE/${slug}.review.XXXXXX")" || return 2
  _cl_log "review[$slug]: autonomous codex gate (base $base)"
  codex exec $(_cl_model_flag "$CL_REVIEW_MODEL") -C "$CL_REPO" -s "$CL_REVIEW_SANDBOX" --json \
    --output-schema "$CL_VERDICT_SCHEMA" -o "$tmp" - > "$jl" 2>&1 <<EOF
$(_cl_review_prompt "$slug" "$base")
Default to verdict="revise" unless you are confident it is correct, faithful to the plan,
honest on failure, and leaks no secrets or cross-tenant data. Every blocking item needs a
concrete fix. approve REQUIRES an empty blocking list.
EOF
  if [ $? -ne 0 ]; then _cl_log "gate[$slug]: codex failed (stale verdicts NOT reused)"; rm -f "$tmp"; return 2; fi
  v="$(jq -r '.verdict // empty' "$tmp" 2>/dev/null)"
  nblock="$(jq -r '(.blocking // []) | length' "$tmp" 2>/dev/null)"
  case "$v" in
    approve)
      if [ "${nblock:-0}" != "0" ]; then
        _cl_log "gate[$slug]: approve carried blockers — downgrading to revise"
        v=revise
        # persist the downgrade: cl_verdict reads the FILE, so a variable-only downgrade
        # would let the next reader see "approve" (rubber-stamp hole).
        jq '.verdict="revise"' "$tmp" > "$tmp.dg" && mv "$tmp.dg" "$tmp" || { _cl_log "gate[$slug]: could not persist downgrade"; rm -f "$tmp" "$tmp.dg"; return 2; }
      fi ;;
    revise) ;;
    *) _cl_log "gate[$slug]: invalid verdict '$v'"; rm -f "$tmp"; return 2 ;;
  esac
  mv "$tmp" "$CL_STATE/${slug}.review.verdict"
  printf '%s\n' "$v"
  [ "$v" = approve ]
}

# --------------------------------------------------------------- writer lock ----
# Atomic mkdir (macOS ships no flock). Stale holder reclaimed by pid.
# Traps are installed ONLY when this file is dispatched as a script — a sourced harness
# must never clobber the calling shell's EXIT/INT traps. When sourced, every return path
# releases the lock explicitly, and a lock orphaned by Ctrl-C is reclaimed by the next
# run's stale-pid check.
CL_DISPATCHED="${CL_DISPATCHED:-0}"
_cl_lock_acquire() {
  local waited=0 holder
  while ! mkdir "$CL_LOCK" 2>/dev/null; do
    holder='?'; read -r holder 2>/dev/null < "$CL_LOCK/pid"
    if [ "$holder" != "?" ] && [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      _cl_log "lock: stale holder pid=$holder — reclaiming"; rm -rf "$CL_LOCK"; continue
    fi
    [ "$waited" -eq 0 ] && _cl_log "lock: writer busy (pid=$holder) — waiting"
    # 5s against a multi-minute codex run: invisible latency, no busy-wait
    sleep 5; waited=$((waited+5))
    if [ "$waited" -ge "${CL_LOCK_TIMEOUT:-7200}" ]; then _cl_log "lock: gave up after ${CL_LOCK_TIMEOUT:-7200}s (pid=$holder)"; return 1; fi
  done
  echo $$ > "$CL_LOCK/pid"
  [ "$CL_DISPATCHED" = 1 ] && trap '_cl_lock_release' EXIT INT TERM
  return 0
}
_cl_lock_release() {
  rm -rf "$CL_LOCK" 2>/dev/null
  [ "$CL_DISPATCHED" = 1 ] && trap - EXIT INT TERM
  return 0
}

# --------------------------------------------------------------------- status ----
cl_status() {   # [slug]
  local f slug base
  printf '%-24s %-8s %-8s %s\n' SLUG PLAN REVIEW BASE
  for f in "$CL_STATE"/*.session; do
    [ -e "$f" ] || { echo "(no slugs yet in $CL_STATE)"; return 0; }
    slug="${f##*/}"; slug="${slug%.session}"
    [ -n "${1:-}" ] && [ "$1" != "$slug" ] && continue
    base="$(_cl_base "$slug" || echo '-')"
    printf '%-24s %-8s %-8s %s\n' "$slug" \
      "$(cl_verdict "$slug" plan   || echo -)" \
      "$(cl_verdict "$slug" review || echo -)" \
      "$(printf '%s' "$base" | cut -c1-8)"
  done
}

# ------------------------------------------------------- driver: one wave ------
# cl_wave <slug> <brief_file>   — sequential loop for a single brief.
#   plan -> (orchestrator approves) -> impl -> (orchestrator reviews, loop) -> done.
#   In pipelined mode the orchestrator calls these phases directly and overlaps the
#   read-only phases across slugs; this driver is the safe sequential reference.
cl_wave() {
  local slug="$1" brief="$2"
  cl_plan "$slug" "$brief" || return 1
  _cl_log "wave[$slug]: PLAN READY — orchestrator must approve (cl_record_verdict $slug plan approve|revise)"
  cl_plan_approved "$slug" || { _cl_log "wave[$slug]: plan not approved — stop"; return 2; }
  cl_impl "$slug" || return 1
  _cl_log "wave[$slug]: IMPL DONE — orchestrator must review (cl_review_human $slug ; cl_record_verdict $slug review approve|revise)"
}

# -------------------------------------------- adversarial self-review ----------
# cl_selfreview — have Codex tear apart THIS harness before you trust it.
cl_selfreview() {
  codex exec -C "$CL_SKILL_DIR" -s read-only \
    "Adversarially review lib/codex-claude-loop.sh and SKILL.md in this dir. Find bugs \
in the bash (quoting, locking, session-id capture, exec/resume flags for codex-cli \
0.144+), unsafe defaults, and any way a gate can rubber-stamp. List concrete fixes."
}

# Direct dispatch (bash codex-claude-loop.sh <fn> args). Sourcing works too, but use bash —
# the guard below is zsh-safe (BASH_SOURCE unset under zsh won't blow up).
CL_CMDS="doctor plan gate_plan record_verdict impl review_human codex_gate revise verdict status wave selfreview"
if [ -n "${BASH_VERSION:-}" ] && [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  set -uo pipefail
  CL_DISPATCHED=1          # now the lock may own the shell's EXIT/INT traps
  cmd="${1:-}"; shift || true
  case " $CL_CMDS " in
    *" ${cmd:-—} "*) "cl_$cmd" "$@" ;;
    *) echo "usage: bash ${0##*/} {${CL_CMDS// /|}} ..." >&2; exit 2 ;;
  esac
fi
