# HOOK_HELPER: true

normalize_command() {
  local raw_command="$1"
  local mode="${2:-basic}"
  local normalized

  normalized="$(printf '%s' "$raw_command" | tr -d "'\"\`\\\\")"

  if [[ "$mode" == "aggressive" ]]; then
    normalized="$(printf '%s' "$normalized" | tr -d '$(){}[]')"
  fi

  printf '%s' "$normalized" | tr -s '[:space:]' ' '
}
