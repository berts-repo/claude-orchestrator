#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash)
# Blocks destructive commands that could cause data loss.
set -euo pipefail

deny_on_parse_error() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Hook failed to parse tool input \xe2\x80\x94 denying to fail secure."}}\n'
  exit 2
}

REAL_SCRIPT="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"

payload="$(cat)"
raw_command="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null)" \
  || deny_on_parse_error

# Normalize command to reduce bypass surface:
# - Strip quotes, backticks, and backslashes that could obfuscate commands
# - Collapse whitespace
# - This catches tricks like r''m, c"u"rl, rm\ -rf, etc.
command="$(printf '%s' "$raw_command" | tr -d "'\"\`\\\\" | tr -s '[:space:]' ' ')"

# Block destructive patterns:
# - rm -rf, rm -f, rm --recursive, rm --force
# - drop table (SQL)
# - shutdown
# - mkfs (format filesystem)
# - dd if= (raw disk writes)
# - git reset --hard
# - git checkout .
# - git push --force / git push -f
# - git clean -f
# - git branch -D
if printf '%s\n' "$command" | grep -Eiq \
  'rm\s+(-[a-z]*r|-[a-z]*f|--recursive|--force)|drop\s+table|shutdown|mkfs|dd\s+if=|git\s+(reset\s+--hard|checkout\s+\.|push\s+(--force|-f)|clean\s+-f|branch\s+-D)'; then
  matched=$(printf '%s' "$command" | grep -Eio 'rm\s+(-rf|-f|--recursive|--force)|drop\s+table|shutdown|mkfs|dd\s+if=|git\s+(reset\s+--hard|checkout\s+\.|push\s+(--force|-f)|clean\s+-f|branch\s+-D)' | head -1)
  "$SCRIPT_DIR/security--log-security-event.sh" "block-destructive-commands" "Bash" "$matched" "$raw_command" "high" &>/dev/null || true
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Destructive command blocked. Commands like rm -rf, git reset --hard, git push --force are not permitted without explicit user approval."
  }
}
EOF
  exit 0
fi

exit 0
