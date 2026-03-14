#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import fs from "fs";
import { db, DB_PATH } from "./db.js";

const server = new McpServer({ name: "audit", version: "1.0.0" });

// --- get_tasks ---

server.tool(
  "get_tasks",
  "List recent audit tasks from the DB. Filter by tool_type, keyword, project, or cwd.",
  {
    limit: z.number().int().min(1).max(500).default(50),
    tool_type: z.string().optional(),
    keyword: z.string().optional(),
    project: z.string().optional(),
    cwd: z.string().optional(),
  },
  async ({ limit, tool_type, keyword, project, cwd }) => {
    if (!db) return { content: [{ type: "text", text: "DB not available" }] };
    const where = [];
    const params = [];
    if (tool_type) { where.push("tool_type = ?"); params.push(tool_type); }
    if (keyword)   { where.push("prompt_slug LIKE ?"); params.push(`%${keyword}%`); }
    if (project)   { where.push("project = ?"); params.push(project); }
    if (cwd)       { where.push("cwd = ?"); params.push(cwd); }
    const clause = where.length ? `WHERE ${where.join(" AND ")}` : "";
    const rows = db.prepare(
      `SELECT invocation_id, tool_type, project, cwd, prompt_slug, sandbox, approval,
              status, failure_reason, duration_ms, started_at, stdout_bytes, response_token_est, prompt_tokens_est
       FROM tasks ${clause} ORDER BY started_at DESC LIMIT ?`
    ).all(...params, limit);
    return { content: [{ type: "text", text: JSON.stringify(rows, null, 2) }] };
  }
);

// --- get_report ---

server.tool(
  "get_report",
  "Pre-built analytics report: usage breakdown, project failure rates, slowest batches, running tasks.",
  {
    days: z.number().int().min(1).max(365).default(7),
  },
  async ({ days }) => {
    if (!db) return { content: [{ type: "text", text: "DB not available" }] };
    const usage = db.prepare(
      `SELECT tool_type, sandbox, status, COUNT(*) as count,
              AVG(duration_ms) as avg_ms, MAX(duration_ms) as max_ms, SUM(response_token_est) as token_sum
       FROM tasks WHERE started_at > (CAST(strftime('%s','now') AS INTEGER) * 1000 - ? * 86400000)
       GROUP BY tool_type, sandbox, status`
    ).all(days);
    const failures = db.prepare(
      `SELECT project, COUNT(*) as total,
              SUM(CASE WHEN status='failed' THEN 1 ELSE 0 END) as failed
       FROM tasks WHERE started_at > (CAST(strftime('%s','now') AS INTEGER) * 1000 - 30 * 86400000)
       GROUP BY project ORDER BY failed DESC LIMIT 20`
    ).all();
    const slowest_batches = db.prepare(
      `SELECT batch_id, COUNT(*) as task_count, MAX(duration_ms) as wall_ms
       FROM tasks GROUP BY batch_id ORDER BY wall_ms DESC LIMIT 5`
    ).all();
    const running = db.prepare(
      `SELECT project, prompt_slug, started_at FROM tasks WHERE status='running' ORDER BY started_at`
    ).all();
    const report = { usage, failures, slowest_batches, running };
    return { content: [{ type: "text", text: JSON.stringify(report, null, 2) }] };
  }
);

// --- get_status ---

server.tool(
  "get_status",
  "DB health: config values, row counts per table, DB file size.",
  {},
  async () => {
    if (!db) return { content: [{ type: "text", text: "DB not available" }] };
    const tables = ["sessions", "batches", "tasks", "task_tags", "tags", "config", "security_events", "web_tasks"];
    const counts = {};
    for (const t of tables) {
      try { counts[t] = db.prepare(`SELECT COUNT(*) as n FROM ${t}`).get().n; }
      catch { counts[t] = null; }
    }
    let config = [];
    try { config = db.prepare("SELECT * FROM config").all(); } catch {}
    let db_size_mb = null;
    try { db_size_mb = fs.statSync(DB_PATH).size / 1024 / 1024; } catch {}
    const status = { config, counts, db_size_mb };
    return { content: [{ type: "text", text: JSON.stringify(status, null, 2) }] };
  }
);

// --- set_config ---

const ALLOWED_CONFIG_KEYS = new Set([
  "full_output_storage",
  "full_prompt_storage",
  "prompt_full_days",
  "output_days",
  "output_full_days",
  "row_days",
  "max_db_mb",
]);

server.tool(
  "set_config",
  "Write a config value to the audit DB. Only an allowlisted set of keys is accepted, plus key patterns prompt_storage_project:<name> and allowed_root:<path>.",
  {
    key: z.string(),
    value: z.string(),
  },
  async ({ key, value }) => {
    if (!db) return { content: [{ type: "text", text: "DB not available" }] };
    if (!ALLOWED_CONFIG_KEYS.has(key) && !/^prompt_storage_project:.+$/.test(key) && !/^allowed_root:.+$/.test(key)) {
      return {
        content: [{ type: "text", text: `Error: key '${key}' is not in the allowed config keys list` }],
        isError: true,
      };
    }
    db.prepare(
      `INSERT INTO config(key, value, updated_at) VALUES(?, ?, datetime('now'))
       ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at`
    ).run(key, value);
    return { content: [{ type: "text", text: JSON.stringify({ ok: true, key, value }) }] };
  }
);

// --- delete_config ---

server.tool(
  "delete_config",
  "Delete a config key from the audit DB. Only keys matching the same patterns as set_config are deletable.",
  {
    key: z.string(),
  },
  async ({ key }) => {
    if (!db) return { content: [{ type: "text", text: "DB not available" }] };
    if (!ALLOWED_CONFIG_KEYS.has(key) && !/^prompt_storage_project:.+$/.test(key) && !/^allowed_root:.+$/.test(key)) {
      return {
        content: [{ type: "text", text: `Error: key '${key}' is not in the allowed config keys list` }],
        isError: true,
      };
    }
    const result = db.prepare("DELETE FROM config WHERE key = ?").run(key);
    if (result.changes > 0) {
      return { content: [{ type: "text", text: `Deleted config key: '${key}'` }] };
    }
    return { content: [{ type: "text", text: `Key '${key}' not found in config` }] };
  }
);

// --- run_query ---

server.tool(
  "run_query",
  "Run a raw SELECT query against the audit DB. Only SELECT statements are permitted.",
  {
    sql: z.string(),
    params: z.array(z.any()).default([]),
  },
  async ({ sql, params }) => {
    if (!db) return { content: [{ type: "text", text: "DB not available" }] };
    if (sql.length > 4000) {
      return {
        content: [{ type: "text", text: "Error: query length exceeds 4000 characters" }],
        isError: true,
      };
    }
    if (sql.includes("--") || sql.includes("/*")) {
      return {
        content: [{ type: "text", text: "Error: SQL comments are not allowed in queries" }],
        isError: true,
      };
    }
    if (sql.includes(";")) {
      return {
        content: [{ type: "text", text: "Error: semicolons are not allowed; only single-statement queries are permitted" }],
        isError: true,
      };
    }
    if (!sql.trim().toUpperCase().startsWith("SELECT")) {
      return {
        content: [{ type: "text", text: "Error: only SELECT queries are allowed" }],
        isError: true,
      };
    }
    const rows = db.prepare(sql).all(...params);
    return { content: [{ type: "text", text: JSON.stringify(rows, null, 2) }] };
  }
);

// --- export_jsonl ---

server.tool(
  "export_jsonl",
  "Export audit tasks as newline-delimited JSON (JSONL) for ingestion by external log aggregators. Accepts optional filters; truncates at 5000 rows.",
  {
    days:      z.number().int().min(1).max(365).default(7),
    tool_type: z.string().optional(),
    table:     z.enum(["tasks", "security_events"]).default("tasks"),
    limit:     z.number().int().min(1).max(5000).default(5000),
  },
  async ({ days, tool_type, table, limit }) => {
    if (!db) return { content: [{ type: "text", text: "DB not available" }] };

    const cutoff = Date.now() - days * 86_400_000;
    const where = ["started_at > ?"];
    const params = [cutoff];

    if (table === "tasks") {
      if (tool_type) { where.push("tool_type = ?"); params.push(tool_type); }
      const rows = db.prepare(
        `SELECT * FROM tasks WHERE ${where.join(" AND ")} ORDER BY started_at DESC LIMIT ?`
      ).all(...params, limit);
      const truncated = rows.length === limit;
      const lines = rows.map((r) => JSON.stringify(r));
      if (truncated) lines.push(JSON.stringify({ truncated: true, row_limit: limit }));
      return { content: [{ type: "text", text: lines.join("\n") }] };
    }

    // security_events uses timestamp_ms instead of started_at
    const seRows = db.prepare(
      `SELECT * FROM security_events WHERE timestamp_ms > ? ORDER BY timestamp_ms DESC LIMIT ?`
    ).all(cutoff, limit);
    const truncated = seRows.length === limit;
    const lines = seRows.map((r) => JSON.stringify(r));
    if (truncated) lines.push(JSON.stringify({ truncated: true, row_limit: limit }));
    return { content: [{ type: "text", text: lines.join("\n") }] };
  }
);

// --- get_alerts ---

server.tool(
  "get_alerts",
  "Run four canned anomaly-detection queries: high-call-count sessions, token overspend, repeated identical Codex prompts (loop detection), and danger-full-access sandbox usage.",
  {
    max_calls_per_session: z.number().int().min(1).default(50),
    max_tokens_per_session: z.number().int().min(1).default(100_000),
    token_window_hours: z.number().int().min(1).max(168).default(24),
    repeat_prompt_threshold: z.number().int().min(2).default(3),
  },
  async ({ max_calls_per_session, max_tokens_per_session, token_window_hours, repeat_prompt_threshold }) => {
    if (!db) return { content: [{ type: "text", text: "DB not available" }] };

    const tokenCutoff = Date.now() - token_window_hours * 3_600_000;

    const highCallSessions = db.prepare(
      `SELECT session_id, COUNT(*) as call_count
       FROM tasks GROUP BY session_id HAVING call_count > ?
       ORDER BY call_count DESC LIMIT 20`
    ).all(max_calls_per_session);

    const tokenOverspend = db.prepare(
      `SELECT session_id,
              SUM(prompt_tokens_est + response_token_est) as total_tokens
       FROM tasks WHERE started_at > ?
       GROUP BY session_id HAVING total_tokens > ?
       ORDER BY total_tokens DESC LIMIT 20`
    ).all(tokenCutoff, max_tokens_per_session);

    const repeatedPrompts = db.prepare(
      `SELECT prompt_hash, prompt_slug, COUNT(*) as repeat_count
       FROM tasks WHERE tool_type = 'codex'
       GROUP BY prompt_hash HAVING repeat_count > ?
       ORDER BY repeat_count DESC LIMIT 20`
    ).all(repeat_prompt_threshold);

    const dangerSandbox = db.prepare(
      `SELECT invocation_id, session_id, project, prompt_slug, started_at, status
       FROM tasks WHERE sandbox = 'danger-full-access'
       ORDER BY started_at DESC LIMIT 20`
    ).all();

    const alerts = {
      high_call_sessions:   { threshold: max_calls_per_session,  hits: highCallSessions },
      token_overspend:      { threshold: max_tokens_per_session, window_hours: token_window_hours, hits: tokenOverspend },
      repeated_prompts:     { threshold: repeat_prompt_threshold, hits: repeatedPrompts },
      danger_full_access:   { hits: dangerSandbox },
    };
    return { content: [{ type: "text", text: JSON.stringify(alerts, null, 2) }] };
  }
);

// --- Start ---

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}
main().catch(console.error);
