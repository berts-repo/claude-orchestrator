# Codex Pool MCP Server

MCP server (registered as `delegate`) exposing `codex` and `codex_parallel` tools. Spawns isolated `codex exec` subprocesses for code generation, review, and refactoring tasks.

## Overview

This server gives Claude Code access to the Codex CLI as isolated subprocesses. Each call spawns `codex exec --ephemeral` with a specified sandbox mode, runs the task, and returns the output. Parallelism is achieved by fanning out to N processes simultaneously via `Promise.all`, bypassing MCP's call serialization.

Key features:
- **Two tools** — `codex` (single task) and `codex_parallel` (up to 10 tasks in parallel)
- **Three sandbox modes** — `read-only`, `workspace-write`, `danger-full-access`
- **Ephemeral processes** — each call is a fresh `codex exec --ephemeral` subprocess; pass full context per call
- **Timeout protection** — 5-minute default (`CODEX_POOL_TIMEOUT_MS`); SIGTERM + SIGKILL on expiry
- **Output capping** — 2 MB limit per subprocess; process terminated if exceeded
- **API key resolution** — checks `OPENAI_API_KEY` env first, then `~/.codex/auth.json`

## Architecture

```
Claude Code
    │
    │ MCP tool call: codex / codex_parallel
    ▼
codex-delegation-mcp (server.js)
    │
    │ spawn: codex exec --ephemeral -s <sandbox>
    ├── subprocess 1 ─── Codex CLI ─── OpenAI API
    ├── subprocess 2 ─── Codex CLI ─── OpenAI API
    └── subprocess N ─── Codex CLI ─── OpenAI API
```

Communication between Claude Code and this server uses **stdio** (stdin/stdout JSON-RPC). Claude Code spawns the server as a child process.

For `codex_parallel`, all subprocesses start simultaneously via `Promise.all`. Wall time equals the slowest task, not the sum.

## File Map

```
codex-delegation-mcp/
├── README.md        # This file
├── server.js        # MCP server — registers codex and codex_parallel tools
├── package.json     # Dependencies: @modelcontextprotocol/sdk, zod
└── node_modules/    # Installed by npm install
```

---

## Prerequisites

- **Node.js v20+**
- **Codex CLI** — installed and authenticated (`OPENAI_API_KEY` env var or `codex login`)
- **Claude Code** — installed and working

---

## Setup

### Step 1 — Install Dependencies

```bash
cd ~/git/claude-orchestrator/codex-delegation-mcp
npm install
```

### Step 2 — Authenticate Codex

**Option A: OPENAI_API_KEY (recommended)**

```bash
export OPENAI_API_KEY="sk-..."
```

Add to your `~/.zshrc` (or `~/.bashrc`) to persist.

**Option B: Codex login (OAuth)**

```bash
codex login
```

Credentials are stored in `~/.codex/auth.json` and read automatically by the server.

### Step 3 — Register with Claude Code

Make the server executable (it uses a `#!/usr/bin/env node` shebang):

```bash
chmod +x ~/git/claude-orchestrator/codex-delegation-mcp/server.js
claude mcp add -s user delegate -- ~/git/claude-orchestrator/codex-delegation-mcp/server.js
```

Verify registration:

```bash
claude mcp list
# delegate: ... - ✓ Connected
```

### Step 4 — Pre-approve Tools (Optional)

When multiple MCP calls are in a single message, rejecting the first cancels the entire batch. Pre-approve in `~/.claude/settings.local.json`:

```json
{
  "permissions": {
    "allow": [
      "mcp__delegate__codex",
      "mcp__delegate__codex_parallel"
    ]
  }
}
```

---

## MCP Tool Interface

### `codex` — Single Task

Run a single Codex task in an isolated subprocess.

**Parameters:**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `prompt` | string | Yes | — | Task description for Codex |
| `cwd` | string | Yes | — | Absolute path to working directory |
| `sandbox` | string | No | `workspace-write` | Sandbox mode (see below) |
| `approval-policy` | string | No | `on-failure` | When Codex asks for approval |
| `model` | string | No | — | Model override (e.g. `o4-mini`) |
| `base-instructions` | string | No | — | Replace default system instructions |

**Example:**

```json
{
  "tool": "mcp__delegate__codex",
  "parameters": {
    "prompt": "Add unit tests for src/utils/validation.ts. Run npm test to verify.",
    "sandbox": "workspace-write",
    "approval-policy": "on-failure",
    "cwd": "/Users/you/Git/my-project"
  }
}
```

### `codex_parallel` — Multiple Tasks in Parallel

Run up to 10 independent Codex tasks simultaneously.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `tasks` | array | Yes | Array of task objects (same fields as `codex`, max 10) |

**Example:**

```json
{
  "tool": "mcp__delegate__codex_parallel",
  "parameters": {
    "tasks": [
      {
        "prompt": "Security review of src/auth/. Report vulnerabilities.",
        "sandbox": "read-only",
        "approval-policy": "never",
        "cwd": "/Users/you/Git/my-project"
      },
      {
        "prompt": "Performance review of src/auth/. Report bottlenecks.",
        "sandbox": "read-only",
        "approval-policy": "never",
        "cwd": "/Users/you/Git/my-project"
      }
    ]
  }
}
```

All tasks start simultaneously. Claude receives all results together.

---

## Sandbox Modes

| Mode | Writes | Network | Use Case |
|------|--------|---------|----------|
| `read-only` | None | No | Code review, analysis, exploration |
| `workspace-write` | `cwd` only | No | Code edits, test generation, refactors |
| `danger-full-access` | Anywhere | Yes | Package installs, git push |

**Rule of thumb:** Use the most restrictive mode that still lets the task succeed.

## Approval Policies

| Policy | Behavior | Use With |
|--------|----------|----------|
| `never` | Fully autonomous — no prompts | `read-only` (can't do damage) |
| `on-failure` | Auto-runs all commands; asks only if one fails | `workspace-write` (recommended default) |
| `on-request` | Auto-runs all commands; asks only if explicitly requested | `workspace-write` |
| `untrusted` | Only auto-runs safe commands (ls, cat, grep); asks for everything else | `danger-full-access` |

**Parallelism safety:**
- `read-only` calls: always safe to parallelize
- `workspace-write` calls: safe only when targeting non-overlapping directories
- Never parallelize when one task depends on another's output

---

## Output Format

### Single task (`codex`)

Returns the raw stdout from the Codex subprocess. On failure:

```
FAILED (exit 1)
Error: <stderr or timeout message>
<any stdout output>
```

### Parallel tasks (`codex_parallel`)

Returns a batched summary with wall time and per-task results:

```
Parallel batch: 3 tasks, total wall time 12340ms

### Task 1 [+0ms start, 4100ms duration]
<task 1 output>

---

### Task 2 [+1ms start, 12340ms duration]
<task 2 output>

---

### Task 3 [+0ms start, 3820ms duration]
<task 3 output>
```

---

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `OPENAI_API_KEY` | — | OpenAI API key (checked before `~/.codex/auth.json`) |
| `CODEX_POOL_TIMEOUT_MS` | `300000` (5 min) | Subprocess timeout in milliseconds |
| `CODEX_BIN` | `codex` | Path to the Codex CLI binary |

---

## Troubleshooting

### "Failed to spawn codex: ..."

Codex CLI is not installed or not on `PATH`. Install it and verify:

```bash
npm install -g @openai/codex
codex --version
```

### Tasks time out

Increase the timeout for long-running tasks:

```bash
CODEX_POOL_TIMEOUT_MS=600000 node server.js  # 10 minutes
```

Or set it permanently in your environment.

### "MCP error -32000: Connection closed"

The server crashed. Check that:
1. `OPENAI_API_KEY` is set (or `codex login` was run)
2. The `cwd` path exists and is accessible
3. `AGENTS.md` rules are not violated (e.g., attempting to access `~/.claude/`)

### Parallel tasks conflict

Two `workspace-write` tasks targeting overlapping files will race. Only parallelize tasks that write to different directories. Use sequential calls for dependent tasks.

---

*Part of the [Claude Code MCP Bridge](../README.md) project.*
