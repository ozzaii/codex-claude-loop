#!/usr/bin/env bash
# smoke.sh — exercise the whole loop offline against a stub `codex`.
# Proves the gates actually gate, without spending any Codex quota.
#
#   bash test/smoke.sh          # run under bash
#   zsh  test/smoke.sh          # the same assertions under zsh
#   CL_LIB=/path/to/lib.sh bash test/smoke.sh    # verify another copy of the harness
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
LIB="${CL_LIB:-$ROOT/plugin/skills/codex-claude-loop/lib/codex-claude-loop.sh}"
TMP="$(mktemp -d)" || exit 1
case "$TMP" in /*/*) [ -d "$TMP" ] || exit 1 ;; *) echo "refusing to run with TMP='$TMP'" >&2; exit 1 ;; esac
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

# ---------------------------------------------------------------- stub codex --
# Deliberately strict: it enforces the invocation contract the harness claims to honor,
# so "impl ran" also proves the flags were placed correctly.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
# codex-cli stand-in. Knobs that simulate a CLI update or a bad call:
#   STUB_VERSION, STUB_EVENT (tier1|tier2|none), STUB_NO_SCHEMA, STUB_NO_RESUME,
#   STUB_VERDICT, STUB_EXPECT_SESSION
args=" $* "
case "$args" in *" --version "*) echo "codex-cli ${STUB_VERSION:-0.144.2} (stub)"; exit 0 ;; esac
case "$args" in
  *" --help "*)
    case "$args" in
      *" resume "*)
        [ "${STUB_NO_RESUME:-0}" = 1 ] && { echo "error: unrecognized subcommand 'resume'" >&2; exit 2; }
        echo "Usage: codex exec resume [OPTIONS] <SESSION_ID>"; exit 0 ;;
    esac
    echo "Usage: codex exec [OPTIONS] [PROMPT]"
    echo "      --json"
    [ "${STUB_NO_SCHEMA:-0}" = 1 ] || echo "      --output-schema <FILE>"
    echo "  -o, --output-last-message <FILE>"
    exit 0 ;;
esac

# contract: global flags must precede `resume`, and -C/-s must be present
seen_resume=0; sess=""; out=""; schema=""; cdir=""; sandbox=""
for a in "$@"; do
  if [ "$seen_resume" = 1 ] && [ -z "$sess" ]; then sess="$a"; continue; fi
  case "$a" in
    resume) seen_resume=1 ;;
    -C|-s|-o|--json|--output-schema)
      [ "$seen_resume" = 1 ] && { echo "error: unexpected argument '$a' found after 'resume'" >&2; exit 2; } ;;
  esac
done
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --output-schema) schema="$2"; shift 2 ;;
    -C) cdir="$2"; shift 2 ;;
    -s) sandbox="$2"; shift 2 ;;
    resume) shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$cdir" ]    || { echo "error: no -C given" >&2; exit 2; }
[ -n "$sandbox" ] || { echo "error: no -s given" >&2; exit 2; }
if [ "$seen_resume" = 1 ]; then
  [ -n "$sess" ] || { echo "error: resume without a session id" >&2; exit 2; }
  if [ -n "${STUB_EXPECT_SESSION:-}" ] && [ "$sess" != "$STUB_EXPECT_SESSION" ]; then
    echo "error: resumed '$sess', expected '$STUB_EXPECT_SESSION'" >&2; exit 2
  fi
fi

cat > /dev/null    # drain stdin (the prompt)
if [ -n "$schema" ]; then
  # NB: build the default in two steps — a JSON default inside ${VAR:-…} terminates at
  # its first `}` and the rest leaks into the output as literal text.
  verdict="${STUB_VERDICT:-}"
  [ -n "$verdict" ] || verdict='{"verdict":"approve","summary":"clean","blocking":[]}'
  printf '%s\n' "$verdict" > "$out"
  echo '{"type":"thread.started","thread_id":"00000000-0000-4000-8000-000000000002"}'
elif [ "$seen_resume" = 1 ]; then
  echo "implemented" > "$cdir/IMPLEMENTED.txt"
  [ -n "$out" ] && echo "wrote IMPLEMENTED.txt" > "$out"
  echo '{"type":"item.completed"}'
elif [ -n "$out" ]; then
  echo "# plan" > "$out"; echo "READY: yes" >> "$out"
  echo 'ERROR: some ansi noise that is not json'   # the jsonl really does get polluted
  case "${STUB_EVENT:-tier1}" in
    tier1) echo '{"type":"thread.started","thread_id":"00000000-0000-4000-8000-000000000001"}' ;;
    tier2) echo '{"type":"session.created","session":{"id":"00000000-0000-4000-8000-00000000dd10"}}' ;;
    bogus) echo '{"type":"thread.started","thread_id":"not an id"}' ;;
    none)  echo '{"type":"item.completed"}' ;;
  esac
else
  echo "review prose"
fi
STUB
chmod +x "$TMP/bin/codex"
PATH="$TMP/bin:$PATH"

# ------------------------------------------------------------------ fixtures --
export CL_REPO="$TMP/repo" CL_STATE="$TMP/state"
mkdir -p "$CL_REPO"
git -C "$CL_REPO" init -q
git -C "$CL_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
echo "do the thing" > "$TMP/brief.md"

# shellcheck source=/dev/null
. "$LIB"

echo "== codex-claude-loop smoke (${BASH_VERSION:+bash}${ZSH_VERSION:+zsh})"

doc="$(cl_doctor 2>&1)"; check "doctor passes" "$?" "0"
[ -n "${SMOKE_VERBOSE:-}" ] && printf '%s\n' "$doc"

# ------------------------------------------------------------ plan and gate 1 --
cl_plan w1 "$TMP/brief.md" >/dev/null 2>&1
[ -f "$CL_STATE/w1.plan.md" ] && ok "plan file written" || bad "plan file written"
check "thread id parsed past ansi noise" "$(cat "$CL_STATE/w1.session" 2>/dev/null)" "00000000-0000-4000-8000-000000000001"

cl_impl w1 >/dev/null 2>&1; check "impl REFUSES an unapproved plan" "$?" "2"
[ -f "$CL_REPO/IMPLEMENTED.txt" ] && bad "tree untouched before approval" || ok "tree untouched before approval"

cl_record_verdict w1 plan approve "looks right"
check "plan verdict recorded" "$(cl_verdict w1 plan)" "approve"

# the approval is bound to the plan text, not merely to the word "approve"
mv "$CL_STATE/w1.plan.md" "$TMP/plan.hidden"
cl_plan_approved w1 2>/dev/null; check "approval is void when the plan is gone" "$?" "1"
mv "$TMP/plan.hidden" "$CL_STATE/w1.plan.md"
cl_plan_approved w1 2>/dev/null; check "approval holds again once the plan is back" "$?" "0"

# ------------------------------------------------------------------- impl -----
STUB_EXPECT_SESSION="$(cat "$CL_STATE/w1.session")" cl_impl w1 >/dev/null 2>&1
check "impl runs once approved, resuming the STORED thread with legal flag order" "$?" "0"
[ -f "$CL_REPO/IMPLEMENTED.txt" ] && ok "tree was written" || bad "tree was written"
[ -s "$CL_STATE/w1.base.sha" ] && ok "base sha recorded" || bad "base sha recorded"
[ -f "$CL_STATE/w1.impl.ok" ]   && ok "success marker written" || bad "success marker written"
[ -d "$CL_STATE/impl.lock.d" ]  && bad "writer lock released" || ok "writer lock released"

STUB_EXPECT_SESSION=deadbeefdeadbeef cl_impl w1 >/dev/null 2>&1
check "the stub can tell a wrong thread id (negative control)" "$?" "2"
[ -f "$CL_STATE/w1.impl.ok" ] && bad "a failed impl leaves no success marker" || ok "a failed impl leaves no success marker"
STUB_EXPECT_SESSION="$(cat "$CL_STATE/w1.session")" cl_impl w1 >/dev/null 2>&1   # restore

# ------------------------------------------------------------ gate 2 (auto) ---
STUB_VERDICT='{"verdict":"approve","summary":"x","blocking":[{"where":"a.ts:1","issue":"i","fix":"f"}]}' \
  cl_codex_gate w1 >/dev/null 2>&1
check "approve+blockers downgraded to revise" "$(cl_verdict w1 review)" "revise"

STUB_VERDICT='{"verdict":"approve","summary":"clean","blocking":[]}' cl_codex_gate w1 >/dev/null 2>&1
check "clean approve accepted (rc)" "$?" "0"
check "clean approve accepted (file)" "$(cl_verdict w1 review)" "approve"

STUB_VERDICT='{"verdict":"approve","summary":"x","blocking":true}' cl_codex_gate w1 >/dev/null 2>&1
check "non-array blocking is refused, not counted as zero" "$?" "2"

STUB_VERDICT='{"verdict":"maybe","summary":"x","blocking":[]}' cl_codex_gate w1 >/dev/null 2>&1
check "invalid verdict rejected (rc 2)" "$?" "2"
check "a failed gate leaves NO standing approval" "$(cl_verdict w1 review)" ""

# ---------------------------------------------------------------- gate 2 use --
cl_release w1 >/dev/null 2>&1; check "release refuses without a review approval" "$?" "2"
cl_record_verdict w1 review approve "clean"
cl_release w1 >/dev/null 2>&1; check "release passes when both gates hold" "$?" "0"
echo "someone edited the tree afterwards" >> "$CL_REPO/IMPLEMENTED.txt"
cl_release w1 >/dev/null 2>&1; check "release refuses after the tree moved post-approval" "$?" "2"
git -C "$CL_REPO" checkout -- . 2>/dev/null; echo "implemented" > "$CL_REPO/IMPLEMENTED.txt"

# --------------------------------------------------------------- revise -------
cl_revise w1 "fix the thing" >/dev/null 2>&1
check "revise clears the review verdict" "$(cl_verdict w1 review)" ""

# --------------------------------------------------------- re-plan invalidates --
cl_plan w1 "$TMP/brief.md" >/dev/null 2>&1
check "re-plan clears the plan verdict" "$(cl_verdict w1 plan)" ""
[ -f "$CL_STATE/w1.base.sha" ] && bad "re-plan clears the recorded base" || ok "re-plan clears the recorded base"
[ -f "$CL_STATE/w1.impl.ok" ]  && bad "re-plan clears the success marker" || ok "re-plan clears the success marker"

case "$(cl_status)" in *"w1 "*) ok "status lists the slug" ;; *) bad "status lists the slug" ;; esac

# ------------------------------------------- surviving a codex-cli update ------
STUB_EVENT=tier2 cl_plan drift "$TMP/brief.md" >/dev/null 2>&1
check "thread id survives a drifted event shape" \
  "$(cat "$CL_STATE/drift.session" 2>/dev/null)" "00000000-0000-4000-8000-00000000dd10"

STUB_EVENT=bogus cl_plan bogus "$TMP/brief.md" >/dev/null 2>&1
check "an id that is not an id is refused" "$?" "1"

STUB_EVENT=none cl_plan nodrift "$TMP/brief.md" >/dev/null 2>&1
check "no thread id at all is a hard failure" "$?" "1"
[ -f "$CL_STATE/nodrift.session" ] && bad "no session file when the id is missing" \
                                   || ok  "no session file when the id is missing"

cl_record_verdict drift plan approve "x"
STUB_NO_RESUME=1 cl_impl drift >/dev/null 2>&1
check "impl refuses when 'exec resume' is gone" "$?" "2"
STUB_NO_RESUME=1 cl_revise drift "fix it" >/dev/null 2>&1
check "revise refuses when 'exec resume' is gone" "$?" "2"

cl_impl drift >/dev/null 2>&1
unset _CL_HELP; STUB_NO_SCHEMA=1 cl_codex_gate drift >/dev/null 2>&1
check "autonomous gate refuses when --output-schema is gone" "$?" "2"
unset _CL_HELP

_cl_has_flag ' --json' >/dev/null 2>&1
[ -n "${_CL_HELP:-}" ] && ok "the help memo actually memoizes" || bad "the help memo actually memoizes"

case "$(STUB_VERSION=9.9.9 cl_doctor 2>/dev/null)" in
  *"outside the tested set"*) ok  "doctor warns on an untested codex family" ;;
  *)                          bad "doctor warns on an untested codex family" ;;
esac
STUB_NO_SCHEMA=1 cl_doctor >/dev/null 2>&1
check "doctor fails when a required flag is missing" "$?" "1"

# ------------------------------------------------------ refusing to review air --
cl_review_human never-ran >/dev/null 2>&1
check "human review refuses when impl never ran" "$?" "2"
mkdir -p "$CL_STATE/impl.lock.d"; echo $$ > "$CL_STATE/impl.lock.d/pid"
cl_review_human w1 >/dev/null 2>&1
check "review refuses while a writer holds the lock" "$?" "2"
rm -rf "$CL_STATE/impl.lock.d"

# ----------------------------------------------------------------- slugs ------
cl_plan "../escape" "$TMP/brief.md" >/dev/null 2>&1
check "a slug that escapes the state dir is refused" "$?" "2"
cl_record_verdict "x/y" plan approve >/dev/null 2>&1
check "record_verdict refuses a slug with a separator" "$?" "2"

# ------------------------------------------------------------- dispatcher ----
bash "$LIB" status >/dev/null 2>&1;      check "dispatcher runs a known verb"        "$?" "0"
bash "$LIB" not-a-verb >/dev/null 2>&1;  check "dispatcher rejects an unknown verb"  "$?" "2"
bash "$LIB" >/dev/null 2>&1;             check "dispatcher rejects an empty verb"    "$?" "2"
bash "$LIB" plan >/dev/null 2>&1;        check "dispatched verb with no args returns usage, not a crash" "$?" "2"

# ------------------------------------------------------------- writer lock ----
cl_record_verdict w1 plan approve "re-approved for the lock tests"

mkdir -p "$CL_STATE/impl.lock.d"; echo 999999 > "$CL_STATE/impl.lock.d/pid"   # dead pid
cl_impl w1 >/dev/null 2>&1; check "stale lock holder reclaimed" "$?" "0"

mkdir -p "$CL_STATE/impl.lock.d"; echo $$ > "$CL_STATE/impl.lock.d/pid"       # live pid
CL_LOCK_TIMEOUT=1 cl_impl w1 >/dev/null 2>&1; check "live lock holder blocks impl" "$?" "2"
_cl_lock_release
[ -d "$CL_STATE/impl.lock.d" ] && bad "owner may release its own lock" || ok "owner may release its own lock"

mkdir -p "$CL_STATE/impl.lock.d"; echo 999999 > "$CL_STATE/impl.lock.d/pid"   # someone else's
_cl_lock_release
[ -d "$CL_STATE/impl.lock.d" ] && ok "a non-owner cannot release the lock" || bad "a non-owner cannot release the lock"
rm -rf "$CL_STATE/impl.lock.d"

# The harness must not steal the caller's EXIT trap when sourced. Checked behaviorally in
# a child shell — `trap -p` inside $(…) reads the subshell's (reset) traps, not ours.
cat > "$TMP/trapcheck.sh" <<CHILD
. "$LIB"
trap 'echo survived > "$TMP/canary"' EXIT
cl_impl w1 >/dev/null 2>&1
CHILD
( PATH="$TMP/bin:$PATH" CL_REPO="$CL_REPO" CL_STATE="$CL_STATE" bash "$TMP/trapcheck.sh" ) >/dev/null 2>&1
[ -f "$TMP/canary" ] && ok "caller's EXIT trap survives a sourced impl" \
                     || bad "caller's EXIT trap survives a sourced impl"

# ------------------------------------------------------------ empty state -----
( CL_STATE="$TMP/fresh" ; mkdir -p "$CL_STATE" ; cl_status >/dev/null 2>&1 )
check "status on an empty state does not abort (zsh glob)" "$?" "0"

echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
