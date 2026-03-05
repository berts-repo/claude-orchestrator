# Web Search MCP Server

MCP server (registered as `delegate-web`) exposing `search` and `fetch` tools. Default search provider: Gemini API with Google Search grounding.

## Overview

This server provides Claude Code with internet access through a controlled, auditable channel. When users explicitly request web searches ("search the web for...", "do research on..."), Claude calls this MCP tool instead of using curl/wget directly.

Key features:
- **Two tools** — `search` (Gemini-grounded search) and `fetch` (URL fetch + Readability extraction)
- **Pluggable providers** — swap search backends via `SEARCH_PROVIDER` env var (default: `gemini`)
- **Google Search grounding** — Gemini performs actual Google searches and grounds responses in results
- **Source attribution** — Every search response includes source URLs for citation
- **SSRF protection** — `fetch` blocks localhost, private IPs, link-local, and metadata endpoints
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
               │  MCP Server      │  web-search-mcp/
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
Name mapping note: register this MCP server as `delegate-web`; in hook/tool matcher names it is exposed under `delegate_web` (`mcp__delegate_web__*`).

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
| Output sanitization | Server | Strips `<script>`, HTML tags, fake system prompts, ANSI escapes, C0/C1 control chars, Unicode bidi overrides |
| Untrust markers | Server | Wraps all web content with clear markers |
| Rate limiting | Server | 30 req/min prevents abuse |
| `security--restrict-bash-network.sh` | Hook | Blocks curl/wget, forces web access through MCP |
| `gemini--inject-web-search-hint.sh` | Hook | Detects web intent, injects "use search" context |
| `gemini--preempt-recency-queries.sh` | Hook | Detects time-sensitive prompts and injects a search hint before inference |

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
web-search-mcp/
├── README.md                    # This file
├── server.mjs                   # Main server — registers search and fetch tools
├── start.sh                     # Launcher — resolves API key, starts node
├── test-security.mjs            # Unit tests for SSRF and sanitization fixes
├── package.json                 # Dependencies
├── package-lock.json            # Lockfile
├── lib/
│   ├── cache.mjs                # In-memory LRU cache with TTL
│   ├── fetcher.mjs              # SSRF-safe HTTP fetcher for fetch
│   ├── sanitize.mjs             # Input/output sanitization and injection detection
│   └── logger.mjs               # Structured JSON logger (stderr only)
└── providers/
    ├── index.mjs                # Provider factory
    ├── base-provider.mjs        # Abstract base class
    ├── gemini-provider.mjs      # Gemini + Google Search implementation
    └── brave-provider.mjs       # Brave Search API implementation
../hooks/                        # All hooks consolidated (runtime at ~/.claude/hooks/)
    ├── gemini--inject-web-search-hint.sh
    ├── security--restrict-bash-network.sh
    └── gemini--preempt-recency-queries.sh
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
cd ~/git/claude-orchestrator/web-search-mcp
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

Pick one of these methods (`start.sh` checks them in this order):

**Option A: Environment variable (simplest)**

```bash
export GEMINI_API_KEY="your-key-here"
```

Add to your `~/.zshrc` (or `~/.bashrc`) to persist.

**Option B: GNOME Keyring (Linux only)**

```bash
secret-tool store --label="MCP Gemini Web" service mcp-delegate-web account api-key
```

Then enter your key when prompted. `start.sh` calls `secret-tool lookup` to retrieve it if `GEMINI_API_KEY` is not already set.

> **macOS note:** macOS Keychain (`security`) is not supported by `start.sh`. Use Option A or C on macOS.

**Option C: Local .env file (dev convenience)**

```bash
echo 'GEMINI_API_KEY=your-key-here' > ~/git/claude-orchestrator/web-search-mcp/.env
chmod 600 ~/git/claude-orchestrator/web-search-mcp/.env
```

> **Note:** `.env` is loaded after the env var and keyring checks. Variables already set in the environment take precedence.

### Step 4 — Register with Claude Code

**Option A: CLI (recommended)**

```bash
claude mcp add -s user delegate-web -- ~/git/claude-orchestrator/web-search-mcp/start.sh
```

**Option B: Manual config**

Add to `~/.claude.json`:

```json
{
  "mcpServers": {
    "delegate-web": {
      "command": "/home/YOUR_USER/git/claude-orchestrator/web-search-mcp/start.sh"
    }
  }
}
```

Replace `YOUR_USER` with your actual username.

Verify registration:

```bash
claude mcp list
# delegate-web: ... - ✓ Connected
```

### Step 5 — Install Hooks

Hook registration is managed via frontmatter headers in each `hooks/*.sh` file (`# HOOK_EVENT:`, `# HOOK_TIMEOUT:`, optional `# HOOK_MATCHER:`). From the repo root, run:

```bash
bash scripts/sync-hooks.sh
```

This updates both `~/.claude/hooks/` symlinks and `~/.claude/settings.json` wiring. Never manually edit `~/.claude/settings.json` for hook wiring.

### Step 6 — Verify End-to-End

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
2. Claude calls the `search` MCP tool
3. The MCP server queries Gemini with Google Search grounding
4. Claude receives the results wrapped in `--- BEGIN/END UNTRUSTED WEB CONTENT ---` markers
5. Claude synthesizes an answer and cites sources with URLs
6. For time-sensitive prompts, `gemini--preempt-recency-queries.sh` injects a pre-inference search hint

---

## How the Code Works

### MCP Server (`server.mjs`)

The server uses the Model Context Protocol over **stdio** (standard input/output). There are no ports or HTTP — Claude Code launches the server as a child process and communicates via JSON-RPC messages over stdin/stdout.

The server registers two tools (`search`, `fetch`) and two resources (`search://cache/stats`, `search://config`), described below.

1. **Rate limits** — 30 requests per 60 seconds (in-memory counter)
2. **Sanitizes the query** — strips control characters, HTML tags, collapses whitespace, caps at 500 characters
3. **Rejects injection attempts** — regex catches phrases like "ignore previous instructions", "sudo", "bash -c"
4. **Checks the cache** — normalized key lookup, 5-minute TTL, 100 entries max
5. **Calls the provider** — sends the query to the configured search provider
6. **Sanitizes the response** — strips `<script>` tags, HTML, and injection headers like "IMPORTANT SYSTEM NOTE"
7. **Wraps output** — surrounds result with `--- BEGIN/END UNTRUSTED WEB CONTENT ---` markers
8. **Caches the result** — errors are never cached

### Launcher (`start.sh`)

Resolves the API key in this order:
1. `GEMINI_API_KEY` environment variable (if already set, used as-is)
2. GNOME Keyring via `secret-tool lookup` (Linux only; skipped if `secret-tool` is not installed)
3. Local `.env` file (loaded last; may set `GEMINI_API_KEY` if still unset)

Then starts the server with `exec node server.mjs`.

### Provider Pattern (`providers/`)

The server uses a provider factory pattern to decouple the MCP interface from the search backend:
- `base-provider.mjs` — abstract class defining the `search(query, maxResults)` interface
- `gemini-provider.mjs` — working implementation using Gemini + Google Search grounding
- `index.mjs` — factory function, selects provider by `SEARCH_PROVIDER` env var (default: `gemini`)

To add a new provider, create a class extending `BaseProvider`, implement `isAvailable()` and `search()`, and register it in `index.mjs`.

### Gemini Provider (`providers/gemini-provider.mjs`)

Calls the Gemini API (`gemini-2.5-flash` by default) with the `google_search` tool enabled. This makes Gemini perform a real Google Search, ground its response in the results, and return structured metadata with source URLs.

The prompt asks for:
- A 1-paragraph factual summary
- Up to N sources with titles and URLs
- Only claims supported by sources

Source URLs come from `response.candidates[0].groundingMetadata.groundingChunks`, not from the text itself.

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

### `search`

Search the web and return grounded results with source URLs.

**Parameters:**
- `query` (string, required): Search query. Max 500 characters.
- `max_results` (integer, optional): Number of sources to return. 1-10, default 5.
- `provider` (`"gemini"` | `"brave"`, optional): Override the active search provider for this call. Defaults to the provider set by `SEARCH_PROVIDER` env var (default: `gemini`).

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

### `fetch`

Fetch a URL and return its main content as Markdown or plain text. Uses Mozilla Readability to extract the article body and strips navigation, ads, and boilerplate.

**Parameters:**
- `url` (string, required): The URL to fetch. Must be `http://` or `https://`. Private IPs, localhost, and metadata endpoints are blocked.
- `format` (`"markdown"` | `"text"`, optional): Output format. Default `"markdown"`.

**Returns:** Extracted page content wrapped in untrust markers, with the final URL noted (after redirects).

**Example response:**
```
[Source: https://nodejs.org/en/about]
--- BEGIN UNTRUSTED WEB CONTENT ---
As an asynchronous event-driven JavaScript runtime, Node.js is designed to build
scalable network applications...
--- END UNTRUSTED WEB CONTENT ---
```

**SSRF protections in `lib/fetcher.mjs`:**
- Blocks `localhost` (including trailing-dot form `localhost.`), `127.0.0.1`, `::1`
- Blocks private IPv4 ranges (10.x, 172.16–31.x, 192.168.x, 169.254.x)
- Blocks IPv4-mapped IPv6 addresses in both dotted (`::ffff:127.0.0.1`) and hex (`::ffff:7f00:1`) forms
- Blocks `.local` / `.internal` domains
- Blocks the AWS/GCP metadata endpoint (`169.254.169.254`)
- Blocks private IPv6 ranges (`fc00::/7` ULA, `fe80::/10` link-local)
- Pre-resolves hostnames via `dns.promises.lookup()` and rejects results that resolve to private/loopback IPs
- Follows redirects manually (`redirect: "manual"`) — validates each `Location` hop before following; caps at 10 redirects
- Enforces 5 MB response size limit and 10-second timeout
- Only accepts `text/html` and `text/plain` content types

## MCP Resources

MCP has three kinds of things a server can expose:

- **Tools** — actions a client *calls* (like a function). Your `search` is a tool.
- **Prompts** — templates a client can *retrieve and inject* into a conversation.
- **Resources** — data a client can *read* at a URI, like fetching a URL.

Resources are addressable, read-only data. Instead of calling a tool with arguments, a client requests a URI and your server returns the content at that address. The client discovers available resources via `resources/list` and reads one via `resources/read`.

### `search://cache/stats`

Returns a live JSON snapshot of the in-memory search cache.

**Request:** `resources/read` with `uri: "search://cache/stats"`

**Response (`application/json`):**
```json
{
  "entries": 12,
  "maxEntries": 100,
  "ttlMs": 300000,
  "enabled": true
}
```

| Field | Description |
|-------|-------------|
| `entries` | Number of cached queries currently stored (expired entries are evicted before this is computed) |
| `maxEntries` | Capacity limit — oldest entry is dropped when exceeded |
| `ttlMs` | Time-to-live in milliseconds (300 000 = 5 minutes) |
| `enabled` | `false` if the `CACHE_ENABLED=false` env var is set |

**Usage from Claude Code:**

```
Read the resource search://cache/stats
```

Claude Code will issue a `resources/read` call and show you the current cache state. Useful for checking whether a query is likely cached before making a real API call, or for debugging unexpected misses.

**Usage via MCP Inspector:**

```bash
cd web-search-mcp
npx @modelcontextprotocol/inspector node server.mjs
```

Open the inspector UI and go to the **Resources** tab. You will see `Cache Statistics` listed. Clicking it fetches the live JSON.

### `search://config`

Returns the active server configuration: the current provider name and all available providers.

**Request:** `resources/read` with `uri: "search://config"`

**Response (`application/json`):**
```json
{
  "activeProvider": "gemini",
  "availableProviders": ["gemini", "brave"]
}
```

| Field | Description |
|-------|-------------|
| `activeProvider` | The provider currently in use (set by `SEARCH_PROVIDER` env var) |
| `availableProviders` | All providers registered in `providers/index.mjs` |

---

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `GEMINI_API_KEY` | (required for gemini) | Google Gemini API key |
| `BRAVE_API_KEY` | (required for brave) | Brave Search API key |
| `GEMINI_MODEL` | `gemini-2.5-flash` | Gemini model to use |
| `SEARCH_PROVIDER` | `gemini` | Provider to use (`gemini` or `brave`) |
| `LOG_LEVEL` | `info` | Logging verbosity (`debug`, `info`, `warn`, `error`) |
| `CACHE_ENABLED` | `true` | Set to `false` to disable caching |

---

## Troubleshooting

### "No API key found" on server start

The launcher checks three sources in order. Make sure at least one is set:
```bash
# Check environment variable
echo $GEMINI_API_KEY

# Check GNOME Keyring (Linux only)
secret-tool lookup service mcp-delegate-web account api-key

# Check .env file
cat ~/git/claude-orchestrator/web-search-mcp/.env
```

### Claude doesn't use search

1. Check MCP registration: `claude mcp list` — `delegate-web` should appear
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
GEMINI_API_KEY="your-key" LOG_LEVEL=debug node ~/git/claude-orchestrator/web-search-mcp/server.mjs 2>&1 | jq '.'
```

---

*Part of the [Claude Code MCP Bridge](../README.md) project.*
