#!/usr/bin/env bash
# HOOK_EVENT: PostToolUse
# HOOK_MATCHER: mcp__delegate_web__*
# HOOK_TIMEOUT: 10
set -euo pipefail

REAL_SCRIPT="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
source "$SCRIPT_DIR/shared--log-helpers.sh"
source "$SCRIPT_DIR/shared--codex-log-helpers.sh"

DB_PATH="${HOME}/.claude/audit.db"
SESSION_FILE="${HOME}/.claude/tmp/current-session-id"

[[ -f "$DB_PATH" ]] || exit 0
command -v sqlite3 >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload="$(cat || true)"
[[ -n "$payload" ]] || exit 0

tool_name="$(codex_log_extract_tool_name "$payload")"
case "$tool_name" in
  mcp__delegate_web__fetch) tool_type="web-fetch" ;;
  mcp__delegate_web__search) tool_type="web-search" ;;
  *) exit 0 ;;
esac

if [[ "$tool_type" == "web-fetch" ]]; then
  prompt_value="$(printf '%s' "$payload" | jq -r '.tool_input.url // "" | tostring' 2>/dev/null || echo "")"
else
  prompt_value="$(printf '%s' "$payload" | jq -r '.tool_input.query // "" | tostring' 2>/dev/null || echo "")"
fi
[[ -n "$prompt_value" ]] || exit 0

ensure_dirs

result_content="$(printf '%s' "$payload" | jq -r '
  def textify:
    if . == null then ""
    elif type == "string" then .
    elif type == "number" or type == "boolean" then tostring
    elif type == "array" then ([ .[] | textify ] | map(select(length > 0)) | join("\n"))
    elif type == "object" then
      if has("text") then (.text | textify)
      elif has("content") then (.content | textify)
      elif has("output_text") then (.output_text | textify)
      elif has("output") then (.output | textify)
      elif has("message") then (.message | textify)
      else ([ .[] | textify ] | map(select(length > 0)) | join("\n"))
      end
    else tostring
    end;
  (
    .tool_result.content
    // .tool_response.content
    // .tool_result
    // .tool_response
    // ""
  ) | textify
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

sql_json() {
  local value="$1"
  printf '%s' "$value" | jq -Rs .
}

compute_start_and_end() {
  local prompt_text="$1"
  local now_ms
  now_ms="$(epoch_ms)"
  STARTED_AT="$now_ms"
  ENDED_AT="$now_ms"
  DURATION_MS=0

  local prompt_hash_key
  prompt_hash_key="$(codex_log_correlation_key "$tool_name" "$prompt_text")"
  local request_nonce
  request_nonce="$(codex_log_extract_request_nonce "$payload")"
  [[ -n "$request_nonce" ]] || return
  local pending_file="${PENDING_DIR}/${prompt_hash_key}-${request_nonce}"

  if [[ -n "$pending_file" && -f "$pending_file" ]]; then
    local start_ms
    start_ms="$(cat "$pending_file" 2>/dev/null || echo "")"
    rm -f "$pending_file"
    if [[ "$start_ms" =~ ^[0-9]+$ ]]; then
      STARTED_AT="$start_ms"
      if (( ENDED_AT >= STARTED_AT )); then
        DURATION_MS=$(( ENDED_AT - STARTED_AT ))
      fi
    fi
  fi
}

invocation_id="$(new_uuid)"
session_id=""
if [[ -f "$SESSION_FILE" ]]; then
  session_id="$(cat "$SESSION_FILE" 2>/dev/null || true)"
fi
prompt_slug="${prompt_value:0:80}"
prompt_hash="$(sha256_text "$prompt_value")"
compute_start_and_end "$prompt_value"
output_truncated="${result_content:0:4096}"
stdout_bytes="$(printf '%s' "$result_content" | wc -c | tr -d '[:space:]')"
store_full_output=false
if [[ "$(sqlite3 "$DB_PATH" "SELECT value FROM config WHERE key = 'full_output_storage' LIMIT 1;" 2>/dev/null || echo "")" == "true" ]]; then
  store_full_output=true
fi

has_output_full_column=false
if [[ "$(sqlite3 "$DB_PATH" "SELECT 1 FROM pragma_table_info('tasks') WHERE name = 'output_full' LIMIT 1;" 2>/dev/null || echo "")" == "1" ]]; then
  has_output_full_column=true
fi

if [[ "$store_full_output" == "true" && "$has_output_full_column" == "true" ]]; then
  sqlite3 "$DB_PATH" >/dev/null <<SQL
.parameter init
.parameter set @invocation_id_json $(sql_json "$invocation_id")
.parameter set @session_id_json $(sql_json "$session_id")
.parameter set @tool_type_json $(sql_json "$tool_type")
.parameter set @prompt_slug_json $(sql_json "$prompt_slug")
.parameter set @prompt_hash_json $(sql_json "$prompt_hash")
.parameter set @url_json $(sql_json "$prompt_value")
.parameter set @started_at $STARTED_AT
.parameter set @ended_at $ENDED_AT
.parameter set @duration_ms $DURATION_MS
.parameter set @status_json $(sql_json "done")
.parameter set @stdout_bytes $stdout_bytes
.parameter set @output_truncated_json $(sql_json "$output_truncated")
.parameter set @output_full_json $(sql_json "$result_content")
INSERT INTO tasks (
  invocation_id,
  session_id,
  tool_type,
  prompt_slug,
  prompt_hash,
  url,
  started_at,
  ended_at,
  duration_ms,
  status,
  stdout_bytes,
  output_truncated,
  output_full
) VALUES (
  json_extract(@invocation_id_json, '$'),
  json_extract(@session_id_json, '$'),
  json_extract(@tool_type_json, '$'),
  json_extract(@prompt_slug_json, '$'),
  json_extract(@prompt_hash_json, '$'),
  json_extract(@url_json, '$'),
  @started_at,
  @ended_at,
  @duration_ms,
  json_extract(@status_json, '$'),
  @stdout_bytes,
  json_extract(@output_truncated_json, '$'),
  json_extract(@output_full_json, '$')
);
SQL
else
  sqlite3 "$DB_PATH" >/dev/null <<SQL
.parameter init
.parameter set @invocation_id_json $(sql_json "$invocation_id")
.parameter set @session_id_json $(sql_json "$session_id")
.parameter set @tool_type_json $(sql_json "$tool_type")
.parameter set @prompt_slug_json $(sql_json "$prompt_slug")
.parameter set @prompt_hash_json $(sql_json "$prompt_hash")
.parameter set @url_json $(sql_json "$prompt_value")
.parameter set @started_at $STARTED_AT
.parameter set @ended_at $ENDED_AT
.parameter set @duration_ms $DURATION_MS
.parameter set @status_json $(sql_json "done")
.parameter set @stdout_bytes $stdout_bytes
.parameter set @output_truncated_json $(sql_json "$output_truncated")
INSERT INTO tasks (
  invocation_id,
  session_id,
  tool_type,
  prompt_slug,
  prompt_hash,
  url,
  started_at,
  ended_at,
  duration_ms,
  status,
  stdout_bytes,
  output_truncated
) VALUES (
  json_extract(@invocation_id_json, '$'),
  json_extract(@session_id_json, '$'),
  json_extract(@tool_type_json, '$'),
  json_extract(@prompt_slug_json, '$'),
  json_extract(@prompt_hash_json, '$'),
  json_extract(@url_json, '$'),
  @started_at,
  @ended_at,
  @duration_ms,
  json_extract(@status_json, '$'),
  @stdout_bytes,
  json_extract(@output_truncated_json, '$')
);
SQL
fi

exit 0
