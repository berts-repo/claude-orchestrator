#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash "$REPO/scripts/sync-hooks.sh" "$@"
bash "$REPO/scripts/sync-commands.sh" "$@"
echo "Done. Restart Claude Code if MCP servers were affected."
