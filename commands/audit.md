Inspect and manage the audit DB.

Parse `$ARGUMENTS` as one of these subcommands:
- `set-project <name> prompt-storage <full|slug-only>`
- `list-projects`
- `set <key> <value>`
- `status`
- `report [days]`
- `log [N] [--list] [--codex|--web] [keyword]`
- `query <sql>`
- `add-path <path>`
- `list-paths`
- `remove-path <path>`

Use `mcp__audit__*` tools for all DB access. Do NOT use `sqlite3` shell commands.

For DB-backed subcommands (`set-project`, `list-projects`, `set`, `status`, `report`, `log`, `query`):
- If the audit MCP server is unavailable, print:
  `Audit MCP server not available — restart Claude Code to register audit-mcp.`
- Then stop.

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
- Display config values, row counts per table, and DB file size.
- Include an "Example Queries" section with helpful hints:
  - Project history this week: `get_tasks` with `project=<name>`
  - Failure rate by project: `get_report` with default days
  - Slowest parallel batches: `get_report`
  - Recall by prompt slug keyword: `get_tasks` with `keyword=<term>`

For `report [days]`:
- Defaults: `days = 7`.
- If `days` is provided, parse it as a positive integer (1-365). If invalid, print: `Error: days must be an integer between 1 and 365.` and stop.
- Call `mcp__audit__get_report` with `days`.
- Display sections from the response: `usage`, `failures`, `slowest_batches`, and `running`.

For `log [N] [--list] [--codex|--web] [keyword]`:
- Defaults: `N = 10`, no type filter, no keyword filter, full mode (not `--list`).
- Parse args in this order:
  - First positional integer → `N` (limit)
  - `--codex` → `tool_type = "codex"`
  - `--web` → run two calls: `tool_type = "web-search"` and `tool_type = "web-fetch"`, combine results
  - `--list` → list mode
  - First non-flag, non-integer positional token → `keyword`
- Call `mcp__audit__get_tasks` with appropriate `limit`, `tool_type`, `keyword` params.
- For `--web`, call twice and concatenate results.

- Full mode output: for each row render:
  - Header: `[N] <type> · <sandbox> · <duration>ms · <timestamp> · <cwd>`
  - `PROMPT` section: `prompt` if non-null/non-empty, else `prompt_slug`
  - `RESPONSE` section: `output_full` if non-null/non-empty, else `output_truncated`
  - If no rows: `No matching audit tasks found.`

- `--list` mode: markdown table with columns:
  `# | timestamp | type | sandbox | status | duration | prompt_slug`
  - If no rows: `No matching audit tasks found.`

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
