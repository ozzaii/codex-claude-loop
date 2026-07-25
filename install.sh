#!/bin/sh
# codex-claude-loop installer. Keep this file 7-bit ASCII: a non-ASCII character glued
# to a variable once got parsed into the variable NAME and broke `curl | sh` in the wild.
set -eu

REPO="ozzaii/codex-claude-loop"
NAME="codex-claude-loop"
MARKER=".installed-by-codex-claude-loop"
REF="main"
DEST="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
ACTION="install"

usage() {
  cat <<USAGE
codex-claude-loop installer

  curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | sh

Installs the skill into ~/.claude/skills/$NAME. Needs curl and tar. Claude Code users
can install the plugin instead (see the README); this path is for driving the harness
from a shell or from another agent harness.

  --dir <path>   install somewhere else (e.g. ./.claude/skills for one project)
  --ref <ref>    branch or tag to install (default: $REF; a tag is the safer choice)
  --uninstall    remove an install this script created
  -h, --help     this text
USAGE
}

need_value() {  # <flag> <count-of-remaining-args>
  [ "$2" -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; }
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)       need_value --dir $#; DEST="$2"; shift 2 ;;
    --ref)       need_value --ref $#; REF="$2";  shift 2 ;;
    --uninstall) ACTION="uninstall"; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

TARGET="$DEST/$NAME"

if [ "$ACTION" = uninstall ]; then
  if [ ! -d "$TARGET" ]; then echo "nothing at $TARGET"; exit 0; fi
  # only remove what this script installed: the target is a path the user chose, and an
  # unconditional recursive delete there is somebody else's bad day
  if [ ! -f "$TARGET/$MARKER" ]; then
    echo "$TARGET was not installed by this script (no $MARKER) - refusing to delete it" >&2
    exit 1
  fi
  rm -rf "$TARGET"
  echo "removed $TARGET"
  exit 0
fi

for bin in curl tar; do
  command -v "$bin" >/dev/null 2>&1 || { echo "need $bin on PATH" >&2; exit 1; }
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

echo "downloading ${REPO}@${REF} ..."
curl -fsSL "https://codeload.github.com/${REPO}/tar.gz/${REF}" > "$tmp/src.tgz" \
  || { echo "download failed - check the ref '${REF}'" >&2; exit 1; }
tar -xzf "$tmp/src.tgz" -C "$tmp" \
  || { echo "archive did not extract - the download may be truncated" >&2; exit 1; }

# -maxdepth before the other primaries: GNU find warns when it comes later
src="$(find "$tmp" -maxdepth 5 -type d -path "*/plugin/skills/$NAME" | head -1)"
[ -n "$src" ] || { echo "archive layout unexpected: no plugin/skills/$NAME inside" >&2; exit 1; }
[ -f "$src/SKILL.md" ] && [ -f "$src/lib/$NAME.sh" ] \
  || { echo "downloaded skill is incomplete - refusing to install it" >&2; exit 1; }

mkdir -p "$DEST"
# Stage beside the target on the same filesystem, then swap. A copy that dies halfway
# must never be the thing sitting at $TARGET.
staged="$DEST/.$NAME.staging.$$"
backup="$DEST/.$NAME.backup.$$"
rm -rf "$staged"
cp -R "$src" "$staged" || { rm -rf "$staged"; echo "staging copy failed" >&2; exit 1; }
date -u +%Y-%m-%dT%H:%M:%SZ > "$staged/$MARKER" 2>/dev/null || : > "$staged/$MARKER"
chmod +x "$staged/lib/$NAME.sh" 2>/dev/null || true

if [ -d "$TARGET" ]; then
  mv "$TARGET" "$backup" || { rm -rf "$staged"; echo "could not move the existing install aside" >&2; exit 1; }
fi
if ! mv "$staged" "$TARGET"; then
  echo "install failed; restoring the previous version" >&2
  [ -d "$backup" ] && mv "$backup" "$TARGET"
  rm -rf "$staged"
  exit 1
fi
[ -d "$backup" ] && rm -rf "$backup"

echo "installed -> $TARGET"

# Verify against the codex you actually have, rather than claiming success blindly.
if command -v bash >/dev/null 2>&1; then
  echo
  bash "$TARGET/lib/$NAME.sh" doctor || echo "(doctor reported problems above - the loop will refuse phases it cannot run)"
fi

cat <<EOF

Next:
  1. open Claude Code in your repo and ask it to use the $NAME skill
  2. or drive it from a shell:
       source $TARGET/lib/$NAME.sh
       cl_doctor && cl_plan <slug> <brief.md>

Uninstall:  curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | sh -s -- --uninstall
EOF
