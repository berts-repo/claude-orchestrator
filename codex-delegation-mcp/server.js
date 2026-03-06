#!/usr/bin/env node
/**
 * codex-delegation-mcp — parallel Codex subprocess dispatcher
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
import path from "path";
import { fileURLToPath } from "url";
import { z } from "zod";

const parsedTimeoutMs = parseInt(process.env.CODEX_POOL_TIMEOUT_MS ?? "300000", 10);
const DEFAULT_TIMEOUT_MS = Number.isFinite(parsedTimeoutMs) && parsedTimeoutMs > 0 ? parsedTimeoutMs : 300000; // 5 min
const FORCE_KILL_DELAY_MS = 5000;
const MAX_OUTPUT_BYTES = 2 * 1024 * 1024;
const USER_HOME = path.resolve(process.env.HOME ?? homedir());
const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));
const CONFIG_PATH = path.resolve(MODULE_DIR, "config.json");
const DEFAULT_CONFIG = {
  allowedRoots: [USER_HOME],
  blockedPaths: ["/", "/etc", "/usr", "/bin", "/sbin", "/lib", "/System", "/Library"],
};

function expandHomePath(targetPath) {
  if (targetPath === "~") return USER_HOME;
  if (targetPath.startsWith("~/")) return path.resolve(USER_HOME, targetPath.slice(2));
  return targetPath;
}

function loadConfig() {
  let rawConfig;
  try {
    rawConfig = JSON.parse(readFileSync(CONFIG_PATH, "utf8"));
  } catch (err) {
    if (err && typeof err === "object" && "code" in err && err.code === "ENOENT") {
      console.warn(
        `[codex-delegation] Missing config file at '${CONFIG_PATH}'. Falling back to default cwd policy.`
      );
      return DEFAULT_CONFIG;
    }
    throw err;
  }

  const allowedRoots = Array.isArray(rawConfig.allowedRoots)
    ? rawConfig.allowedRoots
    : DEFAULT_CONFIG.allowedRoots;
  const blockedPaths = Array.isArray(rawConfig.blockedPaths)
    ? rawConfig.blockedPaths
    : DEFAULT_CONFIG.blockedPaths;

  return {
    allowedRoots: allowedRoots
      .filter((targetPath) => typeof targetPath === "string" && targetPath.trim())
      .map((targetPath) => path.resolve(expandHomePath(targetPath.trim()))),
    blockedPaths: blockedPaths
      .filter((targetPath) => typeof targetPath === "string" && targetPath.trim())
      .map((targetPath) => path.resolve(expandHomePath(targetPath.trim()))),
  };
}

const config = loadConfig();

function parseAllowedCwdRoots() {
  const configured = process.env.CODEX_POOL_ALLOWED_CWD_ROOTS;
  const defaultRoots = config.allowedRoots;
  const roots = [...defaultRoots, ...(configured ? configured.split(",") : [])]
    .map((root) => root.trim())
    .filter(Boolean)
    .filter((root) => path.isAbsolute(root))
    .map((root) => path.resolve(root));
  const deduped = Array.from(new Set(roots));
  return deduped.length > 0 ? deduped : defaultRoots;
}

const ALLOWED_CWD_ROOTS = parseAllowedCwdRoots();

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

const ApprovalPolicy = z.enum(["untrusted", "on-failure", "on-request", "never"]);

const TaskSchema = z.object({
  prompt: z.string().min(1).describe("The task prompt for Codex"),
  cwd: z.string().min(1).describe("Absolute path to the working directory to mount"),
  sandbox: SandboxMode.default("workspace-write"),
  "approval-policy": ApprovalPolicy.default("on-failure").describe("When Codex must ask for approval"),
  model: z.string().optional().describe("Model override (e.g. 'o4-mini')"),
  "base-instructions": z.string().optional().describe("Override system instructions"),
  "skip-git-repo-check": z.boolean().optional().describe("Pass --skip-git-repo-check to codex exec"),
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
      "approval-policy": approvalPolicy,
      model,
      "base-instructions": baseInstructions,
    } = task;
    const startedAt = Date.now();

    const apiKey = resolveApiKey();

    const codexBin = process.env.CODEX_BIN ?? "codex";
    const codexArgs = [
      "exec", "--ephemeral",
      "-s", sandbox,
      ...(approvalPolicy ? ["-c", `approval_policy=${approvalPolicy}`] : []),
      ...(model ? ["-m", model] : []),
      ...(baseInstructions ? ["-c", `instructions=${JSON.stringify(baseInstructions)}`] : []),
      ...(task["skip-git-repo-check"] ? ["--skip-git-repo-check"] : []),
      prompt,
    ];

    const env = {
      ...Object.fromEntries(
        ["PATH", "HOME", "USER", "TMPDIR", "TERM", "LANG", "LC_ALL",
         "OPENAI_API_KEY", "CODEX_BIN", "CODEX_POOL_TIMEOUT_MS"]
          .filter((k) => process.env[k] !== undefined)
          .map((k) => [k, process.env[k]])
      ),
      ...(apiKey ? { OPENAI_API_KEY: apiKey } : {}),
    };

    const proc = spawn(codexBin, codexArgs, {
      cwd,
      env,
      stdio: ["ignore", "pipe", "pipe"],
      detached: true,
    });
    proc.unref();

    let stdout = "";
    let stderr = "";
    let timedOut = false;
    let outputCapped = false;
    let stdoutBytes = 0;
    let stderrBytes = 0;
    let stdoutTruncated = false;
    let stderrTruncated = false;

    let forceKillTimer;
    const terminateProcess = () => {
      if (proc.exitCode === null) {
        try {
          process.kill(-proc.pid, "SIGTERM");
        } catch {}
      }
      if (!forceKillTimer) {
        forceKillTimer = setTimeout(() => {
          if (proc.exitCode === null) {
            try {
              process.kill(-proc.pid, "SIGKILL");
            } catch {}
          }
        }, FORCE_KILL_DELAY_MS);
      }
    };
    const timeoutTimer = setTimeout(() => {
      timedOut = true;
      terminateProcess();
    }, DEFAULT_TIMEOUT_MS);

    proc.stdout.on("data", (chunk) => {
      if (stdoutBytes < MAX_OUTPUT_BYTES) {
        const remaining = MAX_OUTPUT_BYTES - stdoutBytes;
        const take = Math.min(remaining, chunk.length);
        stdout += chunk.subarray(0, take).toString();
        stdoutBytes += take;
      }
      if (stdoutBytes >= MAX_OUTPUT_BYTES && !stdoutTruncated) {
        stdout += "\n[stdout truncated: output limit reached]";
        stdoutTruncated = true;
        outputCapped = true;
        terminateProcess();
      }
    });
    proc.stderr.on("data", (chunk) => {
      if (stderrBytes < MAX_OUTPUT_BYTES) {
        const remaining = MAX_OUTPUT_BYTES - stderrBytes;
        const take = Math.min(remaining, chunk.length);
        stderr += chunk.subarray(0, take).toString();
        stderrBytes += take;
      }
      if (stderrBytes >= MAX_OUTPUT_BYTES && !stderrTruncated) {
        stderr += "\n[stderr truncated: output limit reached]";
        stderrTruncated = true;
        outputCapped = true;
        terminateProcess();
      }
    });

    proc.on("close", (code) => {
      clearTimeout(timeoutTimer);
      clearTimeout(forceKillTimer);
      const success = !timedOut && !outputCapped && code === 0;
      resolve({
        index,
        success,
        output: stdout.trim(),
        error: timedOut
          ? `Timed out after ${DEFAULT_TIMEOUT_MS / 1000}s`
          : outputCapped
            ? `Output exceeded ${MAX_OUTPUT_BYTES} bytes and process was terminated`
          : stderr.trim() || undefined,
        exitCode: code ?? -1,
        startedAt,
        finishedAt: Date.now(),
        batchStart,
      });
    });

    proc.on("error", (err) => {
      clearTimeout(timeoutTimer);
      clearTimeout(forceKillTimer);
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

function isWithinRoot(targetPath, rootPath) {
  const rel = path.relative(rootPath, targetPath);
  return rel === "" || (!rel.startsWith("..") && !path.isAbsolute(rel));
}

function normalizeTask(task, taskLabel = "task") {
  if (!path.isAbsolute(task.cwd)) {
    throw new Error(
      `${taskLabel}: invalid cwd '${task.cwd}'. cwd must be an absolute path within allowed roots: ${ALLOWED_CWD_ROOTS.join(", ")}`
    );
  }

  const normalizedCwd = path.resolve(task.cwd);
  const blockedRoot = config.blockedPaths.find(
    (blocked) => normalizedCwd === blocked || normalizedCwd.startsWith(`${blocked}/`)
  );
  if (blockedRoot) {
    throw new Error(
      `${taskLabel}: invalid cwd '${normalizedCwd}'. '${blockedRoot}' is blocked by config (codex-delegation-mcp/config.json).`
    );
  }

  const inAllowedRoot = ALLOWED_CWD_ROOTS.some((root) => isWithinRoot(normalizedCwd, root));
  if (!inAllowedRoot) {
    throw new Error(
      `${taskLabel}: invalid cwd '${normalizedCwd}'. cwd must match an allowed root prefix from CODEX_POOL_ALLOWED_CWD_ROOTS (current: ${ALLOWED_CWD_ROOTS.join(", ")}).`
    );
  }

  let approvalPolicy = task["approval-policy"];
  if (task.sandbox === "danger-full-access" && approvalPolicy !== "untrusted") {
    console.warn(
      `[codex-delegation] ${taskLabel}: sandbox=danger-full-access requires approval-policy=untrusted; forcing untrusted.`
    );
    approvalPolicy = "untrusted";
  }

  return {
    ...task,
    cwd: normalizedCwd,
    ...(approvalPolicy !== undefined ? { "approval-policy": approvalPolicy } : {}),
  };
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
  { name: "codex-delegation", version: "0.1.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "codex",
      description:
        "Run a single Codex task in an isolated local subprocess. " +
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
            enum: ["untrusted", "on-failure", "on-request", "never"],
            default: "on-failure",
            description: "When Codex must ask for human approval before running a command",
          },
          model: { type: "string", description: "Model override (e.g. o4-mini)" },
          "base-instructions": { type: "string", description: "Override system instructions" },
          "skip-git-repo-check": {
            type: "boolean",
            description: "Pass --skip-git-repo-check to codex exec; use when cwd is not a git repo",
          },
        },
        required: ["prompt", "cwd"],
      },
    },
    {
      name: "codex_parallel",
      description:
        "Run multiple Codex tasks in parallel local subprocesses. " +
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
                  enum: ["untrusted", "on-failure", "on-request", "never"],
                  default: "on-failure",
                },
                model: { type: "string" },
                "base-instructions": { type: "string" },
                "skip-git-repo-check": {
                  type: "boolean",
                  description: "Pass --skip-git-repo-check to codex exec; use when cwd is not a git repo",
                },
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
    const parsedTask = TaskSchema.parse(args);
    const task = normalizeTask(
      {
        ...parsedTask,
        "approval-policy": parsedTask["approval-policy"] ?? "on-failure",
      },
      "codex"
    );
    const result = await runCodexContainer(task, 0);
    return {
      content: [{ type: "text", text: formatResult(result) }],
      isError: !result.success,
    };
  }

  if (name === "codex_parallel") {
    const { tasks } = ParallelSchema.parse(args);
    const normalizedTasks = tasks.map((task, i) => {
      const taskWithApprovalPolicy = {
        ...task,
        "approval-policy": task["approval-policy"] ?? "on-failure",
      };
      return normalizeTask(taskWithApprovalPolicy, `codex_parallel task ${i + 1}`);
    });
    // Fan out — all containers start immediately
    const batchStart = Date.now();
    const results = await Promise.all(
      normalizedTasks.map((task, i) => runCodexContainer(task, i, batchStart))
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
