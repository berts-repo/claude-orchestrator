import fs from "fs";
import { homedir } from "os";
import path from "path";
import { createRequire } from "module";

const require = createRequire(import.meta.url);

const CLAUDE_DIR = path.join(homedir(), ".claude");
export const DB_PATH = path.join(CLAUDE_DIR, "audit.db");
const TMP_DIR = path.join(CLAUDE_DIR, "tmp");
function currentBatchIdPath(invocationId) {
  return path.join(
    TMP_DIR,
    invocationId ? `current-batch-${invocationId}` : "current-batch-id"
  );
}

let db = null;
let statements = null;

function initSchema(conn) {
  conn.exec(`
    PRAGMA journal_mode=WAL;
    PRAGMA synchronous=NORMAL;

    CREATE TABLE IF NOT EXISTS sessions (
      id           TEXT PRIMARY KEY,
      started_at   INTEGER,
      ended_at     INTEGER,
      claude_model TEXT,
      notes        TEXT
    );

    CREATE TABLE IF NOT EXISTS batches (
      id           TEXT PRIMARY KEY,
      session_id   TEXT REFERENCES sessions(id),
      started_at   INTEGER,
      ended_at     INTEGER,
      task_count   INTEGER,
      failed_count INTEGER,
      total_tokens INTEGER
    );

    CREATE TABLE IF NOT EXISTS tasks (
      id               INTEGER PRIMARY KEY,
      invocation_id    TEXT UNIQUE,
      batch_id         TEXT REFERENCES batches(id),
      session_id       TEXT REFERENCES sessions(id),
      parent_task_id   INTEGER REFERENCES tasks(id),
      task_index       INTEGER,
      tool_type        TEXT,
      project          TEXT,
      cwd              TEXT,
      prompt_slug      TEXT,
      prompt_hash      TEXT,
      prompt           TEXT,
      url              TEXT,
      sandbox          TEXT,
      approval         TEXT,
      model            TEXT,
      skip_git_check   INTEGER,
      started_at       INTEGER,
      ended_at         INTEGER,
      duration_ms      INTEGER,
      exit_code        INTEGER,
      status           TEXT,
      failure_reason   TEXT,
      timed_out        INTEGER,
      output_capped    INTEGER,
      stdout_bytes     INTEGER,
      stderr_bytes     INTEGER,
      output_truncated TEXT,
      error_text       TEXT,
      redaction_count  INTEGER DEFAULT 0,
      prompt_tokens_est INTEGER,
      response_token_est INTEGER,
      cost_est_usd     REAL
    );

    CREATE TABLE IF NOT EXISTS task_tags (
      task_id    INTEGER REFERENCES tasks(id),
      tag        TEXT,
      tag_source TEXT,
      PRIMARY KEY (task_id, tag)
    );

    CREATE TABLE IF NOT EXISTS tags (
      name        TEXT PRIMARY KEY,
      description TEXT,
      color       TEXT
    );

    CREATE TABLE IF NOT EXISTS config (
      key        TEXT PRIMARY KEY,
      value      TEXT,
      updated_at TEXT
    );

    CREATE TABLE IF NOT EXISTS security_events (
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id      TEXT,
      timestamp_ms    INTEGER NOT NULL,
      level           TEXT NOT NULL,
      hook            TEXT NOT NULL,
      tool            TEXT NOT NULL,
      action          TEXT NOT NULL DEFAULT 'deny',
      severity        TEXT NOT NULL,
      pattern_matched TEXT,
      command_preview TEXT,
      cwd             TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_security_events_ts      ON security_events(timestamp_ms);
    CREATE INDEX IF NOT EXISTS idx_security_events_session ON security_events(session_id);
    CREATE INDEX IF NOT EXISTS idx_security_events_hook    ON security_events(hook);
    CREATE INDEX IF NOT EXISTS idx_security_events_sev     ON security_events(severity);

    CREATE TABLE IF NOT EXISTS web_tasks (
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id      TEXT,
      invocation_key  TEXT NOT NULL,
      tool_name       TEXT NOT NULL,
      prompt          TEXT,
      prompt_hash     TEXT,
      status          TEXT NOT NULL DEFAULT 'started',
      started_at      INTEGER NOT NULL,
      ended_at        INTEGER,
      duration_ms     INTEGER,
      error_text      TEXT,
      cwd             TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_web_tasks_started    ON web_tasks(started_at);
    CREATE INDEX IF NOT EXISTS idx_web_tasks_session    ON web_tasks(session_id);
    CREATE INDEX IF NOT EXISTS idx_web_tasks_status     ON web_tasks(status);
    CREATE INDEX IF NOT EXISTS idx_web_tasks_tool       ON web_tasks(tool_name);
    CREATE INDEX IF NOT EXISTS idx_web_tasks_inv_key    ON web_tasks(invocation_key);

    CREATE INDEX IF NOT EXISTS idx_tasks_project    ON tasks(project);
    CREATE INDEX IF NOT EXISTS idx_tasks_started    ON tasks(started_at);
    CREATE INDEX IF NOT EXISTS idx_tasks_status     ON tasks(status);
    CREATE INDEX IF NOT EXISTS idx_tasks_session    ON tasks(session_id);
    CREATE INDEX IF NOT EXISTS idx_tasks_parent     ON tasks(parent_task_id);
    CREATE INDEX IF NOT EXISTS idx_tasks_invocation ON tasks(invocation_id);
    CREATE INDEX IF NOT EXISTS idx_task_tags_tag    ON task_tags(tag);
  `);
}

export function migrateSchema(conn) {
  const cols = new Set(conn.prepare("PRAGMA table_info(tasks)").all().map((c) => c.name));
  if (!cols.has("output_full")) {
    conn.exec("ALTER TABLE tasks ADD COLUMN output_full TEXT");
  }
  if (cols.has("token_est") && !cols.has("response_token_est")) {
    try {
      conn.exec("ALTER TABLE tasks RENAME COLUMN token_est TO response_token_est");
    } catch {
      try {
        conn.exec("ALTER TABLE tasks ADD COLUMN response_token_est INTEGER");
      } catch {}
      conn.exec(`
        UPDATE tasks
        SET response_token_est = COALESCE(response_token_est, token_est)
        WHERE token_est IS NOT NULL
      `);
    }
  }
  try {
    conn.exec("ALTER TABLE tasks ADD COLUMN prompt_tokens_est INTEGER");
  } catch {}
  try {
    conn.exec("ALTER TABLE tasks ADD COLUMN response_token_est INTEGER");
  } catch {}
  try {
    conn.exec("ALTER TABLE tasks DROP COLUMN token_est");
  } catch {}
  // Ensure config table has updated_at column
  const configCols = new Set(conn.prepare("PRAGMA table_info(config)").all().map((c) => c.name));
  if (!configCols.has("updated_at")) {
    conn.exec("ALTER TABLE config ADD COLUMN updated_at TEXT");
  }
}

function initDefaults(conn) {
  const count = conn.prepare("SELECT COUNT(*) AS n FROM config").get().n;
  if (count > 0) return;
  const insert = conn.prepare("INSERT INTO config (key, value) VALUES (?, ?)");
  const rows = [
    ["prompt_full_days", "7"],
    ["output_days", "3"],
    ["output_full_days", "3"],
    ["row_days", "365"],
    ["max_prompt_chars", "4000"],
    ["max_db_mb", "100"],
  ];
  const tx = conn.transaction((values) => {
    for (const [key, value] of values) insert.run(key, value);
  });
  tx(rows);
}

function setupStatements(conn) {
  return {
    upsertSession: conn.prepare(`
      INSERT OR IGNORE INTO sessions (id, started_at, claude_model)
      VALUES (@id, @started_at, @claude_model)
    `),
    insertBatch: conn.prepare(`
      INSERT INTO batches (id, session_id, started_at, task_count, failed_count, total_tokens)
      VALUES (@id, @session_id, @started_at, @task_count, 0, 0)
    `),
    insertTask: conn.prepare(`
      INSERT INTO tasks (
        invocation_id, batch_id, session_id, parent_task_id, task_index, tool_type,
        project, cwd, prompt_slug, prompt_hash, prompt, url, sandbox, approval, model,
        skip_git_check, started_at, ended_at, duration_ms, exit_code, status, failure_reason,
        timed_out, output_capped, stdout_bytes, stderr_bytes, output_truncated, output_full, error_text,
        redaction_count, prompt_tokens_est, response_token_est, cost_est_usd
      ) VALUES (
        @invocation_id, @batch_id, @session_id, @parent_task_id, @task_index, @tool_type,
        @project, @cwd, @prompt_slug, @prompt_hash, @prompt, @url, @sandbox, @approval, @model,
        @skip_git_check, @started_at, @ended_at, @duration_ms, @exit_code, @status, @failure_reason,
        @timed_out, @output_capped, @stdout_bytes, @stderr_bytes, @output_truncated, @output_full, @error_text,
        @redaction_count, @prompt_tokens_est, @response_token_est, @cost_est_usd
      )
    `),
    updateTask: conn.prepare(`
      UPDATE tasks SET
        batch_id = COALESCE(@batch_id, batch_id),
        session_id = COALESCE(@session_id, session_id),
        parent_task_id = COALESCE(@parent_task_id, parent_task_id),
        task_index = COALESCE(@task_index, task_index),
        tool_type = COALESCE(@tool_type, tool_type),
        project = COALESCE(@project, project),
        cwd = COALESCE(@cwd, cwd),
        prompt_slug = COALESCE(@prompt_slug, prompt_slug),
        prompt_hash = COALESCE(@prompt_hash, prompt_hash),
        prompt = COALESCE(@prompt, prompt),
        url = COALESCE(@url, url),
        sandbox = COALESCE(@sandbox, sandbox),
        approval = COALESCE(@approval, approval),
        model = COALESCE(@model, model),
        skip_git_check = COALESCE(@skip_git_check, skip_git_check),
        started_at = COALESCE(@started_at, started_at),
        ended_at = COALESCE(@ended_at, ended_at),
        duration_ms = COALESCE(@duration_ms, duration_ms),
        exit_code = COALESCE(@exit_code, exit_code),
        status = COALESCE(@status, status),
        failure_reason = COALESCE(@failure_reason, failure_reason),
        timed_out = COALESCE(@timed_out, timed_out),
        output_capped = COALESCE(@output_capped, output_capped),
        stdout_bytes = COALESCE(@stdout_bytes, stdout_bytes),
        stderr_bytes = COALESCE(@stderr_bytes, stderr_bytes),
        output_truncated = COALESCE(@output_truncated, output_truncated),
        output_full = COALESCE(@output_full, output_full),
        error_text = COALESCE(@error_text, error_text),
        redaction_count = COALESCE(@redaction_count, redaction_count),
        prompt_tokens_est = COALESCE(@prompt_tokens_est, prompt_tokens_est),
        response_token_est = COALESCE(@response_token_est, response_token_est),
        cost_est_usd = COALESCE(@cost_est_usd, cost_est_usd)
      WHERE invocation_id = @invocation_id
    `),
    completeBatch: conn.prepare(`
      UPDATE batches
      SET ended_at = @ended_at, failed_count = @failed_count, total_tokens = @total_tokens
      WHERE id = @id
    `),
    getConfig: conn.prepare("SELECT value FROM config WHERE key = ?"),
    getAllConfig: conn.prepare("SELECT key, value FROM config"),
    insertTaskTag: conn.prepare(`
      INSERT OR IGNORE INTO task_tags (task_id, tag, tag_source)
      VALUES (@task_id, @tag, @tag_source)
    `),
  };
}

function ensurePrivatePath(pathname, mode) {
  if (!fs.existsSync(pathname)) return;
  fs.chmodSync(pathname, mode);
}

function parseRetentionInt(rawValue, fallback) {
  const parsed = Number.parseInt(String(rawValue), 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

export function runRetentionCleanup() {
  if (!dbReady()) return;
  try {
    const now = Date.now();

    const promptFullDays = parseRetentionInt(getConfig("prompt_full_days", "7"), 7);
    const outputDays = parseRetentionInt(getConfig("output_days", "3"), 3);
    const outputFullDays = parseRetentionInt(getConfig("output_full_days", "3"), 3);
    const rowDays = parseRetentionInt(getConfig("row_days", "365"), 365);
    const maxDbMb = parseRetentionInt(getConfig("max_db_mb", "100"), 100);

    const promptCutoff = now - promptFullDays * 86400 * 1000;
    const outputCutoff = now - outputDays * 86400 * 1000;
    const outputFullCutoff = now - outputFullDays * 86400 * 1000;
    const rowCutoff = now - rowDays * 86400 * 1000;

    const nullPromptStmt = db.prepare(`
      UPDATE tasks
      SET prompt = NULL
      WHERE started_at < ? AND prompt IS NOT NULL
    `);
    const nullOutputStmt = db.prepare(`
      UPDATE tasks
      SET output_truncated = NULL
      WHERE started_at < ? AND output_truncated IS NOT NULL
    `);
    const nullFullOutputStmt = db.prepare(`
      UPDATE tasks
      SET output_full = NULL
      WHERE started_at < ? AND output_full IS NOT NULL
    `);
    const deleteOldTasksStmt = db.prepare(`
      DELETE FROM tasks
      WHERE started_at < ?
    `);
    const deleteOldSecurityEventsStmt = db.prepare(`
      DELETE FROM security_events
      WHERE timestamp_ms < ?
    `);
    const deleteOldWebTasksStmt = db.prepare(`
      DELETE FROM web_tasks
      WHERE started_at < ?
    `);
    const deleteOldBatchesStmt = db.prepare(`
      DELETE FROM batches
      WHERE ended_at < ?
        AND id NOT IN (
          SELECT DISTINCT batch_id FROM tasks WHERE batch_id IS NOT NULL
        )
    `);
    const deleteOldSessionsStmt = db.prepare(`
      DELETE FROM sessions
      WHERE started_at < ?
        AND id NOT IN (
          SELECT DISTINCT session_id FROM tasks WHERE session_id IS NOT NULL
        )
    `);
    const trimOldestTasksStmt = db.prepare(`
      DELETE FROM tasks
      WHERE id IN (
        SELECT id FROM tasks
        ORDER BY started_at ASC
        LIMIT ?
      )
    `);
    const vacuumStmt = db.prepare("VACUUM");

    const nulledPrompts = nullPromptStmt.run(promptCutoff).changes;
    const nulledOutputs = nullOutputStmt.run(outputCutoff).changes;
    const nulledFullOutputs = nullFullOutputStmt.run(outputFullCutoff).changes;
    let deletedTasks = deleteOldTasksStmt.run(rowCutoff).changes;
    deleteOldSecurityEventsStmt.run(rowCutoff);
    deleteOldWebTasksStmt.run(rowCutoff);
    deleteOldBatchesStmt.run(rowCutoff);
    deleteOldSessionsStmt.run(rowCutoff);

    const maxDbBytes = maxDbMb * 1024 * 1024;
    for (let i = 0; i < 5; i += 1) {
      let sizeBytes = 0;
      try {
        sizeBytes = fs.statSync(DB_PATH).size;
      } catch {
        break;
      }
      if (sizeBytes <= maxDbBytes) break;
      const trimmed = trimOldestTasksStmt.run(500).changes;
      if (trimmed === 0) break;
      deletedTasks += trimmed;
      vacuumStmt.run();
    }

    console.error(
      `[audit-db] retention: nulled ${nulledPrompts} prompts, ${nulledOutputs} outputs, ${nulledFullOutputs} full outputs, deleted ${deletedTasks} tasks`
    );
  } catch (error) {
    console.error(`[audit-db] retention cleanup failed: ${error.message}`);
  }
}

try {
  fs.mkdirSync(CLAUDE_DIR, { recursive: true, mode: 0o700 });
  fs.mkdirSync(TMP_DIR, { recursive: true, mode: 0o700 });
  ensurePrivatePath(TMP_DIR, 0o700);

  const BetterSqlite3 = require("better-sqlite3");
  db = new BetterSqlite3(DB_PATH);
  ensurePrivatePath(DB_PATH, 0o600);
  ensurePrivatePath(`${DB_PATH}-wal`, 0o600);
  ensurePrivatePath(`${DB_PATH}-shm`, 0o600);

  initSchema(db);
  migrateSchema(db);
  initDefaults(db);
  statements = setupStatements(db);
  runRetentionCleanup();
} catch (error) {
  console.warn(`[audit] SQLite logging disabled: ${error.message}`);
}

export { db };

function dbReady() {
  return db !== null && statements !== null;
}

export function redact(text) {
  if (text === null || text === undefined) return { text, count: 0 };
  if (text === "") return { text: "", count: 0 };
  let count = 0;
  let redactedText = String(text);

  const patterns = [
    /sk-[A-Za-z0-9]{20,}/g,
    /\bBearer [A-Za-z0-9\-._~+/]{20,}/g,
    /ghp_[A-Za-z0-9]{36}/g,
    /AKIA[A-Z0-9]{16}/g,
    /\bAuthorization:\s*Basic\s+[A-Za-z0-9+/=]{8,}/gi,
    /-----BEGIN [A-Z ]+-----[\s\S]+?-----END [A-Z ]+-----/g,
  ];

  for (const pattern of patterns) {
    redactedText = redactedText.replace(pattern, () => {
      count += 1;
      return "[REDACTED]";
    });
  }

  redactedText = redactedText.replace(
    /\b(API_KEY|SECRET|TOKEN|PASSWORD|PASSWD)\s*=\s*("[^"\n]*"|'[^'\n]*'|[^\s\n]+)/gi,
    (_, key) => {
      count += 1;
      return `${key}=[REDACTED]`;
    }
  );

  return { text: redactedText, count };
}

export function upsertSession(sessionId, model) {
  if (!dbReady()) return;
  statements.upsertSession.run({
    id: sessionId,
    started_at: Date.now(),
    claude_model: model ?? null,
  });
}

export function insertBatch(batchId, sessionId, taskCount) {
  if (!dbReady()) return;
  statements.insertBatch.run({
    id: batchId,
    session_id: sessionId,
    started_at: Date.now(),
    task_count: taskCount,
  });
}

export function insertTask(fields) {
  if (!dbReady()) return null;
  const promptRedaction = redact(fields.prompt);
  const outputRedaction = redact(fields.output_truncated);
  const outputFullRedaction = redact(fields.output_full);
  const errorRedaction = redact(fields.error_text);
  const providedRedactionCount = Number(fields.redaction_count ?? 0);
  const safeProvidedRedactionCount = Number.isFinite(providedRedactionCount)
    ? providedRedactionCount
    : 0;
  const totalRedactionCount =
    safeProvidedRedactionCount +
    promptRedaction.count +
    outputRedaction.count +
    outputFullRedaction.count +
    errorRedaction.count;

  const result = statements.insertTask.run({
    invocation_id: fields.invocation_id,
    batch_id: fields.batch_id ?? null,
    session_id: fields.session_id ?? null,
    parent_task_id: fields.parent_task_id ?? null,
    task_index: fields.task_index ?? null,
    tool_type: fields.tool_type ?? null,
    project: fields.project ?? null,
    cwd: fields.cwd ?? null,
    prompt_slug: fields.prompt_slug ?? null,
    prompt_hash: fields.prompt_hash ?? null,
    prompt: promptRedaction.text ?? null,
    url: fields.url ?? null,
    sandbox: fields.sandbox ?? null,
    approval: fields.approval ?? null,
    model: fields.model ?? null,
    skip_git_check: fields.skip_git_check ?? null,
    started_at: fields.started_at ?? null,
    ended_at: fields.ended_at ?? null,
    duration_ms: fields.duration_ms ?? null,
    exit_code: fields.exit_code ?? null,
    status: fields.status ?? null,
    failure_reason: fields.failure_reason ?? null,
    timed_out: fields.timed_out ?? null,
    output_capped: fields.output_capped ?? null,
    stdout_bytes: fields.stdout_bytes ?? null,
    stderr_bytes: fields.stderr_bytes ?? null,
    output_truncated: outputRedaction.text ?? null,
    output_full: outputFullRedaction.text ?? null,
    error_text: errorRedaction.text ?? null,
    redaction_count: totalRedactionCount,
    prompt_tokens_est: fields.prompt_tokens_est ?? null,
    response_token_est: fields.response_token_est ?? null,
    cost_est_usd: fields.cost_est_usd ?? null,
  });
  return Number(result.lastInsertRowid);
}

export function updateTask(invocationId, fields) {
  if (!dbReady()) return;
  const promptRedaction = redact(fields.prompt);
  const outputRedaction = redact(fields.output_truncated);
  const outputFullRedaction = redact(fields.output_full);
  const errorRedaction = redact(fields.error_text);
  const incrementalRedactionCount =
    promptRedaction.count +
    outputRedaction.count +
    outputFullRedaction.count +
    errorRedaction.count;

  let mergedRedactionCount = fields.redaction_count;
  if (incrementalRedactionCount > 0) {
    const providedRedactionCount = Number(fields.redaction_count ?? 0);
    const safeProvidedRedactionCount = Number.isFinite(providedRedactionCount)
      ? providedRedactionCount
      : 0;
    mergedRedactionCount = safeProvidedRedactionCount + incrementalRedactionCount;
  }

  statements.updateTask.run({
    invocation_id: invocationId,
    batch_id: fields.batch_id,
    session_id: fields.session_id,
    parent_task_id: fields.parent_task_id,
    task_index: fields.task_index,
    tool_type: fields.tool_type,
    project: fields.project,
    cwd: fields.cwd,
    prompt_slug: fields.prompt_slug,
    prompt_hash: fields.prompt_hash,
    prompt: promptRedaction.text,
    url: fields.url,
    sandbox: fields.sandbox,
    approval: fields.approval,
    model: fields.model,
    skip_git_check: fields.skip_git_check,
    started_at: fields.started_at,
    ended_at: fields.ended_at,
    duration_ms: fields.duration_ms,
    exit_code: fields.exit_code,
    status: fields.status,
    failure_reason: fields.failure_reason,
    timed_out: fields.timed_out,
    output_capped: fields.output_capped,
    stdout_bytes: fields.stdout_bytes,
    stderr_bytes: fields.stderr_bytes,
    output_truncated: outputRedaction.text,
    output_full: outputFullRedaction.text,
    error_text: errorRedaction.text,
    redaction_count: mergedRedactionCount,
    prompt_tokens_est: fields.prompt_tokens_est,
    response_token_est: fields.response_token_est,
    cost_est_usd: fields.cost_est_usd,
  });
}

export function completeBatch(batchId, failedCount, totalTokens) {
  if (!dbReady()) return;
  statements.completeBatch.run({
    id: batchId,
    ended_at: Date.now(),
    failed_count: failedCount,
    total_tokens: totalTokens,
  });
}

export function getConfig(key, defaultValue) {
  if (!dbReady()) return defaultValue;
  const row = statements.getConfig.get(key);
  return row?.value ?? defaultValue;
}

export function getAllowedRoots() {
  if (!dbReady()) return [];
  const rows = statements.getAllConfig.all();
  return rows
    .filter((row) => row.key.startsWith("allowed_root:"))
    .map((row) => row.key.slice("allowed_root:".length));
}

export function autoTag(taskId, promptSlug, sandbox) {
  if (!dbReady() || !taskId) return;
  const tags = [];
  if (sandbox === "read-only") tags.push("read-only");
  if (/security|audit|vuln|pentest/i.test(promptSlug)) tags.push("security-audit");
  if (/refactor|rename|restructure/i.test(promptSlug)) tags.push("refactor");
  if (/test|spec|coverage/i.test(promptSlug)) tags.push("test-gen");
  if (/doc|comment|readme/i.test(promptSlug)) tags.push("docs");

  for (const tag of new Set(tags)) {
    statements.insertTaskTag.run({
      task_id: taskId,
      tag,
      tag_source: "auto",
    });
  }
}

export function shouldStoreFullPrompt(project) {
  if (process.env.AUDIT_LOG_PROMPTS === "1") return true;
  if (getConfig("full_prompt_storage", "false") === "true") return true;
  if (getConfig(`full_prompt_project:${project}`, "false") === "true") return true;
  if (getConfig(`prompt_storage_project:${project}`, "slug-only") === "full") return true;
  if (getConfig("prompt_storage", "slug-only") === "full") return true;
  return false;
}

export function shouldStoreFullOutput(project) {
  if (process.env.AUDIT_LOG_OUTPUT === "1") return true;
  if (getConfig("full_output_storage", "false") === "true") return true;
  if (getConfig(`full_output_project:${project}`, "false") === "true") return true;
  if (getConfig(`output_storage_project:${project}`, "slug-only") === "full") return true;
  if (getConfig("output_storage", "slug-only") === "full") return true;
  return false;
}

export function writeBatchStatus(batchId, tasks) {
  try {
    fs.mkdirSync(TMP_DIR, { recursive: true, mode: 0o700 });
    ensurePrivatePath(TMP_DIR, 0o700);
    const finalPath = path.join(TMP_DIR, `${batchId}.json`);
    const tempPath = `${finalPath}.tmp.${process.pid}.${Math.random().toString(36).slice(2)}`;
    const payload = {
      batchId,
      updatedAt: Date.now(),
      tasks: tasks.map((task) => ({
        index: task.index,
        status: task.status,
        promptSlug: task.promptSlug,
        project: task.project,
        startedAt: task.startedAt ?? null,
        endedAt: task.endedAt ?? null,
        durationMs: task.durationMs ?? null,
      })),
    };
    fs.writeFileSync(tempPath, JSON.stringify(payload), { mode: 0o600 });
    fs.renameSync(tempPath, finalPath);
    ensurePrivatePath(finalPath, 0o600);
  } catch (error) {
    console.error("Failed to write batch status", { batchId, error });
    throw error;
  }
}

export function cleanBatchStatus(batchId) {
  try {
    fs.unlinkSync(path.join(TMP_DIR, `${batchId}.json`));
  } catch {}
}

export function writeCurrentBatchId(batchId, invocationId) {
  try {
    fs.mkdirSync(TMP_DIR, { recursive: true, mode: 0o700 });
    ensurePrivatePath(TMP_DIR, 0o700);
    const finalPath = currentBatchIdPath(invocationId);
    const tempPath = `${finalPath}.tmp`;
    fs.writeFileSync(tempPath, batchId, { mode: 0o600 });
    fs.renameSync(tempPath, finalPath);
    ensurePrivatePath(finalPath, 0o600);
  } catch {}
}

export function clearCurrentBatchId(invocationId) {
  try {
    fs.unlinkSync(currentBatchIdPath(invocationId));
  } catch {}
}
