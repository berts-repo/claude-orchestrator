# Delegating Tasks from Claude Code to Codex (MCP Bridge)

This directory contains delegation patterns for offloading work from Claude Code to Codex via MCP.

## How It Works

Claude Code has Codex available as MCP tools: `mcp__codex__codex` and `mcp__codex__codex-reply`. When Claude calls these tools, they communicate with the Codex MCP server running inside a sandbox.

```
Claude Code (orchestrator)
    |
    | calls mcp__codex__codex with sandbox="workspace-write"
    v
Codex MCP Server (sandboxed via Bubblewrap/Seatbelt)
    |
    | executes in isolated namespace
    | can only write to cwd
    | no network access (strict mode)
    v
Returns results to Claude Code
```

---

## MCP Tools

### `mcp__codex__codex` — Start a new Codex session

| Parameter | Type | Required | Purpose |
|---|---|---|---|
| `prompt` | string | **Yes** | The task description for Codex |
| `sandbox` | string | No | `"read-only"`, `"workspace-write"`, or `"danger-full-access"` |
| `approval-policy` | string | No | `"untrusted"`, `"on-failure"`, `"on-request"`, `"never"` |
| `cwd` | string | No | Working directory (the target repo) |
| `model` | string | No | Override model (e.g., `"gpt-5.2"`, `"gpt-5.2-codex"`) |
| `developer-instructions` | string | No | Extra instructions injected as developer role |
| `base-instructions` | string | No | Replace default instructions entirely |
| `profile` | string | No | Configuration profile from config.toml |

**Returns:** `{ threadId: string, content: string }`

### `mcp__codex__codex-reply` — Continue an existing conversation

| Parameter | Type | Required | Purpose |
|---|---|---|---|
| `threadId` | string | **Yes** | Thread ID from previous codex call |
| `prompt` | string | **Yes** | Follow-up prompt |

**Returns:** `{ threadId: string, content: string }`

---

## Example Delegations

### Safe code editing (recommended default)

```
Tool: mcp__codex__codex
Parameters:
  prompt: "Add unit tests for the validateEmail function in src/utils/validation.ts.
           Use Jest. Run 'npm test' to verify all tests pass."
  sandbox: "workspace-write"
  approval-policy: "on-failure"
  cwd: "/Users/you/Git/my-project"
```

**What happens:**
- Codex reads the codebase, writes test files, runs `npm test`
- Can only write inside `/Users/you/Git/my-project`
- No network access (can't exfiltrate code)
- If a command fails, Codex asks for approval before retrying

### Read-only analysis

```
Tool: mcp__codex__codex
Parameters:
  prompt: "Review src/auth/ for security vulnerabilities. Check for:
           1. SQL injection
           2. Missing input validation
           3. Hardcoded secrets
           Report findings as a structured list."
  sandbox: "read-only"
  approval-policy: "never"
  cwd: "/Users/you/Git/my-project"
```

**What happens:**
- Codex reads code and produces a review
- Cannot modify any files
- No network access
- Fully autonomous (no approval needed — can't do anything dangerous)

### Task requiring network (use with caution)

```
Tool: mcp__codex__codex
Parameters:
  prompt: "Run 'npm install' to update dependencies, then run 'npm test'
           to verify nothing breaks. Report any test failures."
  sandbox: "danger-full-access"
  approval-policy: "untrusted"
  cwd: "/Users/you/Git/my-project"
```

**What happens:**
- No sandbox — full disk and network access
- But approval-policy is "untrusted" — Codex asks before running any non-trivial command
- Human must approve each potentially dangerous operation

---

## CLAUDE.md Instructions for Safe Delegation

Add these rules to your project's `CLAUDE.md` to ensure Claude always uses sandbox when delegating:

```markdown
## Codex Delegation Rules

When delegating tasks to Codex via mcp__codex__codex:

1. Always set sandbox: "workspace-write" unless the task requires otherwise
2. Use sandbox: "read-only" for analysis, review, and documentation tasks
3. Only use sandbox: "danger-full-access" when explicitly requested by the user,
   and always pair it with approval-policy: "untrusted"
4. Always set cwd to the specific project directory (never home dir or root)
5. Include clear acceptance criteria in the prompt
6. Include the specific test command to run
```

---

## The Orchestrator-Worker Loop

A typical Claude-Codex delegation cycle:

1. **Claude plans** — decomposes the task, identifies scope and constraints
2. **Claude delegates** — calls `mcp__codex__codex` with bounded prompt + sandbox
3. **Codex executes** — edits code, runs tests, reports results
4. **Claude reviews** — checks the output, decides if more work is needed
5. **Repeat or merge** — Claude delegates follow-up tasks or presents final result

### Example multi-step workflow

```
Claude: "I need to add email validation to the signup form."

Step 1 - Claude delegates analysis:
  mcp__codex__codex(sandbox="read-only", prompt="List all files related to
  the signup form. Show the current validation logic.")

Step 2 - Claude delegates implementation:
  mcp__codex__codex(sandbox="workspace-write", prompt="Add email validation
  to src/components/SignupForm.tsx using the existing validator pattern.
  Add tests. Run npm test.")

Step 3 - Claude reviews the diff and delegates polish:
  mcp__codex__codex(sandbox="workspace-write", prompt="The email validation
  works but is missing the error message display. Add an error message
  below the email field. Run npm test.")

Step 4 - Claude presents the final result to the user.
```

---

## Task-Specific Guides

For detailed templates and best practices for common delegation patterns:

| Task Type | Guide | Token Savings |
|---|---|---|
| **Test Generation** | [test-generation.md](test-generation.md) | ~97% |
| **Code Review** | [code-review.md](code-review.md) | ~90% |
| **Refactoring** | [refactoring.md](refactoring.md) | ~85% |
| **Documentation** | [documentation.md](documentation.md) | ~95% |
| **Diff Summarization** | Codex `read-only` | ~95% |
| **Codebase Exploration** | Codex `read-only` | ~90% |

---

## Enforced Delegations (Blocked Subagents)

These Claude Code subagents are blocked via PreToolUse hooks and must be delegated to Codex instead:

| Subagent | Why Blocked | Codex Replacement |
|---|---|---|
| `Explore` | Returns full findings to Claude's context | `read-only`, `never` |
| `test_gen` | Only creates skeletons with TODO assertions | `workspace-write`, `on-failure` |
| `doc_comments` | Only generates text, can't write files | `workspace-write`, `on-failure` |
| `diff_digest` | Summary consumes Claude's context | `read-only`, `never` |

**Token preservation:** These subagents process files within Claude's context window. By delegating to Codex, the file contents stay external — only the summary returns to Claude, saving 90-97% of tokens.

See [hooks/README.md](hooks/README.md) for hook configuration.

---

## Related

- [Sandbox Configuration](../codex-sandbox/README.md) — OS-level isolation modes
- [AGENTS.md Template](../codex-sandbox/AGENTS.md) — Runtime constraints for Codex
- [config.toml Reference](../codex-sandbox/config.toml) — Codex configuration options
