# Gemini Web Search MCP Server

MCP server exposing a `web_search` tool via the Gemini API with Google Search grounding.

## Overview

This server provides Claude Code with internet access through a controlled, auditable channel. When users explicitly request web searches ("search the web for...", "do research on..."), Claude calls this MCP tool instead of using curl/wget directly.

Key features:
- **Google Search grounding** — Gemini performs actual Google searches and grounds responses in results
- **Source attribution** — Every response includes source URLs for citation
- **Input/output sanitization** — Blocks injection patterns, strips HTML/scripts from results
- **Rate limiting** — 30 requests/minute with in-memory caching (5-min TTL)
- **Untrust markers** — All web content is wrapped in `--- BEGIN/END UNTRUSTED WEB CONTENT ---` markers

## Architecture

```
User prompt: "Search the web for latest Node.js release"
                          │
                          ▼
               ┌──────────────────┐
               │   Claude Code    │  (local orchestrator)
               │   reads intent   │
               └────────┬─────────┘
                        │ MCP tool call
                        ▼
               ┌──────────────────┐
               │  MCP Server      │  gemini-web-mcp/server/
               │  (this code)     │
               │                  │
               │  • Validates     │
               │  • Rate limits   │
               │  • Sanitizes     │
               └────────┬─────────┘
                        │ HTTPS
                        ▼
               ┌──────────────────┐
               │   Gemini API     │  generativelanguage.googleapis.com
               │   + Google       │
               │   Search Tool    │
               └──────────────────┘
```

Communication between Claude Code and this server uses **stdio** (stdin/stdout JSON-RPC), not HTTP. Claude Code spawns the server as a child process.

## Security Model

### Why No OS-Level Sandbox?

Unlike Codex (which executes arbitrary code), this server:
- **Only makes HTTP API calls** to Google's Gemini endpoint
- **Has no filesystem write access** beyond its own logs
- **Cannot execute commands** — it's a pure Node.js API client
- **Returns only text** — summaries and URLs, never raw HTML

Kernel-level sandboxing (Seatbelt/Bubblewrap) provides minimal additional protection for API-only processes. The real security is in input validation, output sanitization, and the hook-based enforcement layer.

### Defense-in-Depth Layers

| Defense | Layer | Purpose |
|---------|-------|---------|
| Query sanitization | Server | Strips control chars, HTML, collapses whitespace |
| Injection detection | Server | Regex blocks "ignore instructions", "sudo", etc. |
| Output sanitization | Server | Strips `<script>`, HTML tags, fake system prompts |
| Untrust markers | Server | Wraps all web content with clear markers |
| Rate limiting | Server | 30 req/min prevents abuse |
| `restrict-bash-network.sh` | Hook | Blocks curl/wget, forces web access through MCP |
| `inject-web-search-hint.sh` | Hook | Detects web intent, injects "use web_search" context |
| `require-web-if-recency.sh` | Hook | Blocks recency claims without source URLs |

### Trust Boundaries

```
TRUSTED                          │  UNTRUSTED
                                 │
Claude Code                      │  Gemini API responses
Local files                      │  Web search results
User prompts                     │  Grounding sources
MCP tool interface               │  Any content after "BEGIN UNTRUSTED"
```

## File Map

```
gemini-web-mcp/
├── README.md                    # This file
├── SETUP.md                     # Installation guide
├── server/                      # Canonical server code (runs from here)
│   ├── server.mjs               # Main server — registers web_search tool
│   ├── start.sh                 # Launcher — resolves API key, starts node
│   ├── test-search.mjs          # Standalone test (bypasses MCP transport)
│   ├── package.json             # Dependencies
│   ├── package-lock.json        # Lockfile
│   ├── .gitignore               # Ignores .env, node_modules, logs
│   ├── .env                     # API key (gitignored, create locally)
│   ├── lib/
│   │   ├── cache.mjs            # In-memory LRU cache with TTL
│   │   └── logger.mjs           # Structured JSON logger (stderr only)
│   └── providers/
│       ├── index.mjs            # Provider factory
│       ├── base-provider.mjs    # Abstract base class
│       └── gemini-provider.mjs  # Gemini + Google Search implementation
└── hooks/                       # Reference copies (runtime at ~/.claude/hooks/)
    ├── inject-web-search-hint.sh
    ├── restrict-bash-network.sh
    └── require-web-if-recency.sh
```

## Quick Start

1. Get a Gemini API key from [Google AI Studio](https://aistudio.google.com/apikey)

2. Configure the API key:
   ```bash
   # Option A: Environment variable
   export GEMINI_API_KEY="your-key"

   # Option B: GNOME Keyring (Linux)
   secret-tool store --label="MCP Gemini Web" service mcp-gemini-web account api-key

   # Option C: Local .env file
   echo 'GEMINI_API_KEY=your-key' > gemini-web-mcp/server/.env
   chmod 600 gemini-web-mcp/server/.env
   ```

3. Install dependencies:
   ```bash
   cd gemini-web-mcp/server
   npm install
   ```

4. Test standalone:
   ```bash
   node test-search.mjs "test query"
   ```

5. Register with Claude Code:
   ```bash
   claude mcp add -s user gemini-web -- ~/git/claude-orchestrator/gemini-web-mcp/server/start.sh
   ```

For detailed setup including hooks, see [SETUP.md](SETUP.md).

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `GEMINI_API_KEY` | (required) | Google Gemini API key |
| `GEMINI_MODEL` | `gemini-2.5-flash` | Gemini model to use |
| `LOG_LEVEL` | `info` | Logging verbosity (`debug`, `info`, `warn`, `error`) |
| `CACHE_ENABLED` | `true` | Set to `false` to disable caching |

## MCP Tool Interface

### `web_search`

Search the web and return grounded results with source URLs.

**Parameters:**
- `query` (string, required): Search query. Max 500 characters.
- `max_results` (integer, optional): Number of sources to return. 1-10, default 5.

**Returns:** Markdown text with a summary paragraph and source URLs, wrapped in untrust markers.

**Example response:**
```
--- BEGIN UNTRUSTED WEB CONTENT ---
The latest Node.js LTS release is version 22.14.0, released in February 2026...

Sources:
- Node.js Official Release Notes — https://nodejs.org/en/blog/release/v22.14.0
- Node.js Download Page — https://nodejs.org/en/download
--- END UNTRUSTED WEB CONTENT ---
```
