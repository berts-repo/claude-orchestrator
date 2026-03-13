#!/usr/bin/env bash
# PostToolUse hook — records web delegation completion in the audit DB.
# Companion to web--log-start.sh (PreToolUse).
# HOOK_EVENT: PostToolUse
# HOOK_MATCHER: mcp__delegate_web__*
# HOOK_TIMEOUT: 5
set -euo pipefail

REAL_SCRIPT="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
source "$SCRIPT_DIR/shared--log-helpers.sh"
source "$SCRIPT_DIR/shared--codex-log-helpers.sh"
command -v jq >/dev/null 2>&1 || exit 0
command -v sqlite3 >/dev/null 2>&1 || exit 0
[[ -f "${HOME}/.claude/audit.db" ]] || exit 0

sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

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

prompt_hash="$(codex_log_correlation_key "$tool_name" "$prompt")"
request_nonce="$(codex_log_extract_request_nonce "$payload")"
[[ -n "$request_nonce" ]] || exit 0

invocation_key="${prompt_hash}-${request_nonce}"

if [[ "$(uname)" == "Darwin" ]]; then
  epoch_ms="$(python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || date +%s000)"
else
  epoch_ms="$(date +%s%3N 2>/dev/null || date +%s000)"
fi

# Determine status from payload
is_error="$(echo "$payload" | jq -r '.tool_response.isError // false')"
if [[ "$is_error" == "true" ]]; then
  status="error"
  error_text="$(echo "$payload" | jq -r '.tool_response.content // "" | if type == "array" then .[0].text // "" else . end' | head -c 200)"
else
  status="completed"
  error_text=""
fi

DB="${HOME}/.claude/audit.db"
sqlite3 "$DB" "UPDATE web_tasks SET status='$(sql_escape "$status")', ended_at=${epoch_ms}, duration_ms=${epoch_ms} - started_at, error_text='$(sql_escape "$error_text")' WHERE id=(SELECT id FROM web_tasks WHERE invocation_key='$(sql_escape "$invocation_key")' AND status='started' ORDER BY id DESC LIMIT 1);"

exit 0
