# TODO

## Backlog

- Add uninstall workflow/docs for cleanly removing this orchestrator.
- Add token usage instrumentation to validate savings claims from Codex delegation.
- Mark logging hooks as async via frontmatter (non-blocking: `codex--log-delegation-start.sh`, `codex--log-delegation.sh`, `shared--log-helpers.sh`) — `# HOOK_ASYNC:` is NOT currently parsed by `scripts/sync-hooks.sh`; would require adding support there first before applying.
