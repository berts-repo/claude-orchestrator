Retrieve audit history — Codex batches and web (Gemini) searches — merged into a single timeline.

Parse `$ARGUMENTS` for optional flags:
- `--session <id>` — specific session (default: latest)
- `--limit <n>` — max entries to show (default `5`)
- `-<N>` (e.g. `-1`, `-2`, `-3`) — shorthand for the last N tasks; `-1` shows the single most recent task, `-2` the last two, etc. Equivalent to `--limit <N>` but sorts output newest-first and skips the batch header grouping — show each task as a flat entry.
- `--search <keyword>` — search across ALL sessions by prompt content
- `--list` / `-l` — list available sessions
- `--view <batch_id> [task_index]` — open the full output of a specific task in `$PAGER` (bypasses MCP token limits by querying SQLite directly)

Argument rules:
- If `$ARGUMENTS` contains a token matching `-[0-9]+` (e.g. `-1`, `-10`), extract the absolute value as `<N>` and treat as shorthand mode (newest-N).
- If `--limit` is missing and shorthand mode is not active, use `5`.
- Parse `--limit` as a positive integer. If invalid, print: `Error: --limit must be a positive integer.` and stop.

---

## If `--view <batch_id> [task_index]`

`task_index` defaults to `0` if not provided.

Run:
```bash
bash scripts/db-read.sh view <batch_id> <task_index>
```

The script validates inputs and exits non-zero with an error message on failure. On success it prints the output file path. Print that path to the user.

---

## If shorthand `-<N>` mode

Resolve session as in the default mode. Then fetch the N most recent Codex batches and N most recent web tasks for that session, merge by `started_at` descending, take the top N entries total. Use the standard Output format (with batch grouping) but sorted newest-first.

**Codex batches (fetch tasks for the N most recent batches):**

Step 1 — get the N most recent batch IDs:
```sql
SELECT id FROM batches
WHERE session_id = '<session_id>'
ORDER BY started_at DESC
LIMIT <N>
```

Step 2 — fetch all tasks for those batches (omit `output_full` to stay within MCP token limits):
```sql
SELECT b.id as batch_id, b.session_id, b.started_at, b.task_count, b.failed_count,
       t.task_index, t.prompt, t.output_truncated, t.status, t.duration_ms,
       t.prompt_tokens_est, t.response_token_est, t.error_text
FROM batches b JOIN tasks t ON t.batch_id = b.id
WHERE b.id IN (<batch_ids>)
ORDER BY b.started_at DESC, t.task_index
```

For each task, show `output_truncated` if non-null, otherwise *(use `/history --view <batch_id> <task_index>` for full output)*.

**Web tasks:**
```sql
SELECT id, session_id, tool_name, prompt, status, started_at, ended_at, duration_ms, error_text
FROM web_tasks
WHERE session_id = '<session_id>'
ORDER BY started_at DESC
LIMIT <N>
```

Merge Codex batches and web tasks into a single timeline sorted newest-first. Use the standard Output format. Web task output is omitted from this view — use `/audit query` if needed.

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
       t.task_index, t.prompt, t.output_truncated, t.status, t.duration_ms, t.exit_code,
       t.prompt_tokens_est, t.response_token_est, t.error_text
FROM batches b JOIN tasks t ON t.batch_id = b.id
WHERE t.prompt LIKE '%<keyword>%' OR t.prompt_slug LIKE '%<keyword>%'
ORDER BY b.started_at DESC
LIMIT <limit * 5>
```

**Web tasks:**
```sql
SELECT id, session_id, tool_name, prompt, status, started_at, ended_at, duration_ms, error_text
FROM web_tasks
WHERE prompt LIKE '%<keyword>%'
ORDER BY started_at DESC
LIMIT <limit * 5>
```

Replace `<keyword>` with the search term.

If the combined row count from both queries exceeds 20, write results to a file instead of displaying inline.

Run:
```bash
bash scripts/db-read.sh search <keyword> <limit>
```

The script validates and sanitizes inputs. On success it prints the output file path. Print: `Search results for "<keyword>" written to <path>`

Otherwise merge and display as described in the Output section below.
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
       t.task_index, t.prompt, t.output_truncated, t.status, t.duration_ms, t.exit_code,
       t.prompt_tokens_est, t.response_token_est, t.error_text
FROM batches b JOIN tasks t ON t.batch_id = b.id
WHERE b.session_id = '<session_id>'
ORDER BY b.started_at DESC, t.task_index
LIMIT <limit * 20>
```

**Web tasks:**
```sql
SELECT id, session_id, tool_name, prompt, status, started_at, ended_at, duration_ms, error_text
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
- **Output:** `<output_truncated>` if non-null, else *(use `/history --view <batch_id> <task_index>` for full output)*
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
