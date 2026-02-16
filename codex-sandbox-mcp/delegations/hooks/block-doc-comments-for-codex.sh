#!/usr/bin/env bash
# PreToolUse hook: Block doc_comments subagent
set -euo pipefail

payload="$(cat)"
tool_name="$(echo "$payload" | jq -r '.tool_name // ""')"
[[ "$tool_name" != "Task" ]] && exit 0

subagent="$(echo "$payload" | jq -r '.tool_input.subagent_type // ""' | tr '[:upper:]' '[:lower:]')"

if [[ "$subagent" == "doc_comments" || "$subagent" == "doc-comments" ]]; then
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "doc_comments subagent is blocked. Use mcp__codex__codex with sandbox: workspace-write instead."
  }
}
EOF
  exit 0
fi

exit 0
