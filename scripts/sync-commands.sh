#!/usr/bin/env bash
# sync-commands.sh — Install slash commands from commands/ into ~/.claude/commands/
#
# Usage:
#   bash scripts/sync-commands.sh [--dry-run] [--check]
#
# Creates symlinks so edits in the repo are reflected immediately.
# Safe to run repeatedly (idempotent).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_DIR="$REPO_DIR/commands"
DST_DIR="$HOME/.claude/commands"
DRY_RUN=false
CHECK_ONLY=false

usage() {
  echo "Usage: bash scripts/sync-commands.sh [--dry-run] [--check]" >&2
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --check)   CHECK_ONLY=true ;;
    *)
      usage
      die "unknown argument: $arg"
      ;;
  esac
done

md_files=()
while IFS= read -r _f; do md_files+=("$_f"); done \
  < <(find "$SRC_DIR" -maxdepth 1 -type f -name '*.md' | sort)
[[ ${#md_files[@]} -gt 0 ]] || die "no .md files found in $SRC_DIR"

echo "==> sync-commands: slash command installation"
echo "    src : $SRC_DIR"
echo "    dst : $DST_DIR"
$DRY_RUN   && echo "    (dry run)"
$CHECK_ONLY && echo "    (check only)"
echo

linked=0
would=0
disabled_cmds="$(jq -r '(.commands.disabled // [])[]' "$REPO_DIR/config.json" 2>/dev/null || true)"

for file in "${md_files[@]}"; do
  name="$(basename "$file")"
  dst="$DST_DIR/$name"

  if echo "$disabled_cmds" | grep -qxF "$(basename "$file")"; then
    if [[ -L "$dst" ]]; then
      if $CHECK_ONLY; then
        echo "  Disabled (symlink present): $(basename "$file")"
      elif $DRY_RUN; then
        echo "  WOULD unlink disabled command: $(basename "$file")"
      else
        rm "$dst"
        echo "  Unlinked disabled command: $(basename "$file")"
      fi
    fi
    echo "  Skipping (disabled in config.json): $(basename "$file")"
    continue
  fi

  if $CHECK_ONLY; then
    echo "  command  $name"
    continue
  fi

  if $DRY_RUN; then
    if [[ -L "$dst" && "$(readlink "$dst")" == "$file" ]]; then
      echo "  ok    $name"
    else
      echo "  WOULD link $name -> $file"
      (( would++ )) || true
    fi
    continue
  fi

  mkdir -p "$DST_DIR"

  if [[ -L "$dst" && "$(readlink "$dst")" == "$file" ]]; then
    echo "  ok    $name"
  else
    ln -sf "$file" "$dst"
    echo "  link  $name"
    (( linked++ )) || true
  fi
done

echo
if $CHECK_ONLY; then
  echo "Validation succeeded. Discovered ${#md_files[@]} command(s)."
elif $DRY_RUN; then
  echo "Dry run complete. $would link(s) would be created/updated."
else
  echo "Done. $linked link(s) created/updated (${#md_files[@]} total)."
fi
