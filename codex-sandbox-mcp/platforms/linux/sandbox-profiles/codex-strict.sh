#!/bin/bash
#
# codex-strict.sh -- Strict Bubblewrap Sandbox for Codex CLI
#
# PURPOSE:
#   Maximum isolation for Codex agent tasks. Blocks writes outside cwd,
#   blocks all network access, and hides sensitive home directories.
#
# WHAT THIS BLOCKS:
#   - Writing anywhere except cwd and TMPDIR
#   - All network access (via unshare-net)
#   - Reading sensitive home dotfiles (~/.ssh, ~/.aws, etc.) -- appear empty
#
# WHAT THIS ALLOWS:
#   - Reading system paths (/usr/, /bin/, /lib/, /etc/, /opt/)
#   - Reading most of the home directory (for .gitconfig, .npmrc, etc.)
#   - Reading and writing within the working directory
#   - Writing to TMPDIR (sandbox-private /tmp if TMPDIR not set)
#   - Process execution, signals
#
# USAGE:
#   ./codex-strict.sh codex -s danger-full-access "your task here"
#
#   Or with explicit CWD:
#   CWD=/path/to/repo ./codex-strict.sh codex -s danger-full-access "task"
#
#   NOTE: Use -s danger-full-access with Codex because THIS profile is the
#   real sandbox. Don't double-sandbox.
#
# HOW BUBBLEWRAP WORKS:
#   - Uses Linux namespaces to create isolated environments
#   - --ro-bind creates read-only bind mounts
#   - --bind creates read-write bind mounts
#   - --tmpfs creates fresh tmpfs (hides underlying directory)
#   - --unshare-net creates network namespace with no network access
#   - Last mount wins if paths overlap
#
# REQUIREMENTS:
#   - Bubblewrap (bwrap) installed: apt install bubblewrap
#   - User namespaces enabled (default on most modern distros)
#
# KEY DIFFERENCE FROM MACOS:
#   Bubblewrap uses --tmpfs to HIDE sensitive directories (they appear empty),
#   while macOS Seatbelt uses deny rules (access returns "Operation not permitted").
#   The security effect is similar -- the agent cannot read the sensitive data.
#

set -euo pipefail

# ─────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────

CWD="${CWD:-$(pwd -P)}"
SANDBOX_HOME="${HOME:-/home/$USER}"

# TMPDIR handling: if set and exists, bind it writable. Otherwise use sandbox /tmp.
SANDBOX_TMPDIR="${TMPDIR:-}"

# ─────────────────────────────────────────────────────────────
# Validation
# ─────────────────────────────────────────────────────────────

if ! command -v bwrap &>/dev/null; then
    echo "ERROR: Bubblewrap (bwrap) not found." >&2
    echo "Install with: apt install bubblewrap" >&2
    exit 1
fi

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <command> [args...]" >&2
    echo "Example: $0 codex -s danger-full-access 'your task here'" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────
# Build bwrap command
# ─────────────────────────────────────────────────────────────

# NOTE: Order matters! Later mounts can override earlier ones.
# We mount home read-only first, then overlay tmpfs on sensitive dirs,
# then bind the CWD writable last.

BWRAP_ARGS=(
    # ── Network isolation ──
    --unshare-net                    # No network access at all

    # ── System paths (read-only) ──
    --ro-bind /usr /usr              # System binaries and libraries
    --ro-bind /etc /etc              # System configuration
)

# Handle optional system paths that may or may not exist
# On modern distros (Arch, Fedora), /bin /lib /sbin are symlinks to /usr/*
# We need to use --symlink for symlinks, --ro-bind for real directories
bind_or_symlink() {
    local path="$1"
    if [[ -L "$path" ]]; then
        # It's a symlink - recreate it inside sandbox
        local target
        target=$(readlink "$path")
        BWRAP_ARGS+=(--symlink "$target" "$path")
    elif [[ -d "$path" ]]; then
        # It's a real directory - bind mount it
        BWRAP_ARGS+=(--ro-bind "$path" "$path")
    fi
}

bind_or_symlink /bin
bind_or_symlink /lib
bind_or_symlink /lib64
bind_or_symlink /lib32
bind_or_symlink /sbin
bind_or_symlink /opt

BWRAP_ARGS+=(
    # ── Device and proc ──
    --dev /dev                       # Device nodes (/dev/null, /dev/urandom, etc.)
    --proc /proc                     # Process information

    # ── Temporary filesystem ──
    # Create a fresh, writable /tmp inside the sandbox (isolated from host /tmp)
    --tmpfs /tmp

    # ── Home directory (read-only base) ──
    --ro-bind "$SANDBOX_HOME" "$SANDBOX_HOME"
)

# ── Hide sensitive directories (tmpfs overlay = appears empty) ──
# Only add tmpfs for directories that exist, otherwise bwrap fails
SENSITIVE_DIRS=(
    "$SANDBOX_HOME/.ssh"
    "$SANDBOX_HOME/.aws"
    "$SANDBOX_HOME/.gnupg"
    "$SANDBOX_HOME/.config/gcloud"
    "$SANDBOX_HOME/.codex"
    "$SANDBOX_HOME/.claude"
)

for dir in "${SENSITIVE_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
        BWRAP_ARGS+=(--tmpfs "$dir")
    fi
done

# ── Writable TMPDIR (only if explicitly set and different from /tmp) ──
# If TMPDIR is set to something like /run/user/1000 or similar, bind it writable
if [[ -n "$SANDBOX_TMPDIR" && "$SANDBOX_TMPDIR" != "/tmp" && -d "$SANDBOX_TMPDIR" ]]; then
    BWRAP_ARGS+=(--bind "$SANDBOX_TMPDIR" "$SANDBOX_TMPDIR")
fi

BWRAP_ARGS+=(
    # ── Writable working directory ──
    --bind "$CWD" "$CWD"

    # ── Environment ──
    --chdir "$CWD"                   # Start in working directory
    --setenv HOME "$SANDBOX_HOME"    # Preserve HOME
    --setenv TMPDIR "/tmp"           # Point to sandbox-private /tmp
    --setenv CWD "$CWD"

    # ── Misc ──
    --die-with-parent                # Kill sandbox if parent dies
    --new-session                    # New session (no job control from outside)
)

# ─────────────────────────────────────────────────────────────
# Execute
# ─────────────────────────────────────────────────────────────

exec bwrap "${BWRAP_ARGS[@]}" -- "$@"
