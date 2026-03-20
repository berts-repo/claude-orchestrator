Show errors, security events, and anomaly alerts from the audit DB.

Parse `$ARGUMENTS` for optional flags:
- `--security` / `-s` — show recent security hook blocks (default: last 20)
- `--anomalies` / `-a` — run anomaly detection (high call count, token overspend, repeated prompts, danger sandbox)
- `--errors` / `-e` — show recent failed Codex and web tasks
- `--all` — equivalent to `--security --anomalies --errors`
- `--limit <n>` — max rows per section (default `20`)
- Default (no flag) — same as `--all`

If the audit MCP server is unavailable, print:
  `Audit MCP server not available — restart Claude Code to register audit.`
Then stop.

---

## Security Events (`--security`)

Call `mcp__audit__run_query`:
```sql
SELECT timestamp_ms, event_type, tool_name, matched_pattern, session_id
FROM security_events
ORDER BY timestamp_ms DESC
LIMIT <limit>
```

Display as a markdown table. If no rows: `No security events found.`

---

## Anomaly Detection (`--anomalies`)

Call `mcp__audit__get_alerts` with default thresholds:
- `max_calls_per_session: 50`
- `max_tokens_per_session: 100000`
- `token_window_hours: 24`
- `repeat_prompt_threshold: 3`

Parse the JSON result and display each section:

**High-call sessions** — sessions exceeding the call threshold. Table: `session_id | call_count`.

**Token overspend** — sessions exceeding token threshold in the last 24h. Table: `session_id | total_tokens`.

**Repeated prompts** — identical Codex prompts sent ≥ 3 times (loop detection). Table: `prompt_slug | repeat_count`.

**Danger sandbox usage** — any `danger-full-access` task invocations. Table: `session_id | project | prompt_slug | started_at | status`.

For each section with no hits, print: `✓ None`.

---

## Recent Errors (`--errors`)

Run both queries in parallel:

**Failed Codex tasks:**
```sql
SELECT b.session_id, t.project, t.prompt_slug, t.error_text, t.exit_code,
       datetime(t.started_at/1000, 'unixepoch') as time
FROM tasks t JOIN batches b ON t.batch_id = b.id
WHERE t.status = 'failed'
ORDER BY t.started_at DESC
LIMIT <limit>
```

**Failed web tasks:**
```sql
SELECT session_id, tool_name, prompt, error_text,
       datetime(started_at/1000, 'unixepoch') as time
FROM web_tasks
WHERE status = 'error'
ORDER BY started_at DESC
LIMIT <limit>
```

Display each as a markdown table. If no rows: `✓ No recent errors.`

---

## Output

Produce a concise markdown report with a header showing the current timestamp.

Sections in order (include only requested sections):
1. **Security Events**
2. **Anomaly Alerts**
3. **Recent Errors**

Keep output scannable — use tables, bold for any hits that need attention.
