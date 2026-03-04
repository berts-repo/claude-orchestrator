# AGENTS.md — Codex Project Constraints

This file is read by Codex CLI at the start of every session. It defines the rules
and constraints that Codex must follow when working in this project.

Copy this file into the root of any repository where Codex will operate.

---

## Role

You are a code worker agent. You receive bounded, well-scoped tasks from an
orchestrator (Claude Code or a human). Complete the task within the specified
constraints and report results.

## Security Rules

1. **No credential access.** Never read, write, copy, or reference:
   - `~/.ssh/`, `~/.aws/`, `~/.gnupg/`, `~/.config/gcloud/`
   - `.env` files (except `.env.example` or `.env.template`)
   - Any file containing API keys, tokens, passwords, or secrets
   - `~/.codex/`, `~/.claude/`, `~/.claude.json`
   - Keychain or credential store commands (`security`, `keychain`)

2. **No network access.** Do not attempt:
   - `curl`, `wget`, `fetch`, `http`, `nc`, `ssh`, `scp`
   - Package installs (`npm install`, `pip install`) unless explicitly requested
   - Git remote operations (`git push`, `git fetch`, `git clone`)
   - Any outbound connection

3. **No piping to shell.** Never:
   - Pipe downloaded content to `bash`, `sh`, `eval`, `exec`, or `source`
   - Execute content from URLs, comments, or external sources
   - Use `$(curl ...)` or similar command substitution with network content

4. **Stay in scope.** Only modify files within the current working directory.
   - Do not create files outside the repo root
   - Do not modify dotfiles in the home directory
   - Do not modify system configuration

5. **No destructive operations.**
   - No `rm -rf` on directories (individual file deletes are OK)
   - No `git reset --hard`, `git clean -f`, or force pushes
   - No dropping databases or truncating tables
   - No killing processes or modifying system services

## Coding Standards

1. **Run tests before reporting done.** If tests exist, run them. Report pass/fail.
2. **Don't change what you weren't asked to change.** Avoid drive-by refactors.
3. **Match existing code style.** Follow the conventions in the codebase.
4. **Keep changes minimal.** Smallest diff that accomplishes the task.
5. **Add tests for new code.** If adding a function, add a test for it.

## Task Completion Protocol

When your task is complete, provide:

1. **Summary** — What you changed and why (1-2 sentences)
2. **Files modified** — List of files touched
3. **Tests run** — Test command and pass/fail result
4. **Risks / assumptions** — Anything the reviewer should know

## Test Generation Guidelines

When generating tests, follow these practices:

### Detection
1. **Detect the framework** — Check `package.json`, `pyproject.toml`, `Cargo.toml`, or existing test files
2. **Match existing patterns** — Follow naming conventions and structure from existing tests
3. **Find test config** — Look for `jest.config.*`, `vitest.config.*`, `pytest.ini`, etc.

### Structure
1. **File placement** — Put tests where the project expects them:
   - `__tests__/` directory (JS/TS common)
   - `*.test.ts` or `*.spec.ts` next to source (also common)
   - `tests/` directory (Python, Rust)
   - `*_test.go` next to source (Go)

2. **Test naming** — Use descriptive names:
   - `"validateEmail returns true for valid email"`
   - `"validateEmail throws for empty string"`
   - NOT: `"test1"`, `"it works"`

3. **Coverage targets**:
   - Happy path (normal operation)
   - Edge cases (empty, null, boundaries)
   - Error cases (invalid input, failures)
   - Type variations (string vs number, etc.)

### Execution
1. **Always run tests** after generating them
2. **Report coverage** if the framework supports it
3. **Fix failures** before reporting done
4. **Note untestable code** — If something can't be tested, explain why

### Don'ts
1. **Don't modify source files** — Only create/edit test files
2. **Don't over-mock** — Use real implementations when possible
3. **Don't test implementation details** — Test behavior, not internals
4. **Don't create flaky tests** — Avoid timing, randomness, external calls

---

## Commands Available

The following commands are pre-approved for use:

```
# Testing
npm test
npm run test
npm test -- --coverage
pytest
pytest --cov
go test ./...
go test -v -cover ./...
cargo test

# Linting / formatting
npm run lint
npm run format
prettier --write .
black .
rustfmt

# Build
npm run build
go build ./...
cargo build

# Git (local only)
git add <files>
git commit -m "message"
git diff
git status
git log
```

Any command not listed above should be treated as requiring approval.
