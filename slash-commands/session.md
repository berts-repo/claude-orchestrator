Capture or restore a session snapshot for this project.

Parse $ARGUMENTS for:
- Flags: --resume, --append, --log, --clear, --note
- LOG_N: number immediately after --log (default 5 if --log present but no number given)
- NOTE_TEXT: quoted string after --note

## --clear

Delete .SESSION.md from the project root.
Confirm: "Session snapshot cleared."
Done.

## --note

Read .SESSION.md if it exists.
Append to the file under a "## Manual Notes" section (create section if absent):
  - [YYYY-MM-DD HH:MM] NOTE_TEXT
Confirm: "Note added to .SESSION.md"
Done.

## --resume

If .SESSION.md exists: read it and display its contents under "## Session Context". Done.
If .SESSION.md does not exist: display "No session snapshot found. Run /session to create one." Done.

## Default / --append / --log [N]

Delegate to Codex with:
- sandbox: read-only
- approval_policy: never
- cwd: current working directory

Use this Codex prompt:

---
You are capturing a git session snapshot for this repository.

Run these commands and read their output:
  git log --oneline -20
  git status
  git diff HEAD

If .SESSION.md exists at the repo root, read it. Use only the previous
"## Next Steps" section to carry forward unfinished items.

Produce output in this EXACT format (no extra prose):

# Session Snapshot — [YYYY-MM-DD HH:MM local time]

## Branch
[branch-name from `git status`] @ [short-hash from first entry in `git log --oneline -20`]

## What Was Done
[bullet list of commits made since the hash in the previous snapshot's "## Branch"
line, or last 10 commits if no previous snapshot exists]
[if no new commits since last snapshot: "No new commits since last snapshot"]

## In Progress
[bullet list from `git status`, grouped: new files / modified / deleted]
[if working tree is clean: "Working tree clean"]

## Next Steps
[carry forward uncompleted items from previous .SESSION.md "## Next Steps"]
[add inferred items from the In Progress state]
[if nothing: "(none noted)"]

## Notes
[detached HEAD or other notable git state visible from the command output]
[omit this section entirely if nothing notable]

Keep output under 60 lines total.
---

After Codex returns:
- Display the snapshot under "## Session Snapshot"
- If --log is set, Claude (not Codex) reads `~/.claude/logs/delegations.jsonl` directly,
  extracts the last N entries (N = LOG_N, default 5), and appends:
  `## Recent Audit`
  [one bullet per entry: [sandbox] — [short task description, ≤10 words]]
- If --append AND .SESSION.md exists:
    new content = [Codex output] + "\n\n---\n\n" + [existing .SESSION.md contents]
    Write new content to .SESSION.md
- Otherwise (default, or --append with no existing file):
    Overwrite .SESSION.md with Codex output
- Confirm: "Session snapshot saved to .SESSION.md"
