#!/usr/bin/env bash
# PreToolUse hook: Enforce Codex delegation for large new code file writes.
set -euo pipefail

payload="$(cat)"

deny_on_parse_error() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Hook failed to parse tool input - denying to fail secure."}}\n'
  exit 2
}

tool_name="$(printf '%s' "$payload" | jq -r '.tool_name // ""' 2>/dev/null)" || deny_on_parse_error
[[ "$tool_name" != "Write" ]] && exit 0

file_path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // ""' 2>/dev/null)" || deny_on_parse_error
[[ -z "$file_path" ]] && exit 0

# Overwrites to existing files are allowed.
[[ -e "$file_path" ]] && exit 0

extension="${file_path##*.}"
extension="$(printf '%s' "$extension" | tr '[:upper:]' '[:lower:]')"

case "$extension" in
  py|js|ts|tsx|jsx|go|rs|rb|java|c|cpp|sh|bash|zsh|php|swift|kt|scala|lua|r|m|cs|ex|exs|zig|v|nim)
    ;;
  *)
    exit 0
    ;;
esac

content="$(printf '%s' "$payload" | jq -r '.tool_input.content // .tool_input.file_content // .tool_input.text // ""' 2>/dev/null)" || deny_on_parse_error
line_count="$(printf '%s' "$content" | awk 'END { print NR }')"

# Allow small helpers and config-like files.
if [[ "$line_count" -lt 25 ]]; then
  exit 0
fi

REAL_SCRIPT="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
source "$SCRIPT_DIR/shared--log-helpers.sh"

ensure_dirs
LOG_FILE="${LOG_DIR}/delegations.jsonl"
ABS_CWD="$(pwd -P)"

log_entry="$(log_json "warn" "delegation" "enforce_code_write_block" \
  --arg tool "Write" \
  --arg file_path "$file_path" \
  --arg extension "$extension" \
  --argjson line_count "$line_count" \
  --arg cwd "$ABS_CWD" \
  --arg action "deny")"

echo "$log_entry" >> "$LOG_FILE"

cat <<EOF_JSON
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Large new code file creation is blocked for Write. Use mcp__codex__codex with sandbox: workspace-write and approval-policy: on-failure. Always set cwd to absolute path: $ABS_CWD. Follow CLAUDE.md Codex Delegation rules."
  }
}
EOF_JSON

exit 0
