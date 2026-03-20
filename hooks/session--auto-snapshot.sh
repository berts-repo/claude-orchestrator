#!/usr/bin/env bash
# Stop hook — writes a lightweight .SESSION.md snapshot when Claude Code exits.
# Captures git state directly (no Codex delegation) so it's fast and always runs.
# HOOK_EVENT: Stop
# HOOK_TIMEOUT: 10
set -euo pipefail

# Only run if we're in a git repo with a known working directory
cwd="${CLAUDE_PROJECT_DIR:-$(pwd)}"
[[ -d "$cwd/.git" ]] || exit 0

SESSION_FILE="$cwd/.SESSION.md"

# Get git state
branch="$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
short_hash="$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
timestamp="$(date '+%Y-%m-%d %H:%M')"

# Recent commits (last 10)
recent_commits="$(git -C "$cwd" log --oneline -10 2>/dev/null || echo '(none)')"

# Working tree status
git_status="$(git -C "$cwd" status --short 2>/dev/null || echo '')"
if [[ -z "$git_status" ]]; then
  in_progress="Working tree clean"
else
  in_progress="$git_status"
fi

# Carry forward Next Steps from existing snapshot if present
next_steps="(none noted)"
if [[ -f "$SESSION_FILE" ]]; then
  # Extract content under ## Next Steps until the next ## heading
  next_steps="$(awk '/^## Next Steps/{found=1; next} found && /^## /{exit} found{print}' "$SESSION_FILE" | sed '/^[[:space:]]*$/d' || true)"
  [[ -z "$next_steps" ]] && next_steps="(none noted)"
fi

cat > "$SESSION_FILE" <<EOF
# Session Snapshot — ${timestamp}

## Branch
${branch} @ ${short_hash}

## Recent Commits
${recent_commits}

## In Progress
${in_progress}

## Next Steps
${next_steps}
EOF

exit 0
