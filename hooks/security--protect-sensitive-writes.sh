#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash|Edit|Write)
# Blocks direct write/edit/delete operations against .env files and .ssh paths.
# HOOK_EVENT: PreToolUse
# HOOK_MATCHER: Bash|Edit|Write
# HOOK_TIMEOUT: 5
set -euo pipefail

deny_on_parse_error() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Hook failed to parse tool input \xe2\x80\x94 denying to fail secure."}}\n'
  exit 2
}

REAL_SCRIPT="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
. "$SCRIPT_DIR/shared--normalize-cmd.sh"

payload="$(cat)"
tool_name="$(printf '%s' "$payload" | jq -r '.tool_name // ""' 2>/dev/null)" \
  || deny_on_parse_error

if [[ "$tool_name" != "Bash" && "$tool_name" != "Edit" && "$tool_name" != "Write" ]]; then
  exit 0
fi

clean_token() {
  printf '%s' "$1" | sed -E 's/^[(){};,|&<>]+//; s/[(){};,|&<>]+$//'
}

is_protected_env_path() {
  local raw="$1"
  local candidate="$raw"
  local base=""

  candidate="$(clean_token "$candidate")"
  candidate="${candidate#*=}"
  candidate="${candidate#file:}"
  candidate="${candidate%/}"
  base="${candidate##*/}"

  case "$base" in
    .env.example | .env.sample | .env.template)
      return 1
      ;;
  esac

  [[ "$base" =~ ^\.env(\..+)?$ ]]
}

is_protected_ssh_path() {
  local raw="$1"
  local candidate

  candidate="$(clean_token "$raw")"
  [[ "$candidate" =~ (^|/)\.ssh(/|$) ]]
}

is_sensitive_path() {
  local path="$1"
  is_protected_ssh_path "$path" || is_protected_env_path "$path"
}

resolve_canonical_path() {
  local input_path="$1"

  if command -v realpath >/dev/null 2>&1; then
    realpath -e -- "$input_path" 2>/dev/null && return 0
  fi

  if command -v readlink >/dev/null 2>&1; then
    readlink -f -- "$input_path" 2>/dev/null && return 0
  fi

  return 1
}

PATH_CHECK_REASON=""
PATH_CHECK_MATCH=""
PATH_CHECK_MATCHED_TYPE=""

path_hits_sensitive_target() {
  local raw_path="$1"
  local canonical=""

  PATH_CHECK_REASON=""
  PATH_CHECK_MATCH=""
  PATH_CHECK_MATCHED_TYPE=""

  if canonical="$(resolve_canonical_path "$raw_path")"; then
    if [[ "$canonical" != "$raw_path" ]] && is_sensitive_path "$canonical"; then
      PATH_CHECK_REASON="Symlink target resolves to protected path: $canonical"
      PATH_CHECK_MATCH="$canonical"
      PATH_CHECK_MATCHED_TYPE="symlink-target"
      return 0
    fi

    if is_sensitive_path "$canonical"; then
      PATH_CHECK_MATCH="$canonical"
      return 0
    fi

    return 1
  fi

  if is_sensitive_path "$raw_path"; then
    PATH_CHECK_MATCH="$raw_path"
    return 0
  fi

  return 1
}

deny() {
  local reason="$1"
  local matched="$2"
  local raw_input="$3"

  "$SCRIPT_DIR/security--log-security-event.sh" \
    "protect-sensitive-writes" "$tool_name" "$matched" "$raw_input" "high" \
    &>/dev/null || true

  jq -cn --arg reason "$reason" \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
  exit 0
}

command_has_delete_verb() {
  local command="$1"
  local token=""
  local cleaned=""

  for token in $command; do
    cleaned="$(clean_token "$token")"
    case "$cleaned" in
      rm | unlink | shred | truncate)
        return 0
        ;;
    esac
  done

  return 1
}

command_has_sensitive_path() {
  local command="$1"
  local token=""
  local cleaned=""

  for token in $command; do
    cleaned="$(clean_token "$token")"
    if [[ -n "$cleaned" ]] && path_hits_sensitive_target "$cleaned"; then
      return 0
    fi
  done

  return 1
}

command_redirects_to_protected_env() {
  local command="$1"
  local redirect_targets=""
  local redirect_entry=""
  local target=""
  local tokens=()
  local i=0
  local j=0
  local candidate=""

  redirect_targets="$(printf '%s\n' "$command" | grep -Eo '[0-9]*>>?[[:space:]]*[^[:space:];|&]+' || true)"
  if [[ -n "$redirect_targets" ]]; then
    while IFS= read -r redirect_entry; do
      [[ -z "$redirect_entry" ]] && continue
      target="$(printf '%s' "$redirect_entry" | sed -E 's/^[0-9]*>>?[[:space:]]*//')"
      if path_hits_sensitive_target "$target"; then
        return 0
      fi
    done <<<"$redirect_targets"
  fi

  read -r -a tokens <<< "$command"
  for ((i = 0; i < ${#tokens[@]}; i++)); do
    if [[ "$(clean_token "${tokens[$i]}")" != "tee" ]]; then
      continue
    fi

    for ((j = i + 1; j < ${#tokens[@]}; j++)); do
      candidate="$(clean_token "${tokens[$j]}")"
      [[ -z "$candidate" ]] && continue
      if [[ "$candidate" == "-"* ]]; then
        continue
      fi
      if path_hits_sensitive_target "$candidate"; then
        return 0
      fi
    done
  done

  return 1
}

if [[ "$tool_name" == "Edit" || "$tool_name" == "Write" ]]; then
  raw_path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // ""' 2>/dev/null)" \
    || deny_on_parse_error

  if path_hits_sensitive_target "$raw_path"; then
    if [[ -n "$PATH_CHECK_REASON" ]]; then
      deny "$PATH_CHECK_REASON" "symlink-target-protected-path" "$raw_path"
    fi
  fi

  if is_protected_env_path "${PATH_CHECK_MATCH:-$raw_path}"; then
    deny ".env files must be edited by the user directly. Run manually:\n\n  \$EDITOR $raw_path" \
      "protected-env-path" "$raw_path"
  fi

  if is_protected_ssh_path "${PATH_CHECK_MATCH:-$raw_path}"; then
    deny ".ssh paths must be edited by the user directly. Run manually:\n\n  \$EDITOR $raw_path" \
      "protected-ssh-path" "$raw_path"
  fi

  exit 0
fi

raw_command="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null)" \
  || deny_on_parse_error
command="$(normalize_command "$raw_command")"

if command_has_delete_verb "$command" && command_has_sensitive_path "$command"; then
  if [[ -n "$PATH_CHECK_REASON" ]]; then
    deny "$PATH_CHECK_REASON" "symlink-target-protected-path" "$raw_command"
  fi
  deny "Direct modification of .env or .ssh is not permitted. Run manually:\n\n  $raw_command" \
    "delete-on-sensitive-target" "$raw_command"
fi

if command_redirects_to_protected_env "$command"; then
  if [[ -n "$PATH_CHECK_REASON" ]]; then
    deny "$PATH_CHECK_REASON" "symlink-target-protected-path" "$raw_command"
  fi
  deny "Direct modification of .env or .ssh is not permitted. Run manually:\n\n  $raw_command" \
    "redirect-to-protected-env" "$raw_command"
fi

exit 0
