Produce a monitoring report for this orchestration setup.

Claude should gather data from:
1. `mcp__audit__get_report` (audit DB analytics)
2. `mcp__audit__run_query` against `security_events` and `web_tasks` (audit DB event/task logs)

If either data source is missing or unavailable, note that in the report and continue with whatever data is available.

### Audit Analytics

Call `mcp__audit__get_report` with `days=7` to get:
- `usage`: tool_type/sandbox/status breakdown with counts, avg/max ms, token sums
- `failures`: project failure rates (last 30d)
- `slowest_batches`: top 5 slowest parallel batches
- `running`: currently running tasks

Also call `mcp__audit__get_report` with `days=30` for the 30-day usage breakdown.

### Security Events (last 7 / 30 days)
Call `mcp__audit__run_query` with:

**7-day breakdown:**
```sql
SELECT hook, severity, COUNT(*) as count, datetime(MAX(timestamp_ms)/1000, 'unixepoch') as last_seen
FROM security_events
WHERE timestamp_ms > (strftime('%s','now','-7 days') * 1000)
GROUP BY hook, severity
ORDER BY count DESC
```

**30-day top patterns:**
```sql
SELECT hook, severity, pattern_matched, COUNT(*) as count
FROM security_events
WHERE timestamp_ms > (strftime('%s','now','-30 days') * 1000)
GROUP BY hook, severity, pattern_matched
ORDER BY count DESC
LIMIT 50
```

Report:
- Total blocks, broken down by hook name
- Severity distribution (low / medium / high / critical)
- Most frequently matched patterns
- Any new/unusual patterns not seen in earlier entries (anomaly detection)
- Blocked subagent attempts (hooks starting with `block-`)

### Codex Usage (last 7 / 30 days)
Call `mcp__audit__run_query` with:

**By model (7d):**
```sql
SELECT model, sandbox, status, COUNT(*) as count,
       CAST(AVG(duration_ms) AS INTEGER) as avg_ms,
       SUM(token_est) as total_tokens,
       ROUND(SUM(COALESCE(cost_est_usd, 0)), 4) as total_cost_usd
FROM tasks
WHERE tool_type = 'codex'
  AND started_at > (strftime('%s','now','-7 days') * 1000)
GROUP BY model, sandbox, status
ORDER BY count DESC
```

**By model (30d):**
```sql
SELECT model, sandbox, status, COUNT(*) as count,
       CAST(AVG(duration_ms) AS INTEGER) as avg_ms,
       SUM(token_est) as total_tokens,
       ROUND(SUM(COALESCE(cost_est_usd, 0)), 4) as total_cost_usd
FROM tasks
WHERE tool_type = 'codex'
  AND started_at > (strftime('%s','now','-30 days') * 1000)
GROUP BY model, sandbox, status
ORDER BY count DESC
```

Report: model breakdown, sandbox distribution, token totals, estimated cost, success/failure rates.

### Gemini / Web Delegations (last 7 days)
Call `mcp__audit__run_query` with:
```sql
SELECT tool_name, status, COUNT(*) as count,
       CAST(AVG(duration_ms) AS INTEGER) as avg_ms,
       CAST(MAX(duration_ms) AS INTEGER) as max_ms
FROM web_tasks
WHERE started_at > (strftime('%s','now','-7 days') * 1000)
GROUP BY tool_name, status
ORDER BY count DESC
```

Report: search vs fetch breakdown, success/error rates, avg and max latency.

### Claude Sessions (last 30 days)
Call `mcp__audit__run_query` with:
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
WHERE s.started_at > (strftime('%s','now','-30 days') * 1000)
GROUP BY s.claude_model
ORDER BY sessions DESC
```

Report: Claude model used, sessions/batches/tasks counts, total tokens delegated.

Produce a concise markdown report with these sections in order:
1. Running Tasks
2. Usage (7d / 30d)
3. Codex Usage by Model (7d / 30d)
4. Project Failure Rates
5. Slowest Batches
6. Security Events
7. Gemini / Web Delegations
8. Claude Sessions
