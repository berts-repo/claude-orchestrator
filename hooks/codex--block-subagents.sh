#!/usr/bin/env bash
# PreToolUse hook: Block subagents that should be delegated to Codex
# HOOK_EVENT: PreToolUse
# HOOK_MATCHER: Task
# HOOK_TIMEOUT: 5
set -euo pipefail

payload="$(cat)"

deny_on_parse_error() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Hook failed to parse tool input — denying to fail secure."}}\n'
  exit 2
}

tool_name="$(echo "$payload" | jq -r '.tool_name // ""' 2>/dev/null)" || deny_on_parse_error
[[ "$tool_name" != "Task" ]] && exit 0

subagent="$(echo "$payload" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null \
  | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" || deny_on_parse_error

REAL_SCRIPT="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
LOGGER="$SCRIPT_DIR/security--log-security-event.sh"

deny() {
  local reason="$1"
  "$LOGGER" "block-subagent-for-codex" "Task" "$subagent" "subagent_type=$subagent" "low" &>/dev/null || true
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
  exit 0
}

case "$subagent" in
  explore)
    deny "Explore subagent is blocked. Use mcp__delegate__codex with sandbox: read-only instead." ;;
  test_gen|test-gen)
    deny "test_gen subagent is blocked. Use mcp__delegate__codex with sandbox: workspace-write instead." ;;
  doc_comments|doc-comments)
    deny "doc_comments subagent is blocked. Use mcp__delegate__codex with sandbox: workspace-write instead." ;;
  diff_digest|diff-digest)
    deny "diff_digest subagent is blocked. Use mcp__delegate__codex with sandbox: read-only instead." ;;
esac

exit 0
