#!/usr/bin/env bash
# PreToolUse hook
# Records delegation start time for duration tracking.
# Companion to codex--log-delegation.sh (PostToolUse) which computes duration_ms.
set -euo pipefail

REAL_SCRIPT="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
source "$SCRIPT_DIR/shared--log-helpers.sh"

payload="$(cat)"
tool_name=$(echo "$payload" | jq -r '.tool_name // ""')

# Only track Codex and Gemini calls
case "$tool_name" in
  mcp__codex__codex|mcp__codex__codex-reply) ;;
  mcp__gemini_web__web_search|mcp__gemini_web__web_fetch|mcp__gemini_web__web_summarize) ;;
  *) exit 0 ;;
esac

ensure_dirs

# Hash first 100 chars of prompt/query as a correlation key
prompt=$(echo "$payload" | jq -r '.tool_input.prompt // .tool_input.query // .tool_input.url // ""')
prompt_prefix="${prompt:0:100}"
prompt_hash=$(printf '%s-%s' "$tool_name" "$prompt_prefix" | shasum -a 256 | cut -c1-16)

# Write epoch milliseconds to a pending marker file
if [[ "$(uname)" == "Darwin" ]]; then
  epoch_ms=$(python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || date +%s000)
else
  epoch_ms=$(date +%s%3N 2>/dev/null || date +%s000)
fi

printf '%s' "$epoch_ms" > "${PENDING_DIR}/${prompt_hash}"

exit 0
