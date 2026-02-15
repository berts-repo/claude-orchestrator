# General Security Hooks

General-purpose Claude Code hooks for security.

## Hooks

### `guard-sensitive-reads.sh`
**Event:** `PreToolUse` (Read, Bash)

Blocks reads of sensitive files (credentials, keys, secrets) unless explicitly authorized. Prevents accidental exposure of:
- `.env` files
- SSH/GPG keys
- Cloud credentials
- Password files

### `restrict-bash-network.sh`
**Event:** `PreToolUse` (Bash)

Blocks direct network access via Bash commands (`curl`, `wget`, `nc`, etc.). Forces all web access through the `web_search` MCP tool, which:
- Returns sanitized summaries (no raw HTML/JS execution)
- Logs all external requests
- Prevents command injection via fetched content

### `block-destructive-commands.sh`
**Event:** `PreToolUse` (Bash)

Blocks destructive commands that could cause data loss or system damage:
- `rm -rf`, `rm -f` — Recursive/force delete
- `drop table` — SQL table destruction
- `shutdown` — System shutdown
- `mkfs` — Format filesystem
- `dd if=` — Raw disk writes
- `git reset --hard` — Discard all changes
- `git checkout .` — Discard working tree
- `git push --force` / `git push -f` — Overwrite remote history
- `git clean -f` — Delete untracked files
- `git branch -D` — Force delete branch

## Installation

These hooks are symlinked from `~/.claude/hooks/`. See the root README for setup instructions.
