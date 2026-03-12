#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash)
# Blocks Bash commands that make direct network connections.
# Forces all web access through the search MCP tool.
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
# - Strip quotes, backticks, backslashes, and shell expansion chars that could obfuscate commands
# - Collapse whitespace
# - This catches tricks like c"u"rl, w''get, $(curl foo), etc.
command="$(normalize_command "$raw_command" aggressive)"

# Word-boundary prefix: start-of-string or shell separator, then optional path prefix.
_P='(^|[;&|()[:space:]])([[:alnum:]_./-]*/)?'

# --- Per-category deny patterns ---

PAT_CURL="${_P}(curl|wget|fetch|httpie|http|aria2c|axel)([[:space:];]|$)"
PAT_NET_TOOLS="${_P}(dig|nslookup|host|ping|traceroute|nc|netcat|ncat|socat|ssh|scp|sftp|rsync)([[:space:];]|$)"
PAT_PKG_MGRS="${_P}(apt|apt-get|brew|snap)([[:space:];]|$)"
PAT_GIT="${_P}git([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+(fetch|pull|clone|remote)([[:space:];]|$)"
PAT_PIP="${_P}pip([23](\.[0-9]+)*)?([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+(install|download)([[:space:];]|$)"
PAT_NPM="${_P}npm([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+(install|ci|update)([[:space:];]|$)"
PAT_YARN="${_P}yarn([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+(add|install)([[:space:];]|$)"
PAT_PNPM="${_P}pnpm([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+install([[:space:];]|$)"
PAT_CARGO="${_P}cargo([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+install([[:space:];]|$)"
PAT_GO="${_P}go([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+(get|install)([[:space:];]|$)"
PAT_PYTHON_NET="${_P}python([23](\.[0-9]+)*)?([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+-c[[:space:]].*(urllib|requests|http\.client)"
PAT_NODE_NET="${_P}node([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+-e[[:space:]].*(http|https|fetch)"
PAT_DEV_TCP='/dev/tcp/'

# Allow git push (with optional remote/branch/flags, but no explicit URL).
if printf '%s\n' "$command" | grep -Eiq "${_P}git([[:space:]]+(-[^[:space:]]+|[[:alnum:]_./:-]+))*[[:space:]]+push([[:space:]]+(-[^[:space:]]+|[[:alnum:]_./:-]+))*([[:space:];]|$)" && \
   ! printf '%s\n' "$command" | grep -Eiq 'https?://|git@|git://|ssh://'; then
  exit 0
fi

# Deny-by-default: block if any category matches.
_match() { printf '%s\n' "$command" | grep -Eiq "$1"; }

if _match "$PAT_CURL"       || \
   _match "$PAT_NET_TOOLS"  || \
   _match "$PAT_PKG_MGRS"   || \
   _match "$PAT_GIT"        || \
   _match "$PAT_PIP"        || \
   _match "$PAT_NPM"        || \
   _match "$PAT_YARN"       || \
   _match "$PAT_PNPM"       || \
   _match "$PAT_CARGO"      || \
   _match "$PAT_GO"         || \
   _match "$PAT_PYTHON_NET" || \
   _match "$PAT_NODE_NET"   || \
   _match "$PAT_DEV_TCP"; then

  # Extract the specific matched token for logging.
  PAT_ALL="\
(curl|wget|fetch|httpie|http|aria2c|axel\
|dig|nslookup|host|ping|traceroute|nc|netcat|ncat|socat|ssh|scp|sftp|rsync\
|apt-get|apt|brew|snap\
|git([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+(fetch|pull|clone|remote)\
|pip([23](\.[0-9]+)*)?([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+(install|download)\
|npm([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+(install|ci|update)\
|yarn([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+(add|install)\
|pnpm([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+install\
|cargo([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+install\
|go([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+(get|install)\
|python([23](\.[0-9]+)*)?([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+-c[[:space:]].*(urllib|requests|http\.client)\
|node([[:space:]]+[^;&|()[:space:]]+)*[[:space:]]+-e[[:space:]].*(http|https|fetch)\
|/dev/tcp/)"

  matched=$(printf '%s' "$command" | grep -Eio "$PAT_ALL" | head -1)
  "$SCRIPT_DIR/security--log-security-event.sh" "restrict-bash-network" "Bash" "$matched" "$raw_command" "medium" &>/dev/null || true
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Network access from Bash is restricted by policy. Use approved MCP tools for internet access."
  }
}
EOF
  exit 0
fi

exit 0
