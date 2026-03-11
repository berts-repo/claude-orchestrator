Summarize this project for use as session context.

Parse $ARGUMENTS for flags: --small, --medium, --large, --delegate, --save, --cached, --refresh, --claude.

## --cached (no --refresh)

If `--cached` is set and `--refresh` is NOT set:
Read `.SUMMARY.md` from the project root and display its contents under "## Project Context".
Skip all Codex delegation. Done.

## --claude

Claude reads these files directly (no Codex subprocess):
- CLAUDE.md, README.md, AGENTS.md (if present)
- List top-level *.md files

Produce a ~50-line structured summary and display under "## Project Context". Done.

## Default / --small / --medium / --large / --delegate / --refresh

Delegate to Codex with:
- sandbox: read-only
- approval_policy: never
- cwd: current working directory

### Codex prompt by flag:

**--small** — Read CLAUDE.md and README.md only. Output ~40 lines:
- Purpose (2 sentences)
- Key files (table, 8 rows max)
- Top conventions (5 bullets)

**--medium or default (no size flag)** — Read CLAUDE.md, README.md, AGENTS.md, all top-level *.md files; list hooks/ and any MCP server dirs. Output ~80 lines with sections:
- ## Purpose
- ## Architecture
- ## Key Files
- ## Conventions
- ## Delegation Rules

**--large** — Full exploration: all *.md files, read source entry points (server.js, server.mjs, index.js, etc.), list all subdirectories. Output ~150 lines with all --medium sections plus:
- ## Hook System
- ## Security Constraints
- ## Config Locations

**--delegate** — Read CLAUDE.md and AGENTS.md only. Output ~60 lines focused on:
- ## Delegation Rules (sandbox policies, approval policies, task type table)
- ## Blocked Actions (what Claude must NOT do itself)
- ## Codex Prompt Patterns (examples of well-formed prompts from this project)

After Codex returns its output, display the summary under "## Project Context".

## --save / --refresh

After displaying the summary, write its content to `.SUMMARY.md` in the project root.
Confirm to the user: "Summary saved to .SUMMARY.md"

## Audit DB Context

Also instruct Claude to query `~/.claude/audit.db` for audit history relevant to this project:
- Filter tasks where `cwd` equals the current working directory, or `project` matches the current project name
- Show last 20 tasks for this project: `prompt_slug`, `status`, `duration_ms`, `started_at`
- Use this data to improve the session summary with what was actually delegated

Use:
- `sqlite3 ~/.claude/audit.db "SELECT ..."`

If DB does not exist, skip silently.
