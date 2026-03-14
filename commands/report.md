Produce a monitoring report for this orchestration setup.

Parse `$ARGUMENTS` for optional flags:
- `--weekly` / `-w` — report over last 7 days
- `--monthly` / `-m` — report over last 30 days
- Default (no flag) — report scoped to the current/latest session only

If neither `--weekly` nor `--monthly` is present, resolve the current session:
- Call `mcp__audit__run_query`:
  `SELECT session_id FROM batches ORDER BY started_at DESC LIMIT 1`
- Use the returned `session_id` as `<session_id>` in all queries below.
- If no row is returned, print: `No session data found in audit DB.` and stop.

All queries below have two variants depending on mode. Use the appropriate WHERE clause:
- **session mode** (default): `session_id = '<session_id>'`
- **weekly mode**: `started_at > (strftime('%s','now','-7 days') * 1000)`
- **monthly mode**: `started_at > (strftime('%s','now','-30 days') * 1000)`

For `security_events` and `web_tasks`, the time column is also `started_at` except `security_events` uses `timestamp_ms`.

If any data source is missing or unavailable, note it and continue.

---

### Running Tasks

Call `mcp__audit__get_report` with `days=1` and show the `running` field only.

---

### Usage Breakdown

**Session/weekly/monthly usage:**
```sql
SELECT tool_type, sandbox, status, COUNT(*) as count,
       CAST(AVG(duration_ms) AS INTEGER) as avg_ms,
       MAX(duration_ms) as max_ms,
       SUM(prompt_tokens_est) as prompt_tokens, SUM(response_token_est) as response_tokens
FROM tasks
WHERE <scope>
GROUP BY tool_type, sandbox, status
ORDER BY count DESC
```

---

### Codex Usage by Model

```sql
SELECT model, sandbox, status, COUNT(*) as count,
       CAST(AVG(duration_ms) AS INTEGER) as avg_ms,
       SUM(prompt_tokens_est) as total_prompt_tokens, SUM(response_token_est) as total_response_tokens,
       ROUND(SUM(COALESCE(cost_est_usd, 0)), 4) as total_cost_usd
FROM tasks
WHERE tool_type = 'codex'
  AND <scope>
GROUP BY model, sandbox, status
ORDER BY count DESC
```

Report: model breakdown, sandbox distribution, token totals, estimated cost, success/failure rates.

---

### Project Failure Rates

```sql
SELECT project, COUNT(*) as total,
       SUM(CASE WHEN status='failed' THEN 1 ELSE 0 END) as failed
FROM tasks
WHERE <scope>
GROUP BY project
ORDER BY failed DESC
```

---

### Slowest Batches

```sql
SELECT b.id as batch_id, b.task_count, MAX(t.duration_ms) as wall_ms
FROM batches b
JOIN tasks t ON t.batch_id = b.id
WHERE <scope for batches: replace session_id filter or use b.started_at for time modes>
GROUP BY b.id
ORDER BY wall_ms DESC
LIMIT 5
```

For session mode use `b.session_id = '<session_id>'`.
For weekly/monthly use `b.started_at > (strftime('%s','now','-N days') * 1000)`.

---

### Security Events

**By hook/severity:**
```sql
SELECT hook, severity, COUNT(*) as count,
       datetime(MAX(timestamp_ms)/1000, 'unixepoch') as last_seen
FROM security_events
WHERE <security_scope>
GROUP BY hook, severity
ORDER BY count DESC
```

**Top patterns:**
```sql
SELECT hook, severity, pattern_matched, COUNT(*) as count
FROM security_events
WHERE <security_scope>
GROUP BY hook, severity, pattern_matched
ORDER BY count DESC
LIMIT 50
```

For session mode: `session_id = '<session_id>'`.
For weekly: `timestamp_ms > (strftime('%s','now','-7 days') * 1000)`.
For monthly: `timestamp_ms > (strftime('%s','now','-30 days') * 1000)`.

Report: total blocks by hook, severity distribution, most frequent patterns, any anomalies, blocked subagent attempts.

---

### Gemini / Web Delegations

```sql
SELECT tool_name, status, COUNT(*) as count,
       CAST(AVG(duration_ms) AS INTEGER) as avg_ms,
       CAST(MAX(duration_ms) AS INTEGER) as max_ms
FROM web_tasks
WHERE <web_scope>
GROUP BY tool_name, status
ORDER BY count DESC
```

For session mode: `session_id = '<session_id>'`.
For weekly/monthly: use `started_at` time filter.

Report: search vs fetch breakdown, success/error rates, avg and max latency.

---

### Claude Sessions

```sql
SELECT s.claude_model,
       COUNT(DISTINCT s.id) as sessions,
       COUNT(DISTINCT b.id) as batches,
       SUM(b.task_count) as total_tasks,
       SUM(b.total_tokens) as total_tokens,
       datetime(MIN(s.started_at)/1000, 'unixepoch') as first_seen,
       datetime(MAX(s.started_at)/1000, 'unixepoch') as last_seen
FROM sessions s
LEFT JOIN batches b ON b.session_id = s.id
WHERE <sessions_scope>
GROUP BY s.claude_model
ORDER BY sessions DESC
```

For session mode: `s.id = '<session_id>'`.
For weekly: `s.started_at > (strftime('%s','now','-7 days') * 1000)`.
For monthly: `s.started_at > (strftime('%s','now','-30 days') * 1000)`.

Report: Claude model used, sessions/batches/tasks counts, total tokens delegated.

---

Produce a concise markdown report with these sections in order:
1. Running Tasks
2. Usage Breakdown
3. Codex Usage by Model
4. Project Failure Rates
5. Slowest Batches
6. Security Events
7. Gemini / Web Delegations
8. Claude Sessions

Label the report header with the scope: **Session `<first 8 chars>`**, **Last 7 Days**, or **Last 30 Days**.
