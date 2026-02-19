# TODO

- Add uninstall workflow/docs for cleanly removing this orchestrator.
- Add token usage instrumentation to validate savings claims from Codex delegation.
- Mark logging hooks as async in `hooks/manifest.json` (non-blocking: `codex--log-delegation-start.sh`, `codex--log-delegation.sh`, `shared--log-helpers.sh`), then apply with `bash scripts/sync-hooks.sh`.
