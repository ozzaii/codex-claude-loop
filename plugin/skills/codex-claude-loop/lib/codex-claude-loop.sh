#!/usr/bin/env bash
# codex-claude-loop.sh — a gated plan -> approve -> implement -> review -> release loop
# around Codex CLI.
#
#   Claude plans (brief) -> Codex plans (persistent thread) -> Claude APPROVES the plan
#   -> Codex implements (SAME thread) -> Claude REVIEWS the diff vs the plan -> release.
#
#   Implementation is the single writer and is serialized by a lock. Review refuses to
#   run while that lock is held, so a reviewer never reads a tree mid-write.
#
# Substrate: pure bash around `codex exec` + `codex exec resume` (persistent threads)
# + `--output-schema` (parseable verdict gates). No framework, no MCP, no daemon.
#
# Both gates have a consumer, which is what makes them gates:
#   gate 1  cl_impl    refuses unless the plan is approved AND the plan file still
#                      hashes to what was approved.
#   gate 2  cl_release refuses unless the review is approved AND the tree still hashes
#                      to what was reviewed.
#
# Requires: codex-cli >= 0.144, jq, git, a sha256 tool. Bash 3.2 safe (macOS default bash).

# strict mode only when dispatched (sourcing shells — incl. zsh — must not be poisoned)

# ------------------------------------------------------------------ config ----
# Default target repo: the git root of the current directory, else $PWD.
CL_REPO="${CL_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
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
CL_WRITABLE_ROOTS="${CL_WRITABLE_ROOTS:-}"      # declared: `set -u` must not eat the flag
CL_NET="${CL_NET:-}"

# Bash-3.2 safe (macOS default bash rejects printf %(..)T)
_cl_log() { printf '[codex-loop %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# --------------------------------------------------------------- sha256 ----
# Portable digest. A missing tool must fail LOUDLY: every staleness check in this file
# is built on it, and an empty digest used to read as "no mismatch".
_cl_sha256_file() {   # <file> -> 64 hex chars, rc 1 when it cannot be computed
  [ -f "$1" ] || return 1
  local out=""
  if   command -v shasum   >/dev/null 2>&1; then out="$(shasum -a 256 "$1" 2>/dev/null | awk '{print $1}')"
  elif command -v sha256sum >/dev/null 2>&1; then out="$(sha256sum "$1" 2>/dev/null | awk '{print $1}')"
  elif command -v openssl  >/dev/null 2>&1; then out="$(openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}')"
  fi
  case "$out" in [0-9a-f]*) [ ${#out} -eq 64 ] && { printf '%s\n' "$out"; return 0; } ;; esac
  return 1
}
_cl_sha256_stdin() {
  local out=""
  if   command -v shasum   >/dev/null 2>&1; then out="$(shasum -a 256 2>/dev/null | awk '{print $1}')"
  elif command -v sha256sum >/dev/null 2>&1; then out="$(sha256sum 2>/dev/null | awk '{print $1}')"
  elif command -v openssl  >/dev/null 2>&1; then out="$(openssl dgst -sha256 2>/dev/null | awk '{print $NF}')"
  fi
  case "$out" in [0-9a-f]*) [ ${#out} -eq 64 ] && { printf '%s\n' "$out"; return 0; } ;; esac
  return 1
}

# State lives outside the repo, keyed by the repo's PATH, not its basename: ~/a/app and
# ~/b/app are different projects and must not share plans, threads or approvals.
if [ -z "${CL_STATE:-}" ]; then
  _cl_repo_id="$(printf '%s' "$CL_REPO" | _cl_sha256_stdin | cut -c1-10)" || _cl_repo_id=nohash
  CL_STATE="$HOME/.codex-claude-loop/$(basename "$CL_REPO")-$_cl_repo_id"
fi
CL_LOCK="${CL_LOCK:-$CL_STATE/impl.lock.d}"     # serializes the single writer

# State is owner-only. `chmod` the directory rather than `umask` the shell: this file is
# sourced into interactive shells, and a umask would follow the user out of the harness.
mkdir -p "$CL_STATE" && chmod 700 "$CL_STATE" 2>/dev/null

# A slug names files under CL_STATE. Anything with a separator or `..` would write
# outside it, so the shape is enforced at every public entry point.
_cl_slug_ok() {
  case "${1:-}" in
    ""|*/*|*..*) ;;
    [A-Za-z0-9]*) case "$1" in *[!A-Za-z0-9._-]*) ;; *) return 0 ;; esac ;;
  esac
  _cl_log "bad slug '${1:-}' — use [A-Za-z0-9][A-Za-z0-9._-]*"
  return 2
}

# The flag helpers below expand to ZERO words or to a flag pair, so their call sites are
# deliberately unquoted. Quoting them passes an empty argument and codex rejects it, so
# the SC2046 warnings on those lines are intentional throughout this file.
_cl_model_flag() { [ -n "$1" ] && printf -- '-m %s' "$1"; }
# Extra writable root for the sandbox. Needed when CL_REPO is a LINKED WORKTREE: commits
# write refs/objects into the parent repo's .git, outside the workspace — seen live as
# `cannot lock ref`. A path with whitespace cannot survive the unquoted expansion, so it
# is rejected instead of silently becoming several arguments.
_cl_writable_flag() { [ -n "$CL_WRITABLE_ROOTS" ] && printf -- '-c sandbox_workspace_write.writable_roots=["%s"]' "$CL_WRITABLE_ROOTS"; }
_cl_check_writable_roots() {
  case "$CL_WRITABLE_ROOTS" in
    "") return 0 ;;
    *[[:space:]]*) _cl_log "CL_WRITABLE_ROOTS contains whitespace, which this flag cannot carry — move the worktree or set it to a path without spaces"; return 2 ;;
  esac
  return 0
}
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

# `codex exec --help`, memoized for the life of the process. The assignment must happen
# in THIS shell: a `help="$(_cl_exec_help)"` wrapper caches into a subshell that then
# exits, which is a memo that never memoizes.
# Not cached to disk: a stale capability answer is exactly the failure the probes exist
# to prevent, and cl_doctor unsets the memo so "upgrade codex, re-run doctor" is honest.
_cl_load_help() { [ -n "${_CL_HELP:-}" ] || _CL_HELP="$(codex exec --help 2>&1)"; }
# Probe the EXACT spelling the driver invokes. Accepting an alternate spelling as proof
# would pass the probe and then die at the call site.
_cl_has_flag() {
  local pat
  _cl_load_help
  for pat in "$@"; do
    case "${_CL_HELP:-}" in *"$pat"*) return 0 ;; esac
  done
  return 1
}
_cl_capable() {   # <capability>
  case "$1" in
    json)   _cl_has_flag ' --json' ;;
    out)    _cl_has_flag '-o,' ' -o ' ;;          # both spellings of the SAME short flag
    schema) _cl_has_flag ' --output-schema' ;;
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
# key. Anything non-canonical is announced, and every id must look like an id, so a
# stray `session_id` on an error event cannot become the thread we resume.
_cl_id_ok() { case "${1:-}" in [0-9a-fA-F]*) [ ${#1} -ge 16 ] && case "$1" in *[!0-9a-fA-F-]*) return 1 ;; *) return 0 ;; esac ;; esac; return 1; }
_cl_grab_session() {  # <jsonl-file>  -> prints id, rc 1 when missing
  local json hit id shape
  # grep -a '^{' first: codex interleaves non-JSON stderr lines (ANSI ERROR spam) into
  # the jsonl and jq aborts at the first invalid line — seen live. The head bound keeps
  # this O(1) on a chatty stream; the thread event is always at the top.
  json="$(head -n 500 "$1" 2>/dev/null | grep -a '^{')"
  [ -n "$json" ] || return 1

  hit="$(printf '%s\n' "$json" | jq -r '
      select((.type // "") | test("^(thread\\.started|thread_started|session\\.created|session_configured)$"))
      | (if .type == "thread.started" and (.thread_id // "") != "" then "canonical" else "drifted" end)
        + "\t"
        + (.thread_id // .session_id // .conversation_id // .thread.id // .session.id // "")
      | select(endswith("\t") | not)' 2>/dev/null | head -1)"
  [ -n "$hit" ] || { _cl_log "no thread-start event in the stream — refusing to guess an id"; return 1; }

  shape="${hit%%	*}"; id="${hit#*	}"
  _cl_id_ok "$id" || { _cl_log "thread-start event carried an id that is not an id ('$id') — refusing"; return 1; }
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
_cl_plan_sha() { _cl_sha256_file "$CL_STATE/$1.plan.md"; }

# An identifier for the exact working state a review looked at: HEAD plus everything
# uncommitted. A review approval that no longer matches this describes a tree that has
# since moved.
# Untracked files need their CONTENT hashed, not just their names: `git status` and
# `git diff HEAD` both describe an edited untracked file identically before and after the
# edit, which would let a tree move underneath an approval unnoticed.
_cl_tree_id() {
  local head porc diff unt f
  head="$(git -C "$CL_REPO" rev-parse HEAD 2>/dev/null)" || return 1
  porc="$(git -C "$CL_REPO" status --porcelain=v1 -uall 2>/dev/null)"
  diff="$(git -C "$CL_REPO" diff HEAD 2>/dev/null)"
  unt=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    unt="$unt$f:$(git -C "$CL_REPO" hash-object -- "$f" 2>/dev/null)|"
  done <<EOF
$(git -C "$CL_REPO" ls-files --others --exclude-standard 2>/dev/null)
EOF
  printf '%s\n%s\n%s\n%s' "$head" "$porc" "$diff" "$unt" | _cl_sha256_stdin
}

cl_verdict() { jq -r '.verdict' "$CL_STATE/$1.${2:-review}.verdict" 2>/dev/null; }

# The one answer to "is this plan approved?". An approval describes the plan text that
# was read, so it is void unless the file still hashes to it. Every branch here fails
# CLOSED: a missing plan, a missing digest, or a digest that cannot be computed all mean
# "not approved", never "no mismatch found".
cl_plan_approved() {  # <slug>
  local v="$CL_STATE/$1.plan.verdict" recorded now
  [ -f "$v" ] || return 1
  [ "$(cl_verdict "$1" plan)" = approve ] || return 1
  recorded="$(jq -r '.plan_sha256 // empty' "$v" 2>/dev/null)"
  [ -n "$recorded" ] || { _cl_log "$1: the approval carries no plan digest — re-approve"; return 1; }
  now="$(_cl_plan_sha "$1")" || { _cl_log "$1: cannot hash the plan (missing file or no sha256 tool) — approval void"; return 1; }
  [ "$recorded" = "$now" ] || { _cl_log "$1: the approved plan has CHANGED on disk since it was approved — re-read it and re-approve"; return 1; }
  return 0
}

# The same question for gate 2, against the tree instead of the plan. This is what makes
# the review a gate rather than a note: cl_release consumes it.
cl_review_approved() {  # <slug>
  local v="$CL_STATE/$1.review.verdict" recorded now base rbase
  [ -f "$v" ] || return 1
  [ "$(cl_verdict "$1" review)" = approve ] || return 1
  base="$(_cl_base "$1")" || return 1
  rbase="$(jq -r '.base_sha // empty' "$v" 2>/dev/null)"
  [ "$rbase" = "$base" ] || { _cl_log "$1: the review approved a different base ($rbase vs $base) — re-review"; return 1; }
  recorded="$(jq -r '.tree_id // empty' "$v" 2>/dev/null)"
  [ -n "$recorded" ] || { _cl_log "$1: the review approval carries no tree id — re-review"; return 1; }
  now="$(_cl_tree_id)" || { _cl_log "$1: cannot identify the current tree — approval void"; return 1; }
  [ "$recorded" = "$now" ] || { _cl_log "$1: the tree has CHANGED since it was reviewed — re-review before releasing"; return 1; }
  return 0
}

# ------------------------------------------------------------- codex drivers ----
# Every `codex exec` in this file goes through one of these, so the flag contract lives
# in one place.
#
#   codex-cli 0.144.5: `codex exec resume <id> -C <dir> -s <sandbox> -o <out>` is INVALID.
#   The resume subcommand accepts only -c/-m/--enable etc.; global flags (-C/-s/-o) must
#   come BEFORE `resume`, and the session carries its original cwd+sandbox anyway. Flags
#   after `resume` fail with "unexpected argument" and the lane dies silently in its log
#   — discovered live (cost: 3 lanes x 5h). ALWAYS tail the log within a minute.
_cl_codex_resume() {  # <slug> <label> <prompt>   — caller holds the writer lock
  local slug="$1" label="$2" prompt="$3" sess
  _cl_require "${label}[$slug]" resume json out || return 2
  _cl_check_writable_roots || return 2
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

# A review must not read a tree that a writer is currently editing.
_cl_no_writer_running() {  # <ctx>
  [ -d "$CL_LOCK" ] || return 0
  [ -n "${CL_ALLOW_CONCURRENT_REVIEW:-}" ] && { _cl_log "$1: writer lock is held; reviewing anyway (CL_ALLOW_CONCURRENT_REVIEW)"; return 0; }
  _cl_log "$1 REFUSED: an implementation is writing this tree right now. Reviewing it would judge a half-written file. Wait, or review a separate worktree."
  return 2
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
  if printf '' | _cl_sha256_stdin >/dev/null 2>&1; then printf '  ok   sha256 available\n'
  else printf '  MISS sha256 no shasum/sha256sum/openssl — approvals cannot be bound to content\n'; ok=1; fi
  ver="$(_cl_codex_version)"; fam="$(_cl_codex_family "$ver")"
  printf '  codex version: %s\n' "${ver:-?}"
  if _cl_family_tested "$fam"; then printf '  ok   compat  %s is a tested family\n' "$fam"
  else printf '  warn compat  %s is outside the tested set (%s) — the probes below are what matter\n' "${fam:-unknown}" "$CL_CODEX_TESTED"; fi
  _cl_doctor_cap json   'exec --json'          || ok=1
  _cl_doctor_cap out    'exec -o'              || ok=1
  _cl_doctor_cap schema 'exec --output-schema' || ok=1
  _cl_doctor_cap resume 'exec resume'          || ok=1
  _cl_check_writable_roots || ok=1
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
  local slug="${1:-}" brief="${2:-}"
  _cl_slug_ok "$slug" || return 2
  [ -f "$brief" ] || { _cl_log "usage: cl_plan <slug> <brief.md>"; return 2; }
  local out="$CL_STATE/${slug}.plan.md" jl="$CL_STATE/${slug}.plan.jsonl" brieftext
  _cl_compat_check
  _cl_require "plan[$slug]" json out || return 2
  _cl_check_writable_roots || return 2
  # read the brief before the call: a read failure inside the heredoc would be invisible
  # in the command's exit status and Codex would plan from an empty brief
  brieftext="$(cat "$brief")" || { _cl_log "plan[$slug] REFUSED: cannot read $brief"; return 2; }
  [ -n "$brieftext" ] || { _cl_log "plan[$slug] REFUSED: $brief is empty"; return 2; }
  _cl_log "plan[$slug]: codex authoring execution plan from $brief"
  codex exec $(_cl_model_flag "$CL_PLAN_MODEL") -C "$CL_REPO" -s "$CL_PLAN_SANDBOX" --json \
    -o "$out" - > "$jl" 2>&1 <<EOF
You are the IMPLEMENTER on a locked engineering loop. Read the brief below and
author a DETAILED execution plan you will implement next in THIS same thread.
Cover: exact files to add/change, contracts/interfaces, migrations, the test
plan, failure modes, and any open questions. Do NOT write code yet — plan only.
Be concrete and honest about risk. End with a line: READY: yes  (or READY: no + why).

===== BRIEF =====
$brieftext
EOF
  [ $? -eq 0 ] || { _cl_log "plan[$slug] FAILED (see $jl)"; return 1; }
  local sid
  sid="$(_cl_grab_session "$jl")" || { _cl_log "plan[$slug] FAILED: no usable thread id in $jl — thread not resumable, aborting"; return 1; }
  printf '%s\n' "$sid" > "$CL_STATE/${slug}.session"
  # a fresh plan invalidates everything downstream of it: both verdicts, the recorded
  # base, and the marker saying an implementation of the OLD plan succeeded
  rm -f "$CL_STATE/${slug}.plan.verdict" "$CL_STATE/${slug}.review.verdict" \
        "$CL_STATE/${slug}.base.sha" "$CL_STATE/${slug}.impl.ok"
  _cl_log "plan[$slug]: plan -> $out ; thread $sid (verdicts, base and impl marker cleared)"
  printf '%s\n' "$out"
}

# ------------------------------------------- 2. The orchestrator approves the plan --
# cl_gate_plan <slug>   (ORCHESTRATOR judgment — Claude reads & decides)
#   Prints the plan for Claude to read. Claude writes the verdict by calling
#   cl_record_verdict <slug> plan approve|revise "notes". Returns 0 if approved.
cl_gate_plan() {
  local slug="${1:-}"
  _cl_slug_ok "$slug" || return 2
  cat "$CL_STATE/${slug}.plan.md" || return 2
  cl_plan_approved "$slug"
}
cl_record_verdict() {  # <slug> <phase:plan|review> <approve|revise> [notes]
  local slug="${1:-}" phase="${2:-}" verdict="${3:-}" notes="${4:-}"
  _cl_slug_ok "$slug" || return 2
  case "$phase"   in plan|review) ;; *) _cl_log "record_verdict: bad phase '$phase'"; return 2 ;; esac
  case "$verdict" in approve|revise) ;; *) _cl_log "record_verdict: bad verdict '$verdict'"; return 2 ;; esac
  local psha bsha tid
  psha="$(_cl_plan_sha "$slug" || true)"
  bsha="$(_cl_base "$slug" || true)"
  tid="$(_cl_tree_id || true)"
  # An approval must be bindable to what was judged. Refuse to record one that cannot be.
  if [ "$verdict" = approve ]; then
    case "$phase" in
      plan)   [ -n "$psha" ] || { _cl_log "record_verdict: cannot hash the plan, so this approval could never be verified — refusing"; return 2; } ;;
      review) [ -n "$bsha" ] || { _cl_log "record_verdict: no base sha (did impl run?) — refusing to record a review approval"; return 2; }
              [ -n "$tid"  ] || { _cl_log "record_verdict: cannot identify the tree — refusing to record a review approval"; return 2; } ;;
    esac
  fi
  jq -n --arg v "$verdict" --arg s "$notes" --arg p "$psha" --arg b "$bsha" --arg d "$tid" \
        --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{verdict:$v, summary:$s, blocking:[], plan_sha256:$p, base_sha:$b, tree_id:$d, at:$t}' \
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
  local slug="${1:-}"
  local base rc plantext
  _cl_slug_ok "$slug" || return 2
  cl_plan_approved "$slug" || { _cl_log "impl[$slug] REFUSED: plan not approved (cl_record_verdict $slug plan approve first)"; return 2; }
  _cl_compat_check
  # refuse before taking the lock or recording a base sha, not halfway through
  _cl_require "impl[$slug]" resume json out || return 2
  _cl_session "$slug" >/dev/null || return 2
  plantext="$(cat "$CL_STATE/${slug}.plan.md")" || return 2
  # the implementation starts over: any earlier review approval and success marker are void
  rm -f "$CL_STATE/${slug}.review.verdict" "$CL_STATE/${slug}.impl.ok"
  _cl_lock_acquire || return 2    # one writer only (mkdir lock; macOS has no flock)
  _cl_log "impl[$slug]: implementing approved plan (writer lock held)"
  local dirty; dirty="$(git -C "$CL_REPO" status --porcelain=v1 -uall 2>/dev/null | wc -l | tr -d ' ')"
  [ "${dirty:-0}" != "0" ] && _cl_log "impl[$slug]: WARNING $dirty pre-existing dirty/untracked paths — the review will see them too"
  base="$(git -C "$CL_REPO" rev-parse HEAD)" || { _cl_lock_release; _cl_log "impl[$slug] FAILED: cannot resolve HEAD"; return 2; }
  echo "$base" > "$CL_STATE/${slug}.base.sha"
  # The APPROVED PLAN TEXT travels with the instruction. The thread wrote that plan, but a
  # human may have edited and re-approved the file, and the file is what was approved.
  _cl_codex_resume "$slug" impl \
    "Implement the approved plan. It is reproduced below verbatim; where it differs from \
what you drafted earlier in this thread, THIS TEXT WINS. Make the code changes and run \
the relevant tests. Report exactly what changed and any deviations with their justification.

===== APPROVED PLAN =====
$plantext"
  rc=$?
  _cl_lock_release
  if [ $rc -eq 0 ]; then
    echo "$base" > "$CL_STATE/${slug}.impl.ok"     # the marker review requires
    _cl_log "impl[$slug]: done (base $base)"
  else
    _cl_log "impl[$slug] FAILED ($CL_STATE/${slug}.impl.jsonl) — no success marker written"
  fi
  return $rc
}

# cl_revise <slug> "<blocking items>"  — send the review back into the SAME thread.
cl_revise() {
  local slug="${1:-}" notes="${2:-}" rc
  _cl_slug_ok "$slug" || return 2
  [ -n "$notes" ] || { _cl_log "usage: cl_revise <slug> \"<blocking items>\""; return 2; }
  _cl_compat_check
  _cl_require "revise[$slug]" resume json out || return 2
  _cl_session "$slug" >/dev/null || return 2
  # the tree is about to move: the review approval and the success marker are void
  rm -f "$CL_STATE/${slug}.review.verdict" "$CL_STATE/${slug}.impl.ok"
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
  if [ $rc -eq 0 ]; then
    _cl_base "$slug" > "$CL_STATE/${slug}.impl.ok" 2>/dev/null
    _cl_log "revise[$slug]: done — re-review required"
  else
    _cl_log "revise[$slug] FAILED"
  fi
  return $rc
}

# ---------------------------------------- 4. The orchestrator reviews the diff -------
# cl_review_human <slug>   — rich human-readable review Claude reads.
#   NOTE codex-cli 0.144.2: `codex review --base <sha> "<prompt>"` is INVALID (--base
#   cannot combine with a prompt). Use `codex exec` and let the reviewer run `git diff`.
cl_review_human() {
  local slug="${1:-}" base
  _cl_slug_ok "$slug" || return 2
  [ -f "$CL_STATE/${slug}.impl.ok" ] || { _cl_log "review[$slug] REFUSED: no successful implementation to review (run cl_impl, or check why it failed)"; return 2; }
  base="$(_cl_base "$slug")" || { _cl_log "review[$slug] REFUSED: no base sha"; return 2; }
  _cl_no_writer_running "review[$slug]" || return 2
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
  local slug="${1:-}" base tmp v nblock tid
  local jl="$CL_STATE/${slug}.review.jsonl"
  _cl_slug_ok "$slug" || return 2
  [ -f "$CL_STATE/${slug}.impl.ok" ] || { _cl_log "gate[$slug]: no successful implementation to review"; return 2; }
  base="$(_cl_base "$slug")" || { _cl_log "gate[$slug]: no base sha (did impl run?)"; return 2; }
  _cl_no_writer_running "gate[$slug]" || return 2
  _cl_compat_check
  _cl_require "gate[$slug]" schema json out || return 2
  # A review attempt invalidates the standing approval BEFORE it runs. If this attempt
  # dies, the slug is left unapproved — never carrying an approval for an older tree.
  rm -f "$CL_STATE/${slug}.review.verdict"
  tid="$(_cl_tree_id)" || { _cl_log "gate[$slug]: cannot identify the tree"; return 2; }
  tmp="$(mktemp "$CL_STATE/${slug}.review.XXXXXX")" || return 2
  _cl_log "review[$slug]: autonomous codex gate (base $base)"
  codex exec $(_cl_model_flag "$CL_REVIEW_MODEL") -C "$CL_REPO" -s "$CL_REVIEW_SANDBOX" --json \
    --output-schema "$CL_VERDICT_SCHEMA" -o "$tmp" - > "$jl" 2>&1 <<EOF
$(_cl_review_prompt "$slug" "$base")
Default to verdict="revise" unless you are confident it is correct, faithful to the plan,
honest on failure, and leaks no secrets or cross-tenant data. Every blocking item needs a
concrete fix. approve REQUIRES an empty blocking list.
EOF
  if [ $? -ne 0 ]; then _cl_log "gate[$slug]: codex failed (slug left UNAPPROVED)"; rm -f "$tmp"; return 2; fi
  # Validate the shape independently of the schema: a `blocking` that is not an array
  # would make a length query fail, and a failed count must never read as zero blockers.
  jq -e 'type=="object" and (.verdict|type=="string") and (.blocking|type=="array")' "$tmp" >/dev/null 2>&1 \
    || { _cl_log "gate[$slug]: verdict JSON is not the documented shape — refusing"; rm -f "$tmp"; return 2; }
  v="$(jq -r '.verdict' "$tmp" 2>/dev/null)"
  nblock="$(jq -r '.blocking | length' "$tmp" 2>/dev/null)"
  case "$nblock" in ''|*[!0-9]*) _cl_log "gate[$slug]: cannot count blocking items — refusing"; rm -f "$tmp"; return 2 ;; esac
  case "$v" in
    approve)
      if [ "$nblock" != "0" ]; then
        _cl_log "gate[$slug]: approve carried blockers — downgrading to revise"
        v=revise
        # persist the downgrade: cl_verdict reads the FILE, so a variable-only downgrade
        # would let the next reader see "approve" (rubber-stamp hole).
        jq '.verdict="revise"' "$tmp" > "$tmp.dg" && mv "$tmp.dg" "$tmp" || { _cl_log "gate[$slug]: could not persist downgrade"; rm -f "$tmp" "$tmp.dg"; return 2; }
      fi ;;
    revise) ;;
    *) _cl_log "gate[$slug]: invalid verdict '$v'"; rm -f "$tmp"; return 2 ;;
  esac
  # bind the verdict to what was reviewed, so cl_release can tell if the tree moved after
  jq --arg b "$base" --arg d "$tid" '. + {base_sha:$b, tree_id:$d}' "$tmp" > "$tmp.b" && mv "$tmp.b" "$tmp" \
    || { _cl_log "gate[$slug]: could not bind the verdict to the tree"; rm -f "$tmp" "$tmp.b"; return 2; }
  mv "$tmp" "$CL_STATE/${slug}.review.verdict"
  printf '%s\n' "$v"
  [ "$v" = approve ]
}

# -------------------------------------------------------------- 5. release ----
# cl_release <slug>  — the consumer of gate 2. It ships nothing itself; it answers
# "is this slug releasable right now", and refuses when the answer is no.
cl_release() {
  local slug="${1:-}"
  _cl_slug_ok "$slug" || return 2
  cl_plan_approved   "$slug" || { _cl_log "release[$slug] REFUSED: the plan approval is not valid"; return 2; }
  [ -f "$CL_STATE/${slug}.impl.ok" ] || { _cl_log "release[$slug] REFUSED: no successful implementation"; return 2; }
  cl_review_approved "$slug" || { _cl_log "release[$slug] REFUSED: the review approval is not valid for this tree"; return 2; }
  _cl_log "release[$slug]: both gates hold for the current tree — changelog, tag, merge, deploy"
  return 0
}

# --------------------------------------------------------------- writer lock ----
# Atomic mkdir (macOS ships no flock). A stale holder is reclaimed by RENAMING the lock,
# so two waiters that both spot the same dead pid cannot both proceed: only one rename
# succeeds, and the loser's next mkdir finds the winner's fresh lock.
# Traps are installed ONLY when this file is dispatched as a script — a sourced harness
# must never clobber the calling shell's EXIT/INT traps. When sourced, every return path
# releases the lock explicitly.
CL_DISPATCHED="${CL_DISPATCHED:-0}"
_cl_lock_acquire() {
  local waited=0 holder stale
  case "$CL_LOCK" in "$CL_STATE"/*) ;; *) _cl_log "refusing to use a lock outside the state dir: $CL_LOCK"; return 1 ;; esac
  while ! mkdir "$CL_LOCK" 2>/dev/null; do
    holder=''; read -r holder 2>/dev/null < "$CL_LOCK/pid"
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      stale="$CL_LOCK.stale.$$.$waited"
      if mv "$CL_LOCK" "$stale" 2>/dev/null; then
        _cl_log "lock: stale holder pid=$holder — reclaimed"; rm -rf "$stale"
      fi
      continue                       # loser of the race just retries mkdir
    fi
    [ "$waited" -eq 0 ] && _cl_log "lock: writer busy (pid=${holder:-?}) — waiting"
    # 5s against a multi-minute codex run: invisible latency, no busy-wait
    sleep 5; waited=$((waited+5))
    if [ "$waited" -ge "${CL_LOCK_TIMEOUT:-7200}" ]; then _cl_log "lock: gave up after ${CL_LOCK_TIMEOUT:-7200}s (pid=${holder:-?})"; return 1; fi
  done
  echo $$ > "$CL_LOCK/pid"
  if [ "$CL_DISPATCHED" = 1 ]; then
    trap '_cl_lock_release' EXIT
    trap '_cl_lock_release; exit 130' INT
    trap '_cl_lock_release; exit 143' TERM
  fi
  return 0
}
_cl_lock_release() {
  local holder=''
  read -r holder 2>/dev/null < "$CL_LOCK/pid"
  # only the owner may unlock: an unconditional rm here would delete a lock another
  # process legitimately acquired after ours was reclaimed
  if [ -z "$holder" ] || [ "$holder" = "$$" ]; then rm -rf "$CL_LOCK" 2>/dev/null; fi
  [ "$CL_DISPATCHED" = 1 ] && trap - EXIT INT TERM
  return 0
}

# --------------------------------------------------------------------- status ----
cl_status() {   # [slug]
  local sessions f slug base
  # `find`, not a glob: an unmatched glob is a hard error under zsh, which would abort
  # before the "nothing here yet" branch could run
  sessions="$(find "$CL_STATE" -maxdepth 1 -name '*.session' 2>/dev/null | sort)"
  printf '%-24s %-8s %-8s %-9s %s\n' SLUG PLAN REVIEW IMPL BASE
  [ -n "$sessions" ] || { echo "(no slugs yet in $CL_STATE)"; return 0; }
  printf '%s\n' "$sessions" | while read -r f; do
    slug="${f##*/}"; slug="${slug%.session}"
    [ -n "${1:-}" ] && [ "$1" != "$slug" ] && continue
    base="$(_cl_base "$slug" || echo '-')"
    printf '%-24s %-8s %-8s %-9s %s\n' "$slug" \
      "$(cl_plan_approved "$slug" 2>/dev/null && echo approve || cl_verdict "$slug" plan || echo -)" \
      "$(cl_review_approved "$slug" 2>/dev/null && echo approve || cl_verdict "$slug" review || echo -)" \
      "$([ -f "$CL_STATE/${slug}.impl.ok" ] && echo ok || echo -)" \
      "$(printf '%s' "$base" | cut -c1-8)"
  done
}

# ------------------------------------------------------- driver: one wave ------
# cl_wave <slug> <brief_file>   — RESUMABLE sequential driver. It advances one step per
# call and stops at whichever gate needs your judgment, so you call it again after
# approving. rc 3 means "your turn"; rc 0 means both gates hold.
cl_wave() {
  local slug="${1:-}" brief="${2:-}"
  _cl_slug_ok "$slug" || return 2
  if [ ! -f "$CL_STATE/${slug}.plan.md" ]; then
    cl_plan "$slug" "$brief" || return 1
    _cl_log "wave[$slug]: PLAN READY — read it, then: cl_record_verdict $slug plan approve|revise  (then re-run cl_wave)"
    return 3
  fi
  if ! cl_plan_approved "$slug"; then
    _cl_log "wave[$slug]: waiting on the plan gate — read $CL_STATE/${slug}.plan.md, then cl_record_verdict $slug plan approve|revise"
    return 3
  fi
  if [ ! -f "$CL_STATE/${slug}.impl.ok" ]; then
    cl_impl "$slug" || return 1
    _cl_log "wave[$slug]: IMPL DONE — review it (cl_review_human $slug), then cl_record_verdict $slug review approve|revise (then re-run cl_wave)"
    return 3
  fi
  if ! cl_review_approved "$slug"; then
    _cl_log "wave[$slug]: waiting on the review gate — cl_review_human $slug, then cl_record_verdict $slug review approve|revise"
    return 3
  fi
  _cl_log "wave[$slug]: both gates hold for the current tree — release it (cl_release $slug)"
  return 0
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
CL_CMDS="doctor plan gate_plan record_verdict impl review_human codex_gate revise verdict status release wave selfreview"
if [ -n "${BASH_VERSION:-}" ] && [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  set -uo pipefail
  CL_DISPATCHED=1          # now the lock may own the shell's EXIT/INT traps
  cmd="${1:-}"; shift || true
  case " $CL_CMDS " in
    *" ${cmd:-—} "*) "cl_$cmd" "$@" ;;
    *) echo "usage: bash ${0##*/} {${CL_CMDS// /|}} ..." >&2; exit 2 ;;
  esac
fi
