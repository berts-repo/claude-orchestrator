#!/usr/bin/env bash
# PreToolUse hook: Block test_gen subagent
set -euo pipefail

payload="$(cat)"
tool_name="$(echo "$payload" | jq -r '.tool_name // ""')"
[[ "$tool_name" != "Task" ]] && exit 0

subagent="$(echo "$payload" | jq -r '.tool_input.subagent_type // ""' | tr '[:upper:]' '[:lower:]')"

REAL_SCRIPT="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
LOGGER="$SCRIPT_DIR/security--log-security-event.sh"

if [[ "$subagent" == "test_gen" || "$subagent" == "test-gen" ]]; then
  "$LOGGER" "block-test-gen-for-codex" "Task" "$subagent" "subagent_type=$subagent" &>/dev/null || true
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "test_gen subagent is blocked. Use mcp__codex__codex with sandbox: workspace-write instead."
  }
}
EOF
  exit 0
fi

exit 0
