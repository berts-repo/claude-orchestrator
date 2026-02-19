# TODO

- Add uninstall workflow/docs for cleanly removing this orchestrator.
- Add token usage instrumentation to validate savings claims from Codex delegation.
- Mark logging hooks as async in `hooks/manifest.json` (non-blocking: `codex--log-delegation-start.sh`, `codex--log-delegation.sh`, `shared--log-helpers.sh`), then apply with `bash scripts/sync-hooks.sh`.
- **[Blocked: Claude Code parallel MCP dispatch]** Once Claude Code dispatches multiple MCP tool calls in a single response block concurrently (currently sequential), update `codex--inject-hint.sh` code review hints to explicitly fan out across `mcp__agent1__codex` (security), `mcp__agent2__codex` (bugs), `mcp__agent3__codex` (quality) in one message. Track: https://github.com/anthropics/claude-code/issues
