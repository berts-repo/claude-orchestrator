#!/usr/bin/env bash
# UserPromptSubmit hook
# Detects prompts that imply time-sensitive information needs and injects
# context directing Claude to use search proactively — before any inference.
# Replaces the Stop-hook approach (web--require-web-if-recency.sh) which
# fired too late: tokens were already spent on a response that needed retrying.
# HOOK_EVENT: UserPromptSubmit
# HOOK_TIMEOUT: 5
set -euo pipefail

payload="$(cat)"
prompt="$(echo "$payload" | jq -r '.prompt // ""')"

# Match prompts that imply the answer depends on current/recent external state.
# Patterns cover:
#   - version/release recency ("latest version", "newest release", "most recent update")
#   - currency of status ("is X still supported", "currently maintained", "still alive")
#   - recent news/changes ("what's new in", "recent changes", "breaking news")
#   - explicit time anchors ("as of today", "as of 2025", "right now")
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
