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

### Web Delegations (last 7 days)
Call `mcp__audit__run_query` with:
```sql
SELECT tool_name, status, COUNT(*) as count, CAST(AVG(duration_ms) AS INTEGER) as avg_ms
FROM web_tasks
WHERE started_at > (strftime('%s','now','-7 days') * 1000)
GROUP BY tool_name, status
ORDER BY count DESC
```

Produce a concise markdown report with these sections in order:
1. Running Tasks
2. Usage (7d / 30d)
3. Project Failure Rates
4. Slowest Batches
5. Security Events
6. Web Delegations
