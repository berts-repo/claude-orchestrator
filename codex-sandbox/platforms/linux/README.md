# Linux Sandbox -- Bubblewrap Profiles for Codex

Linux uses **Bubblewrap** (`bwrap`) for sandboxing. Bubblewrap leverages Linux namespaces to create isolated environments -- it's the same technology used by Flatpak. Unlike macOS Seatbelt (kernel sandbox), Bubblewrap works via mount namespaces and network namespaces, which are equally effective but work differently.

## How Bubblewrap Works

1. **Namespaces** create isolated views of system resources
2. **Mount namespaces** control what the process can see in the filesystem
3. **Network namespaces** can completely disconnect a process from the network
4. **Bind mounts** expose specific directories read-only or read-write
5. **tmpfs overlays** hide directories by mounting empty filesystems over them

### What Bubblewrap can control

| Resource | Mechanism |
|---|---|
| **Filesystem reads** | `--ro-bind` exposes read-only; unlisted paths are invisible |
| **Filesystem writes** | `--bind` for writable; `--ro-bind` for read-only |
| **Sensitive dirs** | `--tmpfs` overlay makes directory appear empty |
| **Network access** | `--unshare-net` creates empty network namespace (no connectivity) |
| **Process isolation** | `--unshare-pid`, `--new-session` |

### Key differences from macOS Seatbelt

| Aspect | macOS Seatbelt | Linux Bubblewrap |
|--------|----------------|------------------|
| Mechanism | Kernel sandbox-exec | User namespaces |
| Network block | `(deny network-*)` with selective allow | `--unshare-net` is all-or-nothing |
| Path deny | Returns "Operation not permitted" | `--tmpfs` makes dir appear empty |
| Configuration | Scheme-like `.sb` files | Bash script with CLI flags |
| Granularity | Fine-grained (per-port, per-domain) | Coarse (on/off per namespace) |

## Profiles

### `codex-strict.sh` -- Maximum Isolation

Blocks everything possible while still allowing Codex to function:

- Blocks all network access (`--unshare-net`)
- Hides `~/.ssh/`, `~/.aws/`, `~/.gnupg/`, `~/.codex/`, `~/.claude/` (appear empty)
- Home directory is read-only
- Allows writes only to cwd and TMPDIR
- Allows reads of system paths (/usr, /bin, /lib, /etc, /opt)

### `codex-network.sh` -- Selective Network Access

Same filesystem isolation as strict, but with network access:

- Full network access (no `--unshare-net`)
- All other restrictions remain

Use for tasks like `npm install`, `git push`, or API calls.

## Usage

Both profiles accept commands directly:

```bash
# Basic usage
./sandbox-profiles/codex-strict.sh codex -s danger-full-access "your task here"

# With explicit working directory
CWD=/path/to/repo ./sandbox-profiles/codex-strict.sh codex -s danger-full-access "task"

# Network-enabled tasks
./sandbox-profiles/codex-network.sh npm install
./sandbox-profiles/codex-network.sh git push
```

**Why `-s danger-full-access`?** Because the outer Bubblewrap is the real sandbox. You don't want Codex to apply its own sandbox inside the custom one (double-sandboxing can cause unexpected issues).

## Prerequisites

1. **Install Bubblewrap**
   ```bash
   # Debian/Ubuntu
   sudo apt install bubblewrap

   # Arch
   sudo pacman -S bubblewrap

   # Fedora
   sudo dnf install bubblewrap
   ```

2. **User namespaces must be enabled** (default on most modern distros)
   ```bash
   # Check if enabled
   cat /proc/sys/kernel/unprivileged_userns_clone
   # Should print: 1

   # Enable if disabled (requires root)
   sudo sysctl kernel.unprivileged_userns_clone=1
   ```

3. **Make scripts executable**
   ```bash
   chmod +x sandbox-profiles/*.sh test-sandbox.sh
   ```

## Testing

Run the verification script to confirm your sandbox is working:

```bash
cd codex-sandbox/platforms/linux/
chmod +x test-sandbox.sh sandbox-profiles/*.sh
./test-sandbox.sh
```

The script tests:
1. **Write isolation** -- writes outside cwd should fail
2. **Network isolation** -- outbound connections should fail (strict profile)
3. **Sensitive file protection** -- `~/.ssh/` should appear empty
4. **Legitimate operations** -- reads/writes within cwd should succeed
5. **Network profile** -- connections should work, filesystem still isolated
6. **Codex integration** -- Codex runs inside sandbox

## Troubleshooting

### "bwrap: No permissions to create new namespace"
User namespaces are disabled. Enable with:
```bash
sudo sysctl kernel.unprivileged_userns_clone=1
# Make permanent:
echo 'kernel.unprivileged_userns_clone=1' | sudo tee /etc/sysctl.d/userns.conf
```

### Permission denied on profile scripts
Make them executable:
```bash
chmod +x sandbox-profiles/*.sh
```

### Programs can't find libraries
The profile might be missing a system path. Check if you need to add:
```bash
--ro-bind /lib64 /lib64
--ro-bind /lib32 /lib32
```

### Node.js / npm issues
Node needs `~/.npm/` cache. Options:
1. Set `NPM_CONFIG_CACHE=./node_modules/.npm`
2. Add `--bind "$HOME/.npm" "$HOME/.npm"` to the profile
3. Use `codex-network.sh` with `danger-full-access`

### Git operations
- `git add`, `git commit`: Work with strict profile (writes to cwd/.git)
- `git push`, `git fetch`: Require network profile
- `git clone`: Requires network profile + write access (clone into cwd)

### /tmp writes fail
The sandbox creates its own `/tmp` via `--tmpfs /tmp`. Writes go to the sandbox's private `/tmp`, not the system `/tmp`. This is intentional isolation. Use `$TMPDIR` for cross-sandbox temp files.

### Debug mode
Run with `strace` to see what's happening:
```bash
CWD=/tmp strace -f ./sandbox-profiles/codex-strict.sh ls 2>&1 | head -50
```

## Fine-grained Network Control

Bubblewrap's `--unshare-net` is all-or-nothing. For more granular control:

1. **iptables/nftables**: Create rules before launching the sandbox
2. **Network namespaces with veth**: More complex but allows per-namespace firewall rules
3. **slirp4netns**: User-mode networking with filtering

Example with nftables (requires root setup):
```bash
# Create a restricted network namespace with limited outbound
# This is more complex and typically requires root privileges
```

For most Codex use cases, the all-or-nothing approach is sufficient:
- Use `codex-strict.sh` for local-only tasks
- Use `codex-network.sh` when network is required

## File Map

```
platforms/linux/
  README.md                  <-- You are here
  test-sandbox.sh            <-- Sandbox verification script
  sandbox-profiles/
    codex-strict.sh          <-- Strict profile (no network, sensitive dirs hidden)
    codex-network.sh         <-- Network-enabled profile (filesystem still isolated)
```

## Security Notes

1. **tmpfs overlay vs deny**: Unlike macOS which returns "Operation not permitted", Bubblewrap's `--tmpfs` makes directories appear empty. The security effect is similar -- the agent cannot access the sensitive data.

2. **No inbound-only blocking**: Bubblewrap's `--unshare-net` blocks all network. Unlike macOS Seatbelt, you can't easily allow outbound while blocking inbound. For most AI agent use cases, this is fine.

3. **Escape vectors**: The sandbox is strong but not escape-proof. A compromised root process or kernel exploit could escape. For high-security scenarios, combine with:
   - SELinux/AppArmor policies
   - seccomp-bpf syscall filtering
   - Running in a VM or container

4. **Path visibility**: Paths not explicitly mounted are invisible inside the sandbox. This is more restrictive than macOS's deny-with-error approach.
