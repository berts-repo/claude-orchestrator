# Codex CLI — Standalone Sandbox Usage

## Quick Reference

```bash
# Safe code editing (recommended)
codex -s workspace-write "add tests for the auth module"

# Read-only analysis
codex -s read-only "review this code for bugs"

# Fire-and-forget with sandbox
codex sandbox macos --full-auto -- npm test

# See what the sandbox blocks
codex sandbox macos --full-auto --log-denials -- your-command

# Full access with approval (when you need network)
codex -s danger-full-access -a untrusted "npm install && npm test"
```

---

## Scenario 1: Writing Tests

You want Codex to add unit tests for a module.

```bash
cd /path/to/your/project

# workspace-write: can edit files in the project, no network
codex -s workspace-write \
  "Add unit tests for src/utils/parser.ts. Use Jest. \
   Cover edge cases: empty input, malformed input, unicode. \
   Run 'npm test' to verify."
```

**What Codex can do:**
- Read all project files to understand the code
- Create new test files in the project
- Modify existing test files
- Run `npm test` (as long as it doesn't need network)

**What Codex cannot do:**
- Install new packages (needs network)
- Modify files outside the project
- Exfiltrate code via network

---

## Scenario 2: Code Review

You want Codex to review a PR or set of changes.

```bash
cd /path/to/your/project

# read-only: cannot modify anything, just reads and reports
codex -s read-only \
  "Review the changes in the last 3 commits. Check for: \
   1. Logic errors \
   2. Missing error handling \
   3. Security issues \
   4. Performance concerns \
   Provide a structured review."
```

**What Codex can do:**
- Read all files
- Run read-only commands (git log, git diff, grep, etc.)
- Produce a review report

**What Codex cannot do:**
- Modify any files
- Run tests (test runners often write output files)
- Network access

---

## Scenario 3: Refactoring

You want Codex to perform a mechanical refactor across many files.

```bash
cd /path/to/your/project

# workspace-write with on-failure approval
codex -s workspace-write -a on-failure \
  "Rename the 'UserService' class to 'AccountService' across the entire \
   codebase. Update all imports, references, and tests. \
   Run 'npm test' after each batch of changes."
```

**Tip:** For large refactors, break them into smaller batches. Codex works better with focused tasks.

---

## Scenario 4: Running Tests with Sandbox

You want to run tests inside a sandbox so test code can't escape.

```bash
cd /path/to/your/project

# --full-auto: workspace-write + no network + auto-approve
codex sandbox macos --full-auto -- npm test
```

This is useful when:
- You don't fully trust the test suite (third-party, unfamiliar code)
- Tests might have side effects (writing to disk, network calls)
- You want to ensure tests only affect the project directory

---

## Scenario 5: Debugging with `--log-denials`

Something isn't working and you want to see what the sandbox is blocking.

```bash
cd /path/to/your/project

# --log-denials shows every operation the sandbox denies
codex sandbox macos --full-auto --log-denials -- npm test
```

Example output:
```
Sandbox: deny(1) file-write-data /Users/you/.npm/_cacache/...
Sandbox: deny(1) network-outbound ...
```

This tells you:
- npm tried to write to its cache (outside cwd — blocked)
- npm tried to make a network request (blocked)

**Fix:** If tests need npm cache, set the cache to a local directory:
```bash
NPM_CONFIG_CACHE=./node_modules/.cache codex sandbox macos --full-auto -- npm test
```

---

## Scenario 6: Custom Seatbelt Profile

You want maximum isolation — even blocking reads of sensitive home directories.

```bash
cd /path/to/your/project

# Use the strict profile (blocks reads of ~/.ssh, ~/.aws, etc.)
sandbox-exec \
  -f /path/to/codex-sandbox/sandbox-profiles/codex-strict.sb \
  -D CWD="$(pwd)" \
  -D TMPDIR="$TMPDIR" \
  codex -s danger-full-access \
  "refactor the auth module to use async/await"
```

**Why `-s danger-full-access`?**
Because the *outer* `sandbox-exec` is the real sandbox. We don't want Codex to apply its own sandbox *inside* the custom one (double-sandboxing causes unexpected denials). The outer Seatbelt profile provides all the isolation.

---

## Scenario 7: Task Requiring Network

Some tasks genuinely need network (installing packages, pushing code).

```bash
cd /path/to/your/project

# Option A: Full access with human approval for every command
codex -s danger-full-access -a untrusted \
  "Install the zod package and add input validation to the API handlers"

# Option B: Use the network Seatbelt profile (filesystem still isolated)
sandbox-exec \
  -f /path/to/codex-sandbox/sandbox-profiles/codex-network.sb \
  -D CWD="$(pwd)" \
  -D TMPDIR="$TMPDIR" \
  codex -s danger-full-access \
  "npm install zod && add input validation to src/api/handlers.ts"
```

**Option A** removes all sandbox but makes you approve each command.
**Option B** allows network but still blocks filesystem access outside the project.

---

## Configuration Shortcuts

Instead of typing sandbox flags every time, set defaults in `~/.codex/config.toml`:

```toml
# Default to workspace-write sandbox
sandbox_policy = "workspace-write"

# Auto-approve unless something fails
approval_policy = "on-failure"
```

Now `codex "your task"` automatically uses workspace-write sandbox.

---

## Comparison: When to Use What

| Scenario | Mode | Approval | Command |
|---|---|---|---|
| Write tests | workspace-write | on-failure | `codex -s workspace-write "..."` |
| Code review | read-only | never | `codex -s read-only "..."` |
| Run tests | full-auto | auto | `codex sandbox macos --full-auto -- npm test` |
| Refactor | workspace-write | on-failure | `codex -s workspace-write "..."` |
| Install packages | danger-full-access | untrusted | `codex -s danger-full-access -a untrusted "..."` |
| Max isolation | custom profile | on-failure | `sandbox-exec -f codex-strict.sb ...` |
| Debug sandbox | log-denials | auto | `codex sandbox macos --log-denials ...` |
