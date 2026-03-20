# TODO

Ideas and future improvements for claude-orchestrator. Items marked `[maybe]` are worth considering but not yet committed to.

---

## [maybe] Prompt cache hit rate in /report

Surface Codex prompt cache hits in the audit DB and show hit rate + tokens saved in `/report`.

The prompt cache is already implemented in `codex-delegation-mcp/server.js` (TTL-based, disabled by default). Cache hits are logged as `status = "cache-hit"` in the tasks table. What's missing:
- A `cache_hit` boolean or count column on batches, or a query in `/report` that filters `status = 'cache-hit'`
- A "tokens saved" estimate: if a cache hit skips N input tokens, that's `N * input_price` saved
- Display in `/report` as a summary line: `Cache hits: 3/12 tasks (saved ~4,200 tokens, ~$0.005)`

Depends on enabling the cache (set `CODEX_CACHE_TTL_MS` env var) and having enough usage to make the metric meaningful.

---

## [planned] Unified task timeline (schema rebuild)

**What:** Replace the current split between `tasks` (Codex) and `web_tasks` (Gemini) tables with a single `events` table covering all delegation types.

**Why:** The split causes duplicated query logic everywhere — `/history`, `/report`, and any future tool all need two queries and a merge step. A unified table makes cross-type queries, aggregations, and retention policies trivially simple.

**Proposed schema:**
```sql
CREATE TABLE events (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  invocation_id   TEXT UNIQUE,
  session_id      TEXT,
  batch_id        TEXT,                        -- null for web/non-batch events
  task_index      INTEGER,
  type            TEXT NOT NULL,               -- 'codex' | 'web_search' | 'web_fetch' | 'security'
  project         TEXT,
  cwd             TEXT,
  prompt          TEXT,
  prompt_slug     TEXT,
  prompt_hash     TEXT,
  prompt_tokens_est INTEGER,
  output_full     TEXT,
  output_truncated TEXT,
  response_token_est INTEGER,
  cost_est_usd    REAL,
  status          TEXT NOT NULL DEFAULT 'started',
  failure_reason  TEXT,
  error_text      TEXT,
  sandbox         TEXT,                        -- codex only
  model           TEXT,                        -- codex only
  started_at      INTEGER NOT NULL,
  ended_at        INTEGER,
  duration_ms     INTEGER
);
```

**Migration path:** Keep `tasks` and `web_tasks` as views or legacy tables during transition. Write a migration script that copies rows into `events` with `type` set appropriately.

**Impact:** Requires updates to `audit-mcp/db.js`, `audit-mcp/server.js`, `codex-delegation-mcp/server.js`, `web--log-start.sh`, `web--log-end.sh`, and all commands that query either table.

---

## [planned] Structured Codex output

**What:** Establish a convention where Codex tasks return a structured summary in addition to raw stdout — files changed, tests passed/failed, errors encountered — so `/history` can show a meaningful diff view instead of raw text.

**Why:** Currently `output_full` is a wall of text. You can't quickly scan "what files did this task touch?" or "did tests pass?" without reading the whole thing.

**Approach:**
- Add an output convention to `AGENTS.md`: Codex should end every task response with a fenced `json` block:
  ```json
  {
    "files_modified": ["path/to/file.js"],
    "tests_run": true,
    "tests_passed": true,
    "errors": []
  }
  ```
- In `codex-delegation-mcp/server.js`, parse this block from `stdoutText` before storing, and save it to a new `output_meta JSON` column on tasks.
- In `/history`, render `output_meta` as a compact summary line above the full output.

**Impact:** Requires AGENTS.md update, server.js output parsing, schema addition (`output_meta TEXT`), and history command update.

---

## [planned] Task dependency graph

**What:** Allow Codex tasks to declare dependencies so Claude can orchestrate multi-step workflows where task B receives task A's output as context.

**Why:** Currently every `codex_parallel` call is fully independent and ephemeral. Complex refactors or multi-file changes require Claude to read outputs and manually construct follow-up prompts — burning Claude tokens on work that could be automated.

**Approach:**
- Add a `depends_on: [task_id]` field to `TaskSchema` in `codex-delegation-mcp/server.js`
- The dispatcher resolves the dependency graph, runs independent tasks in parallel, and threads outputs into dependent task prompts via `base-instructions`
- The audit DB `tasks` table already has `parent_task_id` — use it to record the dependency chain
- Add a `codex_pipeline` tool that accepts a DAG of tasks and handles scheduling

**Impact:** Significant server.js rewrite. Requires careful timeout handling (dependent tasks wait on parents). High value for complex orchestration workflows.
