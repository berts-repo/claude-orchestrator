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
| `security--restrict-bash-network.sh` | Hook | Blocks curl/wget, forces web access through MCP |
| `gemini--inject-web-search-hint.sh` | Hook | Detects web intent, injects "use web_search" context |
| `gemini--require-web-if-recency.sh` | Hook | Blocks recency claims without source URLs |
| `codex--enforce-code-write.sh` | Hook | Blocks direct large code file creation; enforces Codex delegation |

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
../hooks/                        # All hooks consolidated (runtime at ~/.claude/hooks/)
    ├── gemini--inject-web-search-hint.sh
    ├── codex--enforce-code-write.sh
    ├── security--restrict-bash-network.sh
    └── gemini--require-web-if-recency.sh
```

---

## Prerequisites

- **Linux or macOS**
- **Claude Code** — installed and working
- **Node.js** — v20+
- **jq** — used by hook scripts to parse JSON (`sudo pacman -S jq` on Arch, `brew install jq` on macOS)
- **A Google Gemini API key** — free tier works

---

## Setup

### Step 1 — Get a Gemini API Key

1. Go to [Google AI Studio](https://aistudio.google.com/apikey)
2. Sign in with a Google account
3. Click **Create API Key**
4. Copy the key — you will need it in Step 3

The free tier allows 15 requests/minute for `gemini-2.5-flash`, which is more than enough.

### Step 2 — Install Dependencies

```bash
cd ~/git/claude-orchestrator/gemini-web-mcp/server
npm install
```

This installs three packages:
- `@modelcontextprotocol/sdk` — MCP protocol over stdio
- `@google/generative-ai` — Google Gemini API client
- `zod` — runtime input validation

Make the launcher executable:

```bash
chmod +x start.sh
```

### Step 3 — Configure the API Key

Pick one of these methods (checked in this order by `start.sh`):

**Option A: Environment variable (simplest)**

```bash
export GEMINI_API_KEY="your-key-here"
```

Add to your `~/.zshrc` (or `~/.bashrc`) to persist.

**Option B: macOS Keychain**

```bash
security add-generic-password -a "mcp-gemini-web" -s "mcp-gemini-web" -w "your-key-here"
```

> **Linux alternative:** Use GNOME Keyring with `secret-tool store --label="MCP Gemini Web" service mcp-gemini-web account api-key`.

**Option C: Local .env file (dev convenience)**

```bash
echo 'GEMINI_API_KEY=your-key-here' > ~/git/claude-orchestrator/gemini-web-mcp/server/.env
chmod 600 ~/git/claude-orchestrator/gemini-web-mcp/server/.env
```

### Step 4 — Test Standalone

This test calls the Gemini API directly, bypassing MCP transport, to confirm your key and network work:

```bash
cd ~/git/claude-orchestrator/gemini-web-mcp/server
GEMINI_API_KEY="your-key" node test-search.mjs "latest Node.js release"
```

Expected output:

```
Testing Gemini web search grounding
  Model: gemini-2.5-flash
  Query: latest Node.js release

--- Response ---
(a paragraph summarizing search results)

--- Grounding Sources ---
  Title — https://...
  Title — https://...

PASS
```

If you see `PASS`, the Gemini integration works. If it fails, check your API key and network.

### Step 5 — Register with Claude Code

**Option A: CLI (recommended)**

```bash
claude mcp add -s user gemini-web -- ~/git/claude-orchestrator/gemini-web-mcp/server/start.sh
```

**Option B: Manual config**

Add to `~/.claude.json`:

```json
{
  "mcpServers": {
    "gemini-web": {
      "command": "/home/YOUR_USER/.local/share/mcp/gemini-web/start.sh"
    }
  }
}
```

Replace `YOUR_USER` with your actual username.

Verify registration:

```bash
claude mcp list
# gemini-web: ... - ✓ Connected
```

### Step 6 — Install Hooks

Hook registration is managed via frontmatter headers in each `hooks/*.sh` file (`# HOOK_EVENT:`, `# HOOK_TIMEOUT:`, optional `# HOOK_MATCHER:`). From the repo root, run:

```bash
bash scripts/sync-hooks.sh
```

This updates both `~/.claude/hooks/` symlinks and `~/.claude/settings.json` wiring. Never manually edit `~/.claude/settings.json` for hook wiring.

### Step 7 — Verify End-to-End

Open a new Claude Code session:

```bash
cd ~/git/claude-orchestrator
claude
```

Type:

```
Search the web for the latest news about AI
```

What should happen:
1. The `gemini--inject-web-search-hint.sh` hook detects "search the web" and injects context
2. Claude calls the `web_search` MCP tool
3. The MCP server queries Gemini with Google Search grounding
4. Claude receives the results wrapped in `--- BEGIN/END UNTRUSTED WEB CONTENT ---` markers
5. Claude synthesizes an answer and cites sources with URLs
6. The `gemini--require-web-if-recency.sh` stop hook confirms sources are present

---

## How the Code Works

### MCP Server (`server.mjs`)

The server uses the Model Context Protocol over **stdio** (standard input/output). There are no ports or HTTP — Claude Code launches the server as a child process and communicates via JSON-RPC messages over stdin/stdout.

The server registers one tool, `web_search`, which:

1. **Rate limits** — 30 requests per 60 seconds (in-memory counter)
2. **Sanitizes the query** — strips control characters, HTML tags, collapses whitespace, caps at 500 characters
3. **Rejects injection attempts** — regex catches phrases like "ignore previous instructions", "sudo", "bash -c"
4. **Checks the cache** — normalized key lookup, 5-minute TTL, 100 entries max
5. **Calls the Gemini provider** — sends the query with Google Search grounding enabled
6. **Sanitizes the response** — strips `<script>` tags, HTML, and injection headers like "IMPORTANT SYSTEM NOTE"
7. **Wraps output** — surrounds result with `--- BEGIN/END UNTRUSTED WEB CONTENT ---` markers
8. **Caches the result** — errors are never cached

### Launcher (`start.sh`)

Resolves the API key from three sources (in order):
1. `GEMINI_API_KEY` environment variable
2. macOS Keychain / GNOME Keyring via `secret-tool`
3. Local `.env` file

Then starts the server with `exec node server.mjs`.

### Gemini Provider (`providers/gemini-provider.mjs`)

Calls the Gemini API (`gemini-2.5-flash` by default) with the `google_search` tool enabled. This makes Gemini perform a real Google Search, ground its response in the results, and return structured metadata with source URLs.

The prompt asks for:
- A 1-paragraph factual summary
- Up to N sources with titles and URLs
- Only claims supported by sources

Source URLs come from `response.candidates[0].groundingMetadata.groundingChunks`, not from the text itself.

### Provider Pattern (`providers/`)

The server uses a provider factory pattern:
- `base-provider.mjs` — abstract class defining the `search(query, maxResults)` interface
- `gemini-provider.mjs` — working implementation
- `index.mjs` — factory function, selects provider by name

To add a new provider, create a class extending `BaseProvider`, implement `isAvailable()` and `search()`, and register it in `index.mjs`.

### Cache (`lib/cache.mjs`)

In-memory LRU cache using a `Map` (which preserves insertion order). Features:
- **Normalized keys** — queries are lowercased and whitespace-collapsed before lookup
- **TTL expiry** — entries older than 5 minutes are evicted
- **LRU eviction** — when full (100 entries), the oldest entry is removed
- **Error exclusion** — error responses are never cached
- Disable with `CACHE_ENABLED=false`

### Logger (`lib/logger.mjs`)

Structured JSON logger that writes to **stderr only** (stdout is reserved for MCP protocol). Log level is set via the `LOG_LEVEL` environment variable (`debug`, `info`, `warn`, `error`). Default is `info`.

---

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

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `GEMINI_API_KEY` | (required) | Google Gemini API key |
| `GEMINI_MODEL` | `gemini-2.5-flash` | Gemini model to use |
| `LOG_LEVEL` | `info` | Logging verbosity (`debug`, `info`, `warn`, `error`) |
| `CACHE_ENABLED` | `true` | Set to `false` to disable caching |

---

## Troubleshooting

### "No API key found" on server start

The launcher checks three sources in order. Make sure at least one is set:
```bash
# Check environment
echo $GEMINI_API_KEY

# Check macOS Keychain
security find-generic-password -a "mcp-gemini-web" -s "mcp-gemini-web" -w

# Check .env file
cat ~/git/claude-orchestrator/gemini-web-mcp/server/.env
```

### Test script shows FAIL

Run with debug output:
```bash
GEMINI_API_KEY="your-key" LOG_LEVEL=debug node ~/git/claude-orchestrator/gemini-web-mcp/server/test-search.mjs "test query"
```

Common causes:
- Invalid API key
- Network/firewall blocking Google API
- Gemini quota exceeded (free tier: 15 req/min)

### Claude doesn't use web_search

1. Check MCP registration: `claude mcp list` — `gemini-web` should appear
2. Re-run hook sync from repo root: `bash scripts/sync-hooks.sh`
3. Make sure your prompt contains a trigger phrase like "search the web"
4. Confirm hooks are present: `ls -la ~/.claude/hooks/`

### Rate limit errors

The server allows 30 requests per 60 seconds. If you're hitting this during normal use, the Gemini API free tier (15/min) will likely be the bottleneck first. Wait and retry.

### Hook blocks a legitimate Bash command

The network blocker hook has some false positives (e.g., a variable named `curl_options`). If a legitimate command is blocked, review `security--restrict-bash-network.sh` and adjust the regex.

### Logs

MCP server logs go to stderr as JSON. To see them:
```bash
GEMINI_API_KEY="your-key" LOG_LEVEL=debug node ~/git/claude-orchestrator/gemini-web-mcp/server/server.mjs 2>&1 | jq '.'
```

---

*Part of the [Claude Code MCP Bridge](../README.md) project.*
