# macOS Sandbox -- Seatbelt Profiles for Codex

macOS has a built-in sandboxing framework called **Seatbelt** (`sandbox-exec`). It's the same technology that sandboxes every App Store app. Seatbelt is enforced at the kernel level -- the agent literally cannot perform blocked actions.

## How Seatbelt Works

1. A **sandbox profile** (`.sb` file) defines rules in a Scheme-like language
2. When a process starts under `sandbox-exec`, the kernel loads these rules
3. Every system call the process makes is checked against the rules
4. Denied operations return "Operation not permitted"
5. The process cannot escape -- kernel-enforced, not userspace

### What Seatbelt can control

| Resource | Example rules |
|---|---|
| **Filesystem reads** | Allow reading `/usr/`, deny reading `~/.ssh/` |
| **Filesystem writes** | Allow writing to `$TMPDIR` and cwd, deny everything else |
| **Network access** | Allow/deny outbound connections, filter by port or domain |
| **Process execution** | Allow/deny spawning child processes |
| **IPC / signals** | Allow/deny inter-process communication |
| **System info** | Allow/deny reading hardware info, user info, etc. |

### Key lessons from testing

When writing custom Seatbelt profiles with `(deny default)`, you **must** include:

```scheme
(allow file-read-metadata)
(allow file-read* (literal "/"))
```

Without these, even `/bin/echo` will abort (exit code 134). The OS needs to traverse the directory tree from root to find any binary. Also needed:

- `(allow process*)` and `(allow mach*)` as broad wildcards -- individual Mach service listing is fragile across macOS versions
- macOS `/tmp` is a symlink to `/private/tmp` -- Seatbelt resolves real paths, so always use `$TMPDIR`
- Later rules take precedence (useful for allow-then-deny patterns)
- `.sb` files must be pure ASCII -- Unicode characters cause SIGABRT

## Profiles

### `codex-strict.sb` -- Maximum Isolation

Goes beyond Codex's built-in `workspace-write` by also **blocking reads** of sensitive directories:

- Blocks reads of `~/.ssh/`, `~/.aws/`, `~/.gnupg/`, `~/.codex/`, `~/.claude/`
- Blocks all network access (outbound and inbound)
- Allows reads of system paths and the working directory
- Allows writes only to cwd and TMPDIR

### `codex-network.sb` -- Selective Network Access

Same filesystem isolation as strict, but allows outbound connections:

- Outbound TCP (HTTPS, HTTP, git protocol)
- DNS resolution (UDP)
- All inbound connections blocked (no reverse shells)

Use for tasks like `npm install` or `git push`.

## Usage

Both profiles require three `-D` parameters:

```bash
sandbox-exec \
  -f sandbox-profiles/codex-strict.sb \
  -D CWD="$(pwd -P)" \
  -D TMPDIR="$TMPDIR" \
  -D HOME="$HOME" \
  codex -s danger-full-access "your task here"
```

**Why `-s danger-full-access`?** Because the outer `sandbox-exec` is the real sandbox. You don't want Codex to apply its own sandbox inside the custom one (double-sandboxing causes unexpected denials).

## Testing

Run the verification script to confirm your sandbox is working:

```bash
cd codex-sandbox/platforms/macos/
chmod +x test-sandbox.sh
./test-sandbox.sh
```

The script tests:
1. **Write isolation** -- writes outside cwd should fail
2. **Network isolation** -- outbound connections should fail (strict profile)
3. **Sensitive file protection** -- reads of `~/.ssh/` should fail
4. **Legitimate operations** -- reads/writes within cwd should succeed
5. **Codex built-in sandbox** -- `codex sandbox macos --full-auto` should work

Use `--log-denials` to debug what the sandbox blocks:

```bash
codex sandbox macos --full-auto --log-denials -- your-command
```

## Troubleshooting

### "Operation not permitted" on legitimate operations
1. Check if the operation is truly necessary
2. Switch to a less restrictive profile (strict -> network)
3. Use `--log-denials` to see exactly what's blocked

### Double-sandboxing issues
If you wrap `codex` in `sandbox-exec` AND use `codex -s workspace-write`, both sandboxes apply (most restrictive wins). Use `-s danger-full-access` when wrapping in a custom profile.

### `/tmp` writes fail even though TMPDIR is allowed
macOS `/tmp` is a symlink to `/private/tmp`. Use `$TMPDIR` (resolves to `/var/folders/...`) instead of `/tmp`. The `-D TMPDIR="$TMPDIR"` parameter handles this.

### Node.js / npm issues
Node needs `~/.npm/` cache. In workspace-write, this is blocked. Set `NPM_CONFIG_CACHE=./node_modules/.cache/npm` or use `danger-full-access` with approval for installs.

### Git operations
- `git add`, `git commit`: Work in workspace-write (writes to cwd/.git)
- `git push`, `git fetch`: Require network (use network profile or danger-full-access)
- `git clone`: Requires both network and write access outside cwd

## File Map

```
platforms/macos/
  README.md                  <-- You are here
  test-sandbox.sh            <-- Sandbox verification script
  sandbox-profiles/
    codex-strict.sb          <-- Strict profile (no network, no sensitive reads)
    codex-network.sb         <-- Network-enabled profile (filesystem still isolated)
```
