#!/usr/bin/env bash
# gates.sh — everything that must be green before publishing a change.
#   ./gates.sh
set -uo pipefail
cd "$(dirname "$0")"
fail=0
step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
verdict() { if [ "$1" -eq 0 ]; then printf '\033[32mok\033[0m\n'; else printf '\033[31mFAILED\033[0m\n'; fail=1; fi; }

# A missing tool is a RED gate, not a quiet pass: "all gates green" has to mean the gates
# ran. Install zsh and shellcheck, or accept that this machine cannot clear the bar.
step "smoke — bash";  bash test/smoke.sh < /dev/null; verdict $?
step "smoke — zsh"
if command -v zsh >/dev/null; then zsh test/smoke.sh < /dev/null; verdict $?
else echo "  MISS zsh not installed — the harness is sourced from zsh, so this gate cannot be skipped"; fail=1; fi

step "shellcheck"
if command -v shellcheck >/dev/null; then
  shellcheck -S error plugin/skills/codex-claude-loop/lib/codex-claude-loop.sh test/smoke.sh gates.sh; verdict $?
  shellcheck -S error -s sh install.sh; verdict $?
else echo "  MISS shellcheck not installed"; fail=1; fi

step "manifests"
if command -v jq >/dev/null; then
  for f in .claude-plugin/marketplace.json plugin/.claude-plugin/plugin.json plugin/skills/codex-claude-loop/schemas/verdict.schema.json; do
    jq -e . "$f" >/dev/null && echo "  ok   $f" || { echo "  BAD  $f"; fail=1; }
  done
else echo "(jq not installed — manifest gate SKIPPED, not passed)"; fail=1; fi
if command -v claude >/dev/null; then
  claude plugin validate . >/dev/null 2>&1        && echo "  ok   marketplace manifest" || { echo "  BAD  marketplace manifest"; fail=1; }
  claude plugin validate ./plugin >/dev/null 2>&1 && echo "  ok   plugin manifest"      || { echo "  BAD  plugin manifest";      fail=1; }
fi

step "installer is pure ASCII"
# a non-ASCII char glued to a variable ($REF...) got parsed into the variable NAME and
# broke `curl | sh` in the wild. Keep install.sh to 7-bit.
if LC_ALL=C grep -n '[^ -~	]' install.sh; then echo "  BAD  non-ASCII above"; fail=1; else echo "  ok   ascii only"; fi

step "no leaked internals"
if grep -rniE '/Users/|gho_[A-Za-z0-9]|sk-[A-Za-z0-9]{10}|AKIA[0-9A-Z]{16}' \
     --exclude-dir=.git --exclude=gates.sh . ; then
  echo "  BAD  see above"; fail=1
else echo "  ok   nothing leaked"; fi

printf '\n'
[ "$fail" -eq 0 ] && { printf '\033[32mALL GATES GREEN\033[0m\n'; exit 0; } || { printf '\033[31mGATES RED\033[0m\n'; exit 1; }
