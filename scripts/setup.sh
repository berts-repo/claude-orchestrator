#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

warn_missing() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "WARNING: '$cmd' is not installed or not in PATH."
    return 1
  fi
  return 0
}

echo "==> Checking prerequisites"
warn_missing node || true
warn_missing npm || true
warn_missing codex || true

echo
echo "==> Installing npm dependencies"
if command -v npm >/dev/null 2>&1; then
  (cd "$REPO/web-search-mcp" && npm install)
  (cd "$REPO/codex-delegation-mcp" && npm install)
else
  echo "WARNING: npm is unavailable; skipping dependency installation."
fi

echo
echo "==> Ensuring executable bit on codex delegation server"
chmod +x "$REPO/codex-delegation-mcp/server.js"

echo
echo "==> Ensuring .env exists"
if [[ ! -f "$REPO/.env" ]]; then
  cp "$REPO/.env.example" "$REPO/.env"
  echo "Created $REPO/.env from .env.example."
  echo "Fill in GEMINI_API_KEY in $REPO/.env."
  read -r -p "Press Enter when .env is filled in..."
else
  echo "$REPO/.env already exists; skipping."
fi

echo
echo "==> Ensuring CLAUDE.md exists"
if [[ ! -f "$REPO/CLAUDE.md" ]]; then
  cp "$REPO/CLAUDE.example.md" "$REPO/CLAUDE.md"
  echo "Review $REPO/CLAUDE.md before continuing."
  read -r -p "Press Enter when ready..."
else
  echo "$REPO/CLAUDE.md already exists; skipping."
fi

echo
echo "==> Ensuring MCP registrations"
if command -v claude >/dev/null 2>&1; then
  mcp_list="$(claude mcp list 2>/dev/null || true)"

  if echo "$mcp_list" | grep -Eq '(^|[^[:alnum:]-])delegate-web([^[:alnum:]-]|$)'; then
    echo "delegate-web already registered, skipping."
  else
    claude mcp add -s user delegate-web -- "$REPO/web-search-mcp/start.sh"
  fi

  if echo "$mcp_list" | grep -Eq '(^|[^[:alnum:]-])delegate([^[:alnum:]-]|$)'; then
    echo "delegate already registered, skipping."
  else
    claude mcp add -s user delegate -- "$REPO/codex-delegation-mcp/server.js"
  fi
else
  echo "WARNING: 'claude' is not installed or not in PATH; skipping MCP registration/validation."
fi

echo
echo "==> Syncing hooks"
bash "$REPO/scripts/sync-hooks.sh"

echo
echo "==> Syncing slash commands"
bash "$REPO/scripts/sync-commands.sh"

echo
echo "==> Validating MCP registrations"
if command -v claude >/dev/null 2>&1; then
  final_mcp_list="$(claude mcp list 2>/dev/null || true)"

  if echo "$final_mcp_list" | grep -Eq '(^|[^[:alnum:]-])delegate([^[:alnum:]-]|$)'; then
    echo "PASS: delegate is registered."
  else
    echo "FAIL: delegate is not registered."
  fi

  if echo "$final_mcp_list" | grep -Eq '(^|[^[:alnum:]-])delegate-web([^[:alnum:]-]|$)'; then
    echo "PASS: delegate-web is registered."
  else
    echo "FAIL: delegate-web is not registered."
  fi
else
  echo "SKIP: claude CLI not found; cannot validate MCP registrations."
fi

echo
echo "Setup complete."
