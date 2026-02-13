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

# Extract the relevant input
if [[ "$tool_name" == "Read" ]]; then
  target=$(echo "$payload" | jq -r '.tool_input.file_path // ""')
else
  # For Bash, check the command for cat/head/tail of sensitive paths
  target=$(echo "$payload" | jq -r '.tool_input.command // ""')
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
  if echo "$target" | grep -qE "$pattern"; then
    # Output block message
    cat <<EOF
{
  "decision": "block",
  "reason": "Blocked read of sensitive file matching pattern: $pattern"
}
EOF
    exit 0
  fi
done

exit 0
