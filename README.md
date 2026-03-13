# Claude Code MCP Bridge — Secure Local Orchestration

## Overview

This project runs **Claude Code locally as the primary orchestrator**, delegating internet access, code generation, and external LLM API calls to controlled local MCP (Model Context Protocol) servers.

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
| `security--log-security-event.sh` | (helper) | Logs denied actions to `~/.claude/logs/security-events.jsonl` (called by PreToolUse hooks) |
| `codex--delegate-task-hint.sh` | UserPromptSubmit | Detects delegation-worthy tasks (implement/refactor/test/audit) and injects Codex delegation guidance before inference |
| `codex--block-subagents.sh` | PreToolUse (Task) | Blocks configured Task subagent types from `hooks/blocked-subagents.conf` and returns sandbox hints for Codex delegation |
| `web--log-start.sh` | PreToolUse (`mcp__delegate_web__*`) | Records web delegation start markers used for duration tracking |
| `shared--codex-log-helpers.sh` | (helper) | Delegation correlation helpers; `codex_log_correlation_key` hashes full prompt inputs to avoid parallel-call collisions |
| `shared--log-helpers.sh` | (helper) | Shared logging functions: `log_json()`, `rotate_jsonl()`, session ID generation |

To block an additional Task subagent type, add a line in `hooks/blocked-subagents.conf` and run `bash scripts/sync.sh`.

### Audit Logging

All log entries share a unified schema with envelope fields: `timestamp`, `level` (info/warn/error), `component`, `session_id`, `event`, plus event-specific fields. The `session_id` groups all events from a single Claude Code process tree per day for correlation.

#### Audit DB — `~/.claude/audit.db`

Primary audit storage is SQLite at `~/.claude/audit.db`. The schema and retention logic live in `audit-mcp/db.js`. The `audit` MCP server is the DB owner: it initialises schema, runs retention cleanup at startup, and exposes the DB to Claude via MCP tools (`get_tasks`, `get_report`, `get_status`, `set_config`, `delete_config`, `run_query`).

- Stores Codex task/delegation records (prompt slug/hash, output, status, cwd/project, timing)
- Includes status and timing fields such as `status`, `started_at`, `ended_at`, and `duration_ms`
- Captures related metadata like project, cwd, tool type, prompt slug/hash, and failure reason
- Stores `output_truncated` for all tasks and `output_full` when full-output storage is enabled
- Use `/audit` for direct SQLite queries/config updates; the `/audit` slash command calls `mcp__audit__*` tools under the hood
- Web delegation task records are not yet written to the audit DB

**Duration tracking** — `~/.claude/logs/.pending/`
- PreToolUse hooks record start time for web delegation duration tracking
- Pending markers are cleaned up automatically on completion

**Security events** — `~/.claude/logs/security-events.jsonl`
- Logged automatically when any PreToolUse hook denies an action
- Fields: timestamp, level, session_id, hook, tool, action, severity (low/medium/high/critical), pattern_matched, command_preview, cwd
- Severity mapping: destructive commands = high, network/sensitive reads = medium, blocked subagents = low
- FIFO rotation keeps the last 200 entries
- Run `/report` for a dashboard view of audit DB metrics plus security events
### Slash Commands

Global slash commands are installed to `~/.claude/commands/`:

| Command | Purpose |
|---|---|
| `/audit` | Query and browse the SQLite audit log (`~/.claude/audit.db`) |
| `/direct` | Handle a task directly with Claude's built-in tools, bypassing MCP delegation; `--allow codex`, `--allow web`, or `--allow all` selectively re-enable MCPs |
| `/report` | Generate a concise monitoring report from audit DB + security events |
| `/summarize` | Generate project context summaries; optional cache in `.SUMMARY.md` |
| `/session` | Capture or restore session snapshots in `.SESSION.md` |

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
# 1. Clone and enter the repo
git clone <repo-url> ~/git/claude-orchestrator
cd ~/git/claude-orchestrator

# 2. Install session instructions (pick one)
# Option A: Global — applies to all projects
cp CLAUDE.global.md ~/.claude/CLAUDE.md
# Option B: Project-scoped — applies only when working in this repo
# WARNING: This overwrites the existing project CLAUDE.md
cp CLAUDE.global.md CLAUDE.md

# 3. Install dependencies for all MCP servers
cd web-delegation-mcp && npm install
cd ../codex-delegation-mcp && npm install  # better-sqlite3 requires native bindings (install scripts run)
cd ../audit-mcp && npm install             # better-sqlite3 requires native bindings (install scripts run)
cd ~/git/claude-orchestrator

# 4. Configure API key
cp web-delegation-mcp/.env.example web-delegation-mcp/.env
chmod 600 web-delegation-mcp/.env
# Edit web-delegation-mcp/.env and add your GEMINI_API_KEY

# 5. Register MCP servers (codex + audit entry points require execute bit)
chmod +x ~/git/claude-orchestrator/codex-delegation-mcp/server.js
chmod +x ~/git/claude-orchestrator/audit-mcp/server.js
claude mcp add -s user delegate-web -- ~/git/claude-orchestrator/web-delegation-mcp/start.sh
claude mcp add -s user delegate -- ~/git/claude-orchestrator/codex-delegation-mcp/server.js
claude mcp add -s user audit -- ~/git/claude-orchestrator/audit-mcp/server.js

# 6. Install hooks + slash commands (unified entry point)
bash scripts/sync.sh

# 7. Verify setup
claude mcp list                # delegate-web, delegate, and audit should show "Connected"
ls -la ~/.claude/hooks/        # hook scripts should be symlinked
ls ~/.claude/commands/         # slash commands should be present

# 8. Test web search
claude "search the web for MCP protocol specification"
```

## Setup Details

- **Slash Commands:** Run `bash scripts/sync.sh` from repo root to keep `commands/*.md` linked into `~/.claude/commands/`.
- **Verification mode:** Run `bash scripts/sync.sh --check` to validate hook/command discovery without applying changes.

---

## Hooks Wiring

Hook registration is managed via frontmatter headers in each `hooks/*.sh` file (`# HOOK_EVENT:`, `# HOOK_TIMEOUT:`, optional `# HOOK_MATCHER:`). Run `bash scripts/sync.sh` to apply updates (it runs unified hooks + slash-command sync, including `~/.claude/hooks/` symlinks and `~/.claude/settings.json` hook entries). Never manually edit `~/.claude/settings.json` for hook wiring.
`scripts/sync-hooks.sh` and `scripts/sync-commands.sh` remain available for targeted operations, but `scripts/sync.sh` is the canonical entry point.

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

## Session Instructions (CLAUDE.md)

Claude Code automatically loads `CLAUDE.md` files at the start of every session — no hooks or scripts required. Files are loaded from a hierarchy:

| Location | Scope |
|---|---|
| `~/.claude/CLAUDE.md` | All projects (global) |
| Parent directory `CLAUDE.md` files | Inherited by child projects |
| `./CLAUDE.md` (project root) | This project only (shared via git) |
| `./.claude/CLAUDE.md` | This project only (gitignored, personal) |

This repo ships [`CLAUDE.global.md`](CLAUDE.global.md) as a template. Copy it to one of the locations above to activate (see Quick Start step 2). The template declares MCP tool usage rules, Codex delegation patterns, and the project structure.

---
*Last updated: 2026-03-13*
