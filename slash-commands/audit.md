Inspect and manage the audit DB.

Parse `$ARGUMENTS` as one of these subcommands:
- `set-project <name> prompt-storage <full|slug-only>`
- `list-projects`
- `set <key> <value>`
- `status`
- `query <sql>`

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

Output requirements:
- Use clean markdown tables where applicable.
- Keep results concise and readable.
- For write operations, print a short confirmation including the key/value changed.
