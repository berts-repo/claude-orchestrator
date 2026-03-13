Produce a monitoring report for this orchestration setup.

Claude should gather data from:
1. `mcp__audit__get_report` (audit DB analytics)
2. `~/.claude/logs/security-events.jsonl` (security event log)

If either data source is missing or unavailable, note that in the report and continue with whatever data is available.

### Audit Analytics

Call `mcp__audit__get_report` with `days=7` to get:
- `usage`: tool_type/sandbox/status breakdown with counts, avg/max ms, token sums
- `failures`: project failure rates (last 30d)
- `slowest_batches`: top 5 slowest parallel batches
- `running`: currently running tasks

Also call `mcp__audit__get_report` with `days=30` for the 30-day usage breakdown.

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
