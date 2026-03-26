Reference guide for querying and managing the audit database.

TRIGGER when: Claude is about to write a raw SQL query against the audit DB, or use `db-read.sh` directly, and needs schema/column references
DO NOT TRIGGER when: using standard `mcp__audit__*` tool calls — their parameter descriptions are sufficient; or when the user is asking about `/audit` subcommands as a slash command (use `/audit` instead)

## Schema
### `sessions`
- `id` — session UUID; primary key.
- `started_at` — session start epoch ms.
- `ended_at` — session end epoch ms.
- `claude_model` — Claude model used for the session.
- `notes` — optional session notes.
### `batches`
- `id` — batch UUID; primary key.
- `session_id` — owning session; FK to `sessions.id`.
- `started_at` — batch start epoch ms.
- `ended_at` — batch end epoch ms.
- `task_count` — number of tasks in the batch.
- `failed_count` — failed task count for the batch.
- `total_tokens` — aggregate batch token count.
### `tasks`
- `id` — integer PK.
- `invocation_id` — unique invocation identifier.
- `batch_id` — owning batch; FK to `batches.id`.
- `session_id` — denormalized owning session.
- `parent_task_id` — parent task FK for nested work.
- `task_index` — position within batch.
- `tool_type` — executor/tool family, e.g. `codex`.
- `project` — logical project/repo label.
- `cwd` — task working directory.
- `prompt_slug` — short normalized prompt summary.
- `prompt_hash` — prompt fingerprint for dedupe/loop detection.
- `prompt` — stored/redacted full prompt text.
- `url` — optional URL associated with the task.
- `sandbox` — sandbox mode.
- `approval` — approval policy.
- `model` — model used for the task.
- `skip_git_check` — boolean-ish skip flag.
- `started_at` — task start epoch ms.
- `ended_at` — task end epoch ms.
- `duration_ms` — runtime in ms.
- `exit_code` — process exit code.
- `status` — lifecycle state (`running`, `success`, `failed`, etc.).
- `failure_reason` — normalized failure category.
- `timed_out` — timeout flag.
- `output_capped` — output truncation/capping flag.
- `stdout_bytes` — stdout byte count.
- `stderr_bytes` — stderr byte count.
- `output_truncated` — preview/truncated output.
- `error_text` — stored/redacted error text.
- `redaction_count` — total redactions applied.
- `prompt_tokens_est` — estimated input tokens.
- `response_token_est` — estimated output tokens.
- `cost_est_usd` — estimated USD cost.
- `output_full` — full output when retention/storage allows it.
### `task_tags`
- `task_id` — FK to `tasks.id`; cascades on delete.
- `tag` — tag name.
- `tag_source` — source of tag assignment.
### `tags`
- `name` — tag primary key.
- `description` — human description.
- `color` — UI color hint.
### `config`
- `key` — config key primary key.
- `value` — config value string.
- `updated_at` — last update timestamp.
### `security_events`
- `id` — integer autoincrement PK.
- `session_id` — related session.
- `timestamp_ms` — event time epoch ms.
- `level` — event level.
- `hook` — hook/source name.
- `tool` — tool involved.
- `action` — action taken, default `deny`.
- `severity` — severity bucket.
- `pattern_matched` — matched rule/pattern.
- `command_preview` — redacted command preview.
- `cwd` — working directory at event time.
### `web_tasks`
- `id` — integer autoincrement PK.
- `session_id` — related session.
- `invocation_key` — unique-ish invocation correlation key.
- `tool_name` — web/MCP tool name.
- `prompt` — prompt sent to web tool.
- `prompt_hash` — prompt fingerprint.
- `status` — web task state; default `started`.
- `started_at` — start epoch ms.
- `ended_at` — end epoch ms.
- `duration_ms` — runtime in ms.
- `error_text` — error text for failures.
- `cwd` — working directory.
- `output_full` — full stored output.
- `prompt_tokens_est` — estimated prompt tokens.
## MCP Tools
- `mcp__audit__get_tasks(limit=1..500, tool_type?, keyword?, project?, cwd?)` — recent task listing; best for quick scoped inspection; returns JSON text only and omits full output.
- `mcp__audit__get_report(days=1..365)` — canned analytics (`usage`, `failures`, `slowest_batches`, `running`); use for summaries, not ad-hoc SQL.
- `mcp__audit__get_status()` — config rows, table row counts, DB size MB; use for health/config checks.
- `mcp__audit__set_config(key, value)` — writes allowlisted keys only: `full_output_storage`, `prompt_full_days`, `output_days`, `output_full_days`, `row_days`, `max_db_mb`, plus `allowed_root:<abs-path>`.
- `mcp__audit__delete_config(key)` — deletes same allowlisted key shapes as `set_config`; use for removing `allowed_root:` entries or reverting config.
- `mcp__audit__run_query(sql, params=[])` — raw single-statement `SELECT`; rejects non-`SELECT`, comments, semicolons, SQL length `> 4000`; use for custom reports until response size becomes the bottleneck.
- `mcp__audit__export_jsonl(days=1..365, tool_type?, table=tasks|security_events, limit=1..5000)` — bulk export for ingestion/pipelines; returns JSONL and appends `{"truncated":true,"row_limit":...}` at limit.
- `mcp__audit__get_alerts(max_calls_per_session=50, max_tokens_per_session=100000, token_window_hours=24, repeat_prompt_threshold=3)` — canned anomaly detection: high-call sessions, token overspend, repeated prompts, `danger-full-access` tasks.
- Token caveat: MCP replies are fine for summaries and small result sets; for full task output, large searches, or wide `SELECT *`, switch to `bash scripts/db-read.sh ...` and consume the emitted file path instead of inline output.
## db-read.sh Bypass
- Exact usage: `bash scripts/db-read.sh view <batch_id> [task_index]`
- Exact usage: `bash scripts/db-read.sh search <keyword> [limit]`
- Exact usage: `bash scripts/db-read.sh query <sql>`
- `view` — writes `/tmp/codex-output-<batch_id>-<task_index>.txt`; use for full `tasks.output_full` when `/history --view` or inline MCP output would blow the token budget.
- `search` — writes `/tmp/history-search.json`; use when merged Codex/web keyword hits are too many to print inline.
- `query` — writes `/tmp/audit-query.json`; `SELECT` only, blocks unsafe SQL and shell metacharacters, good for large ad-hoc result sets.
- Related bulk export: `bash scripts/db-read.sh export --table <tasks|security_events|web_tasks> --days <1-365>`
## Common Query Patterns
- Last N tasks: `SELECT session_id, project, prompt_slug, status, started_at FROM tasks ORDER BY started_at DESC LIMIT 20`
- Failed tasks: `SELECT session_id, project, prompt_slug, error_text, started_at FROM tasks WHERE status='failed' ORDER BY started_at DESC LIMIT 50`
- Tasks by project: `SELECT project, COUNT(*) AS tasks, SUM(CASE WHEN status='failed' THEN 1 ELSE 0 END) AS failed FROM tasks GROUP BY project ORDER BY tasks DESC`
- Cost totals: `SELECT ROUND(SUM(COALESCE(cost_est_usd,0)),4) AS total_cost_usd, SUM(prompt_tokens_est) AS prompt_tokens, SUM(response_token_est) AS response_tokens FROM tasks`
- Web tasks: `SELECT session_id, tool_name, status, prompt, duration_ms, started_at FROM web_tasks ORDER BY started_at DESC LIMIT 50`
- Search by keyword: `SELECT batch_id, task_index, project, prompt_slug, status, started_at FROM tasks WHERE prompt LIKE '%keyword%' OR prompt_slug LIKE '%keyword%' ORDER BY started_at DESC LIMIT 50`
## Subcommands (`/audit`)
- `status` — calls `mcp__audit__get_status`; prints config, row counts, DB size.
- `query <sql> [--to-file]` — read-only `SELECT` only; inline via `mcp__audit__run_query`, or to file via `bash scripts/db-read.sh query <sql>`.
- `add-path <path>` — absolute path only; stores `allowed_root:<path>=true` via `mcp__audit__set_config`.
- `remove-path <path>` — absolute path only; deletes `allowed_root:<path>` via `mcp__audit__delete_config`.
- `list-paths` — queries `config` for `allowed_root:%` and prints configured absolute roots.
