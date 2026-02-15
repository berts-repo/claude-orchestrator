# TODO

- Add log rotation/retention cleanup for `~/.claude/logs/codex-delegations.jsonl` (size/time-based pruning).
- Add install and uninstall workflow/docs for setting up and removing this orchestrator cleanly.

## Token Preservation

- Add token usage instrumentation to validate savings claims from Codex delegation.
- Review `log-codex-delegation.sh` for sensitive data exposure in prompt previews.
- Consider additional enforcement to prevent Claude from bypassing delegation by working directly.
