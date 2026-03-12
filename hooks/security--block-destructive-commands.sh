#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash)
# Blocks destructive commands that could cause data loss.
# HOOK_EVENT: PreToolUse
# HOOK_MATCHER: Bash
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
raw_command="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null)" \
  || deny_on_parse_error

# Normalize command to reduce bypass surface:
# - Strip quotes, backticks, and backslashes that could obfuscate commands
# - Collapse whitespace
# - This catches tricks like r''m, c"u"rl, rm\ -rf, etc.
command="$(normalize_command "$raw_command")"

# Token-based approach: parse normalized command into words and inspect
# flags/options irrespective of argument order, avoiding bypasses like:
# - rm -rf /tmp/foo      -> BLOCK
# - rm /tmp/foo -rf      -> BLOCK
# - rm -r -f /tmp/foo    -> BLOCK
# - rm /tmp/foo          -> ALLOW (no force+recursive)
# - rm -r /tmp/foo       -> depends on existing policy (currently BLOCK)
tokens=()
read -r -a tokens <<< "$command"

contains_token() {
  local needle="$1"
  local token
  for token in "${tokens[@]}"; do
    token="${token##*/}"
    if [[ "$token" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

is_short_flag_group() {
  local token="$1"
  [[ "$token" =~ ^-[^-]+$ ]]
}

has_short_flag_char() {
  local char="$1"
  local token
  for token in "${tokens[@]}"; do
    if is_short_flag_group "$token" && [[ "$token" == *"$char"* ]]; then
      return 0
    fi
  done
  return 1
}

git_has_subcommand() {
  local subcommand="$1"
  local i
  for ((i = 0; i < ${#tokens[@]} - 1; i++)); do
    if [[ "${tokens[$i]##*/}" == "git" && "${tokens[$((i + 1))]}" == "$subcommand" ]]; then
      return 0
    fi
  done
  return 1
}

matched=""

rm_recursive=false
rm_force=false
rm_glob=false
if contains_token "rm"; then
  if contains_token "--recursive" || has_short_flag_char "r" || has_short_flag_char "R"; then
    rm_recursive=true
  fi
  if contains_token "--force" || has_short_flag_char "f"; then
    rm_force=true
  fi
  local_token=""
  for local_token in "${tokens[@]}"; do
    if [[ "$local_token" == *"*"* || "$local_token" == *"?"* || "$local_token" == *"["* ]]; then
      rm_glob=true
      break
    fi
  done
fi

if [[ "$rm_recursive" == true && ( "$rm_force" == true || "$rm_glob" == true ) ]]; then
  matched="rm recursive+force/glob"
elif [[ "$rm_recursive" == true ]]; then
  matched="rm recursive"
elif [[ "$rm_force" == true ]]; then
  matched="rm force"
elif printf '%s\n' "$command" | grep -Eiq 'drop\s+table'; then
  matched="drop table"
elif contains_token "shutdown"; then
  matched="shutdown"
elif contains_token "mkfs"; then
  matched="mkfs"
elif contains_token "dd"; then
  token=""
  for token in "${tokens[@]}"; do
    if [[ "$token" == if=* ]]; then
      matched="dd if="
      break
    fi
  done
elif git_has_subcommand "reset" && contains_token "--hard"; then
  matched="git reset --hard"
elif git_has_subcommand "checkout" && contains_token "."; then
  matched="git checkout ."
elif git_has_subcommand "push" && (contains_token "--force" || has_short_flag_char "f"); then
  matched="git push --force/-f"
elif git_has_subcommand "clean" && (contains_token "-f" || has_short_flag_char "f"); then
  matched="git clean -f"
elif git_has_subcommand "branch" && contains_token "-D"; then
  matched="git branch -D"
fi

if [[ -n "$matched" ]]; then
  "$SCRIPT_DIR/security--log-security-event.sh" "block-destructive-commands" "Bash" "$matched" "$raw_command" "high" &>/dev/null || true
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Destructive command blocked. Commands like rm -rf, git reset --hard, git push --force are not permitted without explicit user approval."
  }
}
EOF
  exit 0
fi

exit 0
