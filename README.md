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
   +---> Gemini MCP Server (stdio) --- Gemini API (web search)
   |
   +---> Codex MCP Server (stdio) ---- Sandboxed local execution (may use provider APIs)
```

Claude Code spawns each MCP server as a child process and communicates over stdin/stdout pipes.

---

## MCP Servers

### Gemini Web Search

| | |
|---|---|
| Purpose | Web search via Google Search grounding |
| Auth | Gemini API key (env var, keyring, or `.env`) |
| Transport | stdio |
| Scope | Global (user) |
| Status | Stable |
| Location | **[gemini-web-mcp/](gemini-web-mcp/)** |

Internet access is triggered by explicit user intent:

* "search the web"
* "look on the internet"
* "do some research"
* "do a deep dive on"

Returned data is retrieval-only: short summaries, source URLs, brief excerpts. Raw HTML is not returned.

See **[gemini-web-mcp/README.md](gemini-web-mcp/README.md)** for architecture, security model, and setup.

### Codex CLI (Experimental)

| | |
|---|---|
| Purpose | Code generation and refactoring |
| Auth | ChatGPT OAuth (no API key) |
| Transport | stdio |
| Scope | Global (user) |
| Status | Experimental |

Codex CLI runs as an MCP server using the `mcp-server` subcommand. Authentication uses ChatGPT OAuth via `codex login` — no API keys needed. Requires a plan with Codex CLI access (see [OpenAI docs](https://platform.openai.com/docs/guides/codex)).

---

## Security Model

### Trust Boundaries

* Web content is treated as **untrusted input**
* Claude Code remains local and isolated
* External APIs are accessed only by MCP servers
* Each MCP server has its own auth boundary

### Hooks

| Hook | Event | Purpose |
|---|---|---|
| `gemini--inject-web-search-hint.sh` | UserPromptSubmit | Detects web intent phrases and injects "use web_search" context |
| `security--restrict-bash-network.sh` | PreToolUse (Bash) | Blocks curl/wget/ssh/etc — forces web access through MCP |
| `security--guard-sensitive-reads.sh` | PreToolUse (Read, Bash) | Blocks reads of sensitive files when untrusted web content is loaded |
| `security--block-destructive-commands.sh` | PreToolUse (Bash) | Blocks rm -rf, git push --force, drop table, and other destructive commands |
| `security--log-security-event.sh` | (helper) | Logs denied actions to `~/.claude/logs/security-events.jsonl` (called by PreToolUse hooks) |
| `gemini--require-web-if-recency.sh` | Stop | Blocks responses with recency claims but no source URLs |
| `codex--inject-hint.sh` | UserPromptSubmit | Detects delegation-worthy tasks and injects Codex guidance |
| `codex--block-explore.sh` | PreToolUse (Task) | Blocks Explore subagent — use Codex read-only instead |
| `codex--block-test-gen.sh` | PreToolUse (Task) | Blocks test_gen subagent — Codex writes complete tests |
| `codex--block-doc-comments.sh` | PreToolUse (Task) | Blocks doc_comments subagent — Codex writes to files |
| `codex--block-diff-digest.sh` | PreToolUse (Task) | Blocks diff_digest subagent — keeps diffs external |
| `codex--log-delegation-start.sh` | PreToolUse (mcp__codex__codex, mcp__gemini_web__*) | Records start time for duration tracking |
| `codex--log-delegation.sh` | PostToolUse (mcp__codex__codex, mcp__gemini_web__*) | Logs delegation summaries to `~/.claude/logs/delegations.jsonl` |
| `shared--log-helpers.sh` | (helper) | Shared logging functions: `log_json()`, `rotate_jsonl()`, session ID generation |

### Audit Logging

All log entries share a unified schema with envelope fields: `timestamp`, `level` (info/warn/error), `component`, `session_id`, `event`, plus event-specific fields. The `session_id` groups all events from a single Claude Code process tree per day for correlation.

**Summary index** — `~/.claude/logs/delegations.jsonl`
- Short identifying summary (first line of prompt, truncated to 80 chars)
- Metadata: timestamp, level, session_id, tool, sandbox mode, threadId, success, duration_ms
- `detail` field points to the full prompt/response file
- FIFO rotation keeps the last 100 entries

**Duration tracking** — `~/.claude/logs/.pending/`
- PreToolUse hook records start time; PostToolUse hook computes `duration_ms`
- Pending markers are cleaned up automatically on completion

**Detail files** — `~/.claude/logs/details/`
- Codex: `{threadId}.jsonl` — one line per turn, preserving multi-turn conversation chains
- Gemini: `gemini-{epoch}-{pid}.jsonl` — one entry per call
- Auto-deleted after 30 days (time-based retention)

**Security events** — `~/.claude/logs/security-events.jsonl`
- Logged automatically when any PreToolUse hook denies an action
- Fields: timestamp, level, session_id, hook, tool, action, severity (low/medium/high/critical), pattern_matched, command_preview, cwd
- Severity mapping: destructive commands = high, network/sensitive reads = medium, blocked subagents = low
- FIFO rotation keeps the last 200 entries
- Run `/monitor` for a dashboard view of both delegation and security logs

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

See **[codex-sandbox-mcp/README.md](codex-sandbox-mcp/README.md)** for sandbox configuration, custom profiles, and verification tests.

## Codex Delegations

When Claude Code delegates tasks to Codex via MCP, significant token savings are possible by offloading high-token, low-reasoning work.

| Delegation Type | Token Savings | Guide |
|---|---|---|
| Test Generation | [test-generation.md](codex-sandbox-mcp/delegations/test-generation.md) |
| Code Review | [code-review.md](codex-sandbox-mcp/delegations/code-review.md) |
| Refactoring | [refactoring.md](codex-sandbox-mcp/delegations/refactoring.md) |
| Documentation | [documentation.md](codex-sandbox-mcp/delegations/documentation.md) |

See **[codex-sandbox-mcp/delegations/README.md](codex-sandbox-mcp/delegations/README.md)** for MCP tool reference and delegation patterns.

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
cp CLAUDE.example.md ~/.claude/CLAUDE.md
# Option B: Project-scoped — applies only when working in this repo
cp CLAUDE.example.md CLAUDE.md

# 3. Install Gemini MCP server dependencies
cd gemini-web-mcp/server
npm install
cd ~/git/claude-orchestrator

# 4. Configure API key
cp gemini-web-mcp/server/.env.example gemini-web-mcp/server/.env
chmod 600 gemini-web-mcp/server/.env
# Edit .env and add your GEMINI_API_KEY

# 5. Register MCP servers
claude mcp add -s user gemini-web -- ~/git/claude-orchestrator/gemini-web-mcp/server/start.sh

# 6. Install hooks
mkdir -p ~/.claude/hooks
ln -s ~/git/claude-orchestrator/hooks/*.sh ~/.claude/hooks/

# 7. Install global slash commands
mkdir -p ~/.claude/commands
cp slash-commands/*.md ~/.claude/commands/

# 8. Wire hooks in settings
# Hooks must be registered in ~/.claude/settings.json to run.
# See the "Hooks Wiring" section below for the full configuration.

# 9. Verify setup
claude mcp list                # gemini-web should show "Connected"
ls -la ~/.claude/hooks/        # hook scripts should be symlinked
ls ~/.claude/commands/          # slash commands should be present

# 10. Test web search
claude "search the web for MCP protocol specification"
```

## Setup Details

- **Gemini Web Search:** See **[gemini-web-mcp/README.md](gemini-web-mcp/README.md)** for architecture, setup, and security model.
- **Codex Sandbox:** See **[codex-sandbox-mcp/README.md](codex-sandbox-mcp/README.md)** for sandbox configuration.
- **Codex Delegations:** See **[codex-sandbox-mcp/delegations/README.md](codex-sandbox-mcp/delegations/README.md)** for delegation patterns.
- **Slash Commands:** Copy `slash-commands/*.md` to `~/.claude/commands/` for global availability.

---

## Hooks Wiring

After symlinking hook scripts (Quick Start step 6), register them in `~/.claude/settings.json`. Hooks are not active until wired here.

### Pre-approve MCP tools (optional, enables parallel delegation)

When multiple MCP calls are in a single message, rejecting the first cancels the entire batch. Pre-approve tools in `~/.claude/settings.local.json` for seamless parallel execution:

```json
{
  "permissions": {
    "allow": [
      "mcp__gemini_web__web_search",
      "mcp__gemini_web__web_fetch",
      "mcp__gemini_web__web_summarize",
      "mcp__codex__codex",
      "mcp__codex__codex-reply"
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

### Full hooks configuration

Edit `~/.claude/settings.json` to wire all hooks. Replace `YOUR_USER` with your actual username:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/home/YOUR_USER/.claude/hooks/gemini--inject-web-search-hint.sh",
            "timeout": 5
          },
          {
            "type": "command",
            "command": "/home/YOUR_USER/.claude/hooks/codex--inject-hint.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "/home/YOUR_USER/.claude/hooks/security--restrict-bash-network.sh",
            "timeout": 5
          },
          {
            "type": "command",
            "command": "/home/YOUR_USER/.claude/hooks/security--block-destructive-commands.sh",
            "timeout": 5
          }
        ]
      },
      {
        "matcher": "Read|Bash",
        "hooks": [
          {
            "type": "command",
            "command": "/home/YOUR_USER/.claude/hooks/security--guard-sensitive-reads.sh",
            "timeout": 5
          }
        ]
      },
      {
        "matcher": "mcp__codex__codex|mcp__codex__codex-reply|mcp__gemini_web__web_search|mcp__gemini_web__web_fetch|mcp__gemini_web__web_summarize",
        "hooks": [
          {
            "type": "command",
            "command": "/home/YOUR_USER/.claude/hooks/codex--log-delegation-start.sh",
            "timeout": 5
          }
        ]
      },
      {
        "matcher": "Task",
        "hooks": [
          {
            "type": "command",
            "command": "/home/YOUR_USER/.claude/hooks/codex--block-explore.sh",
            "timeout": 5
          },
          {
            "type": "command",
            "command": "/home/YOUR_USER/.claude/hooks/codex--block-test-gen.sh",
            "timeout": 5
          },
          {
            "type": "command",
            "command": "/home/YOUR_USER/.claude/hooks/codex--block-doc-comments.sh",
            "timeout": 5
          },
          {
            "type": "command",
            "command": "/home/YOUR_USER/.claude/hooks/codex--block-diff-digest.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "mcp__codex__codex|mcp__codex__codex-reply|mcp__gemini_web__web_search|mcp__gemini_web__web_fetch|mcp__gemini_web__web_summarize",
        "hooks": [
          {
            "type": "command",
            "command": "/home/YOUR_USER/.claude/hooks/codex--log-delegation.sh",
            "timeout": 10
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/home/YOUR_USER/.claude/hooks/gemini--require-web-if-recency.sh",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

---

## Session Instructions (CLAUDE.md)

Claude Code automatically loads `CLAUDE.md` files at the start of every session — no hooks or scripts required. Files are loaded from a hierarchy:

| Location | Scope |
|---|---|
| `~/.claude/CLAUDE.md` | All projects (global) |
| Parent directory `CLAUDE.md` files | Inherited by child projects |
| `./CLAUDE.md` (project root) | This project only (shared via git) |
| `./.claude/CLAUDE.md` | This project only (gitignored, personal) |

This repo ships [`CLAUDE.example.md`](CLAUDE.example.md) as a template. Copy it to one of the locations above to activate (see Quick Start step 2). The template declares MCP tool usage rules, Codex delegation patterns, and the project structure.

---
*Last updated: 2026-02-17*
