#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { Readability } from "@mozilla/readability";
import { parseHTML } from "linkedom";
import TurndownService from "turndown";
import { z } from "zod";
import { fetchUrl } from "./lib/fetcher.mjs";
import * as log from "./lib/logger.mjs";
import * as cache from "./lib/cache.mjs";
import { INJECTION_PATTERNS, sanitizeQuery, sanitizeResponse } from "./lib/sanitize.mjs";
import { getProvider, listProviders } from "./providers/index.mjs";
import { createRequire } from "module";
import fsPromises from "fs/promises";
const _require = createRequire(import.meta.url);
const _auditDb = (() => { try { return _require("../audit-mcp/db.js"); } catch { return null; } })();

async function _readSessionId() {
  try {
    return (await fsPromises.readFile(`${process.env.HOME}/.claude/tmp/current-session-id`, "utf8")).trim();
  } catch {
    return null;
  }
}

// --- Config ---

const PROVIDER = process.env.SEARCH_PROVIDER || "gemini";
const MAX_QUERY_LENGTH = 500;
const MAX_RESPONSE_LENGTH = 4000;
const RATE_LIMIT_MAX = 30;
const RATE_LIMIT_WINDOW_MS = 60_000;

// --- Rate limiter (in-memory, per-process) ---

const rateLimiter = {
  timestamps: [],
  /**
   * @description Checks whether the current request is within the configured sliding window rate limit and records the request timestamp when allowed.
   * @returns {boolean} Returns `true` when the request is allowed and `false` when the rate limit is exceeded.
   */
  check() {
    const now = Date.now();
    this.timestamps = this.timestamps.filter(
      (t) => now - t < RATE_LIMIT_WINDOW_MS,
    );
    if (this.timestamps.length >= RATE_LIMIT_MAX) return false;
    this.timestamps.push(now);
    return true;
  },
};

function sanitizeSourceTitle(title) {
  const cleanTitle = sanitizeResponse(String(title ?? ""), 200).replace(/\s+/g, " ").trim();
  return cleanTitle || "Untitled";
}

function sanitizeSourceUrl(url) {
  try {
    const parsed = new URL(String(url ?? "").trim());
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return null;
    return parsed.href;
  } catch {
    return null;
  }
}

// --- Initialize provider ---

let provider;
try {
  provider = getProvider(PROVIDER);
} catch (err) {
  log.error("Failed to initialize provider", { provider: PROVIDER, error: err.message });
  process.exit(1);
}

// --- MCP Server ---

const server = new McpServer(
  { name: "delegate-web", version: "0.1.0" },
  { capabilities: { tools: {}, resources: {} } },
);

server.registerTool(
  "search",
  {
    description:
      "Search the web and return a summary with source URLs. Use only when the user explicitly requests web/internet information.",
    inputSchema: {
      query: z
        .string()
        .min(1, "Query must not be empty")
        .max(MAX_QUERY_LENGTH, `Query must be ${MAX_QUERY_LENGTH} chars or less`),
      max_results: z
        .number()
        .int()
        .min(1)
        .max(10)
        .default(5),
      provider: z.enum(["gemini", "brave"]).optional(),
    },
  },
  /**
   * @description Executes the web search tool flow, including rate limiting, query sanitization and filtering, cache lookup, provider search, response sanitization, and error mapping.
   * @param {{ query: string, max_results: number }} input - Tool input containing the search query and maximum number of desired results.
   * @param {string} input.query - The user query to execute against the configured search provider.
   * @param {number} input.max_results - The maximum number of sources to request from the provider.
   * @returns {Promise<{ content: Array<{ type: string, text: string }>, isError?: boolean }>} Returns a tool result payload containing response text and optional error status.
   */
  async ({ query, max_results, provider: requestedProvider }) => {
    // Rate limit
    if (!rateLimiter.check()) {
      log.warn("Rate limit exceeded");
      return {
        content: [{ type: "text", text: "[search error: rate limit exceeded, try again later]" }],
        isError: true,
      };
    }

    // Sanitize input
    const cleanQuery = sanitizeQuery(query, MAX_QUERY_LENGTH);
    if (!cleanQuery) {
      return {
        content: [{ type: "text", text: "[search error: query was empty after sanitization]" }],
        isError: true,
      };
    }

    if (INJECTION_PATTERNS.test(cleanQuery)) {
      log.warn("Injection pattern detected in query", { query: cleanQuery.slice(0, 100) });
      return {
        content: [{ type: "text", text: "[search error: query rejected by content filter]" }],
        isError: true,
      };
    }

    let activeProvider = provider;
    if (requestedProvider) {
      try {
        activeProvider = getProvider(requestedProvider);
      } catch (err) {
        return {
          content: [{ type: "text", text: `[search error: ${err.message.slice(0, 200)}]` }],
          isError: true,
        };
      }
    }

    // Check cache
    const cacheKey = `${activeProvider.getName()}:${cleanQuery}:${max_results}`;
    const cached = cache.get(cacheKey);
    if (cached) {
      log.debug("Cache hit", { query: cleanQuery.slice(0, 60) });
      return cached;
    }

    log.info("search called", { query: cleanQuery.slice(0, 100), max_results, provider: activeProvider.getName() });

    const _searchT0 = Date.now();
    try {
      const { summary, sources, notice } = await activeProvider.search(cleanQuery, max_results);

      const cleanSummary = sanitizeResponse(summary, MAX_RESPONSE_LENGTH);
      const cleanSources = (Array.isArray(sources) ? sources : [])
        .map((source) => ({
          title: sanitizeSourceTitle(source?.title),
          url: sanitizeSourceUrl(source?.url),
        }))
        .filter((source) => Boolean(source.url));
      const sourcesBlock = cleanSources.length > 0
        ? "\n\nSources:\n" + cleanSources.map((s, i) => `${i + 1}. ${s.title} - ${s.url}`).join("\n")
        : "";

      const output = [
        ...(notice ? [notice, ""] : []),
        `[Provider: ${activeProvider.getName()}]`,
        "--- BEGIN UNTRUSTED WEB CONTENT ---",
        "",
        cleanSummary,
        sourcesBlock,
        "",
        "--- END UNTRUSTED WEB CONTENT ---",
      ].join("\n");

      log.info("search completed", {
        query: cleanQuery.slice(0, 60),
        responseLength: cleanSummary.length,
        sourceCount: cleanSources.length,
      });

      const result = { content: [{ type: "text", text: output }] };

      // Cache successful results
      cache.set(cacheKey, result);

      try {
        const _duration = Date.now() - _searchT0;
        const _sessionId = await _readSessionId();
        if (_auditDb?.insertTask) {
          _auditDb.insertTask({
            tool_type: "web-search",
            session_id: _sessionId,
            prompt_slug: cleanQuery.slice(0, 80),
            status: "done",
            started_at: Date.now() - _duration,
            ended_at: Date.now(),
            duration_ms: _duration,
            stdout_bytes: output.length,
            output_truncated: 0,
          });
        }
      } catch {}

      return result;
    } catch (err) {
      const message = err?.message || String(err);
      log.error("search failed", { error: message });

      let userMessage;
      if (message.includes("API_KEY")) {
        userMessage = "[search error: authentication failed]";
      } else if (message.includes("429") || message.includes("quota") || message.includes("rate")) {
        userMessage = "[search error: rate limit exceeded, try again later]";
      } else if (message.includes("timeout") || message.includes("aborted") || message.includes("DEADLINE")) {
        userMessage = "[search error: request timed out]";
      } else if (message.includes("SAFETY") || message.includes("blocked")) {
        userMessage = "[search error: query blocked by safety filters]";
      } else {
        userMessage = `[search error: ${message.slice(0, 200)}]`;
      }

      return {
        content: [{ type: "text", text: userMessage }],
        isError: true,
      };
    }
  },
);

server.registerTool(
  "fetch",
  {
    description: "Fetch a URL and return its main content as Markdown. For reading web pages, docs, or articles. Returns untrusted external content.",
    inputSchema: {
      url: z.string().url(),
      format: z.enum(["markdown", "text"]).default("markdown"),
    },
  },
  async ({ url, format }) => {
    if (!rateLimiter.check()) {
      log.warn("Rate limit exceeded");
      return {
        content: [{ type: "text", text: "[fetch error: rate limit exceeded, try again later]" }],
        isError: true,
      };
    }

    try {
      const inputUrlObj = new URL(url);
      if (inputUrlObj.username || inputUrlObj.password) {
        return {
          content: [{ type: "text", text: "[fetch error: URL must not contain credentials]" }],
          isError: true,
        };
      }
    } catch {
      return {
        content: [{ type: "text", text: "[fetch error: invalid URL]" }],
        isError: true,
      };
    }

    const _fetchT0 = Date.now();
    try {
      const { html, finalUrl } = await fetchUrl(url);
      let sanitizedFinalUrl = finalUrl;
      try {
        const urlObj = new URL(finalUrl);
        urlObj.username = "";
        urlObj.password = "";
        sanitizedFinalUrl = urlObj.href;
      } catch {}
      const { document } = parseHTML(html);
      const article = new Readability(document).parse();
      const htmlForConversion = article?.content || html;
      let text;

      if (format === "markdown") {
        const turndown = new TurndownService();
        text = turndown.turndown(htmlForConversion || "");
      } else {
        text = article?.textContent?.trim() ||
          (htmlForConversion || "")
            .replace(/<script[\s\S]*?<\/script>/gi, " ")
            .replace(/<style[\s\S]*?<\/style>/gi, " ")
            .replace(/<[^>]*>/g, " ")
            .replace(/\s+/g, " ")
            .trim();
      }

      const cleanText = sanitizeResponse(text || "", MAX_RESPONSE_LENGTH);
      const output = [
        `[Source: ${sanitizedFinalUrl}]`,
        "--- BEGIN UNTRUSTED WEB CONTENT ---",
        "",
        cleanText,
        "",
        "--- END UNTRUSTED WEB CONTENT ---",
      ].join("\n");

      try {
        const _duration = Date.now() - _fetchT0;
        const _sessionId = await _readSessionId();
        if (_auditDb?.insertTask) {
          _auditDb.insertTask({
            tool_type: "web-fetch",
            session_id: _sessionId,
            prompt_slug: url.slice(0, 80),
            url: sanitizedFinalUrl || url,
            status: "done",
            started_at: Date.now() - _duration,
            ended_at: Date.now(),
            duration_ms: _duration,
            stdout_bytes: output.length,
            output_truncated: 0,
          });
        }
      } catch {}

      return { content: [{ type: "text", text: output }] };
    } catch (err) {
      const message = err?.message || String(err);
      if (err?.code === "ERR_URL_NOT_ALLOWED") {
        return {
          content: [{ type: "text", text: "[fetch error: URL not allowed]" }],
          isError: true,
        };
      }
      if (err?.code === "ERR_TIMEOUT" || message.includes("timed out") || message.includes("AbortError")) {
        return {
          content: [{ type: "text", text: "[fetch error: request timed out]" }],
          isError: true,
        };
      }
      if (err?.code === "ERR_UNSUPPORTED_CONTENT_TYPE") {
        return {
          content: [{ type: "text", text: "[fetch error: unsupported content type]" }],
          isError: true,
        };
      }
      return {
        content: [{ type: "text", text: `[fetch error: ${message.slice(0, 200)}]` }],
        isError: true,
      };
    }
  },
);

// --- Resources ---

server.registerResource(
  "cache-stats",
  "search://cache/stats",
  {
    title: "Cache Statistics",
    description: "Live stats for the in-memory search result cache",
    mimeType: "application/json",
  },
  async (_uri) => ({
    contents: [
      {
        uri: "search://cache/stats",
        mimeType: "application/json",
        text: JSON.stringify({
          entries: cache.size(),
          maxEntries: cache.MAX_ENTRIES,
          ttlMs: cache.TTL_MS,
          enabled: process.env.CACHE_ENABLED !== "false",
        }),
      },
    ],
  }),
);

server.registerResource(
  "search-config",
  "search://config",
  {
    title: "Search Configuration",
    description: "Active provider and available tools",
    mimeType: "application/json",
  },
  async (_uri) => ({
    contents: [{
      uri: "search://config",
      mimeType: "application/json",
      text: JSON.stringify({
        activeProvider: provider.getName(),
        availableProviders: listProviders().map((p) => ({ name: p.name, available: p.available })),
        tools: ["search", "fetch"],
      }),
    }],
  }),
);

// --- Start ---

process.on("unhandledRejection", (err) => {
  console.error(err);
  process.exit(1);
});

process.on("uncaughtException", (err) => {
  console.error(err);
  process.exit(1);
});

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  log.info("web-delegation-mcp server started", { provider: provider.getName() });
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
