#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "WARNING: This will remove MCP registrations, hook symlinks, and command symlinks."
read -r -p "Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

echo
echo "==> Removing MCP registrations"
if command -v claude >/dev/null 2>&1; then
  claude mcp remove delegate || echo "delegate not registered, skipping"
  claude mcp remove delegate-web || echo "delegate-web not registered, skipping"
else
  echo "claude CLI not found; skipping MCP deregistration."
fi

echo
echo "==> Removing hook symlinks into $REPO/hooks/"
HOOKS_DIR="$HOME/.claude/hooks"
if [[ -d "$HOOKS_DIR" ]]; then
  while IFS= read -r link_path; do
    target="$(readlink "$link_path" || true)"
    if [[ "$target" == "$REPO/hooks/"* ]]; then
      rm "$link_path"
      echo "removed $link_path"
    fi
  done < <(find "$HOOKS_DIR" -maxdepth 1 -type l)
else
  echo "$HOOKS_DIR does not exist; skipping."
fi

echo
echo "==> Removing command symlinks into $REPO/slash-commands/"
COMMANDS_DIR="$HOME/.claude/commands"
if [[ -d "$COMMANDS_DIR" ]]; then
  while IFS= read -r link_path; do
    target="$(readlink "$link_path" || true)"
    if [[ "$target" == "$REPO/slash-commands/"* ]]; then
      rm "$link_path"
      echo "removed $link_path"
    fi
  done < <(find "$COMMANDS_DIR" -maxdepth 1 -type l)
else
  echo "$COMMANDS_DIR does not exist; skipping."
fi

echo
read -r -p "Remove .env? [y/N] " remove_env
if [[ "$remove_env" =~ ^[Yy]$ ]]; then
  if [[ -f "$REPO/.env" ]]; then
    rm "$REPO/.env"
    echo "Removed $REPO/.env"
  else
    echo "$REPO/.env does not exist; skipping."
  fi
fi

echo "Uninstall complete."
