Capture or restore a session snapshot for this project.

Parse $ARGUMENTS for:
- Flags: --resume, --append, --clear, --note
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

## Default / --append

Delegate to Codex with:
- sandbox: read-only
- approval-policy: never
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
- Claude (not Codex) calls `mcp__audit__get_tasks` with:
  - `project = <basename of cwd>`
  - `limit = 10`
- Append this section to the snapshot:
  `## Recent Delegation Activity`
  [markdown table with columns: timestamp | type | sandbox | status | duration | prompt_slug]
  [status column uses ✓ for success and ✗ for failed]
  [if any displayed rows have non-null failure_reason, list each inline below the table]
  [footer line: total response_token_est for displayed tasks]
- If --append AND .SESSION.md exists:
    new content = [Codex output] + "\n\n---\n\n" + [existing .SESSION.md contents]
    Write new content to .SESSION.md
- Otherwise (default, or --append with no existing file):
    Overwrite .SESSION.md with Codex output
- Confirm: "Session snapshot saved to .SESSION.md"
