#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Resolve node from PATH instead of hardcoding — works with any version manager
NODE="$(command -v node)"
if [ -z "$NODE" ]; then
  echo "[delegate-web] Node.js not found in PATH" >&2
  exit 1
fi
SERVER="$SCRIPT_DIR/server.mjs"

# Source API key: try GNOME keyring first, fall back to .env file
if [ -z "${GEMINI_API_KEY:-}" ]; then
  if command -v secret-tool &>/dev/null; then
    GEMINI_API_KEY="$(secret-tool lookup service mcp-delegate-web account api-key 2>/dev/null || true)"
  fi
fi

if [ -f "$SCRIPT_DIR/.env" ]; then
  while IFS='=' read -r key value; do
    # Skip comments and blank lines
    [[ "$key" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$key" ]] && continue
    # Only accept valid identifier names; strip surrounding quotes from value
    if [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      value="${value%"${value##*[![:space:]]}"}"  # rtrim
      value="${value#"${value%%[![:space:]]*}"}"  # ltrim
      value="${value#\"}" value="${value%\"}"     # strip double quotes
      value="${value#\'}" value="${value%\'}"     # strip single quotes
      export "$key=$value"
    fi
  done < "$SCRIPT_DIR/.env"
fi

SEARCH_PROVIDER="${SEARCH_PROVIDER:-gemini}"

if [ "$SEARCH_PROVIDER" = "gemini" ] && [ -z "${GEMINI_API_KEY:-}" ]; then
  echo "[delegate-web] No API key found. Set GEMINI_API_KEY, store in keyring, or create .env" >&2
  exit 1
fi

if [ -n "${GEMINI_API_KEY:-}" ]; then
  export GEMINI_API_KEY
fi
exec "$NODE" "$SERVER"
