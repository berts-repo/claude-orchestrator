# TODO

## Backlog

- Add uninstall workflow/docs for cleanly removing this orchestrator.
- Add token usage instrumentation to validate savings claims from Codex delegation.
- Mark logging hooks as async via frontmatter (non-blocking: `codex--log-delegation-start.sh`, `codex--log-delegation.sh`, `shared--log-helpers.sh`) — check if `# HOOK_ASYNC:` is a supported frontmatter field, then apply with `bash scripts/sync-hooks.sh`.
