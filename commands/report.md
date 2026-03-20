Show token usage and cost for Codex and web delegations.

Parse `$ARGUMENTS` for optional flags:
- `--weekly` / `-w` — last 7 days
- `--monthly` / `-m` — last 30 days
- Default (no flag) — current/latest session only

If neither `--weekly` nor `--monthly` is present, resolve the current session:
- Call `mcp__audit__run_query`:
  `SELECT session_id FROM batches ORDER BY started_at DESC LIMIT 1`
- Use the returned `session_id` as `<session_id>` in all queries below.
- If no row is returned, print: `No session data found in audit DB.` and stop.

All queries use one of these WHERE clauses depending on mode:
- **session mode** (default): `session_id = '<session_id>'`
- **weekly mode**: `started_at > (strftime('%s','now','-7 days') * 1000)`
- **monthly mode**: `started_at > (strftime('%s','now','-30 days') * 1000)`

Run all queries in parallel.

---

### Token Totals

```sql
SELECT
  COUNT(*) as tasks,
  SUM(prompt_tokens_est) as prompt_tokens,
  SUM(response_token_est) as response_tokens,
  SUM(prompt_tokens_est + response_token_est) as total_tokens,
  ROUND(SUM(COALESCE(cost_est_usd, 0)), 4) as total_cost_usd
FROM tasks
WHERE <scope>
```

Show as a summary line: **N tasks — Xp / Yr tokens — $Z estimated cost**

---

### By Model

```sql
SELECT model, COUNT(*) as tasks,
       SUM(prompt_tokens_est) as prompt_tokens,
       SUM(response_token_est) as response_tokens,
       SUM(prompt_tokens_est + response_token_est) as total_tokens,
       ROUND(SUM(COALESCE(cost_est_usd, 0)), 4) as cost_usd,
       SUM(CASE WHEN status='failed' THEN 1 ELSE 0 END) as failed
FROM tasks
WHERE <scope>
GROUP BY model
ORDER BY total_tokens DESC
```

---

### By Project

```sql
SELECT project, COUNT(*) as tasks,
       SUM(prompt_tokens_est) as prompt_tokens,
       SUM(response_token_est) as response_tokens,
       SUM(prompt_tokens_est + response_token_est) as total_tokens,
       SUM(CASE WHEN status='failed' THEN 1 ELSE 0 END) as failed
FROM tasks
WHERE <scope>
GROUP BY project
ORDER BY total_tokens DESC
```

---

### Web / Gemini Calls

```sql
SELECT tool_name, status, COUNT(*) as count,
       CAST(AVG(duration_ms) AS INTEGER) as avg_ms
FROM web_tasks
WHERE <web_scope>
GROUP BY tool_name, status
ORDER BY count DESC
```

For session mode: `session_id = '<session_id>'`.
For weekly/monthly: use `started_at` time filter.

---

Produce a concise markdown report labelled **Session `<first 8 chars>`**, **Last 7 Days**, or **Last 30 Days**.

Sections in order:
1. Token Totals (summary line)
2. By Model (table)
3. By Project (table)
4. Web / Gemini Calls (table)
