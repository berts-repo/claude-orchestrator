# Delegation Audit DB + Live Overlay Plan

## Goal
Add SQLite audit logging to the codex delegation MCP server + a live terminal overlay for monitoring parallel tasks in flight.

## Architecture

### Components
1. **SQLite DB** at `~/.claude/delegation.db` — cross-session audit trail
2. **Per-batch JSON status files** at `/tmp/codex-status-{batchId}.json` — live monitoring source
3. **Watcher script** `scripts/watch-tasks.sh` — renders live status table
4. **Pre/Post hooks** — auto-launches/kills overlay window on delegate calls
5. **PostToolUse hook** for web delegate — logs Gemini/web calls to same DB
6. **Skills integration** — /monitor and /summarize query the DB

### Data Flow
```
codex_parallel call
  → PreToolUse hook launches overlay window (reads /tmp status file)
  → server.js writes /tmp/codex-status-{batchId}.json (queued→running→done)
  → watcher polls file, renders live table
  → on completion, server.js flushes to SQLite
  → PostToolUse hook kills overlay
```

## Schema

```sql
CREATE TABLE batches (
  id           TEXT PRIMARY KEY,  -- uuid
  started_at   INTEGER,
  ended_at     INTEGER,
  task_count   INTEGER,
  failed_count INTEGER
);

CREATE TABLE tasks (
  id               INTEGER PRIMARY KEY,
  batch_id         TEXT REFERENCES batches(id),
  task_index       INTEGER,
  tool_type        TEXT,    -- 'codex' | 'web-fetch' | 'web-search'
  project          TEXT,    -- basename(cwd)
  cwd              TEXT,
  prompt           TEXT,    -- full prompt, expired per config
  prompt_slug      TEXT,    -- first ~80 chars, kept longer
  url              TEXT,    -- for web calls
  sandbox          TEXT,
  approval         TEXT,
  started_at       INTEGER, -- unix epoch ms
  ended_at         INTEGER,
  duration_ms      INTEGER,
  exit_code        INTEGER,
  status           TEXT,    -- queued/running/done/failed
  output_truncated TEXT,    -- first 2KB stdout, expired sooner
  error_text       TEXT     -- stderr on failure, truncated 2KB
);

CREATE INDEX idx_tasks_project ON tasks(project);
CREATE INDEX idx_tasks_started ON tasks(started_at);
CREATE INDEX idx_tasks_status  ON tasks(status);

CREATE TABLE config (
  key   TEXT PRIMARY KEY,
  value TEXT
);
-- Default config values:
-- prompt_full_days = 60
-- output_days      = 14
-- row_days         = 365
-- max_prompt_chars = 4000
-- max_db_mb        = 100
```

## Retention Strategy
- Rotate columns at different rates (prompt expires before rows)
- Run cleanup on server startup (not per-insert)
- Hard size cap enforced by trimming oldest rows

## Implementation Order
1. Schema + server.js SQLite logging (load-bearing, enables everything else)
2. Per-task status file writes in server.js (enables live overlay)
3. Watcher script
4. Pre/Post hooks for overlay
5. Web delegate PostToolUse hook
6. Skills integration (/monitor, /summarize)

## Key Decisions
- Use `better-sqlite3` (sync, simpler for Node MCP server)
- DB path: `~/.claude/delegation.db`
- Status files: `/tmp/codex-status-{batchId}.json` (ephemeral, cleaned up post-hook)
- Web delegate logged via PostToolUse hook (no server changes needed for that server)
- Overlay terminal: kitty floating window (adjust per user terminal)

## Sample Queries
```sql
-- Project history
SELECT project, prompt_slug, datetime(started_at/1000, 'unixepoch')
FROM tasks WHERE started_at > ? ORDER BY started_at DESC;

-- Failure rate by project
SELECT project, COUNT(*) total, SUM(status='failed') failures
FROM tasks GROUP BY project;

-- Slowest parallel batches
SELECT batch_id, MAX(duration_ms) wall_time, COUNT(*) tasks
FROM tasks GROUP BY batch_id ORDER BY wall_time DESC LIMIT 10;

-- Recall: have we solved this before?
SELECT project, prompt_slug, datetime(started_at/1000, 'unixepoch')
FROM tasks WHERE prompt LIKE '%auth%' ORDER BY started_at DESC;
```
