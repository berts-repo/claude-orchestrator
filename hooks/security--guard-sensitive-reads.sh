#!/usr/bin/env bash
# PreToolUse hook
# Blocks reads of sensitive files to prevent credential exfiltration.
# Allows ~/.config/hypr/ for legitimate window manager config editing.
# HOOK_EVENT: PreToolUse
# HOOK_MATCHER: Read|Bash|Glob|Edit|Write
# HOOK_TIMEOUT: 5
set -euo pipefail

payload="$(cat)"

deny_on_parse_error() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Hook failed to parse tool input \xe2\x80\x94 denying to fail secure."}}\n'
  exit 2
}

tool_name=$(echo "$payload" | jq -r '.tool_name // ""' 2>/dev/null) || deny_on_parse_error

# Only check Read, Glob, Bash, Edit, and Write tools
if [[ "$tool_name" != "Read" && "$tool_name" != "Glob" && \
      "$tool_name" != "Bash" && "$tool_name" != "Edit" && \
      "$tool_name" != "Write" ]]; then
  exit 0
fi

REAL_SCRIPT="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"

# Helper to deny access
deny() {
  local reason="$1"
  "$SCRIPT_DIR/security--log-security-event.sh" "guard-sensitive-reads" "$tool_name" "$reason" "${raw_path:-}${raw_pattern:-}${raw_command:-}" "medium" &>/dev/null || true
  printf '%s\n' "$(cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "$reason"
  }
}
EOF
)"
  exit 0
}

# Extract the relevant input
if [[ "$tool_name" == "Read" || "$tool_name" == "Edit" || \
      "$tool_name" == "Write" || "$tool_name" == "Glob" ]]; then
  if [[ "$tool_name" == "Read" || "$tool_name" == "Edit" || "$tool_name" == "Write" ]]; then
    raw_path=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // ""' 2>/dev/null) || deny_on_parse_error
  else
    raw_path=$(printf '%s' "$payload" | jq -r '.tool_input.path // ""' 2>/dev/null) || deny_on_parse_error
    raw_pattern=$(printf '%s' "$payload" | jq -r '.tool_input.pattern // ""' 2>/dev/null) || deny_on_parse_error
  fi

  # Canonicalize path to prevent symlink/traversal bypasses
  # Use realpath to resolve symlinks and ../ components
  if [[ -e "$raw_path" ]]; then
    # File exists - resolve to canonical path
    target=$(realpath -e -- "$raw_path" 2>/dev/null) || target="$raw_path"

    # Also block if the original path is a symlink pointing to sensitive location
    if [[ -L "$raw_path" ]]; then
      link_target=$(readlink -f -- "$raw_path" 2>/dev/null) || link_target=""
      # Check both the symlink path and its target
      target="$raw_path $link_target"
    fi
  else
    # File doesn't exist yet - normalize the path components
    target=$(realpath -m -- "$raw_path" 2>/dev/null) || target="$raw_path"
  fi

  # Include glob pattern so path+pattern based attempts are inspectable in logs/matching.
  if [[ "$tool_name" == "Glob" && -n "${raw_pattern:-}" ]]; then
    target="$target $raw_pattern"
  fi
else
  # For Bash, check the command for cat/head/tail of sensitive paths
  raw_command=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null) || deny_on_parse_error
  # Normalize command to catch obfuscation
  target=$(printf '%s' "$raw_command" | tr -d "'\"\`\\\\" | tr -s '[:space:]' ' ')
  # Expand ~ to $HOME
  target="${target//~/$HOME}"
  # Normalize /../ and /./ sequences (iterate for nested traversals)
  while [[ "$target" == *"/../"* || "$target" == *"/./"* ]]; do
    target="$(printf '%s' "$target" | sed 's|/[^/]*/\.\./|/|g; s|/\./|/|g')"
  done
  # Strip any remaining leading ../ sequences
  target="${target//\.\.\//}"
fi

# Expand ~ to $HOME for matching
expanded_home="$HOME"
home_path_prefix="(${expanded_home}|~|['\"]?\\\$HOME['\"]?|['\"]?\\\$\\{HOME\\}['\"]?)"

# Block sensitive paths (but allow ~/.config/ generally)
sensitive_patterns=(
  "${home_path_prefix}/\.ssh"
  "${home_path_prefix}/\.aws"
  "${home_path_prefix}/\.config/(gcloud|gh|claude|codex)"
  "${home_path_prefix}/\.config/[Bb]itwarden"
  "${home_path_prefix}/\.config/1[Pp]assword"
  "${home_path_prefix}/\.1password"
  "${home_path_prefix}/\.codex"
  "${home_path_prefix}/\.claude\.json"
  "\.env($|[^a-zA-Z])"
  "id_rsa|id_ed25519|id_ecdsa"
  "\.pem(\s|$|[|;&>])"
)

for pattern in "${sensitive_patterns[@]}"; do
  if printf '%s\n' "$target" | grep -qE "$pattern"; then
    deny "Blocked access to sensitive file matching pattern: $pattern"
  fi
done

exit 0
