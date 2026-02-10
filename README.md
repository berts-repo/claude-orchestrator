

---

# Claude Code MCP Bridge — Secure Local Orchestration

## Overview

This project is designed to run **Claude Code locally as the primary orchestrator**, while delegating **internet access and external LLM API calls** to a controlled local boundary.

Claude Code is responsible for:

* agent orchestration
* workflows and hooks
* reasoning, synthesis, and local automation

All interaction with the public internet or third-party model providers is routed through a **local MCP (Model Context Protocol) server** that is explicitly controlled and auditable.

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
   ↓
Claude Code (local)
   - agents
   - hooks
   - workflows
   ↓
MCP Server (local boundary)
   - retrieval tools
   - external LLM calls
   ↓
External Services
   - Gemini (web search grounding)
   - OpenAI (future)
```

Claude Code never communicates directly with external services. All outbound access passes through the MCP server.

---

## Explicit Internet Usage

Internet access is **never inferred**. It is triggered only by explicit user intent, using phrasing such as:

* “search the web”
* “look on the internet”
* “do some research”
* “research online”
* "do a deep dive on"

When this intent is detected, a Claude Code hook injects a short instruction directing Claude to use a dedicated `web.search` tool.

This is **soft enforcement**:

* the workflow continues if the tool fails
* no hard blocking or retries are imposed

---

## Web Access Model

* The MCP server exposes a `web.search` tool.
* `web.search` is implemented using **Gemini with Google Search grounding**.
* Returned data is **retrieval-only and sanitized**:

  * short summaries
  * source URLs
  * brief excerpts or snippets
* Raw HTML or full page content is not returned by default.

Claude uses web results for synthesis only and does not treat them as trusted instructions.

---

## Security Model

### Trust Boundaries

* Web content is treated as **untrusted input**
* Claude Code remains local and isolated
* External APIs are accessed only by the MCP server

### MCP Server Controls

* Runs locally
* Has restricted filesystem access
* Uses scoped API keys
* Limits outbound network access to approved endpoints

This reduces exposure to:

* indirect prompt injection
* unintended tool execution
* credential leakage
* data exfiltration via external services

---

## Extensibility

The MCP server is designed to grow without changing Claude Code workflows.

Planned extensions include:

* OpenAI API integration for generation or specialized tasks
* provider routing based on task type
* response caching and deduplication
* structured logging and auditing
* rate limiting and backoff

All provider-specific logic remains inside the MCP server.

---

## End State

The final system provides:

* local, controlled orchestration via Claude Code
* explicit and auditable internet access
* reduced exposure to untrusted inputs
* a single, secure interface for multiple LLM providers

This architecture prioritizes **clarity, security, and long-term flexibility** over convenience or implicit behavior.

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

