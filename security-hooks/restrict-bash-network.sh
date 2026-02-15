#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash)
# Blocks Bash commands that make direct network connections.
# Forces all web access through the web_search MCP tool.
set -euo pipefail

payload="$(cat)"
raw_command="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')"

# Normalize command to reduce bypass surface:
# - Strip quotes, backticks, and backslashes that could obfuscate commands
# - Collapse whitespace
# - This catches tricks like c"u"rl, w''get, etc.
command="$(printf '%s' "$raw_command" | tr -d "'\"\`\\\\" | tr -s '[:space:]' ' ')"

# Match common network client commands and programming language HTTP calls
# Use (^|[;&| ]) to ensure we match commands, not paths like .ssh/
if printf '%s\n' "$command" | grep -Eiq '(^|[;&| ])(curl|wget|nc|ncat|nmap|socat|ssh|scp|sftp|rsync|ftp|telnet|httpie|aria2c?|lynx|links|w3m)( |$|;)|/dev/tcp/|python[23]?\s.*\b(requests|urllib|http\.client|aiohttp|httpx)\b|node\s.*\b(fetch|http|https|axios|got|request)\b|ruby\s.*\b(net.http|open-uri|httparty|faraday)\b|php\s.*\b(curl_exec|file_get_contents\s*\(\s*["\x27]https?)\b'; then
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
