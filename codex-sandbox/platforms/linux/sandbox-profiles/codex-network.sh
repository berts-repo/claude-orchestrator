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
[[ -d /bin ]] && BWRAP_ARGS+=(--ro-bind /bin /bin)
[[ -d /lib ]] && BWRAP_ARGS+=(--ro-bind /lib /lib)
[[ -d /lib64 ]] && BWRAP_ARGS+=(--ro-bind /lib64 /lib64)
[[ -d /lib32 ]] && BWRAP_ARGS+=(--ro-bind /lib32 /lib32)
[[ -d /sbin ]] && BWRAP_ARGS+=(--ro-bind /sbin /sbin)
[[ -d /opt ]] && BWRAP_ARGS+=(--ro-bind /opt /opt)

BWRAP_ARGS+=(
    # ── Device and proc ──
    --dev /dev                       # Device nodes
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
    --new-session                    # New session
)

# ─────────────────────────────────────────────────────────────
# Execute
# ─────────────────────────────────────────────────────────────

exec bwrap "${BWRAP_ARGS[@]}" -- "$@"
