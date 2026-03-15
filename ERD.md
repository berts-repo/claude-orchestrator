# Entity-Relationship Diagram

Database schema used by `audit-mcp` and shared across the Claude Orchestrator project.

Derived from `audit-mcp/db.js` schema and migrations.
Arrows (`▶`/`◀`) denote enforced `REFERENCES` FK constraints.
Dashed annotation `- - →` denotes soft links (plain `TEXT` columns with no DB-level FK enforcement).

```
                     ╔═══════════════════════════╗
                     ║          SESSIONS          ║
                     ╠═══════════════════════════╣
                     ║ id          TEXT  (PK)     ║
                     ║ started_at  INTEGER        ║
                     ║ ended_at    INTEGER        ║
                     ║ claude_model TEXT          ║
                     ║ notes       TEXT           ║
                     ╚════╤═══════════╤═══════════╝
                          │           │
              ┌───── FK ──┘           └── FK ─────┐
              ▼                                   ▼
╔═════════════╧══════════╗         ╔══════════════╧══════════════════════╗
║          BATCHES        ║         ║                TASKS                ║
╠════════════════════════╣         ╠════════════════════════════════════╣
║ id           TEXT (PK)  ║◀── FK ──║ batch_id       TEXT (FK)           ║
║ session_id   TEXT (FK)  ║         ║ id             INTEGER (PK)        ║
║ started_at   INTEGER    ║         ║ invocation_id  TEXT UNIQUE         ║
║ ended_at     INTEGER    ║         ║ session_id     TEXT (FK)           ║
║ task_count   INTEGER    ║         ║ parent_task_id INTEGER (FK)   ◀──┐ ║
║ failed_count INTEGER    ║         ║ task_index     INTEGER            │ ║
║ total_tokens INTEGER    ║         ║ tool_type      TEXT               │ ║
╚════════════════════════╝         ║ project        TEXT               │ ║
                                   ║ cwd            TEXT               │ ║
                                   ║ prompt_slug    TEXT               │ ║
                                   ║ prompt_hash    TEXT               │ ║
                                   ║ prompt         TEXT (Redacted)    │ ║
                                   ║ url            TEXT               │ ║
                                   ║ sandbox        TEXT               │ ║
                                   ║ approval       TEXT               │ ║
                                   ║ model          TEXT               │ ║
                                   ║ skip_git_check INTEGER            │ ║
                                   ║ started_at     INTEGER            │ ║
                                   ║ ended_at       INTEGER            │ ║
                                   ║ duration_ms    INTEGER            │ ║
                                   ║ exit_code      INTEGER            │ ║
                                   ║ status         TEXT               │ ║
                                   ║ failure_reason TEXT               │ ║
                                   ║ timed_out      INTEGER            │ ║
                                   ║ output_capped  INTEGER            │ ║
                                   ║ stdout_bytes   INTEGER            │ ║
                                   ║ stderr_bytes   INTEGER            │ ║
                                   ║ output_truncated TEXT (Redacted)  │ ║
                                   ║ output_full    TEXT (Redacted)    │ ║  ← added by migration
                                   ║ error_text     TEXT (Redacted)    │ ║
                                   ║ redaction_count INTEGER D:0       │ ║
                                   ║ prompt_tokens_est  INTEGER        │ ║
                                   ║ response_token_est INTEGER        │ ║
                                   ║ cost_est_usd   REAL           ────┘ ║
                                   ╚═══════════════╤════════════════════╝
                                                   │ FK ON DELETE CASCADE
                                                   ▼
                                   ╔═══════════════╧════════════════════╗
                                   ║              TASK_TAGS              ║
                                   ╠════════════════════════════════════╣
                                   ║ task_id   INTEGER (PK, FK)         ║
                                   ║ tag       TEXT    (PK)  - - - - - -║- - -┐
                                   ║ tag_source TEXT                    ║     ┆
                                   ╚════════════════════════════════════╝     ▼
                                                                      ╔══════════════════════╗
╔═══════════════════════════════════════════════════════════════╗      ║         TAGS         ║
║                     DATA LIFECYCLE (CONFIG)                   ║      ╠══════════════════════╣
╠═══════════════════════════════════════════════════════════════╣      ║ name        TEXT (PK)║
║ Controls `runRetentionCleanup()` behavior:                     ║      ║ description TEXT     ║
║ • prompt_full_days (D:7)    → Nulls `tasks.prompt`            ║      ║ color       TEXT     ║
║ • output_days (D:3)         → Nulls `tasks.output_truncated`  ║      ╚══════════════════════╝
║ • output_full_days (D:3)    → Nulls `tasks.output_full`       ║
║ • row_days (D:365)          → Deletes old rows                ║      ╔══════════════════════╗
║ • max_db_mb (D:100)         → Trims oldest tasks if > limit   ║      ║        CONFIG        ║
╚═══════════════════════════════════════════════════════════════╝      ╠══════════════════════╣
                                                                       ║ key        TEXT (PK) ║
                                                                       ║ value      TEXT      ║
  ┌ - - - - session_id (Soft Link - no FK) - - - - - - - - -┐          ║ updated_at TEXT      ║
  │                                                         │          ╚══════════════════════╝
  ▼                                                         ▼
╔══════════════════════════════╗           ╔════════════════════════════════╗
║       SECURITY_EVENTS         ║           ║           WEB_TASKS             ║
╠══════════════════════════════╣           ╠════════════════════════════════╣
║ id              INT (PK AI)  ║           ║ id             INT (PK AI)     ║
║ session_id      TEXT         ║           ║ session_id     TEXT            ║
║ timestamp_ms    INTEGER NN   ║           ║ invocation_key TEXT NN         ║
║ level           TEXT NN      ║           ║ tool_name      TEXT NN         ║
║ hook            TEXT NN      ║           ║ prompt         TEXT            ║
║ tool            TEXT NN      ║           ║ prompt_hash    TEXT            ║
║ action          TEXT NN D:'deny'║         ║ status         TEXT NN D:'started'║
║ severity        TEXT NN      ║           ║ started_at     INTEGER NN      ║
║ pattern_matched TEXT         ║           ║ ended_at       INTEGER         ║
║ command_preview TEXT         ║           ║ duration_ms    INTEGER         ║
║ cwd             TEXT         ║           ║ error_text     TEXT            ║
╚══════════════════════════════╝           ║ cwd            TEXT            ║
                                           ╚════════════════════════════════╝
```

## Relationships

| Relationship | Type | FK Enforced? |
|---|---|---|
| `sessions` → `batches` (session_id) | 1:N | Yes — `REFERENCES sessions(id)` |
| `sessions` → `tasks` (session_id) | 1:N | Yes — `REFERENCES sessions(id)` |
| `batches` → `tasks` (batch_id) | 1:N | Yes — `REFERENCES batches(id)` |
| `tasks` → `tasks` (parent_task_id) | Self-ref 1:N | Yes — `REFERENCES tasks(id)` |
| `tasks` → `task_tags` (task_id) | 1:N | Yes — `REFERENCES tasks(id) ON DELETE CASCADE` |
| `task_tags.tag` → `tags.name` | M:N join | No — `tag TEXT` only; soft lookup |
| `security_events.session_id` → `sessions` | Soft ref | No — plain `TEXT`, no `REFERENCES` |
| `web_tasks.session_id` → `sessions` | Soft ref | No — plain `TEXT`, no `REFERENCES` |
| `config` | Standalone | None |

## Indexes

| Table | Index | Column(s) |
|---|---|---|
| `tasks` | `idx_tasks_project` | `project` |
| `tasks` | `idx_tasks_started` | `started_at` |
| `tasks` | `idx_tasks_status` | `status` |
| `tasks` | `idx_tasks_session` | `session_id` |
| `tasks` | `idx_tasks_parent` | `parent_task_id` |
| `tasks` | `idx_tasks_invocation` | `invocation_id` |
| `task_tags` | `idx_task_tags_tag` | `tag` |
| `security_events` | `idx_security_events_ts` | `timestamp_ms` |
| `security_events` | `idx_security_events_session` | `session_id` |
| `security_events` | `idx_security_events_hook` | `hook` |
| `security_events` | `idx_security_events_sev` | `severity` |
| `web_tasks` | `idx_web_tasks_started` | `started_at` |
| `web_tasks` | `idx_web_tasks_session` | `session_id` |
| `web_tasks` | `idx_web_tasks_status` | `status` |
| `web_tasks` | `idx_web_tasks_tool` | `tool_name` |
| `web_tasks` | `idx_web_tasks_inv_key` | `invocation_key` |

## Field Notes

- **Redaction** — `prompt`, `output_truncated`, `output_full`, `error_text` are scanned for secrets before storage; `redaction_count` tracks hits.
- **Token estimation** — `prompt_tokens_est` / `response_token_est` use `chars / 4` (no external tokenizer).
- **`output_full`** — added by migration (`ALTER TABLE tasks ADD COLUMN output_full TEXT`); not in the original `CREATE TABLE`.
- **Tool types** — common values: `codex`, `web-search`, `web-fetch`, `audit`.
- **Sandbox modes** — `read-only`, `workspace-write`, `danger-full-access`.
- **Data lifecycle** — `runRetentionCleanup()` runs on startup; nulls content columns after N days, deletes rows after `row_days`, and emergency-trims oldest 500 tasks if DB exceeds `max_db_mb`.
