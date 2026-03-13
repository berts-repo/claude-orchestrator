#!/usr/bin/env bash
# Shared helpers for Claude Orchestrator hooks.
# Source this file — do not execute directly.
# Provides: SESSION_ID, ensure_dirs()
# HOOK_HELPER: true

# Guard against double-sourcing
[[ -n "${_LOG_HELPERS_LOADED:-}" ]] && return 0
_LOG_HELPERS_LOADED=1

# Session ID: short hash of PPID + today's date.
# Groups all events within one Claude Code process tree per day.
if [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
  SESSION_ID="$CLAUDE_SESSION_ID"
else
  SESSION_ID=$(printf '%s' "${PPID:-0}-$(date -u +%Y-%m-%d)" | shasum -a 256 | cut -c1-12)
fi
export SESSION_ID

# ensure_dirs — create ~/.claude if it does not exist
ensure_dirs() {
  mkdir -p "${HOME}/.claude"
}
