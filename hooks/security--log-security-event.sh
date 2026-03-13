#!/usr/bin/env bash
# Security event logger — called by PreToolUse hooks when they deny an action.
# NOT a hook itself. Invoked by existing hooks before they output the deny JSON.
# Writes to ~/.claude/audit.db security_events table.
# HOOK_HELPER: true
set -euo pipefail

REAL_SCRIPT="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
source "$SCRIPT_DIR/shared--log-helpers.sh"

command -v sqlite3 >/dev/null 2>&1 || exit 0
[[ -f "${HOME}/.claude/audit.db" ]] || exit 0

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

# Map severity to log level
case "$severity" in
  critical|high) log_level="error" ;;
  medium)        log_level="warn" ;;
  low)           log_level="info" ;;
  *)             log_level="warn" ;;
esac

sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

if [[ "$(uname)" == "Darwin" ]]; then
  epoch_ms="$(python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || date +%s000)"
else
  epoch_ms="$(date +%s%3N 2>/dev/null || date +%s000)"
fi

DB="${HOME}/.claude/audit.db"
sqlite3 "$DB" "INSERT INTO security_events (session_id, timestamp_ms, level, hook, tool, action, severity, pattern_matched, command_preview, cwd) VALUES ('$(sql_escape "$SESSION_ID")', ${epoch_ms}, '$(sql_escape "$log_level")', '$(sql_escape "$hook_name")', '$(sql_escape "$tool_name")', 'deny', '$(sql_escape "$severity")', '$(sql_escape "$pattern_matched")', '$(sql_escape "$command_preview")', '$(sql_escape "$(pwd)")');"

exit 0
