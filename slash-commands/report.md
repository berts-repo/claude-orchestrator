Produce a monitoring report for this orchestration setup.

Claude should gather data from:
1. `~/.claude/audit.db` (SQLite)
2. `~/.claude/logs/security-events.jsonl` (security event log)

If either data source is missing or empty, note that in the report and continue with whatever data is available.

For DB-backed metrics, run these queries against `~/.claude/audit.db`.

### Running Tasks
```sql
SELECT project, prompt_slug, started_at FROM tasks WHERE status = 'running';
```

### Usage (run twice: 7d and 30d)
Use cutoff timestamps in milliseconds (`now - 7 days`, `now - 30 days`):
```sql
SELECT tool_type, sandbox, status, COUNT(*) as n,
       AVG(duration_ms) as avg_ms, MAX(duration_ms) as max_ms,
       SUM(token_est) as tokens
FROM tasks
WHERE started_at > ?
GROUP BY tool_type, sandbox, status;
```

### Project Failure Rates (last 30d)
```sql
SELECT project, COUNT(*) as total,
       SUM(CASE WHEN status='failed' THEN 1 ELSE 0 END) as failed
FROM tasks WHERE started_at > ?
GROUP BY project ORDER BY total DESC;
```

### Slowest Batches
```sql
SELECT b.id, COUNT(t.id) as task_count, b.ended_at - b.started_at as wall_ms
FROM batches b JOIN tasks t ON t.batch_id = b.id
GROUP BY b.id ORDER BY wall_ms DESC LIMIT 5;
```

### Security Events (last 7 / 30 days)
Read `~/.claude/logs/security-events.jsonl` and report:
- Total blocks, broken down by hook name
- Severity distribution (low / medium / high / critical)
- Most frequently matched patterns
- Any new/unusual patterns not seen in earlier entries (anomaly detection)
- Blocked subagent attempts (hooks starting with `block-`)

Produce a concise markdown report with these sections in order:
1. Running Tasks
2. Usage (7d / 30d)
3. Project Failure Rates
4. Slowest Batches
5. Security Events
