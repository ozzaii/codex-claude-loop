#!/usr/bin/env bash
# smoke.sh — exercise the whole loop offline against a stub `codex`.
# Proves the gates actually gate, without spending any Codex quota.
#
#   bash test/smoke.sh          # run under bash
#   zsh  test/smoke.sh          # run the same assertions under zsh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
LIB="${CL_LIB:-$ROOT/plugin/skills/codex-loop/lib/codex-loop.sh}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

# ---------------------------------------------------------------- stub codex --
mkdir -p "$TMP/bin"
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
# minimal codex-cli stand-in: honors -o, --output-schema, -C and `resume`
out=""; schema=""; cdir="."; resume=0
while [ $# -gt 0 ]; do
  case "$1" in
    --version) echo "codex-cli 0.144.2 (stub)"; exit 0 ;;
    -o) out="$2"; shift 2 ;;
    --output-schema) schema="$2"; shift 2 ;;
    -C) cdir="$2"; shift 2 ;;
    resume) resume=1; shift 2 ;;   # skip the thread id too
    *) shift ;;
  esac
done
cat > /dev/null    # drain stdin (the prompt)
if [ -n "$schema" ]; then
  # NB: build the default in two steps — a JSON default inside ${VAR:-…} terminates
  # at its first `}` and the rest leaks into the output as literal text.
  verdict="${STUB_VERDICT:-}"
  [ -n "$verdict" ] || verdict='{"verdict":"approve","summary":"clean","blocking":[]}'
  printf '%s\n' "$verdict" > "$out"
  echo '{"type":"thread.started","thread_id":"00000000-0000-4000-8000-000000000002"}'
elif [ "$resume" = 1 ]; then
  echo "implemented" > "$cdir/IMPLEMENTED.txt"
  [ -n "$out" ] && echo "wrote IMPLEMENTED.txt" > "$out"
  echo '{"type":"item.completed"}'
elif [ -n "$out" ]; then
  echo "# plan" > "$out"; echo "READY: yes" >> "$out"
  echo 'ERROR: some ansi noise that is not json'   # the jsonl really does get polluted
  echo '{"type":"thread.started","thread_id":"00000000-0000-4000-8000-000000000001"}'
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

echo "== codex-loop smoke ($(basename "${BASH_VERSION:+bash}${ZSH_VERSION:+zsh}"))"

cl_doctor >/dev/null 2>&1; check "doctor passes" "$?" "0"

cl_plan w1 "$TMP/brief.md" >/dev/null 2>&1
[ -f "$CL_STATE/w1.plan.md" ] && ok "plan file written" || bad "plan file written"
check "thread id parsed past ansi noise" "$(cat "$CL_STATE/w1.session" 2>/dev/null)" "00000000-0000-4000-8000-000000000001"

cl_impl w1 >/dev/null 2>&1; check "impl REFUSES an unapproved plan" "$?" "2"
[ -f "$CL_REPO/IMPLEMENTED.txt" ] && bad "tree untouched before approval" || ok "tree untouched before approval"

cl_record_verdict w1 plan approve "looks right"
check "plan verdict recorded" "$(cl_verdict w1 plan)" "approve"

cl_impl w1 >/dev/null 2>&1; check "impl runs once approved" "$?" "0"
[ -f "$CL_REPO/IMPLEMENTED.txt" ] && ok "tree was written" || bad "tree was written"
[ -s "$CL_STATE/w1.base.sha" ] && ok "base sha recorded" || bad "base sha recorded"
[ -d "$CL_STATE/impl.lock.d" ] && bad "writer lock released" || ok "writer lock released"

STUB_VERDICT='{"verdict":"approve","summary":"x","blocking":[{"where":"a.ts:1","issue":"i","fix":"f"}]}' \
  cl_codex_gate w1 >/dev/null 2>&1
check "approve+blockers downgraded to revise" "$(cl_verdict w1 review)" "revise"

STUB_VERDICT='{"verdict":"approve","summary":"clean","blocking":[]}' cl_codex_gate w1 >/dev/null 2>&1
check "clean approve accepted" "$(cl_verdict w1 review)" "approve"

STUB_VERDICT='{"verdict":"maybe","summary":"x","blocking":[]}' cl_codex_gate w1 >/dev/null 2>&1
check "invalid verdict rejected (rc 2)" "$?" "2"
check "stale verdict NOT overwritten by a failed gate" "$(cl_verdict w1 review)" "approve"

cl_revise w1 "fix the thing" >/dev/null 2>&1
check "revise clears the review verdict" "$(cl_verdict w1 review)" ""

cl_plan w1 "$TMP/brief.md" >/dev/null 2>&1
check "re-plan clears the plan verdict" "$(cl_verdict w1 plan)" ""

cl_status | grep -q '^w1 ' && ok "status lists the slug" || bad "status lists the slug"

# ------------------------------------------------------------- writer lock ----
cl_record_verdict w1 plan approve "re-approved for the lock tests"

mkdir -p "$CL_STATE/impl.lock.d"; echo 999999 > "$CL_STATE/impl.lock.d/pid"   # dead pid
cl_impl w1 >/dev/null 2>&1; check "stale lock holder reclaimed" "$?" "0"

mkdir -p "$CL_STATE/impl.lock.d"; echo $$ > "$CL_STATE/impl.lock.d/pid"       # live pid
CL_LOCK_TIMEOUT=1 cl_impl w1 >/dev/null 2>&1; check "live lock holder blocks impl" "$?" "2"
rm -rf "$CL_STATE/impl.lock.d"

# The harness must not steal the caller's EXIT trap when sourced. Checked behaviorally
# in a child shell — `trap -p` inside $(…) reads the subshell's (reset) traps, not ours.
cat > "$TMP/trapcheck.sh" <<CHILD
. "$LIB"
trap 'echo survived > "$TMP/canary"' EXIT
cl_impl w1 >/dev/null 2>&1
CHILD
( PATH="$TMP/bin:$PATH" CL_REPO="$CL_REPO" CL_STATE="$CL_STATE" bash "$TMP/trapcheck.sh" ) >/dev/null 2>&1
[ -f "$TMP/canary" ] && ok "caller's EXIT trap survives a sourced impl" \
                     || bad "caller's EXIT trap survives a sourced impl"

echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
