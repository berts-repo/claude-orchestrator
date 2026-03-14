#!/usr/bin/env node
/**
 * delegate — parallel Codex subprocess dispatcher
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
import { readFileSync, realpathSync } from "fs";
import { homedir } from "os";
import path from "path";
import { fileURLToPath } from "url";
import { z } from "zod";
import {
  autoTag,
  clearCurrentBatchId,
  cleanBatchStatus,
  completeBatch,
  getConfig,
  getAllowedRoots,
  insertBatch,
  insertTask,
  redact,
  shouldStoreFullOutput,
  shouldStoreFullPrompt,
  updateTask,
  upsertSession,
  writeBatchStatus,
  writeCurrentBatchId,
} from "../audit-mcp/db.js";

const parsedTimeoutMs = parseInt(process.env.CODEX_POOL_TIMEOUT_MS ?? "300000", 10);
const DEFAULT_TIMEOUT_MS = Number.isFinite(parsedTimeoutMs) && parsedTimeoutMs > 0 ? parsedTimeoutMs : 300000; // 5 min
const FORCE_KILL_DELAY_MS = 5000;
const MAX_OUTPUT_BYTES = 2 * 1024 * 1024;
const USER_HOME = toCanonicalPath(path.resolve(process.env.HOME ?? homedir()));
const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));
const CONFIG_PATH = path.resolve(MODULE_DIR, "../config.json");
const DEFAULT_CONFIG = {
  allowedRoots: [USER_HOME],
  blockedPaths: ["/", "/etc", "/usr", "/bin", "/sbin", "/lib", "/System", "/Library"],
};
const BLOCKED_HOME_DIR_NAMES = new Set([".ssh", ".gnupg", ".aws", ".config", ".local", ".cache", ".claude"]);
const ALLOW_DANGER_SANDBOX = process.env.CODEX_ALLOW_DANGER_SANDBOX === "1";
const INJECTION_SCAN_ENABLED = process.env.CODEX_INJECTION_SCAN !== "0";

const parsedMaxSpawns = parseInt(process.env.MAX_CODEX_SPAWNS_PER_SESSION ?? "0", 10);
const MAX_CODEX_SPAWNS_PER_SESSION = Number.isFinite(parsedMaxSpawns) && parsedMaxSpawns > 0 ? parsedMaxSpawns : 0; // 0 = unlimited
let sessionSpawnCount = 0;

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
const SESSION_ID = randomUUID();
let sessionInitialized = false;

function parseAllowedCwdRoots() {
  const configured = process.env.CODEX_POOL_ALLOWED_CWD_ROOTS;
  const auditRoots = getAllowedRoots();
  const defaultRoots = [...config.allowedRoots, ...auditRoots];
  const roots = [...defaultRoots, ...(configured ? configured.split(",") : [])]
    .map((root) => root.trim())
    .filter(Boolean)
    .map((root) => expandHomePath(root))
    .filter((root) => path.isAbsolute(root))
    .map((root) => toCanonicalPath(path.resolve(root)));
  return Array.from(new Set(roots));
}

function logDbError(context, error) {
  console.warn(`[codex-audit] ${context}: ${error.message}`);
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

function toStoredOutputFull(result) {
  return [result.stdoutText ?? "", result.stderrText ?? ""].filter(Boolean).join("\n");
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

function collectApiKeys(value, intoSet) {
  if (Array.isArray(value)) {
    for (const item of value) collectApiKeys(item, intoSet);
    return;
  }
  if (value && typeof value === "object") {
    for (const [key, child] of Object.entries(value)) {
      if (typeof child === "string" && /api[_-]?key/i.test(key) && child.trim()) {
        intoSet.add(child);
      } else {
        collectApiKeys(child, intoSet);
      }
    }
  }
}

// Resolve OPENAI_API_KEY: env var first, then ~/.codex/auth.json.
// Also gather API keys for output redaction.
function resolveAuthConfig() {
  let apiKey = process.env.OPENAI_API_KEY ?? null;
  const redactValues = new Set();
  if (process.env.OPENAI_API_KEY) redactValues.add(process.env.OPENAI_API_KEY);
  try {
    const auth = JSON.parse(readFileSync(`${homedir()}/.codex/auth.json`, "utf8"));
    if (!apiKey && typeof auth.OPENAI_API_KEY === "string" && auth.OPENAI_API_KEY.trim()) {
      apiKey = auth.OPENAI_API_KEY;
    }
    collectApiKeys(auth, redactValues);
  } catch {
    // Best effort only.
  }
  if (apiKey) redactValues.add(apiKey);
  return { apiKey, redactValues: Array.from(redactValues) };
}

function redactSensitiveOutput(text, redactValues = []) {
  if (!text) return text;
  let redacted = text;
  for (const value of redactValues) {
    if (typeof value === "string" && value.trim()) {
      redacted = redacted.split(value).join("[REDACTED]");
    }
  }
  redacted = redacted.replace(/\bsk-[A-Za-z0-9]{20,}\b/g, "[REDACTED]");
  redacted = redacted.replace(/\bBearer [A-Za-z0-9\-._~+/]{20,}\b/g, "[REDACTED]");
  return redacted;
}

// ── Schemas ────────────────────────────────────────────────────────────────

const SandboxMode = z.enum(["read-only", "workspace-write", "danger-full-access"]);

const ApprovalPolicy = z.enum(["untrusted", "on-failure", "on-request", "never"]);

const TaskSchema = z.object({
  prompt: z.string().min(1).max(50000).describe("The task prompt for Codex"),
  cwd: z.string().min(1).describe("Absolute path to the working directory to mount"),
  sandbox: SandboxMode.default("workspace-write"),
  "approval-policy": ApprovalPolicy.default("on-failure").describe("When Codex must ask for approval"),
  model: z.string().optional().describe("Model override (e.g. 'o4-mini')"),
  "base-instructions": z.string().max(20000).optional().describe("Override system instructions"),
  "skip-git-repo-check": z.boolean().optional().describe("Pass --skip-git-repo-check to codex exec"),
});

const ParallelSchema = z.object({
  tasks: z.preprocess((val) => {
    if (typeof val !== "string") return val;
    try {
      return JSON.parse(val);
    } catch {
      return val;
    }
  }, z.array(TaskSchema).min(1).max(10)).describe("Tasks to run in parallel (max 10)"),
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

    const { apiKey, redactValues } = resolveAuthConfig();

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
      const redactedStdout = redactSensitiveOutput(stdout, redactValues);
      const redactedStderr = redactSensitiveOutput(stderr, redactValues);
      resolve({
        index,
        success,
        output: redactedStdout.trim(),
        error: timedOut
          ? `Timed out after ${DEFAULT_TIMEOUT_MS / 1000}s`
          : outputCapped
            ? `Output exceeded ${MAX_OUTPUT_BYTES} bytes and process was terminated`
          : redactedStderr.trim() || undefined,
        exitCode: code ?? -1,
        startedAt,
        finishedAt: Date.now(),
        batchStart,
        timedOut,
        outputCapped,
        stdoutBytes,
        stderrBytes,
        stdoutText: redactedStdout,
        stderrText: redactedStderr,
        spawnError: false,
      });
    });

    proc.on("error", (err) => {
      clearTimeout(timeoutTimer);
      clearTimeout(forceKillTimer);
      const redactedStdout = redactSensitiveOutput(stdout, redactValues);
      const redactedStderr = redactSensitiveOutput(stderr, redactValues);
      resolve({
        index,
        success: false,
        output: "",
        error: redactSensitiveOutput(`Failed to spawn codex: ${err.message}`, redactValues),
        exitCode: -1,
        startedAt,
        finishedAt: Date.now(),
        batchStart,
        timedOut: false,
        outputCapped: false,
        stdoutBytes,
        stderrBytes,
        stdoutText: redactedStdout,
        stderrText: redactedStderr,
        spawnError: true,
      });
    });
  });
}

function isWithinRoot(targetPath, rootPath) {
  const normalizedTarget = path.resolve(targetPath);
  const normalizedRoot = path.resolve(rootPath);
  const rootPrefix = normalizedRoot.endsWith(path.sep)
    ? normalizedRoot
    : `${normalizedRoot}${path.sep}`;
  return normalizedTarget === normalizedRoot || normalizedTarget.startsWith(rootPrefix);
}


function toCanonicalPath(resolvedPath) {
  try {
    return realpathSync(resolvedPath);
  } catch {
    return resolvedPath;
  }
}

function getBlockedHomePath(normalizedCwd) {
  if (!USER_HOME || !isWithinRoot(normalizedCwd, USER_HOME)) return null;
  const rel = path.relative(USER_HOME, normalizedCwd);
  const [firstSegment] = rel.split(path.sep).filter(Boolean);
  if (!firstSegment) return null;
  if (BLOCKED_HOME_DIR_NAMES.has(firstSegment)) {
    return path.join(USER_HOME, firstSegment);
  }
  if (firstSegment.startsWith(".")) {
    return path.join(USER_HOME, firstSegment);
  }
  return null;
}


// Imperative override phrases that indicate a prompt injection attempt.
// Patterns are anchored to action-verb + subject constructions to minimise
// false positives on prompts that legitimately *describe* these techniques.
const PROMPT_INJECTION_PATTERNS = [
  // Instruction-override imperatives
  /\bignore\s+(all\s+)?(previous|prior|above|earlier)\s+(instructions?|prompts?|context|rules?)\b/i,
  /\bdisregard\s+(all\s+)?(previous|prior|above|earlier|your)\b/i,
  /\bforget\s+(all\s+)?(previous|prior|above|earlier)\s+(instructions?|prompts?|context|rules?)\b/i,
  /\byou\s+are\s+now\s+(?!a\s+(?:senior|junior|experienced|software|typescript|python|rust))/i,
  /\bact\s+as\s+(?:a\s+)?(?:different|new|unrestricted|jailbroken|evil|malicious)\b/i,
  /\bnew\s+(system\s+)?(?:instructions?|prompt|role|persona|task):/i,

  // Embedded system-level markup
  /<\s*system\s*>/i,
  /\[SYSTEM\]/,
  /###\s*system/i,

  // Shell command injection in prompt text (backticks, $() expansion, heredoc abuse)
  /`[^`]{1,200}`/,          // backtick command substitution
  /\$\([^)]{1,200}\)/,      // $() substitution
  /;\s*(?:rm|curl|wget|nc|bash|sh|python|node|eval)\b/i,

  // Credential / exfiltration instructions
  /\b(?:send|upload|post|exfiltrate|transmit)\s+(?:all\s+)?(?:files?|keys?|tokens?|secrets?|credentials?)\b/i,
  /\bread\s+(?:and\s+)?(?:send|upload|return|output)\s+(?:~\/\.|\$HOME\/\.)/i,
];

function scanPromptForInjection(prompt, taskLabel) {
  if (!INJECTION_SCAN_ENABLED) return;
  for (const pattern of PROMPT_INJECTION_PATTERNS) {
    if (pattern.test(prompt)) {
      throw new Error(
        `${taskLabel}: prompt rejected by injection scanner (matched: ${pattern}). ` +
        `Review the prompt for instruction-override language. Set CODEX_INJECTION_SCAN=0 to disable.`
      );
    }
  }
}

function normalizeTask(task, taskLabel = "task") {
  const allowedCwdRoots = parseAllowedCwdRoots();
  if (!path.isAbsolute(task.cwd)) {
    throw new Error(
      `${taskLabel}: invalid cwd '${task.cwd}'. cwd must be an absolute path within allowed roots: ${allowedCwdRoots.join(", ")}`
    );
  }

  const normalizedCwd = toCanonicalPath(path.resolve(task.cwd));
  const blockedHomePath = getBlockedHomePath(normalizedCwd);
  if (blockedHomePath) {
    throw new Error(
      `${taskLabel}: invalid cwd '${normalizedCwd}'. Sensitive home directory '${blockedHomePath}' is not allowed.`
    );
  }
  const blockedRoot = config.blockedPaths.find((blocked) => isWithinRoot(normalizedCwd, blocked));
  if (blockedRoot) {
    throw new Error(
      `${taskLabel}: invalid cwd '${normalizedCwd}'. '${blockedRoot}' is blocked by config (config.json).`
    );
  }

  if (allowedCwdRoots.length === 0) {
    throw new Error(
      `${taskLabel}: no allowed cwd roots configured. Configure roots via config.json allowedRoots, audit config keys (allowed_root:<path>), or CODEX_POOL_ALLOWED_CWD_ROOTS.`
    );
  }

  const inAllowedRoot = allowedCwdRoots.some((root) => isWithinRoot(normalizedCwd, root));
  if (!inAllowedRoot) {
    throw new Error(
      `${taskLabel}: invalid cwd '${normalizedCwd}'. cwd must match one of the configured allowed roots (current: ${allowedCwdRoots.join(", ")}).`
    );
  }


  let approvalPolicy = task["approval-policy"];
  if (task.sandbox === "danger-full-access" && !ALLOW_DANGER_SANDBOX) {
    throw new Error(
      "danger-full-access sandbox requires CODEX_ALLOW_DANGER_SANDBOX=1 server-side env var"
    );
  }
  if (task.sandbox === "danger-full-access" && approvalPolicy !== "untrusted") {
    console.warn(
      `[codex-delegation] ${taskLabel}: sandbox=danger-full-access requires approval-policy=untrusted; forcing untrusted.`
    );
    approvalPolicy = "untrusted";
  }

  scanPromptForInjection(task.prompt, taskLabel);

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

function buildTaskRecord(task, state, overrides) {
  return {
    invocation_id: state.invocationId,
    batch_id: state.batchId,
    session_id: SESSION_ID,
    parent_task_id: null,
    task_index: state.taskIndex,
    tool_type: "codex",
    project: state.project,
    cwd: task.cwd,
    prompt_slug: state.promptSlug,
    prompt_hash: toPromptHash(task.prompt),
    prompt: null,
    url: null,
    sandbox: task.sandbox,
    approval: task["approval-policy"],
    model: task.model ?? null,
    skip_git_check: task["skip-git-repo-check"] ? 1 : 0,
    started_at: overrides.started_at,
    ended_at: null,
    duration_ms: null,
    exit_code: null,
    status: overrides.status,
    failure_reason: null,
    timed_out: 0,
    output_capped: 0,
    stdout_bytes: 0,
    stderr_bytes: 0,
    output_truncated: null,
    error_text: null,
    redaction_count: 0,
    prompt_tokens_est: state.promptTokensEst,
    response_token_est: null,
    cost_est_usd: null,
  };
}

function buildStoredOutputs(result, promptText, project, promptCap) {
  const failed = !result.success;
  let redactionCount = 0;
  let promptValue = null;
  let outputFullValue = null;
  let errorText = null;

  if (failed || shouldStoreFullPrompt(project)) {
    const redacted = redact(promptText.slice(0, promptCap));
    promptValue = redacted.text;
    redactionCount += redacted.count;
  }

  const redactedOutput = redact(toStoredOutput(result));
  const outputValue = redactedOutput.text;
  redactionCount += redactedOutput.count;

  if (shouldStoreFullOutput(project)) {
    const redacted = redact(toStoredOutputFull(result));
    outputFullValue = redacted.text;
    redactionCount += redacted.count;
  }

  if (failed) {
    const redacted = redact(toStoredError(result));
    errorText = redacted.text;
    redactionCount += redacted.count;
  }

  return { promptValue, outputValue, outputFullValue, errorText, redactionCount };
}

function buildFinalizeUpdate(result, storedOutputs, startedAt) {
  const failed = !result.success;
  return {
    started_at: startedAt,
    ended_at: result.finishedAt,
    duration_ms: result.finishedAt - startedAt,
    exit_code: result.exitCode,
    status: failed ? "failed" : "done",
    failure_reason: toFailureReason(result),
    timed_out: result.timedOut ? 1 : 0,
    output_capped: result.outputCapped ? 1 : 0,
    stdout_bytes: result.stdoutBytes,
    stderr_bytes: result.stderrBytes,
    response_token_est: Math.ceil(result.stdoutBytes / 4),
    prompt: storedOutputs.promptValue,
    output_truncated: storedOutputs.outputValue,
    output_full: storedOutputs.outputFullValue,
    error_text: storedOutputs.errorText,
    redaction_count: storedOutputs.redactionCount,
  };
}

function coerceArgs(args) {
  let coerced = args;
  if (typeof coerced === "string") {
    try {
      coerced = JSON.parse(coerced);
    } catch {}
  }

  if (!coerced || typeof coerced !== "object" || Array.isArray(coerced)) {
    return coerced;
  }

  if (typeof coerced.prompt !== "string") {
    return coerced;
  }

  const promptText = coerced.prompt.trim();
  if (!promptText.startsWith("{") || !promptText.endsWith("}")) {
    return coerced;
  }

  try {
    const parsedPrompt = JSON.parse(promptText);
    if (!parsedPrompt || typeof parsedPrompt !== "object" || Array.isArray(parsedPrompt)) {
      return coerced;
    }
    if (!Object.hasOwn(parsedPrompt, "cwd") && !Object.hasOwn(parsedPrompt, "sandbox")) {
      return coerced;
    }
    return { ...coerced, ...parsedPrompt };
  } catch {
    return coerced;
  }
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
    if (MAX_CODEX_SPAWNS_PER_SESSION > 0 && sessionSpawnCount >= MAX_CODEX_SPAWNS_PER_SESSION) {
      return {
        content: [{ type: "text", text: `[codex error: session spawn cap reached (${sessionSpawnCount}/${MAX_CODEX_SPAWNS_PER_SESSION}). Set MAX_CODEX_SPAWNS_PER_SESSION to increase the limit.]` }],
        isError: true,
      };
    }
    sessionSpawnCount++;
    const parsedTask = TaskSchema.parse(coerceArgs(args));
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
    const promptTokensEst = Math.ceil(task.prompt.length / 4);
    const maxPromptChars = Number.parseInt(getConfig("max_prompt_chars", "4000"), 10);
    const promptCap = Number.isFinite(maxPromptChars) && maxPromptChars > 0 ? maxPromptChars : 4000;
    const statusTasks = [{
      index: 0,
      status: "running",
      promptSlug,
      project,
      startedAt: batchStart,
      endedAt: null,
      durationMs: null,
    }];
    writeCurrentBatchId(batchId, invocationId);

    ensureSession(task.model);
    try {
      insertBatch(batchId, SESSION_ID, 1);
      const taskId = insertTask(
        buildTaskRecord(
          task,
          { invocationId, batchId, promptSlug, project, promptTokensEst, taskIndex: 0 },
          { status: "running", started_at: batchStart }
        )
      );
      autoTag(taskId, promptSlug, task.sandbox);
      writeBatchStatus(batchId, statusTasks);
    } catch (error) {
      logDbError("single task setup failed", error);
    }

    const result = await runCodexContainer(task, 0, batchStart);
    const storedOutputs = buildStoredOutputs(result, task.prompt, project, promptCap);

    let taskFinalizePersisted = false;
    let batchCompleted = false;
    try {
      updateTask(invocationId, buildFinalizeUpdate(result, storedOutputs, result.startedAt));
      taskFinalizePersisted = true;
      statusTasks[0] = {
        ...statusTasks[0],
        status: result.success ? "done" : "failed",
        endedAt: result.finishedAt,
        durationMs: result.finishedAt - result.startedAt,
      };
      writeBatchStatus(batchId, statusTasks);
      completeBatch(batchId, result.success ? 0 : 1, Math.ceil(result.stdoutBytes / 4));
      batchCompleted = true;
      cleanBatchStatus(batchId);
    } catch (error) {
      logDbError("single task finalize failed", error);
      const endedAt = Date.now();
      const startedAt = result.startedAt ?? batchStart;
      const durationMs = endedAt - startedAt;
      if (!taskFinalizePersisted) {
        try {
          updateTask(invocationId, {
            started_at: startedAt,
            ended_at: endedAt,
            duration_ms: durationMs,
            status: "failed",
            failure_reason: "audit_finalize_error",
            error_text: `finalize failure: ${error.message}`,
          });
        } catch (fallbackError) {
          logDbError("single task finalize fallback task update failed", fallbackError);
        }
      }
      if (!batchCompleted) {
        try {
          completeBatch(batchId, 1, Math.ceil((result.stdoutBytes ?? 0) / 4));
        } catch (fallbackError) {
          logDbError("single task finalize fallback batch completion failed", fallbackError);
        }
      }
      cleanBatchStatus(batchId);
    } finally {
      clearCurrentBatchId(invocationId);
    }

    return {
      content: [{ type: "text", text: formatResult(result) }],
      isError: !result.success,
    };
  }

  if (name === "codex_parallel") {
    const { tasks: rawTasks } = ParallelSchema.parse(args);
    if (MAX_CODEX_SPAWNS_PER_SESSION > 0) {
      const remaining = MAX_CODEX_SPAWNS_PER_SESSION - sessionSpawnCount;
      if (remaining <= 0) {
        return {
          content: [{ type: "text", text: `[codex error: session spawn cap reached (${sessionSpawnCount}/${MAX_CODEX_SPAWNS_PER_SESSION}). Set MAX_CODEX_SPAWNS_PER_SESSION to increase the limit.]` }],
          isError: true,
        };
      }
      if (rawTasks.length > remaining) {
        return {
          content: [{ type: "text", text: `[codex error: ${rawTasks.length} tasks requested but only ${remaining} spawns remaining this session (cap: ${MAX_CODEX_SPAWNS_PER_SESSION}). Reduce task count or increase MAX_CODEX_SPAWNS_PER_SESSION.]` }],
          isError: true,
        };
      }
    }
    sessionSpawnCount += rawTasks.length;
    const tasks = rawTasks;
    const normalizedTasks = tasks.map((task, i) => {
      const taskWithApprovalPolicy = {
        ...task,
        "approval-policy": task["approval-policy"] ?? "on-failure",
      };
      return normalizeTask(taskWithApprovalPolicy, `codex_parallel task ${i + 1}`);
    });
    const invocationId = `${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const batchId = randomUUID();
    const batchStart = Date.now();
    const maxPromptChars = Number.parseInt(getConfig("max_prompt_chars", "4000"), 10);
    const promptCap = Number.isFinite(maxPromptChars) && maxPromptChars > 0 ? maxPromptChars : 4000;
    writeCurrentBatchId(batchId, invocationId);
    const taskStates = normalizedTasks.map((task, index) => ({
      index,
      invocationId: randomUUID(),
      promptSlug: toPromptSlug(task.prompt),
      project: path.basename(task.cwd),
      status: "queued",
      startedAt: null,
      endedAt: null,
      durationMs: null,
      promptTokensEst: Math.ceil(task.prompt.length / 4),
    }));

    ensureSession(normalizedTasks[0]?.model);
    try {
      insertBatch(batchId, SESSION_ID, normalizedTasks.length);
      for (const state of taskStates) {
        const sourceTask = normalizedTasks[state.index];
        const taskId = insertTask(
          buildTaskRecord(
            sourceTask,
            {
              invocationId: state.invocationId,
              batchId,
              promptSlug: state.promptSlug,
              project: state.project,
              promptTokensEst: state.promptTokensEst,
              taskIndex: state.index,
            },
            { status: "queued", started_at: null }
          )
        );
        autoTag(taskId, state.promptSlug, sourceTask.sandbox);
      }
      writeBatchStatus(batchId, taskStates);
    } catch (error) {
      logDbError("parallel setup failed", error);
    }

    // Fan out — all containers start immediately
    const settledResults = await Promise.allSettled(
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
          const storedOutputs = buildStoredOutputs(result, task.prompt, state.project, promptCap);
          state.status = result.success ? "done" : "failed";
          state.startedAt = state.startedAt ?? result.startedAt;
          state.endedAt = result.finishedAt;
          state.durationMs = result.finishedAt - state.startedAt;

          try {
            updateTask(state.invocationId, buildFinalizeUpdate(result, storedOutputs, state.startedAt));
            writeBatchStatus(batchId, taskStates);
          } catch (error) {
            logDbError(`parallel completion update failed (task ${i + 1})`, error);
          }
          return result;
        })
      )
    );

    try {
      const failedCount = settledResults.filter((settled) => {
        if (settled.status === "rejected") return true;
        return !settled.value.success;
      }).length;
      const totalTokens = settledResults.reduce((sum, settled) => {
        if (settled.status === "rejected") return sum;
        return sum + Math.ceil((settled.value.stdoutBytes ?? 0) / 4);
      }, 0);
      completeBatch(batchId, failedCount, totalTokens);
      cleanBatchStatus(batchId);
    } catch (error) {
      logDbError("parallel batch completion failed", error);
    } finally {
      clearCurrentBatchId(invocationId);
    }

    const results = settledResults.map((settled, index) => {
      const state = taskStates[index];
      if (settled.status === "fulfilled") {
        return {
          status: "fulfilled",
          taskIndex: index,
          taskId: state?.invocationId ?? null,
          ...settled.value,
        };
      }
      let message;
      if (settled.reason instanceof Error) {
        message = settled.reason.message;
      } else if (typeof settled.reason === "string") {
        message = settled.reason;
      } else {
        try {
          message = JSON.stringify(settled.reason);
        } catch {
          message = String(settled.reason);
        }
      }
      return {
        status: "rejected",
        taskIndex: index,
        taskId: state?.invocationId ?? null,
        error: message || "Unknown error",
      };
    });

    const succeededCount = results.filter((r) => r.status === "fulfilled").length;
    const summary = `${succeededCount}/${results.length} tasks succeeded`;
    return {
      content: [{ type: "text", text: `${summary}\n${JSON.stringify(results, null, 2)}` }],
      isError: false,
    };
  }

  throw new Error(`Unknown tool: ${name}`);
});

// ── Start ───────────────────────────────────────────────────────────────────

process.on("unhandledRejection", (error) => {
  console.error("[codex-delegation] unhandledRejection", error);
  process.exit(1);
});

process.on("uncaughtException", (error) => {
  console.error("[codex-delegation] uncaughtException", error);
  process.exit(1);
});

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
