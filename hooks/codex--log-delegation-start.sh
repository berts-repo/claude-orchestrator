#!/usr/bin/env bash
# PreToolUse hook
# Records delegation start time for duration tracking.
# Companion to codex--log-delegation.sh (PostToolUse) which computes duration_ms.
# HOOK_EVENT: PreToolUse
# HOOK_MATCHER: mcp__delegate__codex|mcp__delegate__codex_parallel|mcp__delegate_web__search|mcp__delegate_web__fetch
# HOOK_TIMEOUT: 5
set -euo pipefail

REAL_SCRIPT="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
source "$SCRIPT_DIR/shared--log-helpers.sh"
source "$SCRIPT_DIR/shared--codex-log-helpers.sh"

payload="$(cat)"
tool_name=$(codex_log_extract_tool_name "$payload")

# Only track Codex and Gemini calls
if ! codex_log_is_tracked_tool "$tool_name"; then
  exit 0
fi

ensure_dirs

# Hash first 100 chars of prompt/query as a correlation key
if [[ "$tool_name" == "mcp__delegate__codex_parallel" ]]; then
  prompt=$(echo "$payload" | jq -c '.tool_input.tasks // []')
else
  prompt=$(echo "$payload" | jq -r '.tool_input.prompt // .tool_input.query // .tool_input.url // ""')
fi
prompt_hash=$(codex_log_correlation_key "$tool_name" "$prompt")

# Write epoch milliseconds to a pending marker file
if [[ "$(uname)" == "Darwin" ]]; then
  epoch_ms=$(python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || date +%s000)
else
  epoch_ms=$(date +%s%3N 2>/dev/null || date +%s000)
fi

printf '%s' "$epoch_ms" > "${PENDING_DIR}/${prompt_hash}"

exit 0
