#!/bin/bash
#
# test-sandbox.sh — Verify Codex Sandbox Isolation
#
# PURPOSE:
#   Tests that the Codex sandbox properly blocks dangerous operations.
#   Run this BEFORE trusting the sandbox with real tasks.
#
# WHAT IT TESTS:
#   1. Write isolation   — Can't write files outside the working directory
#   2. Network isolation — Can't make outbound connections
#   3. Sensitive reads   — Can't read ~/.ssh/ (with strict profile)
#   4. Legitimate ops    — CAN read/write within the working directory
#
# USAGE:
#   cd codex-sandbox-mcp/platforms/macos/
#   chmod +x test-sandbox.sh
#   ./test-sandbox.sh
#
# PREREQUISITES:
#   - macOS (uses sandbox-exec / Seatbelt)
#   - Codex CLI installed (codex --version)
#
# HOW IT WORKS:
#   Each test runs a command inside the Codex sandbox and checks whether
#   it succeeded or failed. Write/network/sensitive-read tests SHOULD fail
#   (meaning the sandbox blocked them). Legitimate ops SHOULD succeed.
#

set -euo pipefail

# ─────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="$SCRIPT_DIR/sandbox-profiles"
STRICT_PROFILE="$PROFILE_DIR/codex-strict.sb"
NETWORK_PROFILE="$PROFILE_DIR/codex-network.sb"

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
    ((PASS++))
}

fail() {
    echo -e "  ${RED}FAIL${NC} — $1"
    ((FAIL++))
}

skip() {
    echo -e "  ${YELLOW}SKIP${NC} — $1"
    ((SKIP++))
}

# Run a command inside the Codex Seatbelt sandbox
# Usage: run_sandboxed <profile> <command...>
# Returns: the exit code of the sandboxed command
run_sandboxed() {
    local profile="$1"
    shift
    sandbox-exec \
        -f "$profile" \
        -D "CWD=$TEST_CWD" \
        -D "TMPDIR=${TMPDIR:-/tmp}" \
        -D "HOME=$HOME" \
        "$@" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────
# Pre-flight checks
# ─────────────────────────────────────────────────────────────

print_header "Pre-flight Checks"

# Check we're on macOS
if [[ "$(uname)" != "Darwin" ]]; then
    echo -e "  ${RED}ERROR:${NC} This script requires macOS (Seatbelt/sandbox-exec)."
    echo "  You're running: $(uname -s)"
    exit 1
fi
echo -e "  ${GREEN}OK${NC} — macOS detected ($(sw_vers -productVersion))"

# Check sandbox-exec exists
if ! command -v sandbox-exec &>/dev/null; then
    echo -e "  ${RED}ERROR:${NC} sandbox-exec not found. This should be built into macOS."
    exit 1
fi
echo -e "  ${GREEN}OK${NC} — sandbox-exec available"

# Check Codex CLI
if command -v codex &>/dev/null; then
    echo -e "  ${GREEN}OK${NC} — Codex CLI $(codex --version 2>/dev/null || echo 'installed')"
else
    echo -e "  ${YELLOW}NOTE${NC} — Codex CLI not found (sandbox tests still work without it)"
fi

# Check profiles exist
if [[ -f "$STRICT_PROFILE" ]]; then
    echo -e "  ${GREEN}OK${NC} — Strict profile found: $STRICT_PROFILE"
else
    echo -e "  ${RED}ERROR:${NC} Strict profile not found: $STRICT_PROFILE"
    exit 1
fi

if [[ -f "$NETWORK_PROFILE" ]]; then
    echo -e "  ${GREEN}OK${NC} — Network profile found: $NETWORK_PROFILE"
else
    echo -e "  ${RED}ERROR:${NC} Network profile not found: $NETWORK_PROFILE"
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
if run_sandboxed "$STRICT_PROFILE" /bin/bash -c "touch '$ESCAPE_FILE'" 2>/dev/null; then
    if [[ -f "$ESCAPE_FILE" ]]; then
        fail "SECURITY: File was created OUTSIDE sandbox at $ESCAPE_FILE"
        rm -f "$ESCAPE_FILE"
    else
        pass "Command returned 0 but file not created (sandbox blocked write)"
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
        pass "Command returned 0 but file not created (sandbox blocked write)"
    fi
else
    pass "Write to home directory correctly blocked"
fi

# ═══════════════════════════════════════════════════════════
# TEST GROUP 2: Network Isolation
# ═══════════════════════════════════════════════════════════

print_header "Test Group 2: Network Isolation (Strict Profile)"

# Test 2a: Outbound HTTP should fail with strict profile
print_test "Outbound curl request (should FAIL)" \
    "curl -s --connect-timeout 3 https://example.com"

if run_sandboxed "$STRICT_PROFILE" /usr/bin/curl -s --connect-timeout 3 https://example.com 2>/dev/null; then
    fail "SECURITY: Network request succeeded through strict sandbox"
else
    pass "Outbound network correctly blocked by strict profile"
fi

# Test 2b: DNS resolution should fail with strict profile
print_test "DNS resolution (should FAIL)" \
    "nslookup example.com"

if run_sandboxed "$STRICT_PROFILE" /usr/bin/nslookup example.com 2>/dev/null; then
    fail "SECURITY: DNS resolution succeeded through strict sandbox"
else
    pass "DNS resolution correctly blocked by strict profile"
fi

# ═══════════════════════════════════════════════════════════
# TEST GROUP 3: Network Profile (should ALLOW network)
# ═══════════════════════════════════════════════════════════

print_header "Test Group 3: Network Profile (Selective Access)"

# Test 3a: Outbound HTTP should succeed with network profile
print_test "Outbound curl request (should SUCCEED)" \
    "curl -s --connect-timeout 5 https://example.com"

if OUTPUT=$(run_sandboxed "$NETWORK_PROFILE" /usr/bin/curl -s --connect-timeout 5 https://example.com 2>/dev/null) && [[ -n "$OUTPUT" ]]; then
    pass "Network request succeeded with network profile"
else
    # Network might be unavailable or profile too restrictive
    skip "Network request failed (may be offline or profile needs adjustment)"
fi

# Test 3b: Filesystem isolation should still work with network profile
print_test "Write outside cwd with network profile (should FAIL)" \
    "touch /tmp/network-profile-escape-\$\$"

NET_ESCAPE="/tmp/network-profile-escape-$$"
if run_sandboxed "$NETWORK_PROFILE" /bin/bash -c "touch '$NET_ESCAPE'" 2>/dev/null; then
    if [[ -f "$NET_ESCAPE" ]]; then
        fail "SECURITY: Network profile allows writes outside cwd"
        rm -f "$NET_ESCAPE"
    else
        pass "Network profile still blocks writes outside cwd"
    fi
else
    pass "Network profile still blocks writes outside cwd"
fi

# ═══════════════════════════════════════════════════════════
# TEST GROUP 4: Sensitive File Reads
# ═══════════════════════════════════════════════════════════

print_header "Test Group 4: Sensitive File Protection"

# Test 4a: Reading ~/.ssh/ should fail
print_test "Read ~/.ssh/ directory (should FAIL)" \
    "ls ~/.ssh/"

if run_sandboxed "$STRICT_PROFILE" /bin/ls "$HOME/.ssh/" 2>/dev/null; then
    fail "SECURITY: Sandbox allows reading ~/.ssh/"
else
    pass "Reading ~/.ssh/ correctly blocked"
fi

# Test 4b: Reading ~/.aws/ should fail (even if it doesn't exist, the deny is the point)
print_test "Read ~/.aws/ directory (should FAIL)" \
    "ls ~/.aws/"

if run_sandboxed "$STRICT_PROFILE" /bin/ls "$HOME/.aws/" 2>/dev/null; then
    fail "SECURITY: Sandbox allows reading ~/.aws/"
else
    pass "Reading ~/.aws/ correctly blocked (or doesn't exist)"
fi

# Test 4c: Reading system files should succeed (programs need this)
print_test "Read /usr/bin/ (should SUCCEED)" \
    "ls /usr/bin/ls"

if run_sandboxed "$STRICT_PROFILE" /bin/ls /usr/bin/ls 2>/dev/null; then
    pass "System path reads allowed"
else
    fail "System path reads blocked (programs won't work)"
fi

# ═══════════════════════════════════════════════════════════
# TEST GROUP 5: Codex Built-in Sandbox
# ═══════════════════════════════════════════════════════════

print_header "Test Group 5: Codex Built-in Sandbox"

if command -v codex &>/dev/null; then
    # Test 5a: Codex workspace-write mode
    print_test "Codex sandbox macos --full-auto (should work)" \
        "codex sandbox macos --full-auto -- echo 'hello from sandbox'"

    if codex sandbox macos --full-auto -- echo 'hello from sandbox' 2>/dev/null; then
        pass "Codex built-in sandbox works"
    else
        fail "Codex built-in sandbox failed"
    fi

    # Test 5b: Codex sandbox blocks network
    print_test "Codex sandbox macos network block (should FAIL)" \
        "codex sandbox macos --full-auto -- curl -s --connect-timeout 3 https://example.com"

    if codex sandbox macos --full-auto -- /usr/bin/curl -s --connect-timeout 3 https://example.com 2>/dev/null; then
        fail "SECURITY: Codex built-in sandbox allows network"
    else
        pass "Codex built-in sandbox correctly blocks network"
    fi
else
    skip "Codex CLI not installed — skipping built-in sandbox tests"
    skip "Codex CLI not installed — skipping built-in sandbox tests"
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
    echo "    1. Try: codex -s workspace-write 'add a test for src/main.ts'"
    echo "    2. Try: codex sandbox macos --full-auto -- npm test"
    echo "    3. Read the README.md for MCP bridge integration"
else
    echo -e "  ${RED}Some tests failed. Review the failures above.${NC}"
    echo ""
    echo "  Common issues:"
    echo "    - Seatbelt profile syntax errors (check .sb files)"
    echo "    - macOS version differences (some operations may vary)"
    echo "    - SIP or TCC overriding sandbox rules"
    echo ""
    echo "  Debug with: codex sandbox macos --log-denials -- <failing-command>"
fi

echo ""
exit $FAIL
