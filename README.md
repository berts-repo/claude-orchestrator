# Claude Code MCP Bridge — Secure Local Orchestration

## Overview

This project runs **Claude Code locally as the primary orchestrator**, delegating internet access, code generation, and external LLM API calls to controlled local MCP (Model Context Protocol) servers.

A core goal is **token efficiency**: high-volume, low-reasoning tasks (code generation, test writing, refactoring, documentation) are offloaded to specialised agents (Codex, Gemini) that are often better suited to those tasks — preserving Claude's context for orchestration, reasoning, and synthesis. Delegation routinely saves 85–97% of the tokens those tasks would otherwise consume.

Security is a first-class concern throughout: all external content is treated as untrusted input, sensitive file access and destructive commands are blocked by hooks, every delegation is logged to an auditable SQLite DB, and no credentials or private paths are ever exposed to external agents.

Claude Code is responsible for:

* Agent orchestration
* Workflows and hooks
* Reasoning, synthesis, and local automation

All interaction with the public internet or third-party model providers is routed through **local MCP servers** that are explicitly controlled and auditable.

---

## Design Goals

* Keep Claude Code local and authoritative
* Make internet access explicit, intentional, and auditable
* Treat all external content as untrusted input
* Allow multiple LLM providers without changing Claude workflows
* Minimize exposure to prompt injection and data exfiltration risks

---

## Prerequisites

- **Linux or macOS**
- **Claude Code CLI** (`claude`) — installed and authenticated
- **Node.js v20+** — for the Gemini MCP server
- **jq** — JSON parsing in hooks (`sudo pacman -S jq` / `brew install jq`)
- **sqlite3** — required by `/audit`, `/report`, and DB-backed audit hooks
- **Codex CLI** (optional) — for code delegations (`codex login` for auth)

---

## Quick Start

```bash
git clone <repo-url> ~/git/claude-orchestrator
cd ~/git/claude-orchestrator
# setup.sh installs CLAUDE.global.md -> ~/.claude/CLAUDE.md automatically
bash scripts/setup.sh
```
Re-run `bash scripts/setup.sh` at any time — it is idempotent.

## Setup Details

`scripts/setup.sh` handles everything on first run and is safe to re-run. Only run `bash scripts/sync.sh` manually if you modify hooks or slash commands after the initial install — it re-syncs `~/.claude/hooks/` symlinks, `~/.claude/settings.json` hook entries, and `~/.claude/commands/`. Use `bash scripts/sync.sh --check` to validate without applying changes.

`config.json` is machine-local, gitignored state at repo root. `scripts/setup.sh` auto-creates it from `config.example.json` when missing.

### Pre-approve MCP tools (optional, enables parallel delegation)

When multiple MCP calls are in a single message, rejecting the first cancels the entire batch. Pre-approve tools in `~/.claude/settings.local.json` for seamless parallel execution:

```json
{
  "permissions": {
    "allow": [
      "mcp__delegate_web__search",
      "mcp__delegate_web__fetch",
      "mcp__delegate__codex",
      "mcp__delegate__codex_parallel"
    ],
    "deny": [],
    "ask": []
  }
}
```

### Config file distinction

| File | Purpose |
|---|---|
| `~/.claude.json` | MCP server registration, user preferences |
| `~/.claude/settings.json` | Hooks, security settings, status line |
| `~/.claude/settings.local.json` | Tool permissions (allow/deny/ask lists) |
| `.mcp.json` (project root) | Project-scoped MCP servers |

---

## Architecture

```
User Intent
   |
Claude Code (local orchestrator)
   - agents, hooks, workflows
   |
   +---> delegate-web MCP Server (stdio) --- Web API (Gemini/Brave/…)
   |
   +---> codex-delegation MCP Server (stdio) -- codex exec subprocesses (sandboxed)
   |
   +---> audit MCP Server (stdio) ----------- SQLite audit DB (~/.claude/audit.db)
```

Claude Code spawns each MCP server as a child process and communicates over stdin/stdout pipes.
For the web MCP: register the server as `delegate-web`, while hook/tool matchers use the `delegate_web` namespace (`mcp__delegate_web__*`).

---

## MCP Servers

### delegate-web (Web Search + Fetch)

| | |
|---|---|
| Purpose | Web search via Google Search grounding; URL fetching and extraction |
| Auth | Gemini API key (env var, keyring, or `web-delegation-mcp/.env`) |
| Transport | stdio |
| Scope | Global (user) |
| Status | Stable |
| Location | **[web-delegation-mcp/](web-delegation-mcp/)** |

Tools exposed:

* `search` — queries Gemini with Google Search grounding, returns a summary and source URLs
* `fetch` — fetches a URL, extracts readable content via Readability, returns Markdown or plain text

Internet access is triggered by explicit user intent:

* "search the web"
* "look on the internet"
* "do some research"
* "do a deep dive on"

`web--preempt-recency-queries.sh` is an intentional exception to the explicit-intent rule: it is pre-authorized proactive search for time-sensitive prompts (for example: "latest", "as of today", "right now").

Returned data is retrieval-only: short summaries, source URLs, brief excerpts. Raw HTML is not returned.

### audit (Audit DB MCP Server)

| | |
|---|---|
| Purpose | SQLite audit DB owner; exposes query/config tools for the audit log |
| Auth | None (local stdio) |
| Transport | stdio |
| Scope | Global (user) |
| Status | Stable |
| Location | **[audit-mcp/](audit-mcp/)** |

Tools exposed:

* `get_tasks` — list recent audit tasks; filter by `tool_type`, `keyword`, `project`, or `cwd`
* `get_report` — pre-built analytics: usage breakdown, project failure rates, slowest batches, running tasks
* `get_status` — DB health check: config values, row counts per table, file size
* `set_config` — write an allowlisted config key to the DB (retention periods, full-output storage flags)
* `delete_config` — remove an allowlisted config key from the DB (including `allowed_root:<path>` entries)
* `run_query` — run a raw `SELECT` against the audit DB (only `SELECT` statements permitted)

The audit server is the DB owner. It initialises the schema, runs retention cleanup at startup, and is the only server that exposes the DB to Claude via MCP tools. The codex-delegation server writes to the same `~/.claude/audit.db` file via the shared `db.js` module.

---

### codex-delegation (Codex Subprocess Dispatcher)

| | |
|---|---|
| Purpose | Code generation, review, refactoring via isolated subprocesses |
| Auth | `OPENAI_API_KEY` env var or `~/.codex/auth.json` |
| Transport | stdio |
| Scope | Global (user) |
| Status | Stable |
| Location | **[codex-delegation-mcp/](codex-delegation-mcp/)** |

Tools exposed:

* `codex` — spawns a single `codex exec --ephemeral` subprocess; backward-compatible with `mcp__delegate__codex`
* `codex_parallel` — fans out up to 10 tasks simultaneously via `Promise.all`, bypassing MCP call serialization

Each call is ephemeral — full task context must be provided per call. Sandboxing is handled by the Codex CLI's `--sandbox` flag.
Internally, `server.js` now deduplicates shared task lifecycle logic (used by both handlers) via three private helpers: `buildTaskRecord(task, state, overrides)`, `buildStoredOutputs(result, promptText, project, promptCap)`, and `buildFinalizeUpdate(result, storedOutputs, startedAt)`. These helpers are implementation details only and are not a public MCP API.

### Allowed Working Directory Roots (Audit DB Primary, Env Override Secondary)

The codex-delegation server validates every delegated task `cwd` against allowed root prefixes.

- Primary project-managed roots: audit DB config keys `allowed_root:<absolute-path>` (managed via `/audit add-path`, `list-paths`, `remove-path`)
- Bootstrap defaults: repo-root `config.json` (`allowedRoots`)
- Override/additive env var: `CODEX_POOL_ALLOWED_CWD_ROOTS` (comma-separated absolute paths, e.g. `/home/me/git,/tmp`)
- Validation: `cwd` must be absolute, canonicalized, inside an allowed root, and not under blocked system roots (for example `/`, `/etc`, `/usr`)

Common failure message:

```text
invalid cwd '...'. cwd must match one of the configured allowed roots (current: ...)
```

Remediation:
- Run `/audit add-path <absolute-path>` to persist a root in the audit DB
- Optionally set `CODEX_POOL_ALLOWED_CWD_ROOTS` for temporary per-process overrides/additions
- Ensure delegated task `cwd` uses an absolute path inside one of those roots

---

## Security Model

### Trust Boundaries

* Web content is treated as **untrusted input**
* Claude Code remains local and isolated
* External APIs are accessed only by MCP servers
* Each MCP server has its own auth boundary

### Hooks

Guidance-oriented hooks are designed to fire before inference (`UserPromptSubmit`), not after a failed response/retry.

| Hook | Event | Purpose |
|---|---|---|
| `web--inject-web-search-hint.sh` | UserPromptSubmit | Detects web intent phrases and injects "use search" context |
| `web--preempt-recency-queries.sh` | UserPromptSubmit | Detects time-sensitive prompts and injects a search hint before inference |
| `security--restrict-bash-network.sh` | PreToolUse (Bash) | Blocks curl/wget/ssh/etc — forces web access through MCP |
| `security--guard-sensitive-reads.sh` | PreToolUse (Read, Bash, Glob, Edit, Write) | Blocks reads of sensitive files unconditionally |
| `security--protect-sensitive-writes.sh` | PreToolUse (Bash, Edit, Write) | Blocks direct writes/edits/deletes against `.env*` and `.ssh` paths (except `.env.example`/`.env.template`/`.env.sample`) |
| `security--block-destructive-commands.sh` | PreToolUse (Bash) | Blocks rm -rf, git push --force, drop table, and other destructive commands |
| `security--log-security-event.sh` | (helper) | Logs denied actions to the `security_events` table in `~/.claude/audit.db` (called by PreToolUse hooks) |
| `codex--delegate-task-hint.sh` | UserPromptSubmit | Detects delegation-worthy tasks (implement/refactor/test/audit) and injects Codex delegation guidance before inference |
| `codex--block-subagents.sh` | PreToolUse (Task) | Blocks configured Task subagent types from `hooks/blocked-subagents.conf` and returns sandbox hints for Codex delegation |
| `web--log-start.sh` | PreToolUse (`mcp__delegate_web__*`) | Inserts `started` web task records in `~/.claude/audit.db` before web MCP calls |
| `web--log-end.sh` | PostToolUse (`mcp__delegate_web__*`) | Finalizes web task records (`completed`/`error`, `duration_ms`) in `~/.claude/audit.db` |
| `shared--codex-log-helpers.sh` | (helper) | Delegation correlation helpers; `codex_log_correlation_key` hashes full prompt inputs to avoid parallel-call collisions |
| `shared--log-helpers.sh` | (helper) | Shared session helpers (session ID generation and common directory setup) |

To block an additional Task subagent type, add a line in `hooks/blocked-subagents.conf` and run `bash scripts/sync.sh`.

### Audit Logging

All log entries share a unified schema with envelope fields: `timestamp`, `level` (info/warn/error), `component`, `session_id`, `event`, plus event-specific fields. The `session_id` groups all events from a single Claude Code process tree per day for correlation.

#### Audit DB — `~/.claude/audit.db`

Primary audit storage is SQLite at `~/.claude/audit.db`. The schema and retention logic live in `audit-mcp/db.js`. The `audit` MCP server is the DB owner: it initialises schema, runs retention cleanup at startup, and exposes the DB to Claude via MCP tools (`get_tasks`, `get_report`, `get_status`, `set_config`, `delete_config`, `run_query`).

- Stores Codex task/delegation records (prompt slug/hash, output, status, cwd/project, timing, token estimates)
- Stores web MCP task records in `web_tasks` (`tool_name`, prompt/hash, status, timestamps, duration, error text)
- Stores denied-action security records in `security_events` (hook/tool, severity, pattern, command preview, cwd)
- Includes status and timing fields such as `status`, `started_at`, `ended_at`, and `duration_ms`
- Captures related metadata like project, cwd, tool type, prompt slug/hash, and failure reason
- Stores token estimate fields on `tasks`: `prompt_tokens_est` (estimated input tokens, `Math.ceil(prompt.length / 4)`, set at task creation) and `response_token_est` (estimated output tokens, `Math.ceil(stdout_bytes / 4)`, set after subprocess completion)
- Stores `output_truncated` for all tasks and `output_full` when full-output storage is enabled
- Use `/audit` for direct SQLite queries/config updates; the `/audit` slash command calls `mcp__audit__*` tools under the hood
- Run `/report` for a dashboard view of audit DB metrics across Codex tasks, web tasks, and security events
### Slash Commands

Global slash commands are installed to `~/.claude/commands/`:

| Command | Purpose |
|---|---|
| `/audit` | Inspect and manage the SQLite audit DB (`~/.claude/audit.db`): status/report/log/query plus config and allowed-root management |
| `/history` | Retrieve recent audit batch history with full task prompts/responses and per-task/per-batch token-estimate totals; defaults to the latest session |
| `/direct` | Handle a task directly with Claude tools (no MCP delegation by default); `--allow codex`, `--allow web`, or `--allow all` selectively re-enable MCPs |
| `/report` | Generate a monitoring report (session-scoped by default, or 7/30 day views) across tasks, batches, security events, web usage, and Claude sessions, including token-estimate usage sections |
| `/summarize` | Generate project context summaries with size modes/delegation options; optional cache in `.SUMMARY.md` |
| `/session` | Capture, restore, append, clear, or annotate session snapshots in `.SESSION.md` |

Key command options and defaults:

| Command | Options / Behavior |
|---|---|
| `/audit` | Subcommands: `status`, `report [days]`, `log [N] [--list] [--codex|--web|--security] [keyword]`, `query <sql>` (SELECT-only), `set-project`, `set`, `list-projects`, `add-path`, `list-paths`, `remove-path` |
| `/history` | Flags: `--session <id>`, `--limit <n>` (default `5`), `--list` / `-l`; default mode resolves latest session and shows grouped batch/task output with per-task/per-batch token-estimate totals |
| `/direct` | Parses task text plus optional `--allow <codex|web|all>`; without `--allow`, MCP codex/web tools remain blocked |
| `/report` | Flags: `--weekly` / `-w` (last 7 days), `--monthly` / `-m` (last 30 days); default scope is current/latest session. Sections: Running Tasks, Usage Breakdown, Codex Usage by Model, Project Failure Rates, Slowest Batches, Security Events, Gemini/Web Delegations, Claude Sessions (Usage Breakdown and Codex Usage by Model include `prompt_tokens_est`/`response_token_est` totals) |
| `/summarize` | Flags: `--small`, `--medium` (default), `--large`, `--delegate`, `--claude`, `--cached`, `--refresh`, `--save`; can reuse `.SUMMARY.md` cache or regenerate |
| `/session` | Flags: `--resume`, `--append`, `--clear`, `--note "<text>"`; default captures a fresh snapshot and writes `.SESSION.md` |

```bash
# Install/update (included in Quick Start)
bash scripts/sync.sh
# Or commands-only:
# bash scripts/sync-commands.sh
```

Slash command cache files `.SESSION.md` and `.SUMMARY.md` are local/project state and are gitignored.

### Risks Mitigated

* Indirect prompt injection via web results
* Unintended tool execution
* Credential leakage via post-injection file reads
* Data exfiltration via external services
* Cross-contamination between web search and code generation

---

## Codex Sandbox

Codex CLI runs inside OS-level sandboxes (Seatbelt on macOS, Bubblewrap on Linux) — kernel-enforced isolation that restricts filesystem writes, network access, and sensitive file reads. This is the hard boundary that prevents agent escape, even if prompt injection occurs.

| Mode | Writes | Network | Use case |
|---|---|---|---|
| `read-only` | None | No | Code review, analysis |
| `workspace-write` | cwd only | No | Code edits, tests, refactors |
| `danger-full-access` | Anywhere | Yes | Package installs, git push |

## Codex Delegations

When Claude Code delegates tasks to Codex via MCP, significant token savings are possible by offloading high-token, low-reasoning work.

| Delegation Type | Estimated Token Savings |
|---|---|
| Test Generation | ~97% |
| Code Review | ~90% |
| Refactoring | ~85% |
| Documentation | ~95% |

---

## Extensibility

The MCP server architecture grows without changing Claude Code workflows:

* Provider routing based on task type
* Response caching and deduplication
* Structured logging and auditing
* Rate limiting and backoff

All provider-specific logic remains inside the MCP servers.

---

## Session Instructions (CLAUDE.md)

This repo ships [`CLAUDE.global.md`](CLAUDE.global.md) as the session-instructions template. `bash scripts/setup.sh` installs it globally at `~/.claude/CLAUDE.md` and keeps it updated on re-run.

---
*Last updated: 2026-03-13*
