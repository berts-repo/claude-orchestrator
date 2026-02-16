# Enforcement Options: Preventing Delegation Bypass

This report explores options for preventing Claude from bypassing Codex delegation by working directly with primitive tools. The goal is to ensure token-saving delegation patterns are followed consistently.

## Current State

### Existing Enforcement

The orchestrator currently implements two layers of enforcement:

**1. Hard Blocks (PreToolUse hooks)**

| Hook | Target | Behavior |
|------|--------|----------|
| `block-explore-for-codex.sh` | Task subagent "Explore" | Block with redirect message |
| `block-test-gen-for-codex.sh` | Task subagent "test_gen" | Block with redirect message |
| `block-doc-comments-for-codex.sh` | Task subagent "doc_comments" | Block with redirect message |
| `block-diff-digest-for-codex.sh` | Task subagent "diff_digest" | Block with redirect message |

**2. Soft Hints (UserPromptSubmit hook)**

`inject-codex-hint.sh` detects task patterns in user prompts and injects delegation reminders:
- Test generation patterns → Hint to use Codex with `workspace-write`
- Code review patterns → Hint to use Codex with `read-only`
- Refactoring patterns → Hint to use Codex with `workspace-write`
- Documentation patterns → Hint to use Codex with `workspace-write`

### Identified Gaps

Claude can bypass delegation entirely by using primitive tools:

| Bypass Vector | Tools Used | Impact |
|---------------|-----------|--------|
| Direct file exploration | Read, Grep, Glob | Full file contents loaded into context |
| Direct test writing | Edit, Write | Tests written without Codex sandbox |
| Direct docstring additions | Edit | Documentation added inline |
| Inline code review | Read + conversation | Review output in main context |

These bypasses defeat the token-saving purpose of delegation (90-97% savings lost).

---

## Enforcement Options

### Option 1: Block Direct Test File Writes

**Concept:** Prevent Claude from writing test files directly, forcing delegation to Codex.

**Implementation:**

```bash
#!/usr/bin/env bash
# PreToolUse hook: Block direct test file writes
set -euo pipefail

tool_name="$(jq -r '.tool_name // ""')"
[[ "$tool_name" != "Edit" && "$tool_name" != "Write" ]] && exit 0

file_path="$(echo "$CLAUDE_TOOL_INPUT" | jq -r '.file_path // ""')"

# Test file patterns
if echo "$file_path" | grep -Eiq '(_test\.(py|ts|js|go|rb)|\.test\.(ts|js|tsx|jsx)|_spec\.(rb|ts|js)|test_[^/]+\.py$|/__tests__/|/tests?/test_|/spec/)'; then
  cat <<'EOF'
{
  "decision": "block",
  "reason": "Direct test file writes are blocked. Delegate to Codex: mcp__codex__codex with sandbox='workspace-write', approval-policy='on-failure'. Include the test command in your prompt."
}
EOF
  exit 0
fi

echo '{"decision":"allow"}'
```

**Patterns Matched:**
- `*_test.py`, `*_test.ts`, `*_test.js`, `*_test.go`, `*_test.rb`
- `*.test.ts`, `*.test.js`, `*.test.tsx`, `*.test.jsx`
- `*_spec.rb`, `*_spec.ts`, `*_spec.js`
- `test_*.py`
- `__tests__/*`
- `tests/test_*`, `test/test_*`
- `spec/*`

**Pros:**
- Strong enforcement; cannot be ignored
- Clear, actionable error message
- Pattern-based; no state tracking required

**Cons:**
- May block legitimate small test fixes (typos, imports)
- Requires maintaining pattern list across languages
- Cannot distinguish new test creation from test edits

**Variations:**
- Block only `Write` (new files), allow `Edit` (modifications)
- Add allowlist for specific small edits (import fixes, typo corrections)

---

### Option 2: Block Direct Docstring/Comment Additions

**Concept:** Detect when Edit adds documentation patterns and block or warn.

**Implementation:**

```bash
#!/usr/bin/env bash
# PreToolUse hook: Block direct docstring additions
set -euo pipefail

tool_name="$(jq -r '.tool_name // ""')"
[[ "$tool_name" != "Edit" ]] && exit 0

new_string="$(echo "$CLAUDE_TOOL_INPUT" | jq -r '.new_string // ""')"
old_string="$(echo "$CLAUDE_TOOL_INPUT" | jq -r '.old_string // ""')"

# Check if adding docstrings (not present in old, present in new)
# Python docstrings
if echo "$new_string" | grep -q '"""' && ! echo "$old_string" | grep -q '"""'; then
  cat <<'EOF'
{
  "decision": "block",
  "reason": "Direct docstring additions are blocked. Delegate to Codex: mcp__codex__codex with sandbox='workspace-write' for documentation tasks."
}
EOF
  exit 0
fi

# JSDoc comments
if echo "$new_string" | grep -q '/\*\*' && ! echo "$old_string" | grep -q '/\*\*'; then
  cat <<'EOF'
{
  "decision": "block",
  "reason": "Direct JSDoc additions are blocked. Delegate to Codex: mcp__codex__codex with sandbox='workspace-write' for documentation tasks."
}
EOF
  exit 0
fi

echo '{"decision":"allow"}'
```

**Patterns Detected:**
- Python: `"""..."""` or `'''...'''`
- JavaScript/TypeScript: `/** ... */`
- Ruby: `# ...` block comments (harder to distinguish)
- Go: `// ...` preceding function declarations

**Pros:**
- Targets the specific behavior (adding docs)
- Allows other legitimate edits to proceed

**Cons:**
- Heuristic-based; may have false positives
- String containing `"""` for other purposes would trigger
- Complex to detect all documentation patterns across languages
- Cannot distinguish inline comments from docstrings reliably

**Variations:**
- Soft hint instead of hard block
- Only trigger if `new_string` is significantly longer than `old_string` (bulk addition)

---

### Option 3: Rate-Limit or Hint on Excessive File Reads

**Concept:** Track file read count; if Claude reads many files without delegating, inject a hint or block.

**Implementation Approach A: Stateless (Session File)**

```bash
#!/usr/bin/env bash
# PreToolUse hook: Track reads, hint on excessive exploration
set -euo pipefail

tool_name="$(jq -r '.tool_name // ""')"

STATE_FILE="/tmp/claude-read-count-$$"

if [[ "$tool_name" == "mcp__codex__codex" ]]; then
  # Reset counter on Codex use
  rm -f "$STATE_FILE"
  echo '{"decision":"allow"}'
  exit 0
fi

[[ "$tool_name" != "Read" ]] && exit 0

# Increment counter
count=0
[[ -f "$STATE_FILE" ]] && count=$(cat "$STATE_FILE")
count=$((count + 1))
echo "$count" > "$STATE_FILE"

if [[ $count -ge 10 ]]; then
  cat <<'EOF'
{
  "decision": "allow",
  "hookSpecificOutput": {
    "additionalContext": "You have read 10+ files. Consider delegating exploration to Codex with sandbox='read-only' to reduce context usage."
  }
}
EOF
  exit 0
fi

echo '{"decision":"allow"}'
```

**Implementation Approach B: Stateless (Approximate via Hook Timing)**

Hook cannot easily track state across calls without external storage. Options:
- Temp file per session (approach A)
- SQLite database
- Redis/external store (overkill)

**Pros:**
- Addresses the exploration bypass (most common)
- Soft enforcement respects legitimate use cases
- Threshold is tunable

**Cons:**
- Requires state management (temp files, cleanup)
- Session isolation is tricky (PID-based, timestamp-based)
- May trigger during legitimate focused work
- Cleanup on session end is unreliable

**Variations:**
- Hard block after N reads instead of hint
- Reset counter on any tool besides Read/Grep/Glob
- Track unique files, not total read calls

---

### Option 4: Block Writes to Test Directories

**Concept:** Simpler than Option 1; block any Write to common test directories.

**Implementation:**

```bash
#!/usr/bin/env bash
# PreToolUse hook: Block writes to test directories
set -euo pipefail

tool_name="$(jq -r '.tool_name // ""')"
[[ "$tool_name" != "Write" ]] && exit 0

file_path="$(echo "$CLAUDE_TOOL_INPUT" | jq -r '.file_path // ""')"

# Test directory patterns
if echo "$file_path" | grep -Eiq '(/__tests__/|/tests?/|/spec/|/test_)'; then
  cat <<'EOF'
{
  "decision": "block",
  "reason": "Direct writes to test directories are blocked. Delegate test generation to Codex: mcp__codex__codex with sandbox='workspace-write'."
}
EOF
  exit 0
fi

echo '{"decision":"allow"}'
```

**Pros:**
- Simple pattern matching
- Catches most test file creation
- Low false positive rate (directories are unambiguous)

**Cons:**
- Only blocks Write (new files), not Edit (modifications)
- Test files outside standard directories are missed
- Some projects have non-standard test locations

---

### Option 5: Block Inline Review Output

**Concept:** Detect when Claude outputs review-style content without having delegated.

**Implementation Challenge:** This would require a PostToolUse or response-analysis hook that:
1. Checks if Codex was used recently
2. Analyzes Claude's text output for review patterns
3. Blocks or warns if review content detected without delegation

**This is significantly harder because:**
- No hook runs on Claude's text output (only tool use)
- Would require response filtering (not currently supported)
- Cannot reliably distinguish review from explanation

**Alternative Approach:** Strengthen the UserPromptSubmit hint to be more assertive, or add a "review mode" that must be explicitly entered via Codex.

**Verdict:** Not feasible with current hook architecture.

---

### Option 6: Require Codex for Large File Batches

**Concept:** If Claude attempts to read more than N files in a single turn, require Codex delegation instead.

**Implementation:**

```bash
#!/usr/bin/env bash
# PreToolUse hook: Require Codex for batch file operations
set -euo pipefail

# This requires tracking within a single assistant turn
# Hook would need turn-level state, which is complex

# Alternative: Block Read if >N files already read this turn
# Requires CLAUDE_TURN_ID or similar context (not currently available)
```

**Verdict:** Not feasible without turn-level context in hooks.

---

## Comparison Matrix

| Option | Enforcement | Complexity | False Positives | Bypass Risk |
|--------|-------------|------------|-----------------|-------------|
| 1. Block test file writes | Hard | Medium | Medium | Low |
| 2. Block docstring additions | Hard | High | High | Low |
| 3. Rate-limit reads | Soft | High | Medium | Medium |
| 4. Block test directories | Hard | Low | Low | Medium |
| 5. Block inline review | N/A | N/A | N/A | N/A |
| 6. Require Codex for batch | N/A | N/A | N/A | N/A |

---

## Recommendations

### Immediate Implementation (Low Risk, High Value)

**1. Implement Option 4: Block Writes to Test Directories**

- Simple, low false-positive rate
- Catches most test file creation
- Complements existing `block-test-gen-for-codex.sh`

**2. Implement Option 1 (Write-only variant): Block New Test Files**

- Block Write to test file patterns
- Allow Edit for small fixes
- Provides escape hatch for legitimate edits

### Medium-Term Implementation (Requires Testing)

**3. Implement Option 3: Read Rate Hints**

- Start with soft hints at 10+ reads
- Use session-scoped temp files
- Add cleanup on session end
- Monitor for false positive rate before considering hard block

### Deferred (High Complexity, Uncertain Value)

**4. Option 2: Docstring Detection**

- High false positive risk
- Complex pattern matching across languages
- Consider only if documentation bypass becomes a real problem

### Not Recommended

- Option 5 and 6: Not feasible with current architecture

---

## Implementation Priority

1. `block-test-directory-writes.sh` (Option 4) - **Implement first**
2. `block-test-file-writes.sh` (Option 1, Write-only) - **Implement second**
3. `hint-excessive-reads.sh` (Option 3) - **Implement after monitoring**

---

## Appendix: Hook Registration

New hooks should be added to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit|Write",
        "command": "~/.claude/hooks/block-test-file-writes.sh"
      }
    ]
  }
}
```

And symlinked from the project:

```bash
ln -sf ~/git/claude-orchestrator/codex-sandbox-mcp/delegations/hooks/block-test-file-writes.sh \
       ~/.claude/hooks/block-test-file-writes.sh
```
