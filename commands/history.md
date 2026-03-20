Retrieve audit history — Codex batches and web (Gemini) searches — merged into a single timeline.

Parse `$ARGUMENTS` for optional flags:
- `--session <id>` — specific session (default: latest)
- `--limit <n>` — max entries to show (default `5`)
- `--search <keyword>` — search across ALL sessions by prompt content
- `--list` / `-l` — list available sessions

Argument rules:
- If `--limit` is missing, use `5`.
- Parse `--limit` as a positive integer. If invalid, print: `Error: --limit must be a positive integer.` and stop.

---

## If `--list` or `-l`

Call `mcp__audit__run_query`:
```sql
SELECT session_id, datetime(MIN(started_at)/1000, 'unixepoch') as first_batch, datetime(MAX(started_at)/1000, 'unixepoch') as last_batch, COUNT(*) as batch_count, SUM(task_count) as total_tasks, SUM(failed_count) as total_failed FROM batches GROUP BY session_id ORDER BY MAX(started_at) DESC LIMIT 20
```
Print as a markdown table: `session_id | first_batch | last_batch | batch_count | total_tasks | total_failed`. Stop.

---

## If `--search <keyword>`

Run both queries in parallel across ALL sessions (no session filter):

**Codex tasks:**
```sql
SELECT b.id as batch_id, b.session_id, b.started_at, b.task_count, b.failed_count,
       t.task_index, t.prompt, t.output_full, t.status, t.duration_ms, t.exit_code,
       t.prompt_tokens_est, t.response_token_est, t.error_text
FROM batches b JOIN tasks t ON t.batch_id = b.id
WHERE t.prompt LIKE '%<keyword>%' OR t.prompt_slug LIKE '%<keyword>%'
ORDER BY b.started_at DESC
LIMIT <limit * 5>
```

**Web tasks:**
```sql
SELECT id, session_id, tool_name, prompt, output_full, status, started_at, ended_at, duration_ms, error_text
FROM web_tasks
WHERE prompt LIKE '%<keyword>%'
ORDER BY started_at DESC
LIMIT <limit * 5>
```

Replace `<keyword>` with the search term. Merge and display as described in the Output section below.
Print header: `## Search results for "<keyword>"` — no session scope label.

---

## Default (session-scoped)

If `--session` is not provided, call `mcp__audit__run_query`:
`SELECT session_id FROM batches ORDER BY started_at DESC LIMIT 1`
If no row, print: `No batches found in audit DB.` and stop.

Run both queries in parallel using the resolved `session_id`:

**Codex tasks:**
```sql
SELECT b.id as batch_id, b.session_id, b.started_at, b.task_count, b.failed_count,
       t.task_index, t.prompt, t.output_full, t.status, t.duration_ms, t.exit_code,
       t.prompt_tokens_est, t.response_token_est, t.error_text
FROM batches b JOIN tasks t ON t.batch_id = b.id
WHERE b.session_id = '<session_id>'
ORDER BY b.started_at DESC, t.task_index
LIMIT <limit * 20>
```

**Web tasks:**
```sql
SELECT id, session_id, tool_name, prompt, output_full, status, started_at, ended_at, duration_ms, error_text
FROM web_tasks
WHERE session_id = '<session_id>'
ORDER BY started_at DESC
LIMIT <limit * 10>
```

---

## Output

Merge all results into a single timeline sorted by `started_at` ascending (oldest first, latest last).

**For Codex batches** — group tasks under a batch header:
```
## [CODEX] Batch <batch_id first 8 chars> — <started_at> — <task_count> tasks, <failed_count> failed — tokens: <sum prompt_tokens_est>p / <sum response_token_est>r
```
Under each batch, list every task:
- `[<task_index>]` `<status>` — `<duration_ms>ms` — `tokens: <prompt_tokens_est> → <response_token_est>`
- **Prompt:** `<prompt>` (full)
- **Output:** `<output_full>` if non-null, else `<output_truncated>` if non-null, else *(not stored)*
- If `status = failed`: **Error:** `<error_text>` (display prominently, even if output is null)

**For web tasks** — one entry per row:
```
## [WEB] <tool_name> — <started_at> — <status> — <duration_ms>ms
```
- **Prompt:** `<prompt>` (full)
- **Output:** `<output_full>` if non-null, else *(not stored)*
- If `status = error`: **Error:** `<error_text>`

If both queries return no rows, print: `No history found for session <session_id>.`

Output requirements:
- Plain markdown, clear separators between entries.
- Full prompt and output — do not truncate.
