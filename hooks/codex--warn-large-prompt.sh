#!/usr/bin/env bash
# PreToolUse hook: Warn when a Codex prompt exceeds 8000 chars
# HOOK_EVENT: PreToolUse
# HOOK_MATCHER: mcp__delegate__codex|mcp__delegate__codex_parallel
# HOOK_TIMEOUT: 5
set -euo pipefail

LARGE_PROMPT_THRESHOLD=8000

payload="$(cat)"

prompt_len="$(echo "$payload" | jq -r '
  if .tool_input.prompt then
    (.tool_input.prompt | length)
  elif (.tool_input.tasks | type) == "array" then
    [.tool_input.tasks[].prompt | length] | max
  else
    0
  end
' 2>/dev/null)" || exit 0

[[ -z "$prompt_len" || "$prompt_len" == "null" ]] && exit 0

if (( prompt_len > LARGE_PROMPT_THRESHOLD )); then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","hookOutputToModel":"[codex-warn] Prompt is %d chars (threshold: %d). Prefer passing file paths over inlined content — Codex can read files directly with cat/rg. Only inline snippets under 50 lines."}}\n' \
    "$prompt_len" "$LARGE_PROMPT_THRESHOLD"
fi

exit 0
