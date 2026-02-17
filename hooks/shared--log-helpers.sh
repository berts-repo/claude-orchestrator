#!/usr/bin/env bash
# Shared logging helpers for Claude Orchestrator hooks.
# Source this file — do not execute directly.
# Provides: log_json(), rotate_jsonl(), SESSION_ID

# Guard against double-sourcing
[[ -n "${_LOG_HELPERS_LOADED:-}" ]] && return 0
_LOG_HELPERS_LOADED=1

LOG_DIR="${HOME}/.claude/logs"
PENDING_DIR="${LOG_DIR}/.pending"

# Session ID: short hash of PPID + today's date.
# Groups all events within one Claude Code process tree per day.
if [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
  SESSION_ID="$CLAUDE_SESSION_ID"
else
  SESSION_ID=$(printf '%s' "${PPID:-0}-$(date -u +%Y-%m-%d)" | shasum -a 256 | cut -c1-12)
fi
export SESSION_ID

# log_json — build a JSON log entry with standardized envelope fields.
# Usage: log_json <level> <component> <event> [extra_jq_args...]
#   level:     info | warn | error
#   component: delegation | security | gemini-mcp
#   event:     e.g. codex_delegation, security_deny, gemini_query
#   extra args: passed directly to jq -nc (use --arg/--argjson for event-specific fields)
#
# Envelope fields are prefixed with _e_ internally to avoid collisions with
# caller-provided --arg names, then renamed in the output.
log_json() {
  local level="$1" component="$2" event="$3"
  shift 3

  jq -nc \
    --arg _e_ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg _e_level "$level" \
    --arg _e_component "$component" \
    --arg _e_session_id "$SESSION_ID" \
    --arg _e_event "$event" \
    "$@" \
    '{ timestamp: $_e_ts, level: $_e_level, component: $_e_component, session_id: $_e_session_id, event: $_e_event }
     + ([$ARGS.named | to_entries[] | select(.key | startswith("_e_") | not)] | from_entries)'
}

# rotate_jsonl — FIFO rotation by line count.
# Usage: rotate_jsonl <file> <max_entries> [cleanup_callback]
#   cleanup_callback: optional function name called with each removed line
rotate_jsonl() {
  local file="$1" max_entries="$2" cleanup_fn="${3:-}"

  [[ ! -f "$file" ]] && return 0

  local line_count
  line_count=$(wc -l < "$file")

  if [[ "$line_count" -gt "$max_entries" ]]; then
    if [[ -n "$cleanup_fn" ]]; then
      head -n $(( line_count - max_entries )) "$file" | while IFS= read -r line; do
        "$cleanup_fn" "$line"
      done
    fi
    tail -n "$max_entries" "$file" > "${file}.tmp"
    mv "${file}.tmp" "$file"
  fi
}

# ensure_dirs — create standard log directories
ensure_dirs() {
  mkdir -p "$LOG_DIR" "$PENDING_DIR"
}
