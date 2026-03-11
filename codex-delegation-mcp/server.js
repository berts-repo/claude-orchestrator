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
import { spawn, spawnSync } from "child_process";
import { createHash, randomUUID } from "crypto";
import { readFileSync } from "fs";
import { homedir } from "os";
import path from "path";
import { z } from "zod";
import {
  autoTag,
  clearCurrentBatchId,
  cleanBatchStatus,
  completeBatch,
  getConfig,
  insertBatch,
  insertTask,
  redact,
  shouldStoreFullOutput,
  shouldStoreFullPrompt,
  updateTask,
  upsertSession,
  writeBatchStatus,
  writeCurrentBatchId,
} from "./db.js";

const parsedTimeoutMs = parseInt(process.env.CODEX_POOL_TIMEOUT_MS ?? "300000", 10);
const DEFAULT_TIMEOUT_MS = Number.isFinite(parsedTimeoutMs) && parsedTimeoutMs > 0 ? parsedTimeoutMs : 300000; // 5 min
const FORCE_KILL_DELAY_MS = 5000;
const MAX_OUTPUT_BYTES = 2 * 1024 * 1024;
const USER_HOME = path.resolve(process.env.HOME ?? homedir());
const BLOCKED_CWD_ROOTS = ["/", "/etc", "/usr", "/bin", "/sbin", "/lib", "/System", "/Library"];
const SESSION_ID = randomUUID();
let sessionInitialized = false;

function parseAllowedCwdRoots() {
  const configured = process.env.CODEX_POOL_ALLOWED_CWD_ROOTS;
  const defaultRoots = USER_HOME ? [USER_HOME] : [];
  const roots = (configured ? configured.split(",") : defaultRoots)
    .map((root) => root.trim())
    .filter(Boolean)
    .filter((root) => path.isAbsolute(root))
    .map((root) => path.resolve(root));
  const deduped = Array.from(new Set(roots));
  return deduped.length > 0 ? deduped : defaultRoots;
}

const ALLOWED_CWD_ROOTS = parseAllowedCwdRoots();

function logDbError(context, error) {
  console.warn(`[codex-delegation] ${context}: ${error.message}`);
}

function ensureSession(model) {
  if (sessionInitialized) return;
  try {
    upsertSession(SESSION_ID, model);
    sessionInitialized = true;
  } catch (error) {
    logDbError("session init failed", error);
  }
}

function toPromptSlug(prompt) {
  return prompt.replace(/\s+/g, " ").trim().slice(0, 80);
}

function toPromptHash(prompt) {
  return createHash("sha256").update(prompt).digest("hex");
}

function toFailureReason(result) {
  if (result.timedOut) return "timeout";
  if (result.outputCapped) return "output_capped";
  if (result.spawnError) return "spawn_error";
  if (result.exitCode !== 0) return "exit_nonzero";
  return null;
}

function toStoredOutput(result) {
  const merged = [result.stdoutText ?? "", result.stderrText ?? ""].filter(Boolean).join("\n");
  return merged.slice(0, 2048);
}

function toStoredError(result) {
  return (result.stderrText ?? result.error ?? "").slice(0, 2048);
}

function isGitRepository(cwd) {
  const result = spawnSync("git", ["-C", cwd, "rev-parse", "--git-dir"], {
    stdio: "ignore",
  });
  return result.status === 0;
}

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
function runCodexContainer(task, index = 0, batchStart = Date.now(), hooks = {}) {
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
    const shouldSkipGitRepoCheck = task["skip-git-repo-check"] || !isGitRepository(cwd);

    const codexArgs = [
      "exec", "--ephemeral",
      "-s", sandbox,
      ...(approvalPolicy ? ["-c", `approval_policy=${approvalPolicy}`] : []),
      ...(model ? ["-m", model] : []),
      ...(baseInstructions ? ["-c", `instructions=${JSON.stringify(baseInstructions)}`] : []),
      ...(shouldSkipGitRepoCheck ? ["--skip-git-repo-check"] : []),
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
    hooks.onStart?.({ index, startedAt });

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
        timedOut,
        outputCapped,
        stdoutBytes,
        stderrBytes,
        stdoutText: stdout,
        stderrText: stderr,
        spawnError: false,
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
        timedOut: false,
        outputCapped: false,
        stdoutBytes,
        stderrBytes,
        stdoutText: stdout,
        stderrText: stderr,
        spawnError: true,
      });
    });
  });
}

function isWithinRoot(targetPath, rootPath) {
  const rel = path.relative(rootPath, targetPath);
  return rel === "" || (!rel.startsWith("..") && !path.isAbsolute(rel));
}

function getHomeDepth(targetPath) {
  if (!USER_HOME || !isWithinRoot(targetPath, USER_HOME)) return null;
  const rel = path.relative(USER_HOME, targetPath);
  if (!rel) return 0;
  return rel.split(path.sep).filter(Boolean).length;
}

function normalizeTask(task, taskLabel = "task") {
  if (!path.isAbsolute(task.cwd)) {
    throw new Error(
      `${taskLabel}: invalid cwd '${task.cwd}'. cwd must be an absolute path within allowed roots: ${ALLOWED_CWD_ROOTS.join(", ")}`
    );
  }

  const normalizedCwd = path.resolve(task.cwd);
  const blockedRoot = BLOCKED_CWD_ROOTS.find(
    (blocked) => normalizedCwd === blocked || normalizedCwd.startsWith(`${blocked}/`)
  );
  if (blockedRoot) {
    throw new Error(
      `${taskLabel}: invalid cwd '${normalizedCwd}'. Root/system directory '${blockedRoot}' is not allowed.`
    );
  }

  const inAllowedRoot = ALLOWED_CWD_ROOTS.some((root) => isWithinRoot(normalizedCwd, root));
  if (!inAllowedRoot) {
    throw new Error(
      `${taskLabel}: invalid cwd '${normalizedCwd}'. cwd must match an allowed root prefix from CODEX_POOL_ALLOWED_CWD_ROOTS (current: ${ALLOWED_CWD_ROOTS.join(", ")}).`
    );
  }

  const homeDepth = getHomeDepth(normalizedCwd);
  if (task.sandbox === "workspace-write" && homeDepth !== null && homeDepth < 0) {
    throw new Error(
      `${taskLabel}: invalid cwd '${normalizedCwd}'. For workspace-write safety, cwd under '${USER_HOME}' must be at or below home.`
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
    const invocationId = randomUUID();
    const batchId = randomUUID();
    const batchStart = Date.now();
    const promptSlug = toPromptSlug(task.prompt);
    const project = path.basename(task.cwd);
    const tokenEst = Math.ceil(task.prompt.length / 4);
    const statusTasks = [{
      index: 0,
      status: "running",
      promptSlug,
      project,
      startedAt: batchStart,
      endedAt: null,
      durationMs: null,
    }];
    writeCurrentBatchId(batchId);

    ensureSession(task.model);
    try {
      insertBatch(batchId, SESSION_ID, 1);
      const taskId = insertTask({
        invocation_id: invocationId,
        batch_id: batchId,
        session_id: SESSION_ID,
        parent_task_id: null,
        task_index: 0,
        tool_type: "codex",
        project,
        cwd: task.cwd,
        prompt_slug: promptSlug,
        prompt_hash: toPromptHash(task.prompt),
        prompt: null,
        url: null,
        sandbox: task.sandbox,
        approval: task["approval-policy"],
        model: task.model ?? null,
        skip_git_check: task["skip-git-repo-check"] ? 1 : 0,
        started_at: batchStart,
        ended_at: null,
        duration_ms: null,
        exit_code: null,
        status: "running",
        failure_reason: null,
        timed_out: 0,
        output_capped: 0,
        stdout_bytes: 0,
        stderr_bytes: 0,
        output_truncated: null,
        error_text: null,
        redaction_count: 0,
        token_est: tokenEst,
        cost_est_usd: null,
      });
      autoTag(taskId, promptSlug, task.sandbox);
      writeBatchStatus(batchId, statusTasks);
    } catch (error) {
      logDbError("single task setup failed", error);
    }

    const result = await runCodexContainer(task, 0, batchStart);
    const failed = !result.success;
    const failureReason = toFailureReason(result);
    let redactionCount = 0;
    let promptValue = null;
    let outputValue = null;
    let errorText = null;

    const maxPromptChars = Number.parseInt(getConfig("max_prompt_chars", "4000"), 10);
    const promptCap = Number.isFinite(maxPromptChars) && maxPromptChars > 0 ? maxPromptChars : 4000;

    if (failed || shouldStoreFullPrompt(project)) {
      const redacted = redact(task.prompt.slice(0, promptCap));
      promptValue = redacted.text;
      redactionCount += redacted.count;
    }
    if (failed || shouldStoreFullOutput(project)) {
      const redacted = redact(toStoredOutput(result));
      outputValue = redacted.text;
      redactionCount += redacted.count;
    }
    if (failed) {
      const redacted = redact(toStoredError(result));
      errorText = redacted.text;
      redactionCount += redacted.count;
    }

    try {
      updateTask(invocationId, {
        ended_at: result.finishedAt,
        duration_ms: result.finishedAt - result.startedAt,
        exit_code: result.exitCode,
        status: failed ? "failed" : "done",
        failure_reason: failureReason,
        timed_out: result.timedOut ? 1 : 0,
        output_capped: result.outputCapped ? 1 : 0,
        stdout_bytes: result.stdoutBytes,
        stderr_bytes: result.stderrBytes,
        prompt: promptValue,
        output_truncated: outputValue,
        error_text: errorText,
        redaction_count: redactionCount,
      });
      statusTasks[0] = {
        ...statusTasks[0],
        status: failed ? "failed" : "done",
        endedAt: result.finishedAt,
        durationMs: result.finishedAt - result.startedAt,
      };
      writeBatchStatus(batchId, statusTasks);
      completeBatch(batchId, failed ? 1 : 0, tokenEst);
      cleanBatchStatus(batchId);
    } catch (error) {
      logDbError("single task finalize failed", error);
    } finally {
      clearCurrentBatchId();
    }

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
    const batchId = randomUUID();
    const batchStart = Date.now();
    writeCurrentBatchId(batchId);
    const taskStates = normalizedTasks.map((task, index) => ({
      index,
      invocationId: randomUUID(),
      promptSlug: toPromptSlug(task.prompt),
      project: path.basename(task.cwd),
      status: "queued",
      startedAt: null,
      endedAt: null,
      durationMs: null,
      tokenEst: Math.ceil(task.prompt.length / 4),
    }));

    ensureSession(normalizedTasks[0]?.model);
    try {
      insertBatch(batchId, SESSION_ID, normalizedTasks.length);
      for (const state of taskStates) {
        const sourceTask = normalizedTasks[state.index];
        const taskId = insertTask({
          invocation_id: state.invocationId,
          batch_id: batchId,
          session_id: SESSION_ID,
          parent_task_id: null,
          task_index: state.index,
          tool_type: "codex",
          project: state.project,
          cwd: sourceTask.cwd,
          prompt_slug: state.promptSlug,
          prompt_hash: toPromptHash(sourceTask.prompt),
          prompt: null,
          url: null,
          sandbox: sourceTask.sandbox,
          approval: sourceTask["approval-policy"],
          model: sourceTask.model ?? null,
          skip_git_check: sourceTask["skip-git-repo-check"] ? 1 : 0,
          started_at: null,
          ended_at: null,
          duration_ms: null,
          exit_code: null,
          status: "queued",
          failure_reason: null,
          timed_out: 0,
          output_capped: 0,
          stdout_bytes: 0,
          stderr_bytes: 0,
          output_truncated: null,
          error_text: null,
          redaction_count: 0,
          token_est: state.tokenEst,
          cost_est_usd: null,
        });
        autoTag(taskId, state.promptSlug, sourceTask.sandbox);
      }
      writeBatchStatus(batchId, taskStates);
    } catch (error) {
      logDbError("parallel setup failed", error);
    }

    // Fan out — all containers start immediately
    const results = await Promise.all(
      normalizedTasks.map((task, i) =>
        runCodexContainer(task, i, batchStart, {
          onStart: ({ startedAt }) => {
            const state = taskStates[i];
            state.status = "running";
            state.startedAt = startedAt;
            try {
              updateTask(state.invocationId, { status: "running", started_at: startedAt });
              writeBatchStatus(batchId, taskStates);
            } catch (error) {
              logDbError(`parallel start update failed (task ${i + 1})`, error);
            }
          },
        }).then((result) => {
          const state = taskStates[i];
          const failed = !result.success;
          const failureReason = toFailureReason(result);
          let redactionCount = 0;
          let promptValue = null;
          let outputValue = null;
          let errorText = null;
          const project = state.project;
          const maxPromptChars = Number.parseInt(getConfig("max_prompt_chars", "4000"), 10);
          const promptCap = Number.isFinite(maxPromptChars) && maxPromptChars > 0 ? maxPromptChars : 4000;

          if (failed || shouldStoreFullPrompt(project)) {
            const redacted = redact(task.prompt.slice(0, promptCap));
            promptValue = redacted.text;
            redactionCount += redacted.count;
          }
          if (failed || shouldStoreFullOutput(project)) {
            const redacted = redact(toStoredOutput(result));
            outputValue = redacted.text;
            redactionCount += redacted.count;
          }
          if (failed) {
            const redacted = redact(toStoredError(result));
            errorText = redacted.text;
            redactionCount += redacted.count;
          }

          state.status = failed ? "failed" : "done";
          state.startedAt = state.startedAt ?? result.startedAt;
          state.endedAt = result.finishedAt;
          state.durationMs = result.finishedAt - (state.startedAt ?? result.startedAt);

          try {
            updateTask(state.invocationId, {
              started_at: state.startedAt,
              ended_at: result.finishedAt,
              duration_ms: state.durationMs,
              exit_code: result.exitCode,
              status: state.status,
              failure_reason: failureReason,
              timed_out: result.timedOut ? 1 : 0,
              output_capped: result.outputCapped ? 1 : 0,
              stdout_bytes: result.stdoutBytes,
              stderr_bytes: result.stderrBytes,
              prompt: promptValue,
              output_truncated: outputValue,
              error_text: errorText,
              redaction_count: redactionCount,
            });
            writeBatchStatus(batchId, taskStates);
          } catch (error) {
            logDbError(`parallel completion update failed (task ${i + 1})`, error);
          }
          return result;
        })
      )
    );

    try {
      const failedCount = results.filter((result) => !result.success).length;
      const totalTokens = taskStates.reduce((sum, state) => sum + state.tokenEst, 0);
      completeBatch(batchId, failedCount, totalTokens);
      cleanBatchStatus(batchId);
    } catch (error) {
      logDbError("parallel batch completion failed", error);
    } finally {
      clearCurrentBatchId();
    }

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
