Inspect and manage the audit DB.

Parse `$ARGUMENTS` as one of these subcommands:
- `set-project <name> prompt-storage <full|slug-only>`
- `list-projects`
- `set <key> <value>`
- `status`
- `query <sql> [--to-file]`
- `export [--days <n>] [--table tasks|security_events|web_tasks]`
- `add-path <path>`
- `list-paths`
- `remove-path <path>`

Use `mcp__audit__*` tools for all DB access. Exception: `query --to-file` and `export` use `sqlite3` directly to bypass MCP token limits for large results.

If the audit MCP server is unavailable, print:
  `Audit MCP server not available — restart Claude Code to register audit.`
Then stop.

For `query <sql> [--to-file]`:
- Only allow read-only `SELECT` statements.
- Reject anything else with: `Only SELECT queries are allowed.`
- If `--to-file` is present: run this Bash command and print the output path:
  ```bash
  sqlite3 -json ~/.claude/audit.db "<sql>" > /tmp/audit-query.json && echo "Saved to /tmp/audit-query.json"
  ```
  Then stop — do not display the file contents.
- Otherwise: use `mcp__audit__run_query` with the provided `sql`.

For `export [--days <n>] [--table tasks|security_events|web_tasks]`:
- `--days` defaults to `7`. `--table` defaults to `tasks`.
- For `tasks` table:
  ```bash
  sqlite3 -json ~/.claude/audit.db "SELECT * FROM tasks WHERE started_at > (strftime('%s','now','-<days> days') * 1000) ORDER BY started_at DESC" > /tmp/audit-export.json && echo "Exported to /tmp/audit-export.json"
  ```
- For `security_events` table:
  ```bash
  sqlite3 -json ~/.claude/audit.db "SELECT * FROM security_events WHERE timestamp_ms > (strftime('%s','now','-<days> days') * 1000) ORDER BY timestamp_ms DESC" > /tmp/audit-export.json && echo "Exported to /tmp/audit-export.json"
  ```
- For `web_tasks` table:
  ```bash
  sqlite3 -json ~/.claude/audit.db "SELECT * FROM web_tasks WHERE started_at > (strftime('%s','now','-<days> days') * 1000) ORDER BY started_at DESC" > /tmp/audit-export.json && echo "Exported to /tmp/audit-export.json"
  ```
- Print: `Exported <table> (last <days> days) to /tmp/audit-export.json`

For `set-project <name> prompt-storage <full|slug-only>`:
- Map values: `full` → `"full"`, `slug-only` → `"slug-only"`
- Call `mcp__audit__set_config` with `key = "prompt_storage_project:<name>"` and `value`.

For `list-projects`:
- Call `mcp__audit__run_query` with:
  `SELECT replace(key, 'prompt_storage_project:', '') as project, value as prompt_storage FROM config WHERE key LIKE 'prompt_storage_project:%' ORDER BY project`
- Show columns: `project`, `prompt_storage`.

For `set <key> <value>`:
- Allowed keys: `prompt-full-days`, `output-days`, `output-full-days`, `row-days`, `max-db-mb`, `full-output-storage`, `full-prompt-storage`.
- Map to DB config keys:
  - `prompt-full-days` → `prompt_full_days`
  - `output-days` → `output_days`
  - `output-full-days` → `output_full_days`
  - `row-days` → `row_days`
  - `max-db-mb` → `max_db_mb`
  - `full-output-storage` → `full_output_storage`
  - `full-prompt-storage` → `full_prompt_storage`
- Call `mcp__audit__set_config` with the mapped key and value.

For `status`:
- Call `mcp__audit__get_status` (no params).
- Display config values, row counts per table (including `security_events` and `web_tasks`), and DB file size.

For `list-paths`:
- Run `mcp__audit__run_query` with:
  `SELECT key, value FROM config WHERE key LIKE 'allowed_root:%' ORDER BY key`
- Display as a numbered list of absolute paths by stripping the `allowed_root:` prefix from each `key`.
- If no rows, print: `No roots configured in audit DB.`

For `add-path <path>`:
- Validate `<path>` starts with `/`. If not, print: `Error: path must be absolute.` and stop.
- Call `mcp__audit__set_config` with:
  - `key = "allowed_root:<path>"`
  - `value = "true"`
- Print confirmation that the root was added.

For `remove-path <path>`:
- Validate `<path>` starts with `/`. If not, print: `Error: path must be absolute.` and stop.
- Call `mcp__audit__delete_config` with:
  - `key = "allowed_root:<path>"`
- Print confirmation that the root was removed.

Output requirements:
- Use clean markdown tables where applicable.
- Keep results concise and readable.
- For write operations, print a short confirmation including the key/value changed.
