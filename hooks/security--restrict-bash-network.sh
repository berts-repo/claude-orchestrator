#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash)
# Blocks Bash commands that make direct network connections.
# Forces all web access through the search MCP tool.
# HOOK_EVENT: PreToolUse
# HOOK_MATCHER: Bash
# HOOK_TIMEOUT: 5
set -euo pipefail

deny_on_parse_error() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Hook failed to parse tool input \xe2\x80\x94 denying to fail secure."}}\n'
  exit 2
}

REAL_SCRIPT="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
. "$SCRIPT_DIR/shared--normalize-cmd.sh"

payload="$(cat)"
raw_command="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null)" \
  || deny_on_parse_error

# Normalize command to reduce bypass surface:
# - Strip quotes, backticks, backslashes, and shell expansion chars that could obfuscate commands
# - Collapse whitespace
# - This catches tricks like c"u"rl, w''get, $(curl foo), etc.
command="$(normalize_command "$raw_command" aggressive)"

# Deny-by-default for known network-capable commands and transport subcommands.
if printf '%s\n' "$command" | grep -Eiq '(^|[;&|()[:space:]])([[:alnum:]_./-]*/)?(curl|wget|fetch|httpie|http|aria2c|axel|dig|nslookup|host|ping|traceroute|nc|netcat|ncat|socat|ssh|scp|sftp|rsync|apt|apt-get|brew|snap)([[:space:];]|$)|(^|[;&|()[:space:]])([[:alnum:]_./-]*/)?git([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+(fetch|push|pull|clone|remote)([[:space:];]|$)|(^|[;&|()[:space:]])([[:alnum:]_./-]*/)?pip([23](\.[0-9]+)*)?([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+(install|download)([[:space:];]|$)|(^|[;&|()[:space:]])([[:alnum:]_./-]*/)?npm([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+(install|ci|update)([[:space:];]|$)|(^|[;&|()[:space:]])([[:alnum:]_./-]*/)?yarn([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+(add|install)([[:space:];]|$)|(^|[;&|()[:space:]])([[:alnum:]_./-]*/)?pnpm([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+install([[:space:];]|$)|(^|[;&|()[:space:]])([[:alnum:]_./-]*/)?cargo([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+install([[:space:];]|$)|(^|[;&|()[:space:]])([[:alnum:]_./-]*/)?go([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+(get|install)([[:space:];]|$)|(^|[;&|()[:space:]])([[:alnum:]_./-]*/)?python([23](\.[0-9]+)*)?([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+-c[[:space:]].*(urllib|requests|http\.client)|(^|[;&|()[:space:]])([[:alnum:]_./-]*/)?node([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+-e[[:space:]].*(http|https|fetch)|/dev/tcp/'; then
  matched=$(printf '%s' "$command" | grep -Eio '(curl|wget|fetch|httpie|http|aria2c|axel|git([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+(fetch|push|pull|clone|remote)|pip([23](\.[0-9]+)*)?([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+(install|download)|npm([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+(install|ci|update)|yarn([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+(add|install)|pnpm([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+install|cargo([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+install|go([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+(get|install)|apt-get|apt|brew|snap|dig|nslookup|host|ping|traceroute|nc|netcat|ncat|socat|ssh|scp|sftp|rsync|python([23](\.[0-9]+)*)?([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+-c[[:space:]].*(urllib|requests|http\.client)|node([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+-e[[:space:]].*(http|https|fetch)|/dev/tcp/)' | head -1)
  "$SCRIPT_DIR/security--log-security-event.sh" "restrict-bash-network" "Bash" "$matched" "$raw_command" "medium" &>/dev/null || true
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Network access from Bash is restricted by policy. Use approved MCP tools for internet access."
  }
}
EOF
  exit 0
fi

exit 0
