#!/usr/bin/env bash
# HOOK_EVENT: PostToolUse
# HOOK_MATCHER: mcp__delegate-web__fetch|mcp__delegate-web__search
# HOOK_TIMEOUT: 10
set -euo pipefail

DB_PATH="${HOME}/.claude/audit.db"
SESSION_FILE="${HOME}/.claude/tmp/current-session-id"

[[ -f "$DB_PATH" ]] || exit 0
command -v sqlite3 >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload="$(cat || true)"
[[ -n "$payload" ]] || exit 0

tool_name="$(printf '%s' "$payload" | jq -r '.tool_name // ""' 2>/dev/null || echo "")"
case "$tool_name" in
  mcp__delegate-web__fetch) tool_type="web-fetch" ;;
  mcp__delegate-web__search) tool_type="web-search" ;;
  *) exit 0 ;;
esac

if [[ "$tool_type" == "web-fetch" ]]; then
  prompt_value="$(printf '%s' "$payload" | jq -r '.tool_input.url // "" | tostring' 2>/dev/null || echo "")"
else
  prompt_value="$(printf '%s' "$payload" | jq -r '.tool_input.query // "" | tostring' 2>/dev/null || echo "")"
fi
[[ -n "$prompt_value" ]] || exit 0

result_content="$(printf '%s' "$payload" | jq -r '
  (
    .tool_result.content
    // .tool_response.content
    // .tool_result
    // .tool_response
    // ""
  ) | if type == "string" then . else tostring end
' 2>/dev/null || echo "")"

epoch_ms() {
  date +%s%3N 2>/dev/null || python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || echo "0"
}

sha256_text() {
  local text="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$text" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$text" | shasum -a 256 | awk '{print $1}'
  else
    python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' <<<"$text" 2>/dev/null || echo ""
  fi
}

new_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
    return
  fi
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    tr '[:upper:]' '[:lower:]' < /proc/sys/kernel/random/uuid
    return
  fi
  echo "$(date +%s)-$$-${RANDOM}"
}

sql_quote() {
  local value="$1"
  value="${value//\'/\'\'}"
  printf "'%s'" "$value"
}

invocation_id="$(new_uuid)"
session_id=""
if [[ -f "$SESSION_FILE" ]]; then
  session_id="$(cat "$SESSION_FILE" 2>/dev/null || true)"
fi
prompt_slug="${prompt_value:0:80}"
prompt_hash="$(sha256_text "$prompt_value")"
started_at="$(epoch_ms)"
ended_at="$started_at"
stdout_bytes="$(printf '%s' "$result_content" | wc -c | tr -d '[:space:]')"

sqlite3 "$DB_PATH" >/dev/null <<SQL
.parameter init
.parameter set @invocation_id $(sql_quote "$invocation_id")
.parameter set @session_id $(sql_quote "$session_id")
.parameter set @tool_type $(sql_quote "$tool_type")
.parameter set @prompt_slug $(sql_quote "$prompt_slug")
.parameter set @prompt_hash $(sql_quote "$prompt_hash")
.parameter set @url $(sql_quote "$prompt_value")
.parameter set @started_at $started_at
.parameter set @ended_at $ended_at
.parameter set @status 'done'
.parameter set @stdout_bytes $stdout_bytes
INSERT INTO tasks (
  invocation_id,
  session_id,
  tool_type,
  prompt_slug,
  prompt_hash,
  url,
  started_at,
  ended_at,
  status,
  stdout_bytes
) VALUES (
  @invocation_id,
  @session_id,
  @tool_type,
  @prompt_slug,
  @prompt_hash,
  @url,
  @started_at,
  @ended_at,
  @status,
  @stdout_bytes
);
SQL

exit 0
