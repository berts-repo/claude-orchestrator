# Codex Delegation Hooks

Hooks that enforce and audit Codex delegations.

## Hooks

### `inject-codex-hint.sh`
**Event:** `UserPromptSubmit`
**Enforcement:** Soft (injects reminder)

Detects task patterns that should be delegated to Codex and injects guidance:
- Test generation → `sandbox: workspace-write`
- Code review / security audit → `sandbox: read-only`
- Refactoring → `sandbox: workspace-write`
- Documentation → `sandbox: workspace-write`

### `block-explore-for-codex.sh`
**Event:** `PreToolUse` (Task)
**Enforcement:** Hard (blocks tool)

Blocks the `Explore` subagent and requires Codex delegation instead. Exploration tasks should use `mcp__codex__codex` with `sandbox: read-only` to save tokens.

### `block-test-gen-for-codex.sh`
**Event:** `PreToolUse` (Task)
**Enforcement:** Hard (blocks tool)

Blocks the `test_gen` subagent. The built-in subagent only generates skeletons with TODO assertions. Codex can generate complete tests AND run them to verify they pass.

- Sandbox: `workspace-write`
- Approval: `on-failure`

### `block-doc-comments-for-codex.sh`
**Event:** `PreToolUse` (Task)
**Enforcement:** Hard (blocks tool)

Blocks the `doc_comments` subagent. The built-in subagent only generates text output. Codex can write documentation directly to files.

- Sandbox: `workspace-write`
- Approval: `on-failure`

### `block-diff-digest-for-codex.sh`
**Event:** `PreToolUse` (Task)
**Enforcement:** Hard (blocks tool)

Blocks the `diff_digest` subagent. Codex processes large diffs externally, keeping the full diff out of Claude's context window.

- Sandbox: `read-only`
- Approval: `never`

### `log-codex-delegation.sh`
**Event:** `PostToolUse` (mcp__codex__codex)
**Enforcement:** Audit only

Logs all Codex delegations for auditing. Records:
- Timestamp and thread ID
- Prompt summary
- Sandbox mode and approval policy
- Success/failure status

## Design Notes

Two-layer enforcement matching the Gemini web search pattern:
1. **Soft layer** (UserPromptSubmit): Guide Claude toward correct tool choice
2. **Hard layer** (PreToolUse): Block incorrect tool usage for unambiguous cases

### Token Preservation Strategy

The blocked subagents are replaced by Codex delegation because:

| Subagent | Limitation | Codex Advantage |
|----------|-----------|-----------------|
| `Explore` | Returns findings to Claude's context | External processing, summary only |
| `test_gen` | Skeletons with TODO assertions | Complete tests + verification |
| `doc_comments` | Text output only | Writes directly to files |
| `diff_digest` | Summary in Claude's context | Summary stays external |

**Token savings:** ~95-97% for large tasks. The full file contents and generated code stay in Codex's context; only a summary returns to Claude.

## Installation

Symlink from `~/.claude/hooks/`. See the root README for setup.
