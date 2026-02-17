#!/usr/bin/env bash
# Security event logger — called by PreToolUse hooks when they deny an action.
# NOT a hook itself. Invoked by existing hooks before they output the deny JSON.
# Writes to ~/.claude/logs/security-events.jsonl with FIFO rotation.
set -euo pipefail

REAL_SCRIPT="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
source "$SCRIPT_DIR/shared--log-helpers.sh"

MAX_ENTRIES=200
LOG_FILE="${LOG_DIR}/security-events.jsonl"

# Usage: log-security-event.sh <hook_name> <tool_name> <pattern_matched> <command_preview> [severity]
# All args are optional — missing args default to "unknown"
hook_name="${1:-unknown}"
tool_name="${2:-unknown}"
pattern_matched="${3:-unknown}"
command_preview="${4:-}"
severity="${5:-medium}"

# Truncate command preview to 80 chars for safety (no secrets in logs)
if [[ ${#command_preview} -gt 80 ]]; then
  command_preview="${command_preview:0:77}..."
fi

ensure_dirs

# Map severity to log level
case "$severity" in
  critical|high) log_level="error" ;;
  medium)        log_level="warn" ;;
  low)           log_level="info" ;;
  *)             log_level="warn" ;;
esac

# Build and append log entry
log_entry=$(log_json "$log_level" "security" "security_deny" \
  --arg hook "$hook_name" \
  --arg tool "$tool_name" \
  --arg action "deny" \
  --arg severity "$severity" \
  --arg pattern_matched "$pattern_matched" \
  --arg command_preview "$command_preview" \
  --arg cwd "$(pwd)")

echo "$log_entry" >> "$LOG_FILE"

# FIFO rotation: keep last MAX_ENTRIES
rotate_jsonl "$LOG_FILE" "$MAX_ENTRIES"

exit 0
