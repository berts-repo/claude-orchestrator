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
    mcp__delegate_web__search|mcp__delegate_web__fetch) echo "web" ;;
    *) echo "" ;;
  esac
}

# codex_log_is_tracked_tool — success if this tool should be logged
codex_log_is_tracked_tool() {
  local tool_name="$1"
  [[ -n "$(codex_log_tool_type "$tool_name")" ]]
}

# codex_log_correlation_key — stable key used between PreToolUse and PostToolUse
# Hashes tool name + full prompt text to avoid collisions on parallel calls
# with identical prompt prefixes.
codex_log_correlation_key() {
  local tool_name="$1"
  local prompt_text="$2"
  printf '%s-%s' "$tool_name" "$prompt_text" | shasum -a 256 | cut -c1-16
}

# codex_log_extract_request_nonce — best-effort stable nonce for one tool invocation
# Uses payload IDs when available so start/post hooks can resolve the same marker.
codex_log_extract_request_nonce() {
  local payload="$1"
  local nonce
  nonce=$(echo "$payload" | jq -r '
    .tool_call_id // .call_id // .invocation_id // .request_id // .id // ""
  ' 2>/dev/null || echo "")
  # Keep filename-safe chars only.
  nonce=$(printf '%s' "$nonce" | tr -cd '[:alnum:]_.-')
  printf '%s' "$nonce"
}

# codex_log_random_nonce — fallback nonce for invocation marker files
codex_log_random_nonce() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 4 2>/dev/null && return
  fi
  printf '%04x%04x' "$RANDOM" "$RANDOM"
}
