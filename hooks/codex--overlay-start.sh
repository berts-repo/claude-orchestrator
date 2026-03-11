#!/usr/bin/env bash
# PreToolUse hook
# Launches a live task overlay window for Codex delegations.
# HOOK_EVENT: PreToolUse
# HOOK_MATCHER: mcp__delegate__codex|mcp__delegate__codex_parallel
# HOOK_TIMEOUT: 5
set -euo pipefail

WATCH_SCRIPT="/home/me/git/claude-orchestrator/scripts/watch-tasks.sh"
TMP_DIR="${HOME}/.claude/tmp"
OVERLAY_PID_FILE="${TMP_DIR}/overlay.pid"

mkdir -p "$TMP_DIR"

cat >/dev/null || true

terminal_pid=""
if command -v ghostty >/dev/null 2>&1; then
  ghostty --title="Codex Tasks" -e bash "$WATCH_SCRIPT" auto >/dev/null &
  terminal_pid="$!"
elif command -v alacritty >/dev/null 2>&1; then
  alacritty --title "Codex Tasks" -e bash "$WATCH_SCRIPT" auto >/dev/null &
  terminal_pid="$!"
elif command -v kitty >/dev/null 2>&1; then
  kitty --title "Codex Tasks" bash "$WATCH_SCRIPT" auto >/dev/null &
  terminal_pid="$!"
fi

if [[ -n "$terminal_pid" ]]; then
  printf '%s' "$terminal_pid" > "$OVERLAY_PID_FILE"
fi

exit 0
