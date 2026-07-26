#!/usr/bin/env bash
# Claude Code PreToolUse hook: refuse normal git publication commands while any
# codex-claude-loop implementation is not covered by both current approvals.
set -o pipefail

# Explicit session-scoped escape hatch. It is intentionally checked before the input
# parser so an operator can recover even when the local jq or hook input is broken.
[ "${CL_GIT_GUARD:-1}" = 0 ] && exit 0

if ! command -v jq >/dev/null 2>&1; then
  echo "codex-claude-loop git guard: jq is required to inspect this publication command; refusing. Install jq or explicitly set CL_GIT_GUARD=0 for this Claude Code session." >&2
  exit 2
fi

_cl_guard_deny() {
  jq -n --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

action="${1:-}"
case "$action" in
  commit|push|merge|tag) ;;
  *) _cl_guard_deny "codex-claude-loop git guard received an unknown publication action; refusing." ;;
esac

input="$(cat)" || _cl_guard_deny "codex-claude-loop git guard could not read its hook input; refusing publication."
cwd="$(printf '%s' "$input" | jq -er '
  select(
    .hook_event_name == "PreToolUse"
    and .tool_name == "Bash"
    and (.tool_input.command | type) == "string"
    and (.cwd | type) == "string"
    and (.cwd | length) > 0
  ) | .cwd
' 2>/dev/null)" || _cl_guard_deny "codex-claude-loop git guard received malformed PreToolUse input; refusing publication."

case "$cwd" in
  /*) ;;
  *) _cl_guard_deny "codex-claude-loop git guard received a non-absolute working directory; refusing publication." ;;
esac
[ -d "$cwd" ] || _cl_guard_deny "codex-claude-loop git guard cannot inspect the command working directory; refusing publication."

# No git worktree means no loop state can apply. Let git itself report whatever is wrong.
repo="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || exit 0

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin_root="${CLAUDE_PLUGIN_ROOT:-$(cd "$script_dir/.." && pwd)}"
lib="$plugin_root/skills/codex-claude-loop/lib/codex-claude-loop.sh"
[ -f "$lib" ] || _cl_guard_deny "codex-claude-loop git guard cannot find its bundled driver; refusing publication. Reinstall the plugin or set CL_GIT_GUARD=0 explicitly."

# Make the command's actual worktree authoritative while preserving an explicit CL_STATE
# override. Read-only mode prevents the hook from creating empty state in unrelated repos.
CL_REPO="$repo"
CL_SKILL_DIR="$plugin_root/skills/codex-claude-loop"
CL_VERDICT_SCHEMA="$CL_SKILL_DIR/schemas/verdict.schema.json"
CL_STATE_READ_ONLY=1
export CL_REPO CL_SKILL_DIR CL_VERDICT_SCHEMA CL_STATE_READ_ONLY

# shellcheck source=/dev/null
. "$lib" || _cl_guard_deny "codex-claude-loop git guard could not load its bundled driver; refusing publication."
type _cl_pending_publication_slugs >/dev/null 2>&1 \
  || _cl_guard_deny "codex-claude-loop git guard loaded an incompatible driver; refusing publication."

pending="$(_cl_pending_publication_slugs "$action" 2>/dev/null)"
[ -n "$pending" ] || exit 0
slugs="$(printf '%s\n' "$pending" | awk 'BEGIN { sep="" } { printf "%s%s", sep, $0; sep=", " } END { print "" }')"

_cl_guard_deny "codex-claude-loop blocked this git publication step: implementation(s) are not covered by current plan and review approvals: ${slugs}. Review each slug, record the verdict, and run cl_release. Emergency opt-out for this Claude Code session: CL_GIT_GUARD=0."
