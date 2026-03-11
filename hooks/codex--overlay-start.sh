#!/usr/bin/env bash
# PreToolUse hook
# Launches a live task overlay window for Codex delegations.
# HOOK_EVENT: PreToolUse
# HOOK_MATCHER: mcp__delegate__codex|mcp__delegate__codex_parallel
# HOOK_TIMEOUT: 5
set -euo pipefail

WATCH_SCRIPT="/home/me/git/claude-orchestrator/scripts/watch-tasks.sh"
TMP_DIR="${HOME}/.claude/tmp"
CURRENT_BATCH_FILE="${TMP_DIR}/current-batch-id"
OVERLAY_PID_FILE="${TMP_DIR}/overlay.pid"

mkdir -p "$TMP_DIR"

payload="$(cat)"
batch_id=""

# Prefer an explicit batch id if the payload includes one.
if command -v jq >/dev/null 2>&1; then
  batch_id="$(
    printf '%s' "$payload" | jq -r '
      .tool_input.batchId
      // .tool_input.batch_id
      // .tool_input["batch-id"]
      // .batchId
      // .batch_id
      // empty
    ' 2>/dev/null || true
  )"

  # If no explicit id is present, derive a stable id from tool_input when available.
  if [[ -z "$batch_id" ]]; then
    tool_input_compact="$(printf '%s' "$payload" | jq -c '.tool_input // empty' 2>/dev/null || true)"
    if [[ -n "$tool_input_compact" && "$tool_input_compact" != "null" ]]; then
      if command -v shasum >/dev/null 2>&1; then
        batch_id="$(printf '%s' "$tool_input_compact" | shasum -a 256 | cut -c1-36)"
      elif command -v sha256sum >/dev/null 2>&1; then
        batch_id="$(printf '%s' "$tool_input_compact" | sha256sum | cut -c1-36)"
      fi
    fi
  fi
fi

if [[ -z "$batch_id" ]]; then
  batch_id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)"
fi

if [[ -z "$batch_id" ]]; then
  batch_id="$(date +%s)-$$-$RANDOM"
fi

printf '%s' "$batch_id" > "$CURRENT_BATCH_FILE"

terminal_pid=""
if command -v ghostty >/dev/null 2>&1; then
  ghostty --title="Codex Tasks" -e bash "$WATCH_SCRIPT" "$batch_id" >/dev/null &
  terminal_pid="$!"
elif command -v alacritty >/dev/null 2>&1; then
  alacritty --title "Codex Tasks" -e bash "$WATCH_SCRIPT" "$batch_id" >/dev/null &
  terminal_pid="$!"
elif command -v kitty >/dev/null 2>&1; then
  kitty --title "Codex Tasks" bash "$WATCH_SCRIPT" "$batch_id" >/dev/null &
  terminal_pid="$!"
fi

if [[ -n "$terminal_pid" ]]; then
  printf '%s' "$terminal_pid" > "$OVERLAY_PID_FILE"
fi

exit 0
