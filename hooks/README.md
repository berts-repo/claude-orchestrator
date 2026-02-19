# Hooks

All Claude Code hooks for the orchestration system. Hooks are shell scripts that run at specific lifecycle events to enforce security policies, guide delegation, and audit tool usage.

## Installation

```bash
bash scripts/sync-hooks.sh
```

Hook registration is managed in `hooks/manifest.json`. Run `bash scripts/sync-hooks.sh` from the repo root to apply changes (it updates both `~/.claude/hooks/` symlinks and `~/.claude/settings.json` wiring). Never manually edit `~/.claude/settings.json` for hook wiring.

---

## Security Hooks

### `security--guard-sensitive-reads.sh`
**Event:** PreToolUse (Read, Bash)

Blocks reads of sensitive files (credentials, keys, secrets) to prevent exfiltration:
- `~/.ssh/`, `~/.aws/`, `~/.codex/`
- `~/.config/gcloud/`, `~/.config/gh/`, `~/.config/claude/`
- `~/.config/bitwarden/`, `~/.config/1password/`, `~/.1password/`
- `~/.claude.json`
- `.env` files, private keys (`id_rsa`, `id_ed25519`, `.pem`)

### `security--restrict-bash-network.sh`
**Event:** PreToolUse (Bash)

Blocks direct network access via Bash commands (`curl`, `wget`, `nc`, `ssh`, etc.) and language HTTP libraries. Forces all web access through the `web_search` MCP tool.

### `security--block-destructive-commands.sh`
**Event:** PreToolUse (Bash)

Blocks destructive commands that could cause data loss:
- `rm -rf`, `rm -f`, `rm --recursive`, `rm --force`
- `drop table` (SQL), `shutdown`, `mkfs`, `dd if=`
- `git reset --hard`, `git checkout .`
- `git push --force`, `git push -f`
- `git clean -f`, `git branch -D`

### `security--log-security-event.sh`
**Not a hook** -- helper script called by PreToolUse hooks when they deny an action. Writes to `~/.claude/logs/security-events.jsonl` with FIFO rotation (last 200 entries).

Usage: `log-security-event.sh <hook_name> <tool_name> <pattern_matched> <command_preview> [severity]`

Severity levels: `low` (blocked subagents), `medium` (network/sensitive reads), `high` (destructive commands), `critical`. Defaults to `medium` if omitted. Severity maps to log level: high/critical = error, medium = warn, low = info.

---

## Codex Delegation Hooks

Two-layer enforcement: soft hints guide Claude toward Codex, hard blocks prevent blocked subagents.

### `codex--inject-hint.sh`
**Event:** UserPromptSubmit
**Enforcement:** Soft (injects reminder)

Detects task patterns that should be delegated to Codex and injects guidance:
- Test generation, code review, security audit
- Refactoring, documentation, changelog generation
- Error analysis, lint/format fixing, dependency audit

### `codex--enforce-code-write.sh`
**Event:** PreToolUse (Write)
**Enforcement:** Hard (blocks tool)

Blocks direct creation of substantial new code files (>=25 lines). Requires delegation to `mcp__codex__codex` for larger code generation tasks.

### `codex--block-explore.sh`
**Event:** PreToolUse (Task)
**Enforcement:** Hard (blocks tool)

Blocks the `Explore` subagent. Use `mcp__codex__codex` with `sandbox: read-only` instead.

### `codex--block-test-gen.sh`
**Event:** PreToolUse (Task)
**Enforcement:** Hard (blocks tool)

Blocks the `test_gen` subagent. Codex generates complete tests AND runs them to verify.

### `codex--block-doc-comments.sh`
**Event:** PreToolUse (Task)
**Enforcement:** Hard (blocks tool)

Blocks the `doc_comments` subagent. Codex writes documentation directly to files.

### `codex--block-diff-digest.sh`
**Event:** PreToolUse (Task)
**Enforcement:** Hard (blocks tool)

Blocks the `diff_digest` subagent. Codex processes large diffs externally, keeping them out of Claude's context.

### `codex--log-delegation-start.sh`
**Event:** PreToolUse (mcp__codex__codex, mcp__codex__codex-reply, mcp__gemini_web__*)
**Enforcement:** Audit only

Records delegation start time to `~/.claude/logs/.pending/` for duration tracking. Companion to `codex--log-delegation.sh`.

### `codex--log-delegation.sh`
**Event:** PostToolUse (mcp__codex__codex, mcp__gemini_web__*)
**Enforcement:** Audit only

Logs all Codex and Gemini delegations to `~/.claude/logs/delegations.jsonl`. Records timestamp, level, session_id, thread ID, prompt summary, sandbox mode, success status, and `duration_ms` (computed from the PreToolUse start marker).

---

## Shared Helpers

### `shared--log-helpers.sh`
Sourced by logging hooks. Provides:
- `log_json <level> <component> <event> [--arg key val ...]` — builds a JSON log line with unified envelope fields (`timestamp`, `level`, `component`, `session_id`, `event`)
- `rotate_jsonl <file> <max_entries> [cleanup_fn]` — FIFO rotation by line count with optional per-line cleanup callback
- `ensure_dirs` — creates `~/.claude/logs/` and `~/.claude/logs/.pending/`
- `SESSION_ID` — derived from `$CLAUDE_SESSION_ID` if set, otherwise a hash of `$PPID` + date for per-process-tree correlation

---

## Gemini Hooks

### `gemini--inject-web-search-hint.sh`
**Event:** UserPromptSubmit

Detects explicit web search intent ("search the web", "do research", "look online") and injects a hint reminding Claude to use the `web_search` MCP tool.

### `gemini--require-web-if-recency.sh`
**Event:** Stop

Validates that Claude cited sources when making time-sensitive claims. Blocks responses with recency language ("latest version", "as of 2026") but no URLs.

---

## Token Preservation

The blocked subagents are replaced by Codex delegation because:

| Subagent | Limitation | Codex Advantage | Savings |
|----------|-----------|-----------------|---------|
| `Explore` | Returns findings to Claude's context | External processing, summary only | ~90% |
| `test_gen` | Skeletons with TODO assertions | Complete tests + verification | ~97% |
| `doc_comments` | Text output only | Writes directly to files | ~95% |
| `diff_digest` | Summary in Claude's context | Summary stays external | ~95% |
