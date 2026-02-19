#!/usr/bin/env bash
# sync-hooks.sh — Apply hooks/manifest.json to ~/.claude/settings.json and ~/.claude/hooks/
#
# Usage: bash scripts/sync-hooks.sh [--dry-run]
#
# Safe to run repeatedly (idempotent). Does not touch any key in settings.json
# other than "hooks". Preserves statusLine, alwaysThinkingEnabled, etc.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$REPO_DIR/hooks/manifest.json"
HOOKS_REPO_DIR="$REPO_DIR/hooks"
HOOKS_LINK_DIR="$HOME/.claude/hooks"
SETTINGS="$HOME/.claude/settings.json"
DRY_RUN=false

[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required but not found" >&2
  exit 1
fi

[[ -f "$MANIFEST" ]] || { echo "ERROR: manifest not found at $MANIFEST" >&2; exit 1; }

echo "==> sync-hooks: $MANIFEST"
echo "    hooks dir : $HOOKS_LINK_DIR"
echo "    settings  : $SETTINGS"
$DRY_RUN && echo "    (dry run)"
echo

# ── Step 1: Symlinks ──────────────────────────────────────────────────────────

echo "--- symlinks ---"
mkdir -p "$HOOKS_LINK_DIR"

while IFS= read -r script; do
  src="$HOOKS_REPO_DIR/$script"
  dst="$HOOKS_LINK_DIR/$script"

  if [[ ! -f "$src" ]]; then
    echo "  WARN  $script (not found in hooks/, skipping)"
    continue
  fi

  if ! $DRY_RUN; then
    chmod +x "$src"
  fi

  if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then
    echo "  ok    $script"
  else
    if $DRY_RUN; then
      echo "  WOULD link $script -> $src"
    else
      ln -sf "$src" "$dst"
      echo "  link  $script"
    fi
  fi
done < <(jq -r '.entries[].script' "$MANIFEST" | sort -u)
echo

# ── Step 2: Build hooks JSON from manifest ────────────────────────────────────

echo "--- settings.json ---"

new_hooks=$(jq --arg hdir "$HOOKS_LINK_DIR" '
  .entries as $entries |
  [ $entries[] | {event, matcher: (.matcher // "")} ] | unique_by([.event, .matcher]) as $keys |
  reduce $keys[] as $k (
    {};
    . as $acc |
    [ $entries[]
      | select(.event == $k.event and (.matcher // "") == $k.matcher)
      | { type: "command", command: ($hdir + "/" + .script), timeout: .timeout }
    ] as $cmds |
    ($acc[$k.event] // []) + [
      if $k.matcher != "" then { matcher: $k.matcher, hooks: $cmds }
      else { hooks: $cmds }
      end
    ] | { ($k.event): . } | . as $new |
    $acc + $new
  )
' "$MANIFEST")

if $DRY_RUN; then
  echo "  WOULD write hooks section:"
  echo "$new_hooks" | jq .
else
  if [[ -f "$SETTINGS" ]]; then
    tmp=$(mktemp)
    jq --argjson h "$new_hooks" '.hooks = $h' "$SETTINGS" > "$tmp"
    mv "$tmp" "$SETTINGS"
    echo "  updated $SETTINGS"
  else
    jq -n --argjson h "$new_hooks" '{hooks: $h}' > "$SETTINGS"
    echo "  created $SETTINGS"
  fi
fi

echo
echo "Done."
