#!/usr/bin/env bash
# Stop hook — soft enforcement
# Checks the last assistant message for recency claims without source URLs.
# If detected, blocks the response so Claude retries with web_search.
#
# Limitations (documented):
# - Keyword-based detection is bypassable via synonyms
# - Cannot verify that cited URLs are real or match claims
# - Best-effort guardrail, not a hard security boundary
set -euo pipefail

payload="$(cat)"
transcript="$(echo "$payload" | jq -r '.transcript_path // ""')"

# If we can't find the transcript, pass through
if [ -z "$transcript" ] || [ ! -f "$transcript" ]; then
  exit 0
fi

# Get the last assistant message from the transcript (JSONL format)
# Read last 50 lines to find the most recent assistant content
last_output="$(tail -n 50 "$transcript" | grep -i '"assistant"' | tail -n 1 || true)"

if [ -z "$last_output" ]; then
  exit 0
fi

# Check for recency keywords — only phrases that strongly imply external time-sensitive claims.
# Avoids standalone "currently"/"latest" which frequently appear in local file discussions.
if echo "$last_output" | grep -Eiq '\b(as of (today|this week|this month|january|february|march|april|may|june|july|august|september|october|november|december|20[2-3][0-9])|(latest|newest|most recent) (version|release|update|data|report|news|article|study)|(currently|now) (available|supported|maintained|deprecated|recommended) |breaking news|just (released|announced|launched)|updated (today|this week|this month|yesterday))\b'; then
  # Check if there are URLs present (indicating sources were cited)
  if ! echo "$last_output" | grep -Eiq 'https?://'; then
    cat <<'EOF'
{
  "decision": "block",
  "reason": "Your response contains time-sensitive claims but no source URLs. Use the web_search tool to find and cite current sources."
}
EOF
    exit 0
  fi
fi

exit 0
