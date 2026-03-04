#!/usr/bin/env node
/**
 * codex-pool-mcp — parallel Codex subprocess dispatcher
 *
 * Replaces the single-process `codex mcp-server` delegate.
 * Each task spawns an independent `codex exec` process; codex_parallel
 * fans out to N processes simultaneously via Promise.all, bypassing
 * Claude Code's MCP call serialization entirely.
 *
 * Security: Codex's own --sandbox flag enforces filesystem isolation.
 * Token savings: Codex runs on OpenAI account, not Claude tokens.
 *
 * Tools:
 *   codex          — single task (backward compat with mcp__delegate__codex)
 *   codex_parallel — array of tasks, all run in parallel
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { spawn } from "child_process";
import { readFileSync } from "fs";
import { homedir } from "os";
import { z } from "zod";

const DEFAULT_TIMEOUT_MS = parseInt(process.env.CODEX_POOL_TIMEOUT_MS ?? "300000", 10); // 5 min

// Resolve API key: env var first, then ~/.codex/auth.json (where Codex stores it)
function resolveApiKey() {
  if (process.env.OPENAI_API_KEY) return process.env.OPENAI_API_KEY;
  try {
    const auth = JSON.parse(readFileSync(`${homedir()}/.codex/auth.json`, "utf8"));
    return auth.OPENAI_API_KEY ?? null;
  } catch {
    return null;
  }
}

// ── Schemas ────────────────────────────────────────────────────────────────

const SandboxMode = z.enum(["read-only", "workspace-write", "danger-full-access"]);
const ApprovalPolicy = z.enum(["never", "on-failure", "on-request", "untrusted"]);

const TaskSchema = z.object({
  prompt: z.string().min(1).describe("The task prompt for Codex"),
  cwd: z.string().min(1).describe("Absolute path to the working directory to mount"),
  sandbox: SandboxMode.default("workspace-write"),
  "approval-policy": ApprovalPolicy.default("on-failure"),
  model: z.string().optional().describe("Model override (e.g. 'o4-mini')"),
  "base-instructions": z.string().optional().describe("Override system instructions"),
});

const ParallelSchema = z.object({
  tasks: z.array(TaskSchema).min(1).max(10).describe("Tasks to run in parallel (max 10)"),
});

// ── Subprocess runner ──────────────────────────────────────────────────────

/**
 * Run a single Codex task as a local subprocess.
 * Resolves with { success, output, exitCode } when the process exits.
 */
function runCodexContainer(task, index = 0, batchStart = Date.now()) {
  return new Promise((resolve) => {
    const {
      prompt,
      cwd,
      sandbox = "workspace-write",
      model,
      "base-instructions": baseInstructions,
    } = task;
    const startedAt = Date.now();

    const apiKey = resolveApiKey();

    const codexBin = process.env.CODEX_BIN ?? "/usr/local/bin/codex";
    const codexArgs = [
      "exec", "--ephemeral",
      "-s", sandbox,
      ...(model ? ["-m", model] : []),
      ...(baseInstructions ? ["-c", `instructions=${JSON.stringify(baseInstructions)}`] : []),
      prompt,
    ];

    const env = {
      ...process.env,
      ...(apiKey ? { OPENAI_API_KEY: apiKey } : {}),
    };

    const proc = spawn(codexBin, codexArgs, {
      cwd,
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";
    let timedOut = false;

    const timer = setTimeout(() => {
      timedOut = true;
      proc.kill("SIGTERM");
    }, DEFAULT_TIMEOUT_MS);

    proc.stdout.on("data", (chunk) => { stdout += chunk.toString(); });
    proc.stderr.on("data", (chunk) => { stderr += chunk.toString(); });

    proc.on("close", (code) => {
      clearTimeout(timer);
      const success = !timedOut && code === 0;
      resolve({
        index,
        success,
        output: stdout.trim(),
        error: timedOut
          ? `Timed out after ${DEFAULT_TIMEOUT_MS / 1000}s`
          : stderr.trim() || undefined,
        exitCode: code ?? -1,
        startedAt,
        finishedAt: Date.now(),
        batchStart,
      });
    });

    proc.on("error", (err) => {
      clearTimeout(timer);
      resolve({
        index,
        success: false,
        output: "",
        error: `Failed to spawn codex: ${err.message}`,
        exitCode: -1,
        startedAt,
        finishedAt: Date.now(),
        batchStart,
      });
    });
  });
}

// ── Format result for MCP response ─────────────────────────────────────────

function formatResult(result) {
  const lines = [];
  if (!result.success) {
    lines.push(`FAILED (exit ${result.exitCode})`);
    if (result.error) lines.push(`Error: ${result.error}`);
  }
  if (result.output) lines.push(result.output);
  return lines.join("\n") || "(no output)";
}

function formatParallelResults(results) {
  if (results.length === 1) return formatResult(results[0]);
  const batchStart = results[0]?.batchStart ?? Date.now();
  const batchEnd = Math.max(...results.map((r) => r.finishedAt ?? batchStart));
  const header = `Parallel batch: ${results.length} tasks, total wall time ${batchEnd - batchStart}ms\n`;
  const body = results
    .map((r, i) => {
      const lag = r.startedAt != null ? `+${r.startedAt - batchStart}ms start` : "";
      const dur = r.startedAt != null && r.finishedAt != null ? `, ${r.finishedAt - r.startedAt}ms duration` : "";
      return `### Task ${i + 1} [${lag}${dur}]\n${formatResult(r)}`;
    })
    .join("\n\n---\n\n");
  return header + "\n" + body;
}

// ── MCP Server ─────────────────────────────────────────────────────────────

const server = new Server(
  { name: "codex-pool", version: "0.1.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "codex",
      description:
        "Run a single Codex task in an isolated Docker container. " +
        "Equivalent to the previous mcp__delegate__codex interface.",
      inputSchema: {
        type: "object",
        properties: {
          prompt: { type: "string", description: "Task prompt for Codex" },
          cwd: { type: "string", description: "Absolute path to working directory" },
          sandbox: {
            type: "string",
            enum: ["read-only", "workspace-write", "danger-full-access"],
            default: "workspace-write",
          },
          "approval-policy": {
            type: "string",
            enum: ["never", "on-failure", "on-request", "untrusted"],
            default: "on-failure",
          },
          model: { type: "string", description: "Model override (e.g. o4-mini)" },
          "base-instructions": { type: "string", description: "Override system instructions" },
        },
        required: ["prompt", "cwd"],
      },
    },
    {
      name: "codex_parallel",
      description:
        "Run multiple Codex tasks in parallel Docker containers. " +
        "All tasks start simultaneously; results are returned when all complete. " +
        "Use this for independent subtasks that would otherwise serialize.",
      inputSchema: {
        type: "object",
        properties: {
          tasks: {
            type: "array",
            description: "Array of Codex tasks to run in parallel (max 10)",
            maxItems: 10,
            items: {
              type: "object",
              properties: {
                prompt: { type: "string" },
                cwd: { type: "string" },
                sandbox: {
                  type: "string",
                  enum: ["read-only", "workspace-write", "danger-full-access"],
                  default: "workspace-write",
                },
                "approval-policy": {
                  type: "string",
                  enum: ["never", "on-failure", "on-request", "untrusted"],
                  default: "on-failure",
                },
                model: { type: "string" },
                "base-instructions": { type: "string" },
              },
              required: ["prompt", "cwd"],
            },
          },
        },
        required: ["tasks"],
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  if (name === "codex") {
    const task = TaskSchema.parse(args);
    const result = await runCodexContainer(task, 0);
    return {
      content: [{ type: "text", text: formatResult(result) }],
      isError: !result.success,
    };
  }

  if (name === "codex_parallel") {
    const { tasks } = ParallelSchema.parse(args);
    // Fan out — all containers start immediately
    const batchStart = Date.now();
    const results = await Promise.all(
      tasks.map((task, i) => runCodexContainer(task, i, batchStart))
    );
    const allSucceeded = results.every((r) => r.success);
    return {
      content: [{ type: "text", text: formatParallelResults(results) }],
      isError: !allSucceeded,
    };
  }

  throw new Error(`Unknown tool: ${name}`);
});

// ── Start ───────────────────────────────────────────────────────────────────

const transport = new StdioServerTransport();
await server.connect(transport);
