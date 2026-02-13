#!/bin/bash
#
# codex-network.sh -- Selective Network Access Profile for Codex CLI
#
# PURPOSE:
#   Same filesystem isolation as codex-strict.sh, but allows network access.
#   Use for tasks that need npm install, git push, or API calls while still
#   constraining filesystem access.
#
# DIFFERENCE FROM codex-strict.sh:
#   - Allows all network access (no --unshare-net)
#   - Filesystem isolation is identical
#
# USAGE:
#   ./codex-network.sh codex -s danger-full-access "npm install && npm test"
#
# SECURITY NOTE:
#   Unlike macOS Seatbelt which can allow outbound-only, Bubblewrap's
#   --unshare-net is all-or-nothing. This profile allows full network.
#   For more granular control, use iptables/nftables alongside this profile.
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
    echo "Example: $0 codex -s danger-full-access 'npm install && npm test'" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────
# Build bwrap command
# ─────────────────────────────────────────────────────────────

# NOTE: No --unshare-net here (network allowed)
# Otherwise identical to codex-strict.sh

BWRAP_ARGS=(
    # ── Network: NOT isolated (this is the key difference) ──
    # --unshare-net is OMITTED

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
    --dev /dev                       # Device nodes
    --proc /proc                     # Process information

    # ── DNS resolution (systemd-resolved) ──
    # Required for network access on systems using systemd-resolved
    --ro-bind /run/systemd/resolve /run/systemd/resolve

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
    "$SANDBOX_HOME/.claude"
    # NOTE: ~/.codex is NOT hidden - Codex needs access to auth.json and config
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

# ── Allow Codex to write to its own directories ──
# Codex needs write access to ~/.codex for sessions, logs, and cache
if [[ -d "$SANDBOX_HOME/.codex" ]]; then
    BWRAP_ARGS+=(--bind "$SANDBOX_HOME/.codex" "$SANDBOX_HOME/.codex")
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
    --new-session                    # New session
)

# ─────────────────────────────────────────────────────────────
# Execute
# ─────────────────────────────────────────────────────────────

exec bwrap "${BWRAP_ARGS[@]}" -- "$@"
