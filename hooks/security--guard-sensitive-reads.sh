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

sensitive_match_reason=""
is_sensitive_target() {
  local candidate="$1"
  sensitive_match_reason=""

  for pattern in "${sensitive_patterns[@]}"; do
    if [[ "$pattern" == "\\.env($|[^a-zA-Z])" ]]; then
      env_matches=$(printf '%s\n' "$candidate" | grep -oE '\.env(\.[A-Za-z0-9._-]+)?' || true)
      if [[ -n "$env_matches" ]]; then
        while IFS= read -r env_match; do
          [[ -z "$env_match" ]] && continue
          if [[ ! "$env_match" =~ ^\.env\.(example(\.[A-Za-z0-9._-]+)?|template|sample)$ ]]; then
            sensitive_match_reason="Blocked access to sensitive file matching pattern: $pattern"
            return 0
          fi
        done <<<"$env_matches"
      fi
      continue
    fi

    if printf '%s\n' "$candidate" | grep -qE "$pattern"; then
      sensitive_match_reason="Blocked access to sensitive file matching pattern: $pattern"
      return 0
    fi
  done

  return 1
}

path_has_symlink_component() {
  local raw="$1"
  local normalized current segment

  normalized=$(realpath -m -- "$raw" 2>/dev/null) || normalized="$raw"
  current="/"
  IFS='/' read -r -a parts <<< "${normalized#/}"

  for segment in "${parts[@]}"; do
    [[ -z "$segment" ]] && continue
    if [[ "$current" == "/" ]]; then
      current="/$segment"
    else
      current="$current/$segment"
    fi

    if [[ -L "$current" ]]; then
      return 0
    fi
  done

  return 1
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

  # TOCTOU note: this hook is best-effort only.
  # Full prevention requires kernel-level open enforcement (e.g. O_NOFOLLOW).

  # Symlink-aware check: if any path component is a symlink, resolve the
  # canonical target and evaluate it directly for sensitivity.
  if path_has_symlink_component "$raw_path"; then
    canonical_path=$(realpath -e -- "$raw_path" 2>/dev/null || true)
    if [[ -n "$canonical_path" ]] && is_sensitive_target "$canonical_path"; then
      deny "Symlink resolves to sensitive path: $canonical_path"
    fi
  fi

  # Canonicalize path to prevent traversal bypasses.
  if [[ -e "$raw_path" ]]; then
    # File exists - resolve to canonical path
    target=$(realpath -e -- "$raw_path" 2>/dev/null) || target="$raw_path"
  else
    # Block pre-creation races in sensitive directories.
    parent_path="${raw_path%/*}"
    [[ "$parent_path" == "$raw_path" ]] && parent_path="."
    parent_canonical=$(realpath -m -- "$parent_path" 2>/dev/null) || parent_canonical="$parent_path"
    if is_sensitive_target "$parent_canonical"; then
      deny "Blocked access to sensitive parent directory: $parent_canonical"
    fi

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

if is_sensitive_target "$target"; then
  deny "$sensitive_match_reason"
fi

exit 0
