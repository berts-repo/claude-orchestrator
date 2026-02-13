#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NODE="/home/me/.local/share/mise/installs/node/25.2.1/bin/node"
SERVER="$SCRIPT_DIR/server.mjs"

# Source API key: try GNOME keyring first, fall back to .env file
if [ -z "${GEMINI_API_KEY:-}" ]; then
  if command -v secret-tool &>/dev/null; then
    GEMINI_API_KEY="$(secret-tool lookup service mcp-gemini-web account api-key 2>/dev/null || true)"
  fi
fi

if [ -z "${GEMINI_API_KEY:-}" ] && [ -f "$SCRIPT_DIR/.env" ]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/.env"
fi

if [ -z "${GEMINI_API_KEY:-}" ]; then
  echo "[gemini-web] No API key found. Set GEMINI_API_KEY, store in keyring, or create .env" >&2
  exit 1
fi

export GEMINI_API_KEY
exec "$NODE" "$SERVER"
