#!/usr/bin/env bash
# UserPromptSubmit hook
# Detects explicit web search intent OR time-sensitive queries and injects
# context directing Claude to use the search MCP tool before responding.
# HOOK_EVENT: UserPromptSubmit
# HOOK_TIMEOUT: 5
set -euo pipefail

payload="$(cat)"
prompt="$(echo "$payload" | jq -r '.prompt // ""')"

# Explicit web search intent
if echo "$prompt" | grep -Eiq '(search the web|search online|web search|look up online|look on the internet|do (some )?research|do a deep dive|research online|look it up online|find online|check online|google|search for .* online)'; then
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "The user explicitly requested web access. Use the search MCP tool to fulfill this request. Cite all sources returned by the tool."
  }
}
EOF
  exit 0
fi

# Time-sensitive / recency-dependent queries
if echo "$prompt" | grep -Eiq \
  '(latest|newest|most[- ]recent)\s+(version|release|update|patch|build|tag|changelog|news|article|study|report|data)|
(is|are)\s+\S+(\s+\S+)?\s+still\s+(supported|maintained|active|alive|developed|recommended)|
(currently|right now|as of (today|now|this (week|month|year)|20[2-9][0-9]))\s+(available|supported|maintained|deprecated|recommended|the\s+(best|standard|recommended))|
what.{0,20}new\s+in\s+\S|
recent\s+(changes|updates|release|news|developments|commits|activity)|
breaking\s+news|
just\s+(released|announced|launched|shipped|published)|
(updated?|released?|announced?)\s+(today|this\s+(week|month|year)|yesterday|recently)'; then

  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "This prompt asks about time-sensitive or current state information. Use the search MCP tool first to retrieve current data before responding. Cite all source URLs returned by the tool."
  }
}
EOF
  exit 0
fi

exit 0
