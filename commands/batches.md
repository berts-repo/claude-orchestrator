Retrieve recent audit batches with full task prompts and responses.

Parse `$ARGUMENTS` for optional flags:
- `--session <id>`
- `--limit <n>` (default `5`)
- `--list` / `-l` — list available sessions instead of showing batches

Argument rules:
- If `--limit` is missing, use `5`.
- Parse `--limit` as a positive integer. If invalid, print: `Error: --limit must be a positive integer.` and stop.
- `--session` is optional.

If `--list` or `-l` is present:
- Call `mcp__audit__run_query` with:
  ```sql
  SELECT session_id, datetime(MIN(started_at)/1000, 'unixepoch') as first_batch, datetime(MAX(started_at)/1000, 'unixepoch') as last_batch, COUNT(*) as batch_count, SUM(task_count) as total_tasks, SUM(failed_count) as total_failed FROM batches GROUP BY session_id ORDER BY MAX(started_at) DESC LIMIT 20
  ```
- Print results as a markdown table with columns: `session_id`, `first_batch`, `last_batch`, `batch_count`, `total_tasks`, `total_failed`.
- Stop — do not proceed to the batch query.

Use `mcp__audit__run_query` for all DB reads.

If `--session` is not provided:
- Call `mcp__audit__run_query` with:
  `SELECT session_id FROM batches ORDER BY started_at DESC LIMIT 1`
- If no row is returned, print: `No batches found in audit DB.` and stop.
- Use the returned `session_id` for the next query.

Then call `mcp__audit__run_query` with:
`SELECT b.id as batch_id, b.started_at, b.task_count, b.failed_count, t.task_index, t.prompt, t.output_full, t.status, t.duration_ms, t.exit_code FROM batches b JOIN tasks t ON t.batch_id = b.id WHERE b.session_id = '<session_id>' ORDER BY b.started_at DESC, t.task_index LIMIT <n * 20>`

Replace:
- `<session_id>` with the resolved session id
- `<n * 20>` with `--limit * 20`

Present results grouped by batch, ordered by `started_at DESC`:
- Batch header includes:
  - `batch_id` shortened to first 8 chars
  - `started_at`
  - status summary derived from batch fields (include `task_count` and `failed_count`)
- Under each batch, list every task row with:
  - `task_index`
  - `prompt` (full)
  - `output_full` (full)
  - `status`
  - `duration_ms`

If the batch/task query returns no rows, print: `No batches found for session <session_id>.`

Output requirements:
- Plain markdown.
- Keep full `prompt` and full `output_full` content (do not truncate).
- Use clear batch separators so tasks are visually grouped under their batch.
