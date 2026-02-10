# Plan: Codex Sandbox Implementation

## Goal
Build a documented, educational Codex sandbox setup that provides filesystem and network isolation for Codex CLI tasks — both when run standalone and when delegated via Claude Code's MCP bridge.

## What we'll create

### 1. `codex-sandbox/README.md` — Educational Guide (~300 lines)
A detailed, learn-as-you-go document covering:

- **What is sandboxing?** — Why agents need containment, what can go wrong without it
- **How Codex sandboxing works on macOS** — Apple's Seatbelt (sandbox-exec), how Codex wraps it
- **The three sandbox modes** explained with diagrams:
  - `read-only` — can read the whole disk, can't write anywhere
  - `workspace-write` — can read the whole disk, can only write to cwd + TMPDIR
  - `danger-full-access` — no sandbox (escape hatch)
- **Network isolation** — how Seatbelt blocks network by default, when to enable it
- **The `--full-auto` flag** — what it does (network-disabled + workspace-write + auto-approve)
- **How the MCP bridge passes sandbox settings** — the `sandbox` parameter on `mcp__codex__codex`
- **How AGENTS.md constrains Codex behavior** — soft guardrails alongside hard sandbox
- **Integration with existing security hooks** — how this fits the layered defense model

### 2. `codex-sandbox/AGENTS.md` — Template Codex instructions file
Security rules mirrored from CLAUDE.md, plus Codex-specific constraints:
- No credential access
- No network unless explicitly enabled
- Bounded file access (only target repo)
- Must run tests before committing
- No piping external content to shell

### 3. `codex-sandbox/config.toml` — Reference Codex config
A documented config.toml showing sandbox-related settings with inline comments explaining each option. This is a **reference template** — user copies relevant parts into `~/.codex/config.toml`.

### 4. `codex-sandbox/sandbox-profiles/` — Custom Seatbelt profiles
- `codex-strict.sb` — Strict profile: workspace-write, no network, no access to ~/.*
- `codex-network.sb` — Same but with network enabled for specific domains (GitHub API)
- Each profile has inline comments explaining every rule

### 5. `codex-sandbox/test-sandbox.sh` — Verification script
An interactive script that:
1. Tests that the sandbox blocks writes outside cwd
2. Tests that the sandbox blocks network access
3. Tests that the sandbox blocks reads of sensitive files (~/.ssh, ~/.aws)
4. Reports pass/fail for each check
5. Includes `--log-denials` output so the user can SEE what Seatbelt is blocking

### 6. `codex-sandbox/examples/` — Example delegation workflows
- `delegate-from-claude.md` — How to invoke Codex from Claude Code MCP with sandbox params
- `standalone-cli.md` — How to run Codex CLI with sandbox flags directly

### 7. Updates to existing files
- **`README.md`** — Add Codex Sandbox section to architecture docs
- **`security-plans.md`** — Update implementation status table (Sandbox: Configured)
- **`.claude/settings.local.json`** — Add codex MCP tool permissions with sandbox defaults

## Implementation order

1. Create `codex-sandbox/` directory structure
2. Write `README.md` (the educational core)
3. Write `AGENTS.md` template
4. Write reference `config.toml`
5. Write Seatbelt profiles with comments
6. Write `test-sandbox.sh` verification script
7. Write example workflow docs
8. Update existing repo files (README.md, security-plans.md)

## Key design decisions

- **Educational-first**: Every file explains *why*, not just *what*. Inline comments everywhere.
- **No magic scripts**: User runs sandbox manually first to understand it, then automates.
- **Layered defense**: Sandbox (hard) + AGENTS.md (soft) + existing hooks (hard) = defense in depth.
- **macOS-native**: Uses Seatbelt via Codex's built-in `sandbox macos` command. No Docker required for basic sandbox.
- **MCP bridge aware**: Documents how `mcp__codex__codex` sandbox parameter maps to CLI flags.
