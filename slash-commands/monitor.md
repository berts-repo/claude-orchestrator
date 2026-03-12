Produce a monitoring report for this orchestration setup.

Delegate to Codex with:
- sandbox: read-only
- approval_policy: never
- cwd: current working directory

Use this Codex prompt:

---
Claude will read the following two log files directly (do not ask Codex to read `~/.claude/*`):
1. `~/.claude/logs/delegations.jsonl` — delegation audit log (Codex and Gemini calls)
2. `~/.claude/logs/security-events.jsonl` — security event log (blocked actions)

Use only the data Claude provides from those files.

If either file is missing or empty, note that in the report and continue with whatever data is available.

Both log files use a unified schema with envelope fields: `timestamp`, `level`, `component`, `session_id`, `event`, plus event-specific fields.

Produce a report with these sections:

## Audit Usage (last 7 / 30 days)

- Total delegations, broken down by type (Codex vs Gemini) and event name
- Success rate (entries with `"success": true` vs false)
- Most common sandbox modes used
- Count of `danger-full-access` usage (flag if > 0)
- Average and max `duration_ms` for delegations that have it (skip null values)

## Security Events (last 7 / 30 days)

- Total blocks, broken down by hook name
- Severity distribution (low / medium / high / critical)
- Most frequently matched patterns
- Any new/unusual patterns not seen in earlier entries (anomaly detection)
- Blocked subagent attempts (hooks starting with `block-`)

## Session Activity

- List unique `session_id` values with event counts per session
- Identify sessions with the most security denials

## Anomalies

Flag any of these conditions:
- `danger-full-access` used in delegation logs
- Repeated blocks from the same hook in a short timeframe (5+ in 1 hour) — possible injection probing
- Failed delegations (entries with `"success": false`)
- Security events with unusual `cwd` paths (outside typical project directories)
- Any `level: "error"` entries

## Summary

One-paragraph assessment of the overall health of the orchestration setup.

Format the report with markdown tables where appropriate. Keep it concise — this is a dashboard, not a deep dive.
---

After Codex returns, display the report verbatim.

### Audit Activity
Claude (not Codex) should query `~/.claude/audit.db` for recent activity:
- Last 10 tasks: `project`, `prompt_slug`, `status`, `duration_ms`, `started_at`
- Any currently running tasks (`status = 'running'`)
- Failure rate summary by project (last 7 days)

Use:
- `sqlite3 ~/.claude/audit.db "SELECT ..."`

If DB does not exist, skip this section silently.
