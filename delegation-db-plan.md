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
  batch_id         TEXT REFERENCES batches(id),
  session_id       TEXT REFERENCES sessions(id),
  parent_task_id   INTEGER REFERENCES tasks(id), -- for nested delegation
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
  error_text       TEXT,    -- stderr on failure, truncated 2KB
  token_est        INTEGER, -- rough prompt token count (chars/4)
  cost_est_usd     REAL     -- estimated cost based on model + tokens
);

-- Many-to-many tags on tasks
CREATE TABLE task_tags (
  task_id INTEGER REFERENCES tasks(id),
  tag     TEXT,
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
-- prompt_full_days = 60
-- output_days      = 14
-- row_days         = 365
-- max_prompt_chars = 4000
-- max_db_mb        = 100

-- Indexes
CREATE INDEX idx_tasks_project    ON tasks(project);
CREATE INDEX idx_tasks_started    ON tasks(started_at);
CREATE INDEX idx_tasks_status     ON tasks(status);
CREATE INDEX idx_tasks_session    ON tasks(session_id);
CREATE INDEX idx_tasks_parent     ON tasks(parent_task_id);
CREATE INDEX idx_task_tags_tag    ON task_tags(tag);
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
6. Retention/cleanup on startup
7. Skills integration (/monitor, /summarize)

## Key Decisions
- Use `better-sqlite3` (sync, simpler for Node MCP server)
- DB path: `~/.claude/delegation.db`
- Status files: `/tmp/codex-status-{batchId}.json` (ephemeral, cleaned up post-hook)
- Web delegate logged via PostToolUse hook (no server changes needed for that server)
- Overlay terminal: kitty floating window (adjust per user terminal)
- Session ID generated once at server startup, written to sessions table
- Tags auto-inferred from prompt keywords (e.g. 'security', 'refactor') + manually settable
- token_est = prompt char count / 4 (rough but zero-cost approximation)

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

-- Recall: have we solved this before?
SELECT project, prompt_slug, datetime(started_at/1000, 'unixepoch')
FROM tasks WHERE prompt LIKE '%auth%' ORDER BY started_at DESC;

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
```
