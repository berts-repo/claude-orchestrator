#!/usr/bin/env bash
# PreToolUse hook: Block diff_digest subagent
set -euo pipefail

tool_name="$(jq -r '.tool_name // ""')"
[[ "$tool_name" != "Task" ]] && exit 0

subagent="$(echo "$CLAUDE_TOOL_INPUT" | jq -r '.subagent_type // ""' | tr '[:upper:]' '[:lower:]')"

if [[ "$subagent" == "diff_digest" || "$subagent" == "diff-digest" ]]; then
  echo '{"decision":"block","reason":"Use mcp__codex__codex with sandbox:read-only instead."}'
  exit 0
fi

echo '{"decision":"allow"}'
