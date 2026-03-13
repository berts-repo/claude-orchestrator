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
  claude mcp remove audit || echo "audit not registered, skipping"
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
echo "==> Removing command symlinks into $REPO/commands/"
COMMANDS_DIR="$HOME/.claude/commands"
if [[ -d "$COMMANDS_DIR" ]]; then
  while IFS= read -r link_path; do
    target="$(readlink "$link_path" || true)"
    if [[ "$target" == "$REPO/commands/"* ]]; then
      rm "$link_path"
      echo "removed $link_path"
    fi
  done < <(find "$COMMANDS_DIR" -maxdepth 1 -type l)
else
  echo "$COMMANDS_DIR does not exist; skipping."
fi

echo
echo "==> Pruning hook entries from settings.json"
SETTINGS="$HOME/.claude/settings.json"
if [[ -f "$SETTINGS" ]] && command -v node >/dev/null 2>&1; then
  node -e "
    const fs = require('fs');
    const s = JSON.parse(fs.readFileSync('$SETTINGS','utf8'));
    const repo = '$REPO';
    let removed = 0;
    for (const event of Object.keys(s.hooks || {})) {
      s.hooks[event] = (s.hooks[event] || []).map(group => {
        const before = (group.hooks || []).length;
        group.hooks = (group.hooks || []).filter(h => !(h.command || '').includes(repo + '/hooks/'));
        removed += before - group.hooks.length;
        return group;
      }).filter(g => g.hooks.length > 0);
    }
    fs.writeFileSync('$SETTINGS', JSON.stringify(s, null, 2));
    console.log('Pruned ' + removed + ' hook entry/entries from settings.json');
  " 2>&1 || echo "settings.json pruning failed (non-fatal)"
else
  echo "settings.json not found or node unavailable; skipping."
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
