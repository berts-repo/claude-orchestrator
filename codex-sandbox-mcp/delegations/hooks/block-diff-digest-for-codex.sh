#!/usr/bin/env bash
# PreToolUse hook: Block diff_digest subagent
set -euo pipefail

payload="$(cat)"
tool_name="$(echo "$payload" | jq -r '.tool_name // ""')"
[[ "$tool_name" != "Task" ]] && exit 0

subagent="$(echo "$payload" | jq -r '.tool_input.subagent_type // ""' | tr '[:upper:]' '[:lower:]')"

if [[ "$subagent" == "diff_digest" || "$subagent" == "diff-digest" ]]; then
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
