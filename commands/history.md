Retrieve recent audit history — Codex batches and web (Gemini) searches — for the current or specified session.

Parse `$ARGUMENTS` for optional flags:
- `--session <id>`
- `--limit <n>` (default `5`)
- `--list` / `-l` — list available sessions instead of showing history

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

Run both of the following queries in parallel using the resolved `session_id`:

**Codex tasks query:**
`SELECT b.id as batch_id, b.started_at, b.task_count, b.failed_count, t.task_index, t.prompt, t.output_full, t.status, t.duration_ms, t.exit_code, t.prompt_tokens_est, t.response_token_est FROM batches b JOIN tasks t ON t.batch_id = b.id WHERE b.session_id = '<session_id>' ORDER BY b.started_at DESC, t.task_index LIMIT <n * 20>`

**Web tasks query:**
`SELECT id, tool_name, prompt, status, started_at, ended_at, duration_ms, error_text FROM web_tasks WHERE session_id = '<session_id>' ORDER BY started_at DESC LIMIT <n * 10>`

Replace:
- `<session_id>` with the resolved session id
- `<n * 20>` with `--limit * 20`
- `<n * 10>` with `--limit * 10`

Merge all results from both queries into a single timeline sorted by `started_at` ascending (oldest first, latest last). Use a clear type label for each entry:

**For Codex batches** — group tasks under a batch header:
- Batch header: `## [CODEX] Batch <batch_id first 8 chars> — <started_at> — <task_count> tasks, <failed_count> failed — tokens: <sum prompt_tokens_est>p / <sum response_token_est>r`
- Under each batch, list every task with:
  - `task_index`
  - `prompt` (full)
  - `output_full` (full, or `output_truncated` if `output_full` is null)
  - `status`
  - `duration_ms`
  - `tokens: <prompt_tokens_est> → <response_token_est>`

**For web tasks** — one entry per row:
- Header: `## [WEB] <tool_name> — <started_at> — <status> — <duration_ms>ms`
- `prompt` (full)
- `error_text` if present

If both queries return no rows, print: `No history found for session <session_id>.`

Output requirements:
- Plain markdown.
- Keep full `prompt` and full `output_full` content (do not truncate).
- Use clear separators so entries are visually distinct.
