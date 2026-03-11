# Codex Test Delegation Security in `claude-orchestrator`

## Introduction

This document defines a secure delegation pattern for testing workflows in the `claude-orchestrator` project, a portable Claude Code MCP bridge that delegates tasks to Codex subprocesses. The goal is to preserve portability across machines while reducing execution risk when tests require dependency setup.

## Context

`claude-orchestrator` is built to let Claude delegate work such as code generation, testing, and analysis through Codex without assuming machine-specific preinstalled tooling. In practice, this means delegated tasks must operate safely under sandbox and approval controls while still supporting common project workflows.

## Problem

When a user asks Claude to "test the code" in a project, the observed flow was:

1. Claude delegates to Codex via `mcp__delegate__codex` with `sandbox: "workspace-write"` and `approval-policy: "on-failure"`.
2. The Codex prompt instructs it to run:
   - `pip install -r requirements.txt`
   - `python -m pytest tests/ -v`
3. Two failure modes occurred:
   - `pytest` is not installed at the system level.
   - Network is blocked in the sandbox, so `pip` cannot fetch packages.
4. The network block is correct behavior, but it exposes a design gap: test writing and test running are treated as one operation despite having different trust boundaries.

### Security risks if network is enabled naively

- `pip install` executes package build/install hooks (`setup.py`, `pyproject.toml` backends), which can run arbitrary code.
- A compromised dependency in `requirements.txt` could modify project files or introduce backdoors when sandbox writes are allowed.
- With `approval-policy: "on-failure"`, malicious installs that succeed do not trigger user review.
- `network + workspace-write` is the highest-risk delegation combination in this workflow.

## Solution

### Core principle: separate writing from running

Test writing and test running must be delegated as separate phases because they have different risk profiles.

### Phase 1: write tests

- Sandbox: `workspace-write`
- Approval policy: `on-failure`
- Network: not required
- Behavior: Codex reads source and writes test files only. No dependency installation.

### Phase 2: run tests (ranked options)

#### Option A: human-executed (safest)

- Codex writes `run-tests.sh` or prints exact commands.
- User executes locally.
- No sandbox network access is required during delegation.

#### Option B: scoped venv with hash-pinned dependencies

- Sandbox: `workspace-write`
- Approval policy: `untrusted` (prompt before each shell command)
- Flow:
  - Create `.venv`
  - Run `pip install --require-hashes -r requirements.txt`
  - Run pytest from the venv
- Rationale:
  - Hash pinning prevents package substitution attacks.
  - `untrusted` ensures command-by-command visibility.

#### Option C: read-only run (fastest)

- Sandbox: `read-only`
- Approval policy: `never`
- Assumption: dependencies are already installed in a venv.
- Benefit: zero workspace write surface and fast execution.

### The one rule

> Never combine `approval-policy: "on-failure"` with network access.
> Silent success is the attack surface. If network is involved, always use `untrusted`.

## Updated Delegation Table

| Task Type | Tool | Sandbox | Approval Policy |
|-----------|------|---------|-----------------|
| Test writing | codex | workspace-write | on-failure |
| Test running (pre-installed deps) | codex | read-only | never |
| Test running (needs pip install) | codex | workspace-write | untrusted |

## Portability recommendation

For a portable project that cannot assume pre-installed dependencies:

1. Add `scripts/bootstrap.sh` to create `.venv` and install dependencies (run once by the user).
2. Delegate test writing to Codex using `workspace-write` + `on-failure`.
3. Delegate test running to Codex using `.venv/bin/pytest` with `read-only` + `never` and no runtime network access.
4. Document this flow in `CLAUDE.md` so orchestration behavior is explicit and repeatable.

## Conclusion

Separating test writing from test execution aligns delegation behavior with risk boundaries. This preserves portability while avoiding unsafe default combinations, especially any path that mixes network access with low-visibility approval policies.
