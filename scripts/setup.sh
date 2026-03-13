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
  # Prefer npm ci for reproducible installs from lockfiles. If a lockfile is missing,
  # run npm install once to generate it, then subsequent runs use npm ci.
  if [[ -f "$REPO/web-delegation-mcp/package-lock.json" ]]; then
    # No lifecycle scripts are required for this package; ignore scripts to reduce
    # supply-chain risk from dependency install hooks.
    (cd "$REPO/web-delegation-mcp" && npm ci --ignore-scripts)
  else
    (cd "$REPO/web-delegation-mcp" && npm install --ignore-scripts)
  fi

  if [[ -f "$REPO/delegate/package-lock.json" ]]; then
    # better-sqlite3 relies on install scripts to provide native bindings.
    (cd "$REPO/delegate" && npm ci)
  else
    (cd "$REPO/delegate" && npm install)
  fi

  if [[ -f "$REPO/audit/package-lock.json" ]]; then
    # better-sqlite3 relies on install scripts to provide native bindings.
    (cd "$REPO/audit" && npm ci)
  else
    (cd "$REPO/audit" && npm install)
  fi
else
  echo "WARNING: npm is unavailable; skipping dependency installation."
fi

echo
echo "==> Ensuring executable bit on codex delegation server"
chmod +x "$REPO/delegate/server.js"
chmod +x "$REPO/audit/server.js"

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
echo "==> Ensuring config.json exists"
if [[ ! -f "$REPO/config.json" ]]; then
  cp "$REPO/config.example.json" "$REPO/config.json"
  echo "Created $REPO/config.json from config.example.json."
  echo "Edit allowedRoots for this machine, then re-run setup if needed."
else
  echo "$REPO/config.json already exists; skipping."
fi

echo
echo "==> Ensuring CLAUDE.md exists"
if [[ ! -f "$REPO/CLAUDE.md" ]]; then
  echo "$REPO/CLAUDE.md is missing. Restore it before continuing."
  exit 1
else
  echo "$REPO/CLAUDE.md already exists; skipping."
fi

echo
echo "==> Ensuring MCP registrations"
if command -v claude >/dev/null 2>&1; then
  # Resolve allowed cwd roots: .env override or parent of this repo
  ALLOWED_ROOTS=""
  if [[ -f "$REPO/.env" ]]; then
    ALLOWED_ROOTS="$(grep -E '^CODEX_POOL_ALLOWED_CWD_ROOTS=' "$REPO/.env" | cut -d'=' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  fi
  if [[ -z "$ALLOWED_ROOTS" ]]; then
    ALLOWED_ROOTS="$(dirname "$REPO")"
  fi
  echo "Codex allowed roots: $ALLOWED_ROOTS"

  mcp_list="$(claude mcp list 2>/dev/null || true)"

  if echo "$mcp_list" | grep -Eq '(^|[^[:alnum:]-])delegate-web([^[:alnum:]-]|$)'; then
    echo "delegate-web already registered, skipping."
  else
    claude mcp add -s user delegate-web -- "$REPO/web-delegation-mcp/start.sh"
  fi

  if echo "$mcp_list" | grep -Eq '(^|[^[:alnum:]-])delegate([^[:alnum:]-]|$)'; then
    echo "delegate already registered, skipping."
    echo "NOTE: To update allowed roots, run: /audit add-path <path>  (then restart Claude Code)"
  else
    claude mcp add -s user delegate \
      --env "CODEX_POOL_ALLOWED_CWD_ROOTS=$ALLOWED_ROOTS" \
      -- "$REPO/delegate/server.js"
  fi

  if echo "$mcp_list" | grep -Eq '(^|[^[:alnum:]-])audit([^[:alnum:]-]|$)'; then
    echo "audit already registered, skipping."
  else
    claude mcp add -s user audit -- "$REPO/audit/server.js"
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

  if echo "$final_mcp_list" | grep -Eq '(^|[^[:alnum:]-])audit([^[:alnum:]-]|$)'; then
    echo "PASS: audit is registered."
  else
    echo "FAIL: audit is not registered."
  fi
else
  echo "SKIP: claude CLI not found; cannot validate MCP registrations."
fi

echo
echo "Setup complete."
