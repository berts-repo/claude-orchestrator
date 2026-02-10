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
   +---> Codex MCP Server (stdio) ---- OpenAI API (code generation)
   |
   +---> Docker MCP Gateway ---------- Additional tools
```

Claude Code spawns each MCP server as a child process and communicates over stdin/stdout pipes.

---

## MCP Servers

### Gemini Web Search

| | |
|---|---|
| Purpose | Web search via Google Search grounding |
| Auth | Gemini API key (env var) |
| Transport | stdio |
| Scope | Global (user) |
| Status | Stable |

Internet access is **never inferred**. It is triggered only by explicit user intent:

* "search the web"
* "look on the internet"
* "do some research"
* "do a deep dive on"

Returned data is retrieval-only: short summaries, source URLs, brief excerpts. Raw HTML is not returned.

### Codex CLI (Experimental)

| | |
|---|---|
| Purpose | Code generation and refactoring |
| Auth | ChatGPT OAuth (no API key) |
| Transport | stdio |
| Scope | Global (user) |
| Status | Experimental |

Codex CLI v0.98.0 runs as an MCP server using the `mcp-server` subcommand. Authentication uses ChatGPT OAuth via `codex login` — no API keys needed. Requires a ChatGPT Pro plan ($20/month).

### Docker MCP Gateway

Additional tools exposed via Docker MCP gateway (Brave search, Wikipedia, Hacker News, Obsidian, Puppeteer, Git, etc.).

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

### Risks Mitigated

* Indirect prompt injection via web results
* Unintended tool execution
* Credential leakage via post-injection file reads
* Data exfiltration via external services
* Cross-contamination between web search and code generation

---

## Extensibility

The MCP server architecture grows without changing Claude Code workflows:

* Provider routing based on task type
* Response caching and deduplication
* Structured logging and auditing
* Rate limiting and backoff

All provider-specific logic remains inside the MCP servers.

---

## Setup

See **[SETUP.md](SETUP.md)** for the complete installation guide.

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
*Last updated: 2026-02-10*
