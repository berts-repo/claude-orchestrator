#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash)
# Blocks Bash commands that make direct network connections.
# Forces all web access through the web_search MCP tool.
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
# - Strip quotes, backticks, backslashes, and shell expansion chars that could obfuscate commands
# - Collapse whitespace
# - This catches tricks like c"u"rl, w''get, $(curl foo), etc.
command="$(printf '%s' "$raw_command" | tr -d "'\"\`\\\\\$(){}[]" | tr -s '[:space:]' ' ')"

# Match common network client commands and programming language HTTP calls
# Use (^|[^a-zA-Z0-9_/-]) to ensure we match commands, not paths like .ssh/
if printf '%s\n' "$command" | grep -Eiq '(^|[^a-zA-Z0-9_/-])(curl|wget|nc|ncat|nmap|socat|ssh|scp|sftp|rsync|ftp|telnet|httpie|aria2c?|lynx|links|w3m)( |$|;)|/dev/tcp/|python[23]?\s.*\b(requests|urllib|http\.client|aiohttp|httpx)\b|node\s.*\b(fetch|http|https|axios|got|request)\b|ruby\s.*\b(net.http|open-uri|httparty|faraday)\b|php\s.*\b(curl_exec|file_get_contents\s*\(\s*["\x27]https?)\b'; then
  matched=$(printf '%s' "$command" | grep -Eio '(curl|wget|nc|ncat|nmap|socat|ssh|scp|sftp|rsync|ftp|telnet|httpie|aria2c?|lynx|links|w3m|/dev/tcp/|requests|urllib|fetch|http\.client)' | head -1)
  "$SCRIPT_DIR/security--log-security-event.sh" "restrict-bash-network" "Bash" "$matched" "$raw_command" "medium" &>/dev/null || true
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Direct network access via Bash is restricted. Use the web_search MCP tool for internet access."
  }
}
EOF
  exit 0
fi

exit 0
