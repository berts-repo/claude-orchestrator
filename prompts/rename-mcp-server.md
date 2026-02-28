# Rename MCP Server

Rename an MCP server registration from `OLD_NAME` to `NEW_NAME`.

Replace `OLD_NAME` and `NEW_NAME` before running.

## Locations to update

### 1. `~/.claude.json` — server registration key

Find the `mcpServers` object and rename the key:

```json
"OLD_NAME": { ... }  →  "NEW_NAME": { ... }
```

Use Python to edit safely (file is large and frequently written by Claude Code):

```python
import json
with open('/home/me/.claude.json', 'r') as f:
    data = json.load(f)
servers = data['mcpServers']
servers['NEW_NAME'] = servers.pop('OLD_NAME')
with open('/home/me/.claude.json', 'w') as f:
    json.dump(data, f, indent=2)
```

### 2. `~/.claude/settings.json` — hook matchers

Tool IDs use underscores and the pattern `mcp__<server-name>__<tool>`.
Dashes in server names become dashes (not underscores) in the tool ID.

Find and replace all occurrences of `mcp__OLD_NAME__` → `mcp__NEW_NAME__` in both
`PreToolUse` and `PostToolUse` hook matcher fields.

### 3. `./claude/settings.local.json` — allowed permissions

Same tool ID pattern. Replace in the `permissions.allow` array:

```
"mcp__OLD_NAME__<tool>"  →  "mcp__NEW_NAME__<tool>"
```

File: `/home/me/git/claude-orchestrator/.claude/settings.local.json`

### 4. `web-search-mcp/start.sh` — startup log prefix

Log lines use `[OLD_NAME]` as a prefix. Replace all occurrences:

```
[OLD_NAME]  →  [NEW_NAME]
```

File: `/home/me/git/claude-orchestrator/web-search-mcp/start.sh`

## Notes

- `~/.claude.json` and `~/.claude/settings.json` are outside the repo — commit only the in-repo files (`settings.local.json`, `start.sh`).
- The two registered servers are currently `delegate` (Codex) and `delegate-web` (web search). Renaming either to the same name would conflict.
- After renaming, restart Claude Code for the new name to take effect in the UI.
- The keyring service name in `start.sh` follows the pattern `mcp-<server-name>`. Update it alongside the server name. If a key was previously stored under the old service name, re-store it:
  ```bash
  # Read old value and store under new name
  old_key=$(secret-tool lookup service mcp-OLD_NAME account api-key)
  secret-tool store --label="mcp-NEW_NAME api-key" service mcp-NEW_NAME account api-key <<< "$old_key"
  # Optionally remove the old entry
  secret-tool clear service mcp-OLD_NAME account api-key
  ```
