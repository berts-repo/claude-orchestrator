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
| `inject-web-search-hint.sh` | UserPromptSubmit | Detects web intent phrases and injects "use web_search" context |
| `restrict-bash-network.sh` | PreToolUse (Bash) | Blocks curl/wget/ssh/etc — forces web access through MCP |
| `guard-sensitive-reads.sh` | PreToolUse (Read, Bash) | Blocks reads of sensitive files when untrusted web content is loaded |
| `require-web-if-recency.sh` | Stop | Blocks responses with recency claims but no source URLs |
| `block-explore-for-codex.sh` | PreToolUse (Task) | Blocks Explore subagent — use Codex read-only instead |
| `block-test-gen-for-codex.sh` | PreToolUse (Task) | Blocks test_gen subagent — Codex writes complete tests |
| `block-doc-comments-for-codex.sh` | PreToolUse (Task) | Blocks doc_comments subagent — Codex writes to files |
| `block-diff-digest-for-codex.sh` | PreToolUse (Task) | Blocks diff_digest subagent — keeps diffs external |
| `log-codex-delegation.sh` | PostToolUse (mcp__codex__codex) | Logs Codex delegations to `~/.claude/logs/codex-delegations.jsonl` |

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

See **[codex-sandbox/README.md](codex-sandbox/README.md)** for sandbox configuration, custom profiles, and verification tests.

## Codex Delegations

When Claude Code delegates tasks to Codex via MCP, significant token savings are possible by offloading high-token, low-reasoning work.

| Delegation Type | Token Savings | Guide |
|---|---|---|
| Test Generation | [test-generation.md](codex-delegations/test-generation.md) |
| Code Review | [code-review.md](codex-delegations/code-review.md) |
| Refactoring | [refactoring.md](codex-delegations/refactoring.md) |
| Documentation | [documentation.md](codex-delegations/documentation.md) |

See **[codex-delegations/README.md](codex-delegations/README.md)** for MCP tool reference and delegation patterns.

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

# 2. Install Gemini MCP server dependencies
cd gemini-web-mcp/server
npm install
cd ~/git/claude-orchestrator

# 3. Configure API key
cp gemini-web-mcp/server/.env.example gemini-web-mcp/server/.env
chmod 600 gemini-web-mcp/server/.env
# Edit .env and add your GEMINI_API_KEY

# 4. Register MCP servers
claude mcp add -s user gemini-web -- ~/git/claude-orchestrator/gemini-web-mcp/server/start.sh

# 5. Install hooks
mkdir -p ~/.claude/hooks
ln -s ~/git/claude-orchestrator/security-hooks/*.sh ~/.claude/hooks/
ln -s ~/git/claude-orchestrator/gemini-web-mcp/hooks/*.sh ~/.claude/hooks/
ln -s ~/git/claude-orchestrator/codex-delegations/hooks/*.sh ~/.claude/hooks/

# 6. Wire hooks in settings (see gemini-web-mcp/SETUP.md Step 6 for full config)
# Hooks must be registered in ~/.claude/settings.json to run

# 7. Verify setup
claude mcp list                # gemini-web should show "Connected"
ls -la ~/.claude/hooks/        # hook scripts should be symlinked

# 8. Test web search
claude "search the web for MCP protocol specification"
```

## Setup Details

- **Gemini Web Search:** See **[gemini-web-mcp/SETUP.md](gemini-web-mcp/SETUP.md)** for the complete installation guide.
- **Codex Sandbox:** See **[codex-sandbox/README.md](codex-sandbox/README.md)** for sandbox configuration.
- **Codex Delegations:** See **[codex-delegations/README.md](codex-delegations/README.md)** for delegation patterns and hooks.

---

## Session Instructions (CLAUDE.md)

Claude Code automatically loads `CLAUDE.md` files at the start of every session — no hooks or scripts required. Files are loaded from a hierarchy:

| Location | Scope |
|---|---|
| `~/.claude/CLAUDE.md` | All projects (global) |
| Parent directory `CLAUDE.md` files | Inherited by child projects |
| `./CLAUDE.md` (project root) | This project only (shared via git) |
| `./.claude/CLAUDE.md` | This project only (gitignored, personal) |

This project uses a project-root `CLAUDE.md` to declare the `web_search` tool, its usage rules, and the project structure. To apply these rules globally, copy the relevant sections to `~/.claude/CLAUDE.md`.

---
*Last updated: 2026-02-13*
