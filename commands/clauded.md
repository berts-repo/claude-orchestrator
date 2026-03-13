Handle the following task directly using Claude's own tools.

Parse $ARGUMENTS:
- Extract zero or more `--allow <service>` flags (service = `codex`, `web`, or `all`)
- Remaining text after flags is TASK

## Restrictions (apply unless overridden by --allow)

By default, do NOT use any MCP tools:
- `mcp__delegate__codex` / `mcp__delegate__codex_parallel` — blocked unless `--allow codex` or `--allow all`
- `mcp__delegate_web__search` / `mcp__delegate_web__fetch` — blocked unless `--allow web` or `--allow all`

Use only Claude's built-in tools: Read, Grep, Glob, Bash, Edit, Write.

## Task

$ARGUMENTS (after flag parsing)

Work through the task step by step using only the permitted tools.
