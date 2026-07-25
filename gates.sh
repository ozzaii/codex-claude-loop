#!/usr/bin/env bash
# gates.sh — everything that must be green before publishing a change.
#   ./gates.sh
set -uo pipefail
cd "$(dirname "$0")"
fail=0
step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
verdict() { if [ "$1" -eq 0 ]; then printf '\033[32mok\033[0m\n'; else printf '\033[31mFAILED\033[0m\n'; fail=1; fi; }

step "smoke — bash";  bash test/smoke.sh < /dev/null; verdict $?
step "smoke — zsh";   if command -v zsh >/dev/null; then zsh test/smoke.sh < /dev/null; verdict $?; else echo "(zsh not installed — skipped)"; fi

step "shellcheck"
if command -v shellcheck >/dev/null; then
  shellcheck -S error plugin/skills/codex-claude-loop/lib/codex-claude-loop.sh test/smoke.sh gates.sh; verdict $?
else echo "(shellcheck not installed — skipped)"; fi

step "manifests"
for f in .claude-plugin/marketplace.json plugin/.claude-plugin/plugin.json plugin/skills/codex-claude-loop/schemas/verdict.schema.json; do
  if command -v jq >/dev/null; then jq -e . "$f" >/dev/null && echo "  ok   $f" || { echo "  BAD  $f"; fail=1; }; fi
done
if command -v claude >/dev/null; then
  claude plugin validate . >/dev/null 2>&1        && echo "  ok   marketplace manifest" || { echo "  BAD  marketplace manifest"; fail=1; }
  claude plugin validate ./plugin >/dev/null 2>&1 && echo "  ok   plugin manifest"      || { echo "  BAD  plugin manifest";      fail=1; }
fi

step "no leaked internals"
if grep -rniE '/Users/|gho_[A-Za-z0-9]|sk-[A-Za-z0-9]{10}|AKIA[0-9A-Z]{16}' \
     --exclude-dir=.git --exclude=gates.sh . ; then
  echo "  BAD  see above"; fail=1
else echo "  ok   nothing leaked"; fi

printf '\n'
[ "$fail" -eq 0 ] && { printf '\033[32mALL GATES GREEN\033[0m\n'; exit 0; } || { printf '\033[31mGATES RED\033[0m\n'; exit 1; }
