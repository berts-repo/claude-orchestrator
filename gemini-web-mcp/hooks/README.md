# Gemini Web Search Hooks

Claude Code hooks that enforce and enhance web search behavior via the Gemini MCP server.

## Hooks

### `inject-web-search-hint.sh`
**Event:** `UserPromptSubmit`

Detects when user prompts request web/internet access and injects a hint reminding Claude to use the `web_search` MCP tool. Trigger phrases include:
- "search the web", "search online"
- "look up online", "look on the internet"
- "do research", "do a deep dive"

### `require-web-if-recency.sh`
**Event:** `Stop`

Validates that Claude used `web_search` when the user's prompt required current/recent information. Catches cases where Claude answered from stale training data when the user expected live results.

## Installation

These hooks are symlinked from `~/.claude/hooks/`. See the root README for setup instructions.
