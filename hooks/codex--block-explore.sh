#!/usr/bin/env bash
# PreToolUse hook: Block Explore subagent
set -euo pipefail

payload="$(cat)"

deny_on_parse_error() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Hook failed to parse tool input \xe2\x80\x94 denying to fail secure."}}\n'
  exit 2
}

tool_name="$(echo "$payload" | jq -r '.tool_name // ""' 2>/dev/null)" || deny_on_parse_error
[[ "$tool_name" != "Task" ]] && exit 0

subagent="$(echo "$payload" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null \
  | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" || deny_on_parse_error

REAL_SCRIPT="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
LOGGER="$SCRIPT_DIR/security--log-security-event.sh"

if [[ "$subagent" == "explore" ]]; then
  "$LOGGER" "block-explore-for-codex" "Task" "explore" "subagent_type=explore" "low" &>/dev/null || true
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Explore subagent is blocked. Use mcp__codex__codex with sandbox: read-only instead."
  }
}
EOF
  exit 0
fi

exit 0
