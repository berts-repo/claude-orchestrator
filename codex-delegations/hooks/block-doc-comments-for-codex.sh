#!/usr/bin/env bash
# PreToolUse hook: Block doc_comments subagent
set -euo pipefail

tool_name="$(jq -r '.tool_name // ""')"
[[ "$tool_name" != "Task" ]] && exit 0

subagent="$(echo "$CLAUDE_TOOL_INPUT" | jq -r '.subagent_type // ""' | tr '[:upper:]' '[:lower:]')"

if [[ "$subagent" == "doc_comments" || "$subagent" == "doc-comments" ]]; then
  echo '{"decision":"block","reason":"Use mcp__codex__codex with sandbox:workspace-write instead."}'
  exit 0
fi

echo '{"decision":"allow"}'
