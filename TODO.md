# TODO

- Add log rotation/retention cleanup for `~/.claude/logs/codex-delegations.jsonl` (size/time-based pruning).
- Add install and uninstall workflow/docs for setting up and removing this orchestrator cleanly.

## Token Preservation

- Commit rationale for `token-preserve/` directory removal before finalizing staged changes.
- Add token usage instrumentation to validate savings claims from Codex delegation.
- Tighten soft-hint regex patterns in `inject-codex-hint.sh` or switch to structured detection.
- Review `log-codex-delegation.sh` for sensitive data exposure in prompt previews.
- Consider additional enforcement to prevent Claude from bypassing delegation by working directly.
