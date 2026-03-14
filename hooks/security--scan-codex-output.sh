#!/usr/bin/env bash
# PostToolUse hook — scans Codex subprocess output for credential patterns
# before surfacing results to Claude. Logs a security event and emits a
# warning if credentials are detected; Claude should not use or relay them.
# HOOK_EVENT: PostToolUse
# HOOK_MATCHER: mcp__delegate__codex|mcp__delegate__codex_parallel
# HOOK_TIMEOUT: 5
set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

REAL_SCRIPT="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"

payload="$(cat)"

# Extract the tool response text
response_text="$(printf '%s' "$payload" | jq -r '
  .tool_response.content
  | if type == "array" then map(.text // "") | join("\n")
    elif type == "string" then .
    else ""
    end
' 2>/dev/null)" || exit 0

[[ -n "$response_text" ]] || exit 0

tool_name="$(printf '%s' "$payload" | jq -r '.tool_name // "unknown"' 2>/dev/null)" || tool_name="unknown"

# Credential patterns to scan for (parallel label/regex arrays, bash 3.2 compatible)
PATTERN_LABELS=(
  "AWS access key"
  "AWS secret key"
  "generic API key assignment"
  "bearer token"
  "private key header"
  "GitHub PAT (classic)"
  "GitHub PAT (fine-grained)"
  "npm token"
  "Slack token"
  "generic secret assignment"
  "OpenAI key"
)
PATTERN_REGEXES=(
  'AKIA[0-9A-Z]{16}'
  '[Aa][Ww][Ss]_?[Ss][Ee][Cc][Rr][Ee][Tt][^=]*=[[:space:]]*[A-Za-z0-9/+]{40}'
  '(api[_-]?key|apikey)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9_\-]{20,}'
  '[Bb]earer[[:space:]]+[A-Za-z0-9._\-]{20,}'
  '-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----'
  'ghp_[A-Za-z0-9]{36}'
  'github_pat_[A-Za-z0-9_]{82}'
  'npm_[A-Za-z0-9]{36}'
  'xox[baprs]-[0-9A-Za-z\-]{10,}'
  '(secret|password|passwd|token)[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"'\n]{12,}["'"'"']'
  'sk-[A-Za-z0-9]{20,}'
)

detected=()
for i in "${!PATTERN_LABELS[@]}"; do
  if printf '%s' "$response_text" | grep -qE -e "${PATTERN_REGEXES[$i]}"; then
    detected+=("${PATTERN_LABELS[$i]}")
  fi
done

[[ ${#detected[@]} -eq 0 ]] && exit 0

# Build a comma-separated list of what was found
joined="$(IFS=', '; echo "${detected[*]}")"

# Log a security event to the audit DB
"$SCRIPT_DIR/security--log-security-event.sh" \
  "scan-codex-output" \
  "$tool_name" \
  "credential pattern detected: $joined" \
  "(codex output)" \
  "high" &>/dev/null || true

# Emit a structured warning that Claude Code will surface as hook output.
# This does NOT block the result but alerts Claude before it acts on it.
jq -n \
  --arg msg "SECURITY WARNING: Codex output may contain credentials ($joined). Do not relay, log, or use these values. Treat the detected content as sensitive and advise the user to rotate any exposed credentials." \
  '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      outputText: $msg
    }
  }'

exit 0
