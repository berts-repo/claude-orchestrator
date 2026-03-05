#!/usr/bin/env bash
# Shared Codex/Gemini delegation logging helpers.
# Source this file — do not execute directly.
# HOOK_HELPER: true

# Guard against double-sourcing
[[ -n "${_CODEX_LOG_HELPERS_LOADED:-}" ]] && return 0
_CODEX_LOG_HELPERS_LOADED=1

# codex_log_extract_tool_name — parse tool_name from hook payload JSON
codex_log_extract_tool_name() {
  local payload="$1"
  echo "$payload" | jq -r '.tool_name // ""'
}

# codex_log_tool_type — classify tracked delegation tools
# Echoes: codex | gemini | ""
codex_log_tool_type() {
  local tool_name="$1"
  case "$tool_name" in
    mcp__delegate__codex|mcp__delegate__codex_parallel) echo "codex" ;;
    mcp__gemini_web__web_search|mcp__gemini_web__web_fetch|mcp__gemini_web__web_summarize) echo "gemini" ;;
    *) echo "" ;;
  esac
}

# codex_log_is_tracked_tool — success if this tool should be logged
codex_log_is_tracked_tool() {
  local tool_name="$1"
  [[ -n "$(codex_log_tool_type "$tool_name")" ]]
}

# codex_log_correlation_key — stable key used between PreToolUse and PostToolUse
# Uses tool name + first 100 chars of prompt/query payload text.
codex_log_correlation_key() {
  local tool_name="$1"
  local prompt_text="$2"
  local prompt_prefix="${prompt_text:0:100}"
  printf '%s-%s' "$tool_name" "$prompt_prefix" | shasum -a 256 | cut -c1-16
}
