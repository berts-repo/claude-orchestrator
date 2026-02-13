#!/usr/bin/env bash
# UserPromptSubmit hook
# Detects explicit web search intent and injects context
# directing Claude to use the web_search MCP tool.
set -euo pipefail

payload="$(cat)"
prompt="$(echo "$payload" | jq -r '.prompt // ""')"

# Match explicit web access phrases
if echo "$prompt" | grep -Eiq '(search the web|search online|web search|look up online|look on the internet|do (some )?research|do a deep dive|research online|look it up online|find online|check online|google|search for .* online)'; then
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "The user explicitly requested web access. Use the web_search MCP tool to fulfill this request. Cite all sources returned by the tool."
  }
}
EOF
  exit 0
fi

exit 0
