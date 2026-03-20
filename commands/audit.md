Inspect and manage the audit DB.

Parse `$ARGUMENTS` as one of these subcommands:
- `set-project <name> prompt-storage <full|slug-only>`
- `list-projects`
- `set <key> <value>`
- `status`
- `query <sql>`
- `add-path <path>`
- `list-paths`
- `remove-path <path>`

Use `mcp__audit__*` tools for all DB access. Do NOT use `sqlite3` shell commands.

If the audit MCP server is unavailable, print:
  `Audit MCP server not available — restart Claude Code to register audit.`
Then stop.

For `query <sql>`:
- Only allow read-only `SELECT` statements.
- Reject anything else with: `Only SELECT queries are allowed.`
- Use `mcp__audit__run_query` with the provided `sql`.

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
