# Linux Sandbox -- Planned

Linux sandbox profiles for Codex CLI are not yet implemented. This directory is a placeholder for future work.

## Candidate Technologies

| Technology | Kernel version | Scope |
|---|---|---|
| [Bubblewrap](https://github.com/containers/bubblewrap) (`bwrap`) | Any modern | Namespace-based sandboxing (filesystem, network, PID) |
| [Landlock](https://landlock.io/) | 5.13+ | LSM for filesystem access control, no root required |
| [seccomp-bpf](https://www.kernel.org/doc/html/latest/userspace-api/seccomp_filter.html) | 3.5+ | System call filtering |

## Goals

The Linux profiles should provide equivalent isolation to the macOS Seatbelt profiles:

1. **Write isolation** -- Codex can only write to cwd and TMPDIR
2. **Network isolation** -- No outbound connections (strict), or controlled outbound (network profile)
3. **Sensitive file protection** -- Block reads of `~/.ssh/`, `~/.aws/`, `~/.gnupg/`, etc.
4. **System path reads** -- Allow reading `/usr/`, `/bin/`, `/lib/`, etc.

## File Map

```
platforms/linux/
  README.md              <-- You are here
  sandbox-profiles/      <-- Future profile files
  test-sandbox.sh        <-- Future verification script
```
