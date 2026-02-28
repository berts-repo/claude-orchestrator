# TODO

## Priority: Debug

- **BUG: `security--guard-sensitive-reads.sh` hook fires but doesn't block Read/Glob tools.** Hook receives correct payload (`tool_name: "Read"`, `file_path: "/home/me/.ssh/config"`) but Claude Code proceeds with the read anyway. Bash matcher works (destructive commands blocked), but Read/Glob matchers don't prevent tool execution. Debug logging added — check `/tmp/hook-debug.log` after testing. Possible causes: hook output format incorrect, Claude Code ignores deny for Read/Glob, or pattern matching fails silently.

## Backlog

- Add uninstall workflow/docs for cleanly removing this orchestrator.
- Add token usage instrumentation to validate savings claims from Codex delegation.
- Mark logging hooks as async via frontmatter (non-blocking: `codex--log-delegation-start.sh`, `codex--log-delegation.sh`, `shared--log-helpers.sh`) — check if `# HOOK_ASYNC:` is a supported frontmatter field, then apply with `bash scripts/sync-hooks.sh`.
- True parallel Codex calls are blocked because Claude Code serializes MCP tool calls sequentially. Workaround: use background Bash processes (`mcp__delegate__codex ... &`) or a wrapper script that fans out multiple `codex` CLI invocations concurrently and collects results — bypasses MCP serialization entirely.
