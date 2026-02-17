# Hooks

All Claude Code hooks for the orchestration system. Hooks are shell scripts that run at specific lifecycle events to enforce security policies, guide delegation, and audit tool usage.

## Installation

```bash
mkdir -p ~/.claude/hooks
ln -s ~/git/claude-orchestrator/hooks/*.sh ~/.claude/hooks/
```

Hooks must also be registered in `~/.claude/settings.json` to run. See the [Hooks Wiring](../README.md#hooks-wiring) section in the project README for the full settings configuration.

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

### `codex--log-delegation.sh`
**Event:** PostToolUse (mcp__codex__codex, mcp__gemini_web__*)
**Enforcement:** Audit only

Logs all Codex and Gemini delegations to `~/.claude/logs/delegations.jsonl`. Records timestamp, thread ID, prompt summary, sandbox mode, and success status.

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
