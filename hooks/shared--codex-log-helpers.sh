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
