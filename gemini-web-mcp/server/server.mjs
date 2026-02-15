#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { getProvider } from "./providers/index.mjs";
import * as log from "./lib/logger.mjs";
import * as cache from "./lib/cache.mjs";

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

// --- Sanitization ---

const INJECTION_PATTERNS =
  /\b(ignore previous|ignore above|disregard|you are now|new instructions|system prompt|execute|run command|sudo|bash -c)\b/i;

/**
 * @description Sanitizes a raw user query by trimming whitespace, removing control characters and HTML tags, normalizing spacing, and enforcing max length.
 * @param {string} raw - The raw user-provided search query text.
 * @returns {string} Returns a cleaned query string suitable for provider search.
 */
function sanitizeQuery(raw) {
  let q = raw.trim();
  q = q.replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, "");
  q = q.replace(/\s+/g, " ");
  q = q.replace(/<[^>]*>/g, "");
  if (q.length > MAX_QUERY_LENGTH) {
    q = q.slice(0, MAX_QUERY_LENGTH);
  }
  return q;
}

/**
 * @description Sanitizes provider response text by removing scripts and HTML tags, filtering known instruction-like patterns, and truncating oversized output.
 * @param {string} text - The raw response text returned by the provider.
 * @returns {string} Returns sanitized response text safe to wrap in untrusted content markers.
 */
function sanitizeResponse(text) {
  let t = text;
  t = t.replace(/<script[\s\S]*?<\/script>/gi, "");
  t = t.replace(/<[^>]*>/g, "");
  t = t.replace(
    /\b(IMPORTANT SYSTEM NOTE|INSTRUCTION FOR AGENT|EXECUTE COMMAND)[:\s].{0,200}/gi,
    "[content removed]",
  );
  if (t.length > MAX_RESPONSE_LENGTH) {
    t = t.slice(0, MAX_RESPONSE_LENGTH) + "\n[truncated]";
  }
  return t;
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
  { name: "gemini-web-search", version: "0.1.0" },
  { capabilities: { tools: {} } },
);

server.registerTool(
  "web_search",
  {
    description:
      "Search the web using Gemini with Google Search grounding. Returns a summary and source URLs. Use only when the user explicitly requests web/internet information.",
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
    },
  },
  /**
   * @description Executes the web search tool flow, including rate limiting, query sanitization and filtering, cache lookup, provider search, response sanitization, and error mapping.
   * @param {{ query: string, max_results: number }} input - Tool input containing the search query and maximum number of desired results.
   * @param {string} input.query - The user query to execute against the configured search provider.
   * @param {number} input.max_results - The maximum number of sources to request from the provider.
   * @returns {Promise<{ content: Array<{ type: string, text: string }>, isError?: boolean }>} Returns a tool result payload containing response text and optional error status.
   */
  async ({ query, max_results }) => {
    // Rate limit
    if (!rateLimiter.check()) {
      log.warn("Rate limit exceeded");
      return {
        content: [{ type: "text", text: "[web_search error: rate limit exceeded, try again later]" }],
        isError: true,
      };
    }

    // Sanitize input
    const cleanQuery = sanitizeQuery(query);
    if (!cleanQuery) {
      return {
        content: [{ type: "text", text: "[web_search error: query was empty after sanitization]" }],
        isError: true,
      };
    }

    if (INJECTION_PATTERNS.test(cleanQuery)) {
      log.warn("Injection pattern detected in query", { query: cleanQuery.slice(0, 100) });
      return {
        content: [{ type: "text", text: "[web_search error: query rejected by content filter]" }],
        isError: true,
      };
    }

    // Check cache
    const cached = cache.get(cleanQuery);
    if (cached) {
      log.debug("Cache hit", { query: cleanQuery.slice(0, 60) });
      return cached;
    }

    log.info("web_search called", { query: cleanQuery.slice(0, 100), max_results, provider: provider.getName() });

    try {
      const { summary, sources } = await provider.search(cleanQuery, max_results);

      const cleanSummary = sanitizeResponse(summary);
      const sourcesBlock = sources.length > 0
        ? "\n\nSources:\n" + sources.map((s, i) => `${i + 1}. ${s.title} - ${s.url}`).join("\n")
        : "";

      const output = [
        "--- BEGIN UNTRUSTED WEB CONTENT ---",
        "",
        cleanSummary,
        sourcesBlock,
        "",
        "--- END UNTRUSTED WEB CONTENT ---",
      ].join("\n");

      log.info("web_search completed", {
        query: cleanQuery.slice(0, 60),
        responseLength: cleanSummary.length,
        sourceCount: sources.length,
      });

      const result = { content: [{ type: "text", text: output }] };

      // Cache successful results
      cache.set(cleanQuery, result);

      return result;
    } catch (err) {
      const message = err?.message || String(err);
      log.error("web_search failed", { error: message });

      let userMessage;
      if (message.includes("API_KEY")) {
        userMessage = "[web_search error: authentication failed]";
      } else if (message.includes("429") || message.includes("quota") || message.includes("rate")) {
        userMessage = "[web_search error: Gemini rate limit, try again later]";
      } else if (message.includes("timeout") || message.includes("aborted") || message.includes("DEADLINE")) {
        userMessage = "[web_search error: request timed out]";
      } else if (message.includes("SAFETY") || message.includes("blocked")) {
        userMessage = "[web_search error: query blocked by Gemini safety filters]";
      } else {
        userMessage = `[web_search error: ${message.slice(0, 200)}]`;
      }

      return {
        content: [{ type: "text", text: userMessage }],
        isError: true,
      };
    }
  },
);

// --- Start ---

const transport = new StdioServerTransport();
await server.connect(transport);
log.info("gemini-web-search server started", { provider: provider.getName() });
