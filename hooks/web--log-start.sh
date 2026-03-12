#!/usr/bin/env bash
# PreToolUse hook
# Records web delegation start time for duration tracking.
# Companion to web--log-audit.sh (PostToolUse) which computes duration_ms.
# HOOK_EVENT: PreToolUse
# HOOK_MATCHER: mcp__delegate_web__*
# HOOK_TIMEOUT: 5
set -euo pipefail

REAL_SCRIPT="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
source "$SCRIPT_DIR/shared--log-helpers.sh"
source "$SCRIPT_DIR/shared--codex-log-helpers.sh"
command -v jq >/dev/null 2>&1 || exit 0

payload="$(cat)"
tool_name="$(codex_log_extract_tool_name "$payload")"

case "$tool_name" in
  mcp__delegate_web__fetch)
    prompt="$(echo "$payload" | jq -r '.tool_input.url // ""')"
    ;;
  mcp__delegate_web__search)
    prompt="$(echo "$payload" | jq -r '.tool_input.query // ""')"
    ;;
  *)
    exit 0
    ;;
esac

[[ -n "$prompt" ]] || exit 0

ensure_dirs

prompt_hash="$(codex_log_correlation_key "$tool_name" "$prompt")"
request_nonce="$(codex_log_extract_request_nonce "$payload")"
[[ -n "$request_nonce" ]] || exit 0

if [[ "$(uname)" == "Darwin" ]]; then
  epoch_ms="$(python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || date +%s000)"
else
  epoch_ms="$(date +%s%3N 2>/dev/null || date +%s000)"
fi

printf '%s' "$epoch_ms" > "${PENDING_DIR}/${prompt_hash}-${request_nonce}"

exit 0
