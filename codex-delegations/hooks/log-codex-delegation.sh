#!/usr/bin/env bash
# PostToolUse hook
# Logs Codex delegations to ~/.claude/logs/codex-delegations.jsonl
set -euo pipefail

LOG_DIR="${HOME}/.claude/logs"
LOG_FILE="${LOG_DIR}/codex-delegations.jsonl"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Read input
payload="$(cat)"

tool_name=$(echo "$payload" | jq -r '.tool_name // ""')

# Only log mcp__codex__codex calls
if [[ "$tool_name" != "mcp__codex__codex" ]]; then
  exit 0
fi

# Extract fields
tool_input=$(echo "$payload" | jq -c '.tool_input // {}')
# tool_response is a JSON string, need to parse it
tool_response=$(echo "$payload" | jq -r '.tool_response // "{}"')

timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
thread_id=$(echo "$tool_response" | jq -r '.threadId // "unknown"')
sandbox=$(echo "$tool_input" | jq -r '.sandbox // "default"')
approval_policy=$(echo "$tool_input" | jq -r '.["approval-policy"] // "default"')
cwd=$(echo "$tool_input" | jq -r '.cwd // "unknown"')

# Truncate prompt and content for preview (first 100 chars)
prompt_preview=$(echo "$tool_input" | jq -r '.prompt // ""' | head -c 100 | tr '\n' ' ')
content_preview=$(echo "$tool_response" | jq -r '.content // ""' | head -c 100 | tr '\n' ' ')

# Determine success (has threadId and content)
if [[ "$thread_id" != "unknown" && "$thread_id" != "null" && -n "$thread_id" ]]; then
  success=true
else
  success=false
fi

# Build log entry
log_entry=$(jq -nc \
  --arg ts "$timestamp" \
  --arg tid "$thread_id" \
  --arg sb "$sandbox" \
  --arg ap "$approval_policy" \
  --arg cwd "$cwd" \
  --arg pp "$prompt_preview" \
  --arg cp "$content_preview" \
  --argjson success "$success" \
  '{
    timestamp: $ts,
    threadId: $tid,
    sandbox: $sb,
    approval_policy: $ap,
    cwd: $cwd,
    prompt_preview: $pp,
    content_preview: $cp,
    success: $success
  }')

# Append to log file
echo "$log_entry" >> "$LOG_FILE"

exit 0
