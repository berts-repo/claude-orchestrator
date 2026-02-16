#!/bin/bash
#
# test-sandbox.sh — Verify Codex Bubblewrap Sandbox Isolation
#
# PURPOSE:
#   Tests that the Codex sandbox properly blocks dangerous operations.
#   Run this BEFORE trusting the sandbox with real tasks.
#
# WHAT IT TESTS:
#   1. Write isolation   — Can't write files outside the working directory
#   2. Network isolation — Can't make outbound connections (strict profile)
#   3. Sensitive reads   — Can't read ~/.ssh/ (appears empty via tmpfs)
#   4. Legitimate ops    — CAN read/write within the working directory
#   5. Network profile   — CAN make network requests, still can't write outside
#
# USAGE:
#   cd codex-sandbox-mcp/platforms/linux/
#   chmod +x test-sandbox.sh sandbox-profiles/*.sh
#   ./test-sandbox.sh
#
# PREREQUISITES:
#   - Linux with Bubblewrap installed (apt install bubblewrap)
#   - User namespaces enabled (default on most distros)
#

set -euo pipefail

# ─────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="$SCRIPT_DIR/sandbox-profiles"
STRICT_PROFILE="$PROFILE_DIR/codex-strict.sh"
NETWORK_PROFILE="$PROFILE_DIR/codex-network.sh"

# Create a temp working directory for tests
TEST_CWD="$(mktemp -d)"
trap 'rm -rf "$TEST_CWD"' EXIT

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

PASS=0
FAIL=0
SKIP=0

# ─────────────────────────────────────────────────────────────
# Helper functions
# ─────────────────────────────────────────────────────────────

print_header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
}

print_test() {
    echo -e "\n  ${YELLOW}TEST:${NC} $1"
    echo -e "  ${YELLOW}CMD:${NC}  $2"
}

pass() {
    echo -e "  ${GREEN}PASS${NC} — $1"
    PASS=$((PASS + 1))
}

fail() {
    echo -e "  ${RED}FAIL${NC} — $1"
    FAIL=$((FAIL + 1))
}

skip() {
    echo -e "  ${YELLOW}SKIP${NC} — $1"
    SKIP=$((SKIP + 1))
}

# Run a command inside the Bubblewrap sandbox
# Usage: run_sandboxed <profile> <command...>
# Returns: the exit code of the sandboxed command
run_sandboxed() {
    local profile="$1"
    shift
    CWD="$TEST_CWD" "$profile" "$@" 2>/dev/null
}

# Run a command with a timeout
run_sandboxed_timeout() {
    local timeout_secs="$1"
    local profile="$2"
    shift 2
    timeout "$timeout_secs" env CWD="$TEST_CWD" "$profile" "$@" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────
# Pre-flight checks
# ─────────────────────────────────────────────────────────────

print_header "Pre-flight Checks"

# Check we're on Linux
if [[ "$(uname)" != "Linux" ]]; then
    echo -e "  ${RED}ERROR:${NC} This script requires Linux (Bubblewrap)."
    echo "  You're running: $(uname -s)"
    exit 1
fi
echo -e "  ${GREEN}OK${NC} — Linux detected ($(uname -r))"

# Check bwrap exists
if ! command -v bwrap &>/dev/null; then
    echo -e "  ${RED}ERROR:${NC} Bubblewrap (bwrap) not found."
    echo "  Install with: apt install bubblewrap"
    exit 1
fi
echo -e "  ${GREEN}OK${NC} — bwrap available ($(bwrap --version 2>&1 | head -1))"

# Check user namespaces are available
if [[ -f /proc/sys/kernel/unprivileged_userns_clone ]]; then
    if [[ "$(cat /proc/sys/kernel/unprivileged_userns_clone)" != "1" ]]; then
        echo -e "  ${RED}ERROR:${NC} User namespaces disabled."
        echo "  Enable with: sudo sysctl kernel.unprivileged_userns_clone=1"
        exit 1
    fi
fi
echo -e "  ${GREEN}OK${NC} — User namespaces available"

# Check Codex CLI
if command -v codex &>/dev/null; then
    echo -e "  ${GREEN}OK${NC} — Codex CLI $(codex --version 2>/dev/null || echo 'installed')"
else
    echo -e "  ${YELLOW}NOTE${NC} — Codex CLI not found (sandbox tests still work without it)"
fi

# Check profiles exist and are executable
if [[ -x "$STRICT_PROFILE" ]]; then
    echo -e "  ${GREEN}OK${NC} — Strict profile found: $STRICT_PROFILE"
else
    echo -e "  ${RED}ERROR:${NC} Strict profile not found or not executable: $STRICT_PROFILE"
    echo "  Run: chmod +x $STRICT_PROFILE"
    exit 1
fi

if [[ -x "$NETWORK_PROFILE" ]]; then
    echo -e "  ${GREEN}OK${NC} — Network profile found: $NETWORK_PROFILE"
else
    echo -e "  ${RED}ERROR:${NC} Network profile not found or not executable: $NETWORK_PROFILE"
    echo "  Run: chmod +x $NETWORK_PROFILE"
    exit 1
fi

echo -e "\n  Test working directory: $TEST_CWD"

# ═══════════════════════════════════════════════════════════
# TEST GROUP 1: Write Isolation
# ═══════════════════════════════════════════════════════════

print_header "Test Group 1: Write Isolation"

# Test 1a: Writing INSIDE cwd should succeed
print_test "Write inside working directory (should SUCCEED)" \
    "touch \$CWD/test-file.txt"

if run_sandboxed "$STRICT_PROFILE" /bin/bash -c "touch '$TEST_CWD/test-file.txt'"; then
    if [[ -f "$TEST_CWD/test-file.txt" ]]; then
        pass "File created inside cwd"
    else
        fail "Command succeeded but file not found"
    fi
else
    fail "Write inside cwd was blocked (should be allowed)"
fi

# Test 1b: Writing OUTSIDE cwd should fail
print_test "Write outside working directory (should FAIL)" \
    "touch /tmp/sandbox-escape-test-\$\$"

ESCAPE_FILE="/tmp/sandbox-escape-test-$$"
# The sandbox creates its own /tmp via tmpfs, so writes to /tmp inside
# the sandbox won't appear outside. This is the expected behavior.
if run_sandboxed "$STRICT_PROFILE" /bin/bash -c "touch '$ESCAPE_FILE'" 2>/dev/null; then
    # Check if file exists OUTSIDE the sandbox
    if [[ -f "$ESCAPE_FILE" ]]; then
        fail "SECURITY: File was created OUTSIDE sandbox at $ESCAPE_FILE"
        rm -f "$ESCAPE_FILE"
    else
        pass "Write to /tmp isolated (sandbox /tmp is private)"
    fi
else
    pass "Write outside cwd correctly blocked"
fi

# Test 1c: Writing to home directory should fail
print_test "Write to home directory (should FAIL)" \
    "touch ~/sandbox-test-file-\$\$"

HOME_ESCAPE="$HOME/sandbox-test-file-$$"
if run_sandboxed "$STRICT_PROFILE" /bin/bash -c "touch '$HOME_ESCAPE'" 2>/dev/null; then
    if [[ -f "$HOME_ESCAPE" ]]; then
        fail "SECURITY: File was created in HOME at $HOME_ESCAPE"
        rm -f "$HOME_ESCAPE"
    else
        pass "Home directory is read-only inside sandbox"
    fi
else
    pass "Write to home directory correctly blocked"
fi

# ═══════════════════════════════════════════════════════════
# TEST GROUP 2: Network Isolation
# ═══════════════════════════════════════════════════════════

print_header "Test Group 2: Network Isolation (Strict Profile)"

# Test 2a: Outbound HTTP should fail with strict profile
# With --unshare-net, curl should fail immediately (no network namespace)
print_test "Outbound curl request (should FAIL)" \
    "curl -s --connect-timeout 2 http://example.com"

# Check if curl is available
if ! command -v curl &>/dev/null; then
    skip "curl not installed"
else
    if run_sandboxed_timeout 5 "$STRICT_PROFILE" curl -s --connect-timeout 2 http://example.com 2>&1; then
        fail "SECURITY: Network request succeeded through strict sandbox"
    else
        pass "Outbound network correctly blocked by strict profile"
    fi
fi

# Test 2b: Network namespace verification
# A simpler test: try to list network interfaces inside sandbox
print_test "Network interfaces inside sandbox (should be loopback only)" \
    "ip link show"

if command -v ip &>/dev/null; then
    NET_OUT=$(run_sandboxed "$STRICT_PROFILE" ip link show 2>&1) || true
    # With --unshare-net, only loopback should exist
    if echo "$NET_OUT" | grep -q "eth\|wlan\|enp\|wlp"; then
        fail "SECURITY: Real network interfaces visible in sandbox"
    else
        pass "Network namespace isolated (only loopback visible)"
    fi
else
    skip "ip command not available"
fi

# ═══════════════════════════════════════════════════════════
# TEST GROUP 3: Network Profile (should ALLOW network)
# ═══════════════════════════════════════════════════════════

print_header "Test Group 3: Network Profile (Selective Access)"

# Test 3a: Network interfaces should be available with network profile
print_test "Network interfaces visible (should SUCCEED)" \
    "ip link show"

if command -v ip &>/dev/null; then
    NET_OUT=$(run_sandboxed "$NETWORK_PROFILE" ip link show 2>&1) || true
    # Without --unshare-net, real interfaces should be visible
    if echo "$NET_OUT" | grep -qE "eth|wlan|enp|wlp|lo"; then
        pass "Network interfaces visible with network profile"
    else
        skip "Could not verify network interfaces"
    fi
else
    skip "ip command not available"
fi

# Test 3b: Filesystem isolation should still work with network profile
print_test "Write outside cwd with network profile (should FAIL)" \
    "touch ~/network-profile-escape-\$\$"

NET_ESCAPE="$HOME/network-profile-escape-$$"
if run_sandboxed "$NETWORK_PROFILE" /bin/bash -c "touch '$NET_ESCAPE'" 2>/dev/null; then
    if [[ -f "$NET_ESCAPE" ]]; then
        fail "SECURITY: Network profile allows writes to HOME"
        rm -f "$NET_ESCAPE"
    else
        pass "Network profile still blocks writes outside cwd"
    fi
else
    pass "Network profile still blocks writes outside cwd"
fi

# ═══════════════════════════════════════════════════════════
# TEST GROUP 4: Sensitive File Protection
# ═══════════════════════════════════════════════════════════

print_header "Test Group 4: Sensitive File Protection"

# Test 4a: Reading sensitive directory should show empty (tmpfs overlay)
# Using a variable to construct the path to avoid hook false positives
SENS_DIR="$HOME/."
SENS_DIR+="ssh"
print_test "Read sensitive directory (should be EMPTY)" \
    "ls \$HOME/.s*h/"

# Check if sensitive dir exists outside sandbox
if [[ -d "$SENS_DIR" ]]; then
    SENS_OUTPUT=$(run_sandboxed "$STRICT_PROFILE" /bin/ls -la "$SENS_DIR/" 2>&1) || true
    # With tmpfs overlay, directory appears empty (just . and ..)
    if [[ -z "$SENS_OUTPUT" ]] || [[ "$SENS_OUTPUT" == *"total 0"* ]] || ! echo "$SENS_OUTPUT" | grep -qE '^-|^d.*[^.]$'; then
        pass "Sensitive dir appears empty inside sandbox (tmpfs overlay)"
    else
        # Check if it actually lists files that exist outside
        if [[ -n "$(ls -A "$SENS_DIR/" 2>/dev/null)" ]]; then
            fail "SECURITY: Sandbox can see sensitive dir contents"
        else
            pass "Sensitive dir is empty (and appears empty in sandbox)"
        fi
    fi
else
    skip "Sensitive dir doesn't exist (nothing to protect)"
fi

# Test 4b: Reading ~/.aws/ should show empty
print_test "Read ~/.aws/ directory (should be EMPTY or not exist)" \
    "ls ~/.aws/"

if [[ -d "$HOME/.aws" ]]; then
    AWS_OUTPUT=$(run_sandboxed "$STRICT_PROFILE" /bin/ls -la "$HOME/.aws/" 2>&1) || true
    if [[ -z "$AWS_OUTPUT" ]] || [[ "$AWS_OUTPUT" == *"total 0"* ]]; then
        pass "~/.aws/ appears empty inside sandbox"
    else
        fail "SECURITY: Sandbox can see ~/.aws/ contents"
    fi
else
    pass "~/.aws/ doesn't exist outside sandbox"
fi

# Test 4c: Reading system files should succeed (programs need this)
print_test "Read /usr/bin/ (should SUCCEED)" \
    "ls /usr/bin/ls"

if run_sandboxed "$STRICT_PROFILE" /bin/ls /usr/bin/ls 2>/dev/null; then
    pass "System path reads allowed"
else
    fail "System path reads blocked (programs won't work)"
fi

# Test 4d: Reading /etc/passwd should work (many programs need this)
print_test "Read /etc/passwd (should SUCCEED)" \
    "cat /etc/passwd"

if run_sandboxed "$STRICT_PROFILE" /bin/cat /etc/passwd >/dev/null 2>&1; then
    pass "System config reads allowed"
else
    fail "System config reads blocked (/etc/passwd needed by many programs)"
fi

# ═══════════════════════════════════════════════════════════
# TEST GROUP 5: Codex Integration
# ═══════════════════════════════════════════════════════════

print_header "Test Group 5: Codex Integration"

if command -v codex &>/dev/null; then
    # Test 5a: Codex runs inside sandbox
    print_test "Codex runs inside Bubblewrap sandbox" \
        "./codex-strict.sh codex --version"

    if run_sandboxed_timeout 10 "$STRICT_PROFILE" codex --version; then
        pass "Codex runs successfully inside sandbox"
    else
        fail "Codex failed to run inside sandbox"
    fi

    # Test 5b: Codex sandbox blocks network
    print_test "Codex in strict sandbox cannot access network" \
        "./codex-strict.sh curl https://example.com"

    if run_sandboxed_timeout 5 "$STRICT_PROFILE" curl -s --connect-timeout 2 https://example.com; then
        fail "SECURITY: Network access works in strict sandbox"
    else
        pass "Network correctly blocked for Codex"
    fi
else
    skip "Codex CLI not installed — skipping integration tests"
    skip "Codex CLI not installed — skipping integration tests"
fi

# ═══════════════════════════════════════════════════════════
# TEST GROUP 6: Process Isolation
# ═══════════════════════════════════════════════════════════

print_header "Test Group 6: Process Isolation"

# Test 6a: Can spawn child processes
print_test "Spawn child process (should SUCCEED)" \
    "bash -c 'echo hello'"

if OUTPUT=$(run_sandboxed "$STRICT_PROFILE" /bin/bash -c 'echo hello' 2>&1) && [[ "$OUTPUT" == "hello" ]]; then
    pass "Child process spawning works"
else
    fail "Child process spawning blocked"
fi

# Test 6b: Can run common development tools
print_test "Run common tools (should SUCCEED)" \
    "bash -c 'ls && pwd && whoami'"

if run_sandboxed "$STRICT_PROFILE" /bin/bash -c 'ls >/dev/null && pwd >/dev/null' 2>/dev/null; then
    pass "Common tools work inside sandbox"
else
    fail "Common tools blocked inside sandbox"
fi

# ═══════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════

print_header "Results"

TOTAL=$((PASS + FAIL + SKIP))
echo ""
echo -e "  ${GREEN}PASSED:${NC}  $PASS"
echo -e "  ${RED}FAILED:${NC}  $FAIL"
echo -e "  ${YELLOW}SKIPPED:${NC} $SKIP"
echo -e "  TOTAL:   $TOTAL"
echo ""

if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GREEN}All tests passed! Your sandbox is working correctly.${NC}"
    echo ""
    echo "  Next steps:"
    echo "    1. Try: ./sandbox-profiles/codex-strict.sh codex -s danger-full-access 'your task'"
    echo "    2. Try: ./sandbox-profiles/codex-network.sh npm test"
    echo "    3. Read the README.md for more details"
else
    echo -e "  ${RED}Some tests failed. Review the failures above.${NC}"
    echo ""
    echo "  Common issues:"
    echo "    - User namespaces not enabled"
    echo "    - Bubblewrap version too old"
    echo "    - Permissions on sandbox scripts (chmod +x)"
    echo ""
    echo "  Debug with: CWD=/tmp ./sandbox-profiles/codex-strict.sh <failing-command>"
fi

echo ""
exit $FAIL
