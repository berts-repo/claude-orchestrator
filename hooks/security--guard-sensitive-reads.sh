#!/usr/bin/env bash
# PreToolUse hook
# Blocks reads of sensitive files to prevent credential exfiltration.
# Allows ~/.config/hypr/ for legitimate window manager config editing.
set -euo pipefail

payload="$(cat)"

tool_name=$(echo "$payload" | jq -r '.tool_name // ""')

# Only check Read and Bash tools
if [[ "$tool_name" != "Read" && "$tool_name" != "Bash" ]]; then
  exit 0
fi

REAL_SCRIPT="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"

# Helper to deny access
deny() {
  local reason="$1"
  "$SCRIPT_DIR/security--log-security-event.sh" "guard-sensitive-reads" "$tool_name" "$reason" "${raw_path:-}${raw_command:-}" &>/dev/null || true
  cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "$reason"
  }
}
EOF
  exit 0
}

# Extract the relevant input
if [[ "$tool_name" == "Read" ]]; then
  raw_path=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // ""')

  # Canonicalize path to prevent symlink/traversal bypasses
  # Use realpath to resolve symlinks and ../ components
  if [[ -e "$raw_path" ]]; then
    # File exists - resolve to canonical path
    target=$(realpath -e -- "$raw_path" 2>/dev/null) || target="$raw_path"

    # Also block if the original path is a symlink pointing to sensitive location
    # (even if we're checking the resolved path, log the attempt)
    if [[ -L "$raw_path" ]]; then
      link_target=$(readlink -f -- "$raw_path" 2>/dev/null) || link_target=""
      # Check both the symlink path and its target
      target="$raw_path $link_target"
    fi
  else
    # File doesn't exist yet - normalize the path components
    target=$(realpath -m -- "$raw_path" 2>/dev/null) || target="$raw_path"
  fi
else
  # For Bash, check the command for cat/head/tail of sensitive paths
  raw_command=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')
  # Normalize command to catch obfuscation
  target=$(printf '%s' "$raw_command" | tr -d "'\"\`\\\\" | tr -s '[:space:]' ' ')
fi

# Expand ~ to $HOME for matching
expanded_home="$HOME"

# Block sensitive paths (but allow ~/.config/ generally)
sensitive_patterns=(
  "(${expanded_home}|~)/\.ssh"
  "(${expanded_home}|~)/\.aws"
  "(${expanded_home}|~)/\.config/(gcloud|gh|claude|codex)"
  "(${expanded_home}|~)/\.config/[Bb]itwarden"
  "(${expanded_home}|~)/\.config/1[Pp]assword"
  "(${expanded_home}|~)/\.1password"
  "(${expanded_home}|~)/\.codex"
  "(${expanded_home}|~)/\.claude\.json"
  "\.env($|[^a-zA-Z])"
  "id_rsa|id_ed25519|id_ecdsa"
  "\.pem$"
)

for pattern in "${sensitive_patterns[@]}"; do
  if printf '%s\n' "$target" | grep -qE "$pattern"; then
    deny "Blocked read of sensitive file matching pattern: $pattern"
  fi
done

exit 0
