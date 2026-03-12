Inspect and manage the audit DB.

Parse `$ARGUMENTS` as one of these subcommands:
- `set-project <name> prompt-storage <full|slug-only>`
- `list-projects`
- `set <key> <value>`
- `status`
- `log [N] [--list] [--codex|--web] [keyword]`
- `query <sql>`
- `add-root <path>`
- `list-roots`

Use Bash with `sqlite3` for all DB access:
- `sqlite3 ~/.claude/audit.db "..."`

For DB-backed subcommands (`set-project`, `list-projects`, `set`, `status`, `log`, `query`):
- If `~/.claude/audit.db` does not exist, print:
  `Audit DB not found at ~/.claude/audit.db`
- Then stop.

For `query <sql>`:
- Only allow read-only `SELECT` statements.
- Reject anything else with: `Only SELECT queries are allowed.`

For `set-project <name> prompt-storage <full|slug-only>`:
- Write/update config key `prompt_storage_project:<name>` in the `config` table.
- Map values:
  - `full` -> `full`
  - `slug-only` -> `slug_only`
- Use an upsert.

For `list-projects`:
- Query all config entries where key starts with `prompt_storage_project:`.
- Show columns: `project`, `prompt_storage`.
- Sort by project name.

For `set <key> <value>`:
- Allowed keys only: `prompt-full-days`, `output-days`, `output-full-days`, `row-days`, `max-db-mb`, `full-output-storage`, `full-prompt-storage`.
- Map to DB config keys:
  - `prompt-full-days` -> `prompt_full_days`
  - `output-days` -> `output_days`
  - `output-full-days` -> `output_full_days`
  - `row-days` -> `row_days`
  - `max-db-mb` -> `max_db_mb`
  - `full-output-storage` -> `full_output_storage`
  - `full-prompt-storage` -> `full_prompt_storage`
- Upsert into `config`.

For `status`:
- Show current config values for:
  - `prompt_full_days`
  - `output_days`
  - `output_full_days`
  - `row_days`
  - `max_db_mb`
  - `full_output_storage`
  - `full_prompt_storage`
  - `prompt_storage` (if present)
- Show DB stats:
  - Row counts per table (`sessions`, `batches`, `tasks`, `task_tags`, `tags`, `config`)
  - DB file size for `~/.claude/audit.db`
- Include an "Example Queries" section with helpful SQL from the audit DB plan:
  - Project history this week
  - Failure rate by project
  - Slowest parallel batches
  - Recall by prompt slug keyword
  - Cost estimate this month

For `log [N] [--list] [--codex|--web] [keyword]`:
- Query `~/.claude/audit.db` directly with `sqlite3`.
- Defaults:
  - `N = 10`
  - no type filter (all tool types)
  - no keyword filter
  - full mode (not `--list`)
- Parse args in this order:
  - First positional integer => `N`
  - `--codex` => filter `tool_type = 'codex'`
  - `--web` => filter `tool_type IN ('web-search', 'web-fetch')`
  - `--list` => list mode
  - First non-flag, non-integer positional token => `keyword`
- For keyword filter, match case-insensitive `prompt_slug` or `cwd`.

- Use this SQL template for full mode:
```sql
SELECT t.invocation_id, t.tool_type, t.project, t.cwd, t.prompt_slug,
       t.prompt, t.output_full, t.output_truncated, t.sandbox, t.approval,
       t.status, t.failure_reason, t.duration_ms, t.started_at,
       t.stdout_bytes, t.token_est
FROM tasks t
WHERE (tool_type = ? OR ? IS NULL)
  AND (lower(prompt_slug) LIKE ? OR lower(cwd) LIKE ? OR ? IS NULL)
ORDER BY started_at DESC LIMIT ?
```

- Bind values:
  - codex mode: `(tool_type, tool_type_check) = ('codex', 'codex')`
  - web mode: run twice (once for `web-search`, once for `web-fetch`) or use equivalent `IN (...)` SQL preserving the same filters and limit semantics.
  - all mode: `(tool_type, tool_type_check) = (NULL, NULL)`
  - keyword present: `keyword_like = '%' || lower(keyword) || '%'` and `keyword_check = keyword`
  - keyword absent: `keyword_like = '%'` and `keyword_check = NULL`
  - `LIMIT = N`

- Full mode output:
  - For each row, render:
    - Header: `[N] <type> · <sandbox> · <duration>ms · <timestamp> · <cwd>`
    - `PROMPT` section: `prompt` if non-null/non-empty, else `prompt_slug`
    - `RESPONSE` section: `output_full` if non-null/non-empty, else `output_truncated`
  - If no rows, print: `No matching audit tasks found.`

- `--list` mode:
  - Return only a markdown table with columns:
    - `# | timestamp | type | sandbox | status | duration | prompt_slug`
  - Use `started_at` as timestamp and `duration_ms` as duration.
  - If no rows, print: `No matching audit tasks found.`

For `list-roots`:
- Run: `python3 -c "import json,os; d=json.load(open(os.path.expanduser('~/.claude.json'))); print(d.get('mcpServers',{}).get('delegate',{}).get('env',{}).get('CODEX_POOL_ALLOWED_CWD_ROOTS',''))"`
- Split the result on commas and display as a numbered list.
- If empty or missing, print: `No roots configured. Run setup.sh to initialize.`

For `add-root <path>`:
- Validate `<path>` starts with `/`. If not, print: `Error: path must be absolute.` and stop.
- Run this Python snippet via Bash to append the path (deduplicated) and write back:
  ```bash
  python3 -c "
  import json, os, sys
  p = os.path.expanduser('~/.claude.json')
  d = json.load(open(p))
  env = d.setdefault('mcpServers', {}).setdefault('delegate', {}).setdefault('env', {})
  roots = [r.strip() for r in env.get('CODEX_POOL_ALLOWED_CWD_ROOTS', '').split(',') if r.strip()]
  new = sys.argv[1]
  if new not in roots:
      roots.append(new)
  env['CODEX_POOL_ALLOWED_CWD_ROOTS'] = ','.join(roots)
  open(p, 'w').write(json.dumps(d, indent=2) + chr(10))
  print('Added:', new)
  print('All roots:', env['CODEX_POOL_ALLOWED_CWD_ROOTS'])
  " "$path"
  ```
  (Pass the actual path as the `"$path"` argument when running.)
- Print confirmation and remind the user: **Restart Claude Code for the change to take effect.**

Output requirements:
- Use clean markdown tables where applicable.
- Keep results concise and readable.
- For write operations, print a short confirmation including the key/value changed.
