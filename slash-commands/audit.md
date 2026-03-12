Inspect and manage the audit DB.

Parse `$ARGUMENTS` as one of these subcommands:
- `set-project <name> prompt-storage <full|slug-only>`
- `list-projects`
- `set <key> <value>`
- `status`
- `query <sql>`
- `add-root <path>`
- `list-roots`

Use Bash with `sqlite3` for all DB access:
- `sqlite3 ~/.claude/audit.db "..."`

If `~/.claude/audit.db` does not exist, print:
`Audit DB not found at ~/.claude/audit.db`
Then stop.

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
- Allowed keys only: `prompt-full-days`, `output-days`, `row-days`, `max-db-mb`.
- Map to DB config keys:
  - `prompt-full-days` -> `prompt_full_days`
  - `output-days` -> `output_days`
  - `row-days` -> `row_days`
  - `max-db-mb` -> `max_db_mb`
- Upsert into `config`.

For `status`:
- Show current config values for:
  - `prompt_full_days`
  - `output_days`
  - `row_days`
  - `max_db_mb`
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

For `list-roots`:
- Run: `python3 -c "import json,os; d=json.load(open(os.path.expanduser('~/.claude.json'))); print(d.get('mcpServers',{}).get('delegate',{}).get('env',{}).get('CODEX_POOL_ALLOWED_CWD_ROOTS',''))"`
- Split the result on commas and display as a numbered list.
- If empty or missing, print: `No roots configured. Run setup.sh to initialize.`

For `add-root <path>`:
- Validate `<path>` starts with `/`. If not, print: `Error: path must be absolute.` and stop.
- Run this Python snippet via Bash to append the path (deduplicated) and write back:
  ```bash
  python3 -c "
  import json, os
  p = os.path.expanduser('~/.claude.json')
  d = json.load(open(p))
  env = d.setdefault('mcpServers', {}).setdefault('delegate', {}).setdefault('env', {})
  roots = [r.strip() for r in env.get('CODEX_POOL_ALLOWED_CWD_ROOTS', '').split(',') if r.strip()]
  new = '<path>'
  if new not in roots:
      roots.append(new)
  env['CODEX_POOL_ALLOWED_CWD_ROOTS'] = ','.join(roots)
  open(p, 'w').write(json.dumps(d, indent=2) + chr(10))
  print('Added:', new)
  print('All roots:', env['CODEX_POOL_ALLOWED_CWD_ROOTS'])
  "
  ```
  (Replace `<path>` with the actual argument before running.)
- Print confirmation and remind the user: **Restart Claude Code for the change to take effect.**

Output requirements:
- Use clean markdown tables where applicable.
- Keep results concise and readable.
- For write operations, print a short confirmation including the key/value changed.
