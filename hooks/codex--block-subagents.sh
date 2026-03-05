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

# Load blocked list from blocked-subagents.conf (same directory as this script)
CONF_FILE="$SCRIPT_DIR/blocked-subagents.conf"

if [[ -f "$CONF_FILE" ]]; then
  # Normalise incoming subagent: lowercase, replace hyphens with underscores
  normalised_subagent="${subagent//-/_}"
  while IFS= read -r line; do
    # Skip comments and blank lines
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    name="${line%%:*}"
    sandbox="${line#*:}"
    # Normalise config entry the same way
    normalised_name="${name//-/_}"
    normalised_name="$(printf '%s' "$normalised_name" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    if [[ "$normalised_subagent" == "$normalised_name" ]]; then
      deny "${name} subagent is blocked. Use mcp__delegate__codex with sandbox: ${sandbox} instead."
    fi
  done < "$CONF_FILE"
fi

exit 0
