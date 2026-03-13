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
              status, failure_reason, duration_ms, started_at, stdout_bytes, token_est
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
              AVG(duration_ms) as avg_ms, MAX(duration_ms) as max_ms, SUM(token_est) as token_sum
       FROM tasks WHERE started_at > datetime('now', '-' || ? || ' days')
       GROUP BY tool_type, sandbox, status`
    ).all(days);
    const failures = db.prepare(
      `SELECT project, COUNT(*) as total,
              SUM(CASE WHEN status='failed' THEN 1 ELSE 0 END) as failed
       FROM tasks WHERE started_at > datetime('now', '-30 days')
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
    const tables = ["sessions", "batches", "tasks", "task_tags", "tags", "config"];
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

// --- Start ---

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}
main().catch(console.error);
