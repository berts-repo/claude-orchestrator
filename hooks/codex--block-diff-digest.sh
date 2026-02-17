#!/usr/bin/env bash
# PreToolUse hook: Block diff_digest subagent
set -euo pipefail

payload="$(cat)"
tool_name="$(echo "$payload" | jq -r '.tool_name // ""')"
[[ "$tool_name" != "Task" ]] && exit 0

subagent="$(echo "$payload" | jq -r '.tool_input.subagent_type // ""' | tr '[:upper:]' '[:lower:]')"

REAL_SCRIPT="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
LOGGER="$SCRIPT_DIR/security--log-security-event.sh"

if [[ "$subagent" == "diff_digest" || "$subagent" == "diff-digest" ]]; then
  "$LOGGER" "block-diff-digest-for-codex" "Task" "$subagent" "subagent_type=$subagent" &>/dev/null || true
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "diff_digest subagent is blocked. Use mcp__codex__codex with sandbox: read-only instead."
  }
}
EOF
  exit 0
fi

exit 0
