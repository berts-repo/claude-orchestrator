#!/usr/bin/env bash
# PreToolUse hook
# Records web delegation start time for duration tracking.
# Companion to web--log-end.sh (PostToolUse) which computes duration_ms.
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

prompt_hash="$(codex_log_correlation_key "$tool_name" "$prompt")"
request_nonce="$(codex_log_extract_request_nonce "$payload")"
if [[ -z "$request_nonce" ]]; then
  fallback_seed="${SESSION_ID:-}|$tool_name|${prompt:0:32}"
  request_nonce="fallback-$(printf '%s' "$fallback_seed" | shasum -a 256 | cut -c1-16)"
  echo "WARN: request_nonce missing, using fallback correlation key" >&2
fi

if [[ "$(uname)" == "Darwin" ]]; then
  epoch_ms="$(python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || date +%s000)"
else
  epoch_ms="$(date +%s%3N 2>/dev/null || date +%s000)"
fi

command -v sqlite3 >/dev/null 2>&1 || exit 0
[[ -f "${HOME}/.claude/audit.db" ]] || exit 0

sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

DB="${HOME}/.claude/audit.db"
invocation_key="${prompt_hash}-${request_nonce}"
sqlite3 "$DB" "INSERT INTO web_tasks (session_id, invocation_key, tool_name, prompt, prompt_hash, status, started_at, cwd) VALUES ('$(sql_escape "$SESSION_ID")', '$(sql_escape "$invocation_key")', '$(sql_escape "$tool_name")', '$(sql_escape "${prompt:0:500}")', '$(sql_escape "$prompt_hash")', 'started', ${epoch_ms}, '$(sql_escape "$(pwd)")');"

exit 0
