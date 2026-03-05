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
   +---> delegate-web MCP Server (stdio) --- Gemini API (web search + fetch)
   |
   +---> codex-pool MCP Server (stdio) -- codex exec subprocesses (sandboxed)
```

Claude Code spawns each MCP server as a child process and communicates over stdin/stdout pipes.
For the web MCP: register the server as `delegate-web`, while hook/tool matchers use the `delegate_web` namespace (`mcp__delegate_web__*`).

---

## MCP Servers

### delegate-web (Web Search + Fetch)

| | |
|---|---|
| Purpose | Web search via Google Search grounding; URL fetching and extraction |
| Auth | Gemini API key (env var, keyring, or `.env`) |
| Transport | stdio |
| Scope | Global (user) |
| Status | Stable |
| Location | **[web-search-mcp/](web-search-mcp/)** |

Tools exposed:

* `search` — queries Gemini with Google Search grounding, returns a summary and source URLs
* `fetch` — fetches a URL, extracts readable content via Readability, returns Markdown or plain text

Internet access is triggered by explicit user intent:

* "search the web"
* "look on the internet"
* "do some research"
* "do a deep dive on"

Returned data is retrieval-only: short summaries, source URLs, brief excerpts. Raw HTML is not returned.

### codex-pool (Codex Subprocess Dispatcher)

| | |
|---|---|
| Purpose | Code generation, review, refactoring via isolated subprocesses |
| Auth | `OPENAI_API_KEY` env var or `~/.codex/auth.json` |
| Transport | stdio |
| Scope | Global (user) |
| Status | Stable |
| Location | **[codex-pool-mcp/](codex-pool-mcp/)** |

Tools exposed:

* `codex` — spawns a single `codex exec --ephemeral` subprocess; backward-compatible with `mcp__delegate__codex`
* `codex_parallel` — fans out up to 10 tasks simultaneously via `Promise.all`, bypassing MCP call serialization

Each call is ephemeral — full task context must be provided per call. Sandboxing is handled by the Codex CLI's `--sandbox` flag.

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
| `gemini--inject-web-search-hint.sh` | UserPromptSubmit | Detects web intent phrases and injects "use search" context |
| `gemini--preempt-recency-queries.sh` | UserPromptSubmit | Detects time-sensitive prompts and injects a search hint before inference |
| `security--restrict-bash-network.sh` | PreToolUse (Bash) | Blocks curl/wget/ssh/etc — forces web access through MCP |
| `security--guard-sensitive-reads.sh` | PreToolUse (Read, Bash, Glob, Edit, Write) | Blocks reads of sensitive files when untrusted web content is loaded |
| `security--block-destructive-commands.sh` | PreToolUse (Bash) | Blocks rm -rf, git push --force, drop table, and other destructive commands |
| `security--log-security-event.sh` | (helper) | Logs denied actions to `~/.claude/logs/security-events.jsonl` (called by PreToolUse hooks) |
| `codex--delegate-task-hint.sh` | UserPromptSubmit | Detects delegation-worthy tasks (implement/refactor/test/audit) and injects Codex delegation guidance before inference |
| `codex--block-subagents.sh` | PreToolUse (Task) | Blocks configured Task subagent types from `hooks/blocked-subagents.conf` and returns sandbox hints for Codex delegation |
| `codex--log-delegation-start.sh` | PreToolUse (mcp__delegate__codex, mcp__delegate__codex_parallel, mcp__delegate_web__search, mcp__delegate_web__fetch) | Records start time for duration tracking |
| `codex--log-delegation.sh` | PostToolUse (mcp__delegate__codex, mcp__delegate__codex_parallel, mcp__delegate_web__search, mcp__delegate_web__fetch) | Logs delegation summaries to `~/.claude/logs/delegations.jsonl` |
| `shared--codex-log-helpers.sh` | (helper) | Codex logging helpers; `codex_log_correlation_key` hashes the full prompt to avoid parallel-call collisions |
| `shared--log-helpers.sh` | (helper) | Shared logging functions: `log_json()`, `rotate_jsonl()`, session ID generation |

To block an additional Task subagent type, add a line in `hooks/blocked-subagents.conf` and run `bash scripts/sync-hooks.sh`.

### Audit Logging

All log entries share a unified schema with envelope fields: `timestamp`, `level` (info/warn/error), `component`, `session_id`, `event`, plus event-specific fields. The `session_id` groups all events from a single Claude Code process tree per day for correlation.

**Summary index** — `~/.claude/logs/delegations.jsonl`
- Short identifying summary (first line of prompt, truncated to 80 chars)
- Metadata: timestamp, level, session_id, tool, sandbox mode, call_id, success, duration_ms
- `detail` field points to the full prompt/response file
- FIFO rotation keeps the last 100 entries

**Duration tracking** — `~/.claude/logs/.pending/`
- PreToolUse hook records start time; PostToolUse hook computes `duration_ms`
- Pending markers are cleaned up automatically on completion

**Detail files** — `~/.claude/logs/details/`
- Codex: `{threadId}.jsonl` — one JSONL entry per turn, appended across turns of the same thread
- Gemini: `gemini-{epoch}-{pid}.jsonl` — one entry per call
- Auto-deleted after 30 days (time-based retention)

**Security events** — `~/.claude/logs/security-events.jsonl`
- Logged automatically when any PreToolUse hook denies an action
- Fields: timestamp, level, session_id, hook, tool, action, severity (low/medium/high/critical), pattern_matched, command_preview, cwd
- Severity mapping: destructive commands = high, network/sensitive reads = medium, blocked subagents = low
- FIFO rotation keeps the last 200 entries
- Run `/monitor` for a dashboard view of both delegation and security logs
- Run `bash scripts/log-view.sh` to browse full prompt/response content from the terminal

**Viewing logs** — `scripts/log-view.sh`:
```bash
bash scripts/log-view.sh              # last 5 entries, full prompt/response
bash scripts/log-view.sh 20           # last 20 entries
bash scripts/log-view.sh --list       # summary table only (no prompt/response)
bash scripts/log-view.sh --codex      # Codex delegations only
bash scripts/log-view.sh --gemini     # Gemini (web search/fetch) only
bash scripts/log-view.sh auth         # keyword filter on summary/cwd
bash scripts/log-view.sh 10 --codex   # combinable
```
Or use `/delegation-log [args]` inside a Claude session.

**Cleanup** — run `/log-cleanup` to:
- Remove orphaned detail files not referenced by the summary index
- Remove expired detail files (30+ days)
- Remove stale pending markers (1+ hours old) from interrupted delegations
- Clean up stale summary entries
- Report disk usage

### Slash Commands

Global slash commands are installed to `~/.claude/commands/`:

| Command | Purpose |
|---|---|
| `/delegation-log [args]` | Browse delegation logs with full prompt/response (wraps `scripts/log-view.sh`) |
| `/log-cleanup` | Clean up orphaned and expired delegation audit logs |
| `/monitor` | Dashboard showing delegation stats and security event analysis |

```bash
# Install (included in Quick Start)
mkdir -p ~/.claude/commands
cp slash-commands/*.md ~/.claude/commands/
```

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

# 3. Install dependencies for both MCP servers
cd web-search-mcp && npm install
cd ../codex-pool-mcp && npm install
cd ~/git/claude-orchestrator

# 4. Configure API key
cp web-search-mcp/.env.example web-search-mcp/.env
chmod 600 web-search-mcp/.env
# Edit .env and add your GEMINI_API_KEY

# 5. Register MCP servers
chmod +x ~/git/claude-orchestrator/codex-pool-mcp/server.js  # needs execute bit (shebang-based)
claude mcp add -s user delegate-web -- ~/git/claude-orchestrator/web-search-mcp/start.sh
claude mcp add -s user delegate -- ~/git/claude-orchestrator/codex-pool-mcp/server.js

# 6. Install hooks and apply manifest wiring
bash scripts/sync-hooks.sh   # discovers hook frontmatter headers, updates ~/.claude/hooks/ symlinks and ~/.claude/settings.json

# 7. Install global slash commands
mkdir -p ~/.claude/commands
cp slash-commands/*.md ~/.claude/commands/

# 8. Verify setup
claude mcp list                # delegate-web and delegate should show "Connected"
ls -la ~/.claude/hooks/        # hook scripts should be symlinked
ls ~/.claude/commands/         # slash commands should be present

# 9. Test web search
claude "search the web for MCP protocol specification"
```

## Setup Details

- **Slash Commands:** Copy `slash-commands/*.md` to `~/.claude/commands/` for global availability.

---

## Hooks Wiring

Hook registration is managed via frontmatter headers in each `hooks/*.sh` file (`# HOOK_EVENT:`, `# HOOK_TIMEOUT:`, optional `# HOOK_MATCHER:`). Run `bash scripts/sync-hooks.sh` to apply updates (it discovers these headers and manages both `~/.claude/hooks/` symlinks and `~/.claude/settings.json` entries). Never manually edit `~/.claude/settings.json` for hook wiring.

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
*Last updated: 2026-03-04*
