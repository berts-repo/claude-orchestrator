#!/usr/bin/env bash
# sync-hooks.sh — Discover hooks from frontmatter and apply to ~/.claude/settings.json and ~/.claude/hooks/
#
# Usage:
#   bash scripts/sync-hooks.sh [--dry-run] [--check]
#
# Safe to run repeatedly (idempotent). Does not touch any key in settings.json
# other than "hooks". Preserves statusLine, alwaysThinkingEnabled, etc.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_REPO_DIR="$REPO_DIR/hooks"
HOOKS_LINK_DIR="$HOME/.claude/hooks"
SETTINGS="$HOME/.claude/settings.json"
DRY_RUN=false
CHECK_ONLY=false

usage() {
  echo "Usage: bash scripts/sync-hooks.sh [--dry-run] [--check]" >&2
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --check) CHECK_ONLY=true ;;
    *)
      usage
      die "unknown argument: $arg"
      ;;
  esac
done

if ! command -v jq &>/dev/null; then
  die "jq is required but not found"
fi

hook_files=()
while IFS= read -r _f; do hook_files+=("$_f"); done \
  < <(find "$HOOKS_REPO_DIR" -maxdepth 1 -type f -name '*.sh' | sort)
[[ ${#hook_files[@]} -gt 0 ]] || die "no hook scripts found in $HOOKS_REPO_DIR"

echo "==> sync-hooks: frontmatter discovery"
echo "    hooks src : $HOOKS_REPO_DIR"
echo "    hooks dir : $HOOKS_LINK_DIR"
echo "    settings  : $SETTINGS"
$DRY_RUN && echo "    (dry run)"
$CHECK_ONLY && echo "    (check only)"
echo

tmp_entries="$(mktemp "${TMPDIR:-/tmp}/sync-hooks.XXXXXX")"
trap 'rm -f "$tmp_entries"' EXIT

declare -a hook_scripts=()

valid_event() {
  case "$1" in
    PreToolUse|PostToolUse|UserPromptSubmit|Stop) return 0 ;;
    *) return 1 ;;
  esac
}

for file in "${hook_files[@]}"; do
  script="$(basename "$file")"

  hook_helper="$(grep -m1 '^# HOOK_HELPER:[[:space:]]*true[[:space:]]*$' "$file" || true)"
  if [[ -n "$hook_helper" ]]; then
    echo "  helper $script"
    continue
  fi

  hook_event="$(grep -m1 '^# HOOK_EVENT:' "$file" | sed 's/^# HOOK_EVENT:[[:space:]]*//' || true)"
  hook_matcher="$(grep -m1 '^# HOOK_MATCHER:' "$file" | sed 's/^# HOOK_MATCHER:[[:space:]]*//' || true)"
  hook_timeout="$(grep -m1 '^# HOOK_TIMEOUT:' "$file" | sed 's/^# HOOK_TIMEOUT:[[:space:]]*//' || true)"

  [[ -n "$hook_event" ]] || die "$script is missing required frontmatter: # HOOK_EVENT:"
  valid_event "$hook_event" || die "$script has invalid HOOK_EVENT '$hook_event' (must be one of: PreToolUse, PostToolUse, UserPromptSubmit, Stop)"

  if [[ -z "$hook_timeout" ]]; then
    hook_timeout=5
  fi

  [[ "$hook_timeout" =~ ^[1-9][0-9]*$ ]] || die "$script has invalid HOOK_TIMEOUT '$hook_timeout' (must be a positive integer in seconds)"

  timeout_ms=$((hook_timeout * 1000))

  jq -nc \
    --arg event "$hook_event" \
    --arg matcher "$hook_matcher" \
    --arg script "$script" \
    --argjson timeout "$timeout_ms" \
    '{event: $event, matcher: $matcher, script: $script, timeout: $timeout}' >> "$tmp_entries"

  hook_scripts+=("$script")
  if [[ -n "$hook_matcher" ]]; then
    echo "  hook   $script ($hook_event, matcher=$hook_matcher, timeout=${hook_timeout}s)"
  else
    echo "  hook   $script ($hook_event, timeout=${hook_timeout}s)"
  fi
done

echo
[[ ${#hook_scripts[@]} -gt 0 ]] || die "no hooks discovered (all scripts were marked as helpers?)"

new_hooks="$(jq -s --arg hdir "$HOOKS_LINK_DIR" '
  . as $entries |
  [
    $entries[]
    | . as $entry
    | (
        if (($entry.matcher // "") | contains("|")) then
          ($entry.matcher
            | split("|")
            | map(gsub("^\\s+|\\s+$"; ""))
            | map(select(length > 0))
          )
        else
          [($entry.matcher // "")]
        end
      )[]
    | $entry + { matcher: . }
  ] as $expanded_entries |
  [ $expanded_entries[] | {event, matcher: (.matcher // "")} ] | unique_by([.event, .matcher]) as $keys |
  reduce $keys[] as $k (
    {};
    . as $acc |
    [ $expanded_entries[]
      | select(.event == $k.event and (.matcher // "") == $k.matcher)
      | { type: "command", command: ($hdir + "/" + .script), timeout: .timeout }
    ] as $cmds |
    (
      if $k.matcher != "" then
        { matcher: $k.matcher, hooks: $cmds }
      else
        { hooks: $cmds }
      end
    ) as $group |
    $acc + { ($k.event): (($acc[$k.event] // []) + [$group]) }
  )
' "$tmp_entries")"

if $CHECK_ONLY; then
  echo "Validation succeeded."
  echo "Discovered ${#hook_scripts[@]} hook script(s)."
  exit 0
fi

# ── Step 1: Symlinks ──────────────────────────────────────────────────────────

echo "--- symlinks ---"
mkdir -p "$HOOKS_LINK_DIR"

for script in "${hook_scripts[@]}"; do
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
done

echo

# ── Step 2: Write hooks JSON ─────────────────────────────────────────────────

echo "--- settings.json ---"

if $DRY_RUN; then
  echo "  WOULD write hooks section:"
  echo "$new_hooks" | jq .
else
  if [[ -f "$SETTINGS" ]]; then
    tmp_settings="$(mktemp "${TMPDIR:-/tmp}/sync-hooks.XXXXXX")"
    jq --argjson h "$new_hooks" '.hooks = $h' "$SETTINGS" > "$tmp_settings"
    mv "$tmp_settings" "$SETTINGS"
    echo "  updated $SETTINGS"
  else
    jq -n --argjson h "$new_hooks" '{hooks: $h}' > "$SETTINGS"
    echo "  created $SETTINGS"
  fi
fi

echo
echo "Done."
