#!/bin/sh
# codex-claude-loop installer.
#
#   curl -fsSL https://raw.githubusercontent.com/ozzaii/codex-claude-loop/main/install.sh | sh
#
# Installs the skill into ~/.claude/skills/codex-claude-loop. Needs curl and tar.
# Claude Code users can install the plugin instead (see README) - this path is for
# anyone driving the harness from a shell or from another agent harness.
#
#   --dir <path>   install somewhere else (e.g. ./.claude/skills for one project)
#   --ref <ref>    branch or tag to install (default: main)
#   --uninstall    remove an existing install
set -eu

REPO="ozzaii/codex-claude-loop"
NAME="codex-claude-loop"
REF="main"
DEST="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
ACTION="install"

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)       DEST="$2"; shift 2 ;;
    --ref)       REF="$2";  shift 2 ;;
    --uninstall) ACTION="uninstall"; shift ;;
    -h|--help)   sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

TARGET="$DEST/$NAME"

if [ "$ACTION" = uninstall ]; then
  if [ -d "$TARGET" ]; then rm -rf "$TARGET"; echo "removed $TARGET"; else echo "nothing at $TARGET"; fi
  exit 0
fi

for bin in curl tar; do
  command -v "$bin" >/dev/null 2>&1 || { echo "need $bin on PATH" >&2; exit 1; }
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

echo "downloading ${REPO}@${REF} ..."
curl -fsSL "https://codeload.github.com/${REPO}/tar.gz/${REF}" | tar -xzf - -C "$tmp" \
  || { echo "download failed - check the ref '${REF}'" >&2; exit 1; }

# -maxdepth before the other primaries: GNU find warns when it comes later
src="$(find "$tmp" -maxdepth 5 -type d -path "*/plugin/skills/$NAME" | head -1)"
[ -n "$src" ] || { echo "archive layout unexpected: no plugin/skills/$NAME inside" >&2; exit 1; }

mkdir -p "$DEST"
if [ -d "$TARGET" ]; then
  backup="$TARGET.bak-$(date +%Y%m%d%H%M%S)"
  mv "$TARGET" "$backup"
  echo "existing install moved to $backup"
fi
cp -R "$src" "$TARGET"
chmod +x "$TARGET/lib/$NAME.sh" 2>/dev/null || true

echo "installed -> $TARGET"

# Verify against the codex you actually have, rather than claiming success blindly.
if command -v bash >/dev/null 2>&1; then
  echo
  bash "$TARGET/lib/$NAME.sh" doctor || echo "(doctor reported problems above - the loop will refuse phases it cannot run)"
fi

cat <<EOF

Next:
  1. open Claude Code in your repo and ask it to use the codex-claude-loop skill
  2. or drive it from a shell:
       source $TARGET/lib/$NAME.sh
       cl_plan <slug> <brief.md>

Uninstall:  curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | sh -s -- --uninstall
EOF
