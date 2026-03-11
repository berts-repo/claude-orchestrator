#!/usr/bin/env bash
# PostToolUse hook
# Stops the live task overlay window for Codex delegations.
# HOOK_EVENT: PostToolUse
# HOOK_MATCHER: mcp__delegate__codex|mcp__delegate__codex_parallel
# HOOK_TIMEOUT: 5
set -u

TMP_DIR="${HOME}/.claude/tmp"
CURRENT_BATCH_FILE="${TMP_DIR}/current-batch-id"
OVERLAY_PID_FILE="${TMP_DIR}/overlay.pid"

if [[ -f "$OVERLAY_PID_FILE" ]]; then
  pid="$(cat "$OVERLAY_PID_FILE" 2>/dev/null || true)"

  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
fi

rm -f "$OVERLAY_PID_FILE" "$CURRENT_BATCH_FILE" 2>/dev/null || true

exit 0
