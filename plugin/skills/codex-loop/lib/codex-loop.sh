#!/usr/bin/env bash
# codex-loop.sh — a gated plan → approve → implement → review loop around Codex CLI.
#
#   Claude plans (brief) → Codex plans (persistent thread) → Claude APPROVES the plan
#   → Codex implements (SAME thread) → Claude REVIEWS the diff vs the plan → release.
#
#   Pipelined: implementation (the single writer) is serialized by a lock; planning of
#   the NEXT brief and review of the PREVIOUS diff (both read-only) overlap it, so
#   Codex is never idle and the orchestrator is never blocked.
#
# Substrate: pure bash around `codex exec` + `codex exec resume` (persistent threads)
# + `--output-schema` (parseable verdict gates). No framework, no MCP, no daemon.
#
# The ORCHESTRATOR (Claude, in the session that loaded this skill) owns the two
# judgment gates: cl_gate_plan (approve the plan) and cl_gate_review (approve the
# diff). Those gates are Claude reading prose and deciding. For fully-autonomous
# runs, cl_codex_gate stands in a Codex reviewer that emits the same verdict JSON.
#
# Requires: codex-cli >= 0.144, jq, git. Bash 3.2 safe (macOS default bash).

# strict mode only when dispatched (sourcing shells — incl. zsh — must not be poisoned)

# ------------------------------------------------------------------ config ----
# Default target repo: the git root of the current directory, else $PWD.
CL_REPO="${CL_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
CL_STATE="${CL_STATE:-$HOME/.codex-loop/$(basename "$CL_REPO")}"
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
CL_LOCK="$CL_STATE/impl.lock"                   # serializes the single writer

mkdir -p "$CL_STATE"
umask 077

# The $(_cl_*_flag) call sites below are deliberately UNQUOTED — they expand to zero
# words or to a flag pair. Quoting them passes an empty string as an argument and codex
# rejects it. shellcheck disable=SC2046 is intentional throughout this file.

# Bash-3.2 safe (macOS default bash rejects printf %(..)T)
_cl_log() { printf '[codex-loop %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
_cl_model_flag() { [ -n "$1" ] && printf -- '-m %s' "$1"; }
# Extra writable roots for the sandbox (single path). Needed when CL_REPO is a LINKED
# WORKTREE: commits write refs/objects into the parent repo's .git, outside the
# workspace — seen live as `cannot lock ref`.
_cl_writable_flag() { [ -n "$CL_WRITABLE_ROOTS" ] && printf -- '-c sandbox_workspace_write.writable_roots=["%s"]' "$CL_WRITABLE_ROOTS"; }
# CL_NET=1 grants the sandbox network access (npm installs, a DB on loopback) —
# needed for test gates that talk to a local service.
_cl_net_flag() { [ -n "$CL_NET" ] && printf -- '-c sandbox_workspace_write.network_access=true'; }

# Capture the codex thread id from a --json event stream. 0.144.x emits exactly
# {"type":"thread.started","thread_id":"<uuid>"} — parse ONLY that; rc 1 if absent.
_cl_grab_session() {  # <jsonl-file>  -> prints uuid, rc 1 when missing
  local id
  # grep -a '^{' first: codex interleaves non-JSON stderr lines (ANSI ERROR spam)
  # into the jsonl and jq aborts at the first invalid line — seen live.
  id="$(grep -a '^{' "$1" 2>/dev/null | jq -r 'select(.type=="thread.started") | .thread_id' 2>/dev/null | head -1)"
  case "$id" in ""|null) return 1 ;; esac
  printf '%s\n' "$id"
}

# Writer lock: atomic mkdir (macOS ships no flock). Stale holder reclaimed by pid.
# Traps are installed ONLY when this file is dispatched as a script — a sourced
# harness must never clobber the calling shell's EXIT/INT traps. When sourced, every
# return path releases the lock explicitly, and a lock orphaned by Ctrl-C is reclaimed
# by the next run's stale-pid check.
CL_DISPATCHED="${CL_DISPATCHED:-0}"
_cl_lock_acquire() {
  local waited=0 holder
  while ! mkdir "$CL_LOCK.d" 2>/dev/null; do
    holder="$(cat "$CL_LOCK.d/pid" 2>/dev/null || echo '?')"
    if [ "$holder" != "?" ] && ! kill -0 "$holder" 2>/dev/null; then
      _cl_log "lock: stale holder pid=$holder — reclaiming"; rm -rf "$CL_LOCK.d"; continue
    fi
    [ "$waited" -eq 0 ] && _cl_log "lock: writer busy (pid=$holder) — waiting"
    sleep 5; waited=$((waited+5))
    if [ "$waited" -ge "${CL_LOCK_TIMEOUT:-7200}" ]; then _cl_log "lock: gave up after ${CL_LOCK_TIMEOUT:-7200}s (pid=$holder)"; return 1; fi
  done
  echo $$ > "$CL_LOCK.d/pid"
  [ "$CL_DISPATCHED" = 1 ] && trap '_cl_lock_release' EXIT INT TERM
  return 0
}
_cl_lock_release() {
  rm -rf "$CL_LOCK.d" 2>/dev/null
  [ "$CL_DISPATCHED" = 1 ] && trap - EXIT INT TERM
  return 0
}

# ------------------------------------------------------------------ doctor ----
# cl_doctor — verify the substrate before trusting the loop.
cl_doctor() {
  local ok=0
  for bin in codex jq git; do
    if command -v "$bin" >/dev/null 2>&1; then printf '  ok   %-6s %s\n' "$bin" "$(command -v $bin)"
    else printf '  MISS %-6s not on PATH\n' "$bin"; ok=1; fi
  done
  printf '  codex version: %s\n' "$(codex --version 2>/dev/null || echo '?')"
  printf '  repo:   %s\n' "$CL_REPO"
  printf '  state:  %s\n' "$CL_STATE"
  printf '  schema: %s%s\n' "$CL_VERDICT_SCHEMA" "$([ -f "$CL_VERDICT_SCHEMA" ] || echo '  (MISSING)')"
  git -C "$CL_REPO" rev-parse HEAD >/dev/null 2>&1 || { printf '  MISS repo is not a git worktree\n'; ok=1; }
  [ -f "$CL_VERDICT_SCHEMA" ] || ok=1
  return $ok
}

# ------------------------------------------------------ 1. Codex plans ---------
# cl_plan <slug> <brief_file>
#   Opens a fresh persistent Codex thread, hands it the brief, and has Codex author
#   a detailed execution plan (prose) that the SAME thread will later implement.
#   Stores the thread id so implementation resumes with full context.
cl_plan() {
  local slug="$1" brief="$2"
  [ -n "$slug" ] && [ -f "${brief:-}" ] || { _cl_log "usage: cl_plan <slug> <brief.md>"; return 2; }
  local out="$CL_STATE/${slug}.plan.md" sess="$CL_STATE/${slug}.session" jl="$CL_STATE/${slug}.plan.jsonl"
  _cl_log "plan[$slug]: codex authoring execution plan from $brief"
  codex exec $(_cl_model_flag "$CL_PLAN_MODEL") -C "$CL_REPO" -s "$CL_PLAN_SANDBOX" --json \
    -o "$out" - < <(cat <<EOF
You are the IMPLEMENTER on a locked engineering loop. Read the brief below and
author a DETAILED execution plan you will implement next in THIS same thread.
Cover: exact files to add/change, contracts/interfaces, migrations, the test
plan, failure modes, and any open questions. Do NOT write code yet — plan only.
Be concrete and honest about risk. End with a line: READY: yes  (or READY: no + why).

===== BRIEF =====
$(cat "$brief")
EOF
) > "$jl" 2>&1 || { _cl_log "plan[$slug] FAILED (see $jl)"; return 1; }
  local sid
  sid="$(_cl_grab_session "$jl")" || { _cl_log "plan[$slug] FAILED: no thread.started id in $jl — thread not resumable, aborting"; return 1; }
  printf '%s\n' "$sid" > "$sess"
  # a fresh plan invalidates any earlier approvals for this slug
  rm -f "$CL_STATE/${slug}.plan.verdict" "$CL_STATE/${slug}.review.verdict"
  _cl_log "plan[$slug]: plan -> $out ; session $sid (stale verdicts cleared)"
  printf '%s\n' "$out"
}

# ------------------------------------------- 2. The orchestrator approves the plan --
# cl_gate_plan <slug>   (ORCHESTRATOR judgment — Claude reads & decides)
#   Prints the plan for Claude to read. Claude writes the verdict by calling
#   cl_record_verdict <slug> plan approve|revise "notes". Returns 0 if approved.
cl_gate_plan() {
  # two `local` statements on purpose: zsh expands a whole `local` line BEFORE
  # assigning, so ${slug} on the same line as slug="$1" is EMPTY under zsh.
  local slug="$1"
  local v="$CL_STATE/${slug}.plan.verdict"
  cat "$CL_STATE/${slug}.plan.md"
  [ -f "$v" ] && [ "$(jq -r .verdict "$v" 2>/dev/null)" = approve ]
}
cl_record_verdict() {  # <slug> <phase:plan|review> <approve|revise> [notes]
  local slug="$1" phase="$2" verdict="$3" notes="${4:-}"
  case "$phase"   in plan|review) ;; *) _cl_log "record_verdict: bad phase '$phase'"; return 2 ;; esac
  case "$verdict" in approve|revise) ;; *) _cl_log "record_verdict: bad verdict '$verdict'"; return 2 ;; esac
  local plansha="" base=""
  [ -f "$CL_STATE/${slug}.plan.md" ] && plansha="$(shasum -a 256 "$CL_STATE/${slug}.plan.md" 2>/dev/null | awk '{print $1}')"
  [ -f "$CL_STATE/${slug}.base.sha" ] && base="$(cat "$CL_STATE/${slug}.base.sha")"
  jq -n --arg v "$verdict" --arg s "$notes" --arg p "$plansha" --arg b "$base" \
    --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{verdict:$v, summary:$s, blocking:[], plan_sha256:$p, base_sha:$b, at:$t}' \
    > "$CL_STATE/${slug}.${phase}.verdict"
}

# --------------------------------------------- 3. Codex implements the plan ----
# cl_impl <slug>
#   Resumes the SAME thread (plan context intact) and implements the approved plan.
#   Serialized by CL_LOCK so only one writer touches the tree at a time.
cl_impl() {
  # NOTE two local statements: zsh expands a whole `local` line BEFORE assigning,
  # so ${slug} on the same line as slug="$1" is EMPTY under zsh (bash is fine).
  # Cost discovered live: impl logs landed in a slugless ".impl.jsonl".
  local slug="$1" sess
  local jl="$CL_STATE/${slug}.impl.jsonl" out="$CL_STATE/${slug}.impl.md"
  [ "$(cl_verdict "$slug" plan)" = approve ] || { _cl_log "impl[$slug] REFUSED: plan not approved (cl_record_verdict $slug plan approve first)"; return 2; }
  sess="$(cat "$CL_STATE/${slug}.session" 2>/dev/null)"
  [ -n "$sess" ] || { _cl_log "impl[$slug] REFUSED: no stored session id — re-run cl_plan (never resume --last: another thread may be newer)"; return 2; }
  _cl_lock_acquire || return 2    # one writer only (mkdir lock; macOS has no flock)
  _cl_log "impl[$slug]: implementing approved plan (writer lock held, session $sess)"
  if ! git -C "$CL_REPO" diff --quiet 2>/dev/null; then
    _cl_log "impl[$slug]: WARNING dirty baseline — review will include pre-existing changes"
  fi
  local base; base="$(git -C "$CL_REPO" rev-parse HEAD)" || { _cl_lock_release; _cl_log "impl[$slug] FAILED: cannot resolve HEAD"; return 2; }
  echo "$base" > "$CL_STATE/${slug}.base.sha"
  codex exec $(_cl_model_flag "$CL_IMPL_MODEL") $(_cl_writable_flag) $(_cl_net_flag) -C "$CL_REPO" -s "$CL_SANDBOX" --json \
    -o "$out" resume "$sess" \
    "Implement the plan you authored earlier in this thread (the approved plan). \
Make the code changes and run the relevant tests. Report exactly what changed \
and any deviations from the plan with their justification." > "$jl" 2>&1
  local rc=$?
  _cl_lock_release
  [ $rc -eq 0 ] && _cl_log "impl[$slug]: done (base $base)" || _cl_log "impl[$slug] FAILED ($jl)"
  return $rc
}

# ---------------------------------------- 4. The orchestrator reviews the diff -------
# cl_review_human <slug>   — rich human-readable review Claude reads.
#   NOTE codex-cli 0.144.2: `codex review --base <sha> "<prompt>"` is INVALID
#   (--base cannot combine with a prompt). Use `codex exec` and let the reviewer
#   run `git diff` itself.
#   NOTE codex-cli 0.144.5: `codex exec resume <id> -C <dir> -s <sandbox> -o <out>`
#   is INVALID — the resume subcommand only accepts -c/-m/--enable etc.; global
#   flags (-C/-s/-o) must come BEFORE `resume` (as cl_impl above does), and the
#   session carries its original cwd+sandbox anyway. Flags after `resume` fail with
#   "unexpected argument" and the lane dies silently in its log — discovered live
#   (cost: 3 lanes x 5h). ALWAYS tail the log within a minute of launching a lane.
cl_review_human() {
  local slug="$1" base; base="$(cat "$CL_STATE/${slug}.base.sha" 2>/dev/null)"
  codex exec $(_cl_model_flag "$CL_REVIEW_MODEL") -C "$CL_REPO" -s "$CL_REVIEW_SANDBOX" - <<EOF
Adversarially review the changes since ${base:-HEAD} STRICTLY against the
approved plan at $CL_STATE/${slug}.plan.md. Run: git diff ${base:-HEAD} (and
git log --oneline ${base:-HEAD}..HEAD) to see what changed; read any file you
need. Flag: correctness/safety holes, plan deviations, fake-success/silent-
degrade, secret leaks, cross-tenant reads. Severity-ranked findings with
file:line + concrete fix each; end with verdict: approve or revise.
EOF
}

# cl_codex_gate <slug>   — AUTONOMOUS fallback reviewer -> parseable verdict JSON.
#   Use only when no orchestrator/human is available to judge.
cl_codex_gate() {  # rc: 0 approve · 1 revise · 2 infra failure
  local slug="$1" base tmp          # jl below needs its own statement (zsh, see cl_impl)
  local jl="$CL_STATE/${slug}.review.jsonl"
  base="$(cat "$CL_STATE/${slug}.base.sha" 2>/dev/null)"
  [ -n "${base:-}" ] || { _cl_log "gate[$slug]: no base sha (did impl run?)"; return 2; }
  tmp="$(mktemp "$CL_STATE/${slug}.review.XXXXXX")" || return 2
  _cl_log "review[$slug]: autonomous codex gate (base $base)"
  codex exec $(_cl_model_flag "$CL_REVIEW_MODEL") -C "$CL_REPO" -s "$CL_REVIEW_SANDBOX" --json \
    --output-schema "$CL_VERDICT_SCHEMA" -o "$tmp" - < <(cat <<EOF
Adversarially review ALL changes since $base against the approved plan at
$CL_STATE/${slug}.plan.md. Inspect the real diff yourself: git log --oneline $base..HEAD,
git diff $base (covers committed + working tree), git status --short (untracked files count
too — a new-files-only implementation is NOT an empty change). Default to verdict="revise"
unless you are confident it is correct, faithful to the plan, honest on failure, and leaks
no secrets or cross-tenant data. Every blocking item needs a concrete fix.
approve REQUIRES an empty blocking list.
EOF
) > "$jl" 2>&1
  local rc=$?
  if [ $rc -ne 0 ]; then _cl_log "gate[$slug]: codex failed rc=$rc (stale verdicts NOT reused)"; rm -f "$tmp"; return 2; fi
  local v nblock
  v="$(jq -r '.verdict // empty' "$tmp" 2>/dev/null)"
  nblock="$(jq -r '(.blocking // []) | length' "$tmp" 2>/dev/null || echo 99)"
  case "$v" in
    approve)
      if [ "$nblock" != "0" ]; then
        _cl_log "gate[$slug]: approve carried blockers — downgrading to revise"
        v=revise
        # persist the downgrade: cl_verdict reads the FILE, so a variable-only
        # downgrade would let the next reader see "approve" (rubber-stamp hole).
        jq '.verdict="revise"' "$tmp" > "$tmp.dg" && mv "$tmp.dg" "$tmp" || { _cl_log "gate[$slug]: could not persist downgrade"; rm -f "$tmp" "$tmp.dg"; return 2; }
      fi ;;
    revise) ;;
    *) _cl_log "gate[$slug]: invalid verdict '$v'"; rm -f "$tmp"; return 2 ;;
  esac
  mv "$tmp" "$CL_STATE/${slug}.review.verdict"
  printf '%s\n' "$v"
  [ "$v" = approve ]
}

cl_verdict() { jq -r '.verdict' "$CL_STATE/$1.${2:-review}.verdict" 2>/dev/null; }

# cl_revise <slug> "<blocking items>"  — send the review back into the SAME thread.
cl_revise() {
  local slug="$1" notes="$2" sess
  sess="$(cat "$CL_STATE/${slug}.session" 2>/dev/null)"
  [ -n "$sess" ] || { _cl_log "revise[$slug]: no stored session id"; return 2; }
  [ -n "$notes" ] || { _cl_log "usage: cl_revise <slug> \"<blocking items>\""; return 2; }
  _cl_lock_acquire || return 2
  _cl_log "revise[$slug]: sending blocking items back to session $sess"
  codex exec $(_cl_model_flag "$CL_IMPL_MODEL") $(_cl_writable_flag) $(_cl_net_flag) \
    -C "$CL_REPO" -s "$CL_SANDBOX" --json -o "$CL_STATE/${slug}.revise.md" resume "$sess" \
    "Review of your implementation found BLOCKING items. Fix every one of them, re-run \
the relevant tests, and report what changed. Do not argue — fix, or explain concretely \
why the finding is wrong.

===== BLOCKING =====
$notes" > "$CL_STATE/${slug}.revise.jsonl" 2>&1
  local rc=$?
  _cl_lock_release
  # the tree moved: the previous review verdict no longer describes it
  rm -f "$CL_STATE/${slug}.review.verdict"
  [ $rc -eq 0 ] && _cl_log "revise[$slug]: done — re-review required" || _cl_log "revise[$slug] FAILED"
  return $rc
}

# cl_status [slug]  — where every slug stands.
cl_status() {
  local f slug
  printf '%-24s %-8s %-8s %s\n' SLUG PLAN REVIEW BASE
  for f in "$CL_STATE"/*.session; do
    [ -e "$f" ] || { echo "(no slugs yet in $CL_STATE)"; return 0; }
    slug="$(basename "$f" .session)"
    [ -n "${1:-}" ] && [ "$1" != "$slug" ] && continue
    printf '%-24s %-8s %-8s %s\n' "$slug" \
      "$(cl_verdict "$slug" plan   || echo -)" \
      "$(cl_verdict "$slug" review || echo -)" \
      "$(cut -c1-8 "$CL_STATE/${slug}.base.sha" 2>/dev/null || echo -)"
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
  cl_gate_plan "$slug" >/dev/null || { _cl_log "wave[$slug]: plan not approved — stop"; return 2; }
  cl_impl "$slug" || return 1
  _cl_log "wave[$slug]: IMPL DONE — orchestrator must review (cl_review_human $slug ; cl_record_verdict $slug review approve|revise)"
}

# -------------------------------------------- adversarial self-review ----------
# cl_selfreview — have Codex tear apart THIS harness before you trust it.
cl_selfreview() {
  codex exec -C "$CL_SKILL_DIR" -s read-only \
    "Adversarially review lib/codex-loop.sh and SKILL.md in this dir. Find bugs \
in the bash (quoting, locking, session-id capture, exec/resume flags for \
codex-cli 0.144), unsafe defaults, and any way a gate can rubber-stamp. List \
concrete fixes."
}

# Direct dispatch (bash codex-loop.sh <fn> args). Sourcing works too, but use bash —
# the guard below is zsh-safe (BASH_SOURCE unset under zsh won't blow up).
if [ -n "${BASH_VERSION:-}" ] && [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  set -uo pipefail
  CL_DISPATCHED=1          # now the lock may own the shell's EXIT/INT traps
  cmd="${1:-}"; shift || true
  case "$cmd" in
    plan|impl|wave|gate_plan|review_human|codex_gate|verdict|record_verdict|revise|status|doctor|selfreview) "cl_$cmd" "$@" ;;
    *) echo "usage: bash codex-loop.sh {doctor|plan|gate_plan|record_verdict|impl|review_human|codex_gate|revise|verdict|status|wave|selfreview} ..." >&2; exit 2 ;;
  esac
fi
