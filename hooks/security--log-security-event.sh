#!/usr/bin/env bash
# Security event logger — called by PreToolUse hooks when they deny an action.
# NOT a hook itself. Invoked by existing hooks before they output the deny JSON.
# Writes to ~/.claude/logs/security-events.jsonl with FIFO rotation.
set -euo pipefail

MAX_ENTRIES=200
LOG_DIR="${HOME}/.claude/logs"
LOG_FILE="${LOG_DIR}/security-events.jsonl"

# Usage: log-security-event.sh <hook_name> <tool_name> <pattern_matched> <command_preview>
# All args are optional — missing args default to "unknown"
hook_name="${1:-unknown}"
tool_name="${2:-unknown}"
pattern_matched="${3:-unknown}"
command_preview="${4:-}"

# Truncate command preview to 80 chars for safety (no secrets in logs)
if [[ ${#command_preview} -gt 80 ]]; then
  command_preview="${command_preview:0:77}..."
fi

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Build log entry — use jq if available, fall back to printf
if command -v jq &>/dev/null; then
  log_entry=$(jq -nc \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg hook "$hook_name" \
    --arg tool "$tool_name" \
    --arg action "deny" \
    --arg pattern "$pattern_matched" \
    --arg preview "$command_preview" \
    --arg cwd "$(pwd)" \
    '{
      timestamp: $ts,
      hook: $hook,
      tool: $tool,
      action: $action,
      pattern_matched: $pattern,
      command_preview: $preview,
      cwd: $cwd
    }')
else
  # Fallback: manual JSON (escape double quotes in values)
  escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
  log_entry=$(printf '{"timestamp":"%s","hook":"%s","tool":"%s","action":"deny","pattern_matched":"%s","command_preview":"%s","cwd":"%s"}' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    "$(escape "$hook_name")" \
    "$(escape "$tool_name")" \
    "$(escape "$pattern_matched")" \
    "$(escape "$command_preview")" \
    "$(escape "$(pwd)")")
fi

# Append entry
echo "$log_entry" >> "$LOG_FILE"

# FIFO rotation: keep last MAX_ENTRIES
if [[ -f "$LOG_FILE" ]]; then
  line_count=$(wc -l < "$LOG_FILE")
  if [[ "$line_count" -gt "$MAX_ENTRIES" ]]; then
    tail -n "$MAX_ENTRIES" "$LOG_FILE" > "${LOG_FILE}.tmp"
    mv "${LOG_FILE}.tmp" "$LOG_FILE"
  fi
fi

exit 0
