# Delegation Audit DB + Live Overlay Plan

## Goal
Replace existing JSONL hook-based logging with a SQLite audit DB that provides real-time
task visibility, cross-session querying, and project history — while keeping stored data
minimal and safe by default.

## Architecture

### Components
1. **SQLite DB** at `~/.claude/delegation.db` (`0600`) — cross-session audit trail
2. **Per-batch JSON status files** at `~/.claude/tmp/{random}.json` (`0700` dir) — live monitoring source
3. **Watcher script** `scripts/watch-tasks.sh` — renders live status table
4. **Pre/Post hooks** — auto-launches/kills overlay window on delegate calls
5. **PostToolUse hook** for web delegate — logs Gemini/web calls to same DB
6. **`/audit` skill** — configure retention, per-project prompt storage, and query the DB
7. **Skills updated** — /monitor and /summarize query the DB; /log-cleanup retired (DB handles retention)
8. **JSONL logs retired** once DB is stable (existing hooks removed)

### Data Flow
```
codex_parallel call
  → PreToolUse hook launches overlay window (reads ~/.claude/tmp status file)
  → server.js writes ~/.claude/tmp/{batchId}.json (queued→running→done)
  → watcher polls file, renders live table
  → on completion, server.js flushes metadata to SQLite (full prompt only on failure)
  → PostToolUse hook kills overlay
```

## Storage Tiers (security model)

Prompts and outputs can contain secrets. Default to minimal storage:

| Column | Default | When full content stored |
|--------|---------|--------------------------|
| `prompt_slug` | Always (80 chars) | — |
| `prompt_hash` | Always (SHA-256) | — |
| `prompt` | **Never by default** | Failure only, or `DELEGATION_LOG_PROMPTS=1` |
| `output_truncated` | **Never by default** | Failure only, or `DELEGATION_LOG_OUTPUT=1` |
| `error_text` | **Always on failure** | stderr truncated to 2KB, redacted |
| `redaction_count` | Always | — |

Redaction pass applied before any text is written: strips API keys (`sk-*`, `Bearer *`),
private key blocks, `.env`-style `KEY=VALUE` lines, and high-entropy strings (>50 bits).

## Schema

```sql
-- Tracks Claude sessions (one row per conversation)
CREATE TABLE sessions (
  id           TEXT PRIMARY KEY,  -- uuid generated at server start
  started_at   INTEGER,
  ended_at     INTEGER,           -- updated on graceful shutdown
  claude_model TEXT,              -- e.g. claude-sonnet-4-6
  notes        TEXT               -- optional, set via skill
);

-- Groups parallel tasks launched together
CREATE TABLE batches (
  id           TEXT PRIMARY KEY,  -- uuid
  session_id   TEXT REFERENCES sessions(id),
  started_at   INTEGER,
  ended_at     INTEGER,
  task_count   INTEGER,
  failed_count INTEGER,
  total_tokens INTEGER            -- sum of token_est across tasks
);

-- Every delegated task (codex or web)
CREATE TABLE tasks (
  id               INTEGER PRIMARY KEY,
  invocation_id    TEXT UNIQUE,   -- uuid per tool call, avoids hash collisions
  batch_id         TEXT REFERENCES batches(id),
  session_id       TEXT REFERENCES sessions(id),
  parent_task_id   INTEGER REFERENCES tasks(id), -- for nested delegation
  task_index       INTEGER,
  tool_type        TEXT,    -- 'codex' | 'web-fetch' | 'web-search'
  project          TEXT,    -- basename(cwd)
  cwd              TEXT,
  prompt_slug      TEXT,    -- first 80 chars, always stored
  prompt_hash      TEXT,    -- SHA-256 of full prompt
  prompt           TEXT,    -- NULL by default; only on failure or opt-in
  url              TEXT,    -- for web calls
  sandbox          TEXT,
  approval         TEXT,
  model            TEXT,    -- codex model override if set
  skip_git_check   INTEGER, -- bool: --skip-git-repo-check was passed
  started_at       INTEGER, -- unix epoch ms
  ended_at         INTEGER,
  duration_ms      INTEGER,
  exit_code        INTEGER,
  status           TEXT,    -- queued/running/done/failed
  failure_reason   TEXT,    -- exit_nonzero|timeout|output_capped|spawn_error
  timed_out        INTEGER, -- bool
  output_capped    INTEGER, -- bool: output was truncated by server
  stdout_bytes     INTEGER,
  stderr_bytes     INTEGER,
  output_truncated TEXT,    -- NULL by default; first 2KB on failure or opt-in
  error_text       TEXT,    -- stderr on failure, truncated+redacted to 2KB
  redaction_count  INTEGER DEFAULT 0,
  token_est        INTEGER, -- prompt char count / 4
  cost_est_usd     REAL     -- estimated cost based on model + tokens
);

-- Many-to-many tags on tasks
CREATE TABLE task_tags (
  task_id    INTEGER REFERENCES tasks(id),
  tag        TEXT,
  tag_source TEXT,  -- 'auto' | 'manual' | 'rule'
  PRIMARY KEY (task_id, tag)
);

-- All known tags (for autocomplete/listing)
CREATE TABLE tags (
  name        TEXT PRIMARY KEY,
  description TEXT,
  color       TEXT  -- hex color for display
);

CREATE TABLE config (
  key   TEXT PRIMARY KEY,
  value TEXT
);
-- Default config values:
-- prompt_full_days    = 7    (how long to keep full prompt text if stored)
-- output_days         = 3    (how long to keep output text if stored)
-- row_days            = 365  (how long to keep task rows)
-- max_prompt_chars    = 4000 (truncation cap when storing full prompt)
-- max_db_mb           = 100  (hard size cap, trims oldest rows)

-- Indexes
CREATE INDEX idx_tasks_project      ON tasks(project);
CREATE INDEX idx_tasks_started      ON tasks(started_at);
CREATE INDEX idx_tasks_status       ON tasks(status);
CREATE INDEX idx_tasks_session      ON tasks(session_id);
CREATE INDEX idx_tasks_parent       ON tasks(parent_task_id);
CREATE INDEX idx_tasks_invocation   ON tasks(invocation_id);
CREATE INDEX idx_task_tags_tag      ON task_tags(tag);
```

## Prompt Storage Opt-In

Default is `slug_only` for all projects. Full prompt storage is opt-in via three tiers:

### Tier 1 — Per-project (persistent, recommended for trusted projects)
Config table entries keyed by project name:
```sql
INSERT INTO config VALUES ('prompt_storage_project:parrot', 'full');
INSERT INTO config VALUES ('prompt_storage_project:claude-orchestrator', 'full');
```
Managed via `/audit` skill:
```
/audit set-project parrot prompt-storage full        ← enable full prompts for project
/audit set-project parrot prompt-storage slug-only   ← revert to default
/audit list-projects                                 ← show all per-project overrides
/audit set prompt-full-days 30                       ← change global retention
/audit status                                        ← show current config + DB stats
```

### Tier 2 — Session opt-in (env var, one terminal session)
```bash
DELEGATION_LOG_PROMPTS=1 claude          # store full prompts this session
DELEGATION_LOG_OUTPUT=1 claude           # store full output this session
DELEGATION_LOG_PROMPTS=1 DELEGATION_LOG_OUTPUT=1 claude   # both
```
Gone when terminal closes. Good for ad-hoc audit sessions.

### Tier 3 — Failure automatic (no opt-in needed)
On any failed task, full prompt is always stored regardless of config.
This is the most common debug need — requires zero action.

### Server lookup order at write time
1. `prompt_storage_project:{project}` in config table
2. Global `prompt_storage` in config table
3. Hardcoded default: `slug_only`

### Queries enabled by per-project full storage
```sql
-- Full-text recall on a trusted project
SELECT project, prompt, datetime(started_at/1000, 'unixepoch')
FROM tasks
WHERE project = 'parrot' AND prompt LIKE '%SSRF%'
ORDER BY started_at DESC;

-- Compare what we tried across sessions on same project
SELECT session_id, prompt, status, duration_ms
FROM tasks WHERE project = 'parrot'
ORDER BY started_at DESC;
```

## Security Requirements

- DB file and WAL/SHM sidecar files: `chmod 0600` on creation
- Status dir `~/.claude/tmp/`: `chmod 0700`, random filenames, atomic writes (write to `.tmp` then rename)
- All SQL writes via prepared statements only — no dynamic SQL fragments from user/prompt data
- Redaction pass on `prompt`, `error_text`, `output_truncated` before any insert
- Full prompt stored only on failure (default) or explicit env var opt-in

## Retention Strategy

- Column-level expiry: null out `prompt`/`output_truncated` after their retention age
- Row-level expiry: delete rows older than `row_days`
- Size cap: trim oldest rows when DB exceeds `max_db_mb`
- Run once at server startup, not per-insert
- Replaces existing hook-based `MAX_ENTRIES=100` / `RETENTION_DAYS=30` JSONL rotation

## Migration from JSONL

- Phase 1: DB writes alongside existing JSONL (dual-write)
- Phase 2: Update /monitor, /summarize, /log-cleanup to read from DB
- Phase 3: Remove JSONL hooks once DB is confirmed stable
- Fix `/session` log filename typo: `delegation.jsonl` → `delegations.jsonl` during migration

## Implementation Order

1. Schema + server.js SQLite logging with tiered storage (load-bearing)
2. Per-task status file writes in server.js for live overlay
3. Watcher script (detect ghostty/alacritty/kitty at runtime)
4. Pre/Post hooks for overlay window
5. Web delegate PostToolUse hook
6. Retention/cleanup on startup
7. `/audit` skill (set-project, list-projects, set, status subcommands)
8. Update /monitor and /summarize to query DB; retire /log-cleanup
9. JSONL hook retirement + migration

## Key Decisions

- `better-sqlite3` (sync, no callback complexity in Node MCP server)
- DB path: `~/.claude/delegation.db`
- Status files: `~/.claude/tmp/{randomId}.json` (not /tmp — private dir, 0700)
- Web delegate logged via PostToolUse hook (no server changes needed for that server)
- Terminal overlay: runtime detection order — ghostty → alacritty → kitty → skip
- Session ID generated once at server startup, written to sessions table
- Tags auto-inferred from prompt keywords + manually settable; `tag_source` tracks provenance
- `token_est` = prompt char count / 4 (zero-cost approximation)
- `invocation_id` = UUID per call, eliminates hash-collision issues in current hooks

## Sample Queries

```sql
-- Project history this week
SELECT project, prompt_slug, datetime(started_at/1000, 'unixepoch')
FROM tasks WHERE started_at > (unixepoch()-7*86400)*1000
ORDER BY started_at DESC;

-- Failure rate by project
SELECT project, COUNT(*) total, SUM(status='failed') failures
FROM tasks GROUP BY project;

-- Slowest parallel batches
SELECT batch_id, MAX(duration_ms) wall_time, COUNT(*) tasks
FROM tasks GROUP BY batch_id ORDER BY wall_time DESC LIMIT 10;

-- Recall: have we done similar work before?
SELECT project, prompt_slug, datetime(started_at/1000, 'unixepoch')
FROM tasks WHERE prompt_slug LIKE '%auth%' ORDER BY started_at DESC;

-- Everything in this session
SELECT tool_type, project, prompt_slug, status, duration_ms
FROM tasks WHERE session_id = ? ORDER BY started_at;

-- All security audit tasks across all projects
SELECT t.project, t.prompt_slug, datetime(t.started_at/1000, 'unixepoch')
FROM tasks t JOIN task_tags tt ON t.id = tt.task_id
WHERE tt.tag = 'security-audit' ORDER BY t.started_at DESC;

-- Cost estimate this month
SELECT project, SUM(cost_est_usd) cost, COUNT(*) tasks
FROM tasks WHERE started_at > (unixepoch()-30*86400)*1000
GROUP BY project ORDER BY cost DESC;

-- Nested task tree for a batch
SELECT t.id, t.parent_task_id, t.prompt_slug, t.status
FROM tasks t WHERE t.batch_id = ?
ORDER BY t.parent_task_id NULLS FIRST, t.task_index;

-- Tasks with secrets redacted (audit)
SELECT project, prompt_slug, redaction_count, started_at
FROM tasks WHERE redaction_count > 0 ORDER BY started_at DESC;
```
