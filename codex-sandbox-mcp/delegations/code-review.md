# Code Review Delegation — Claude to Codex

## When to Use

- Reviewing a PR or set of commits
- Security audits of specific modules
- Quality checks before merging
- Analyzing unfamiliar codebases
- Checking for common anti-patterns

**Token savings**: ~90% — Codex reads all files and produces a structured review summary.

## Prerequisites

- **Sandbox mode**: `read-only` (review doesn't modify files)
- **Approval policy**: `never` (fully autonomous — can't do anything dangerous)
- **Project setup**: None required

---

## MCP Call Template

```json
{
  "tool": "mcp__codex__codex",
  "parameters": {
    "prompt": "Review the changes in the last 3 commits. Check for:\n1. Logic errors\n2. Missing error handling\n3. Security issues\n4. Performance concerns\n\nProvide a structured review with severity ratings.",
    "sandbox": "read-only",
    "approval-policy": "never",
    "cwd": "/path/to/project"
  }
}
```

---

## Prompt Variations

### Variant A: PR Review (Commits)

```json
{
  "tool": "mcp__codex__codex",
  "parameters": {
    "prompt": "Review the changes in commits abc123..def456.\n\nFor each file changed:\n1. Summarize the change\n2. Note any concerns (bugs, security, performance)\n3. Suggest improvements\n\nProvide an overall assessment: APPROVE, REQUEST_CHANGES, or COMMENT.",
    "sandbox": "read-only",
    "approval-policy": "never",
    "cwd": "/path/to/project"
  }
}
```

### Variant B: Security Audit

```json
{
  "tool": "mcp__codex__codex",
  "parameters": {
    "prompt": "Security review of src/auth/ directory.\n\nCheck for:\n1. SQL injection vulnerabilities\n2. XSS vulnerabilities\n3. Missing input validation\n4. Hardcoded secrets or credentials\n5. Insecure cryptographic practices\n6. Authentication/authorization bypasses\n\nFor each finding:\n- Severity: CRITICAL, HIGH, MEDIUM, LOW\n- Location: file:line\n- Description: What's wrong\n- Recommendation: How to fix",
    "sandbox": "read-only",
    "approval-policy": "never",
    "cwd": "/path/to/project"
  }
}
```

### Variant C: Architecture Review

```json
{
  "tool": "mcp__codex__codex",
  "parameters": {
    "prompt": "Review the architecture of the src/services/ directory.\n\nAnalyze:\n1. Separation of concerns\n2. Dependency direction (are dependencies pointing inward?)\n3. Coupling between modules\n4. Error handling patterns\n5. Testability\n\nProvide recommendations for improving the structure.",
    "sandbox": "read-only",
    "approval-policy": "never",
    "cwd": "/path/to/project"
  }
}
```

### Variant D: Performance Review

```json
{
  "tool": "mcp__codex__codex",
  "parameters": {
    "prompt": "Performance review of src/api/handlers/.\n\nCheck for:\n1. N+1 query patterns\n2. Missing database indexes (based on query patterns)\n3. Unnecessary data fetching\n4. Missing caching opportunities\n5. Blocking operations in async code\n6. Memory leaks (unclosed resources, growing collections)\n\nFor each finding, estimate impact and suggest fix.",
    "sandbox": "read-only",
    "approval-policy": "never",
    "cwd": "/path/to/project"
  }
}
```

### Variant E: Code Quality Review

```json
{
  "tool": "mcp__codex__codex",
  "parameters": {
    "prompt": "Quality review of src/utils/.\n\nCheck for:\n1. Dead code (unused functions, unreachable branches)\n2. Code duplication\n3. Overly complex functions (cyclomatic complexity)\n4. Missing error handling\n5. Inconsistent naming conventions\n6. Magic numbers/strings\n\nPrioritize findings by impact on maintainability.",
    "sandbox": "read-only",
    "approval-policy": "never",
    "cwd": "/path/to/project"
  }
}
```

---

## Expected Return Format

```
## Review Summary
Reviewed 5 files, 312 lines changed.
Overall: REQUEST_CHANGES (2 issues require attention)

## Critical Issues
None

## High Severity
1. **SQL Injection Risk** - src/api/users.ts:47
   - Raw user input concatenated into SQL query
   - Fix: Use parameterized queries

2. **Missing Auth Check** - src/api/admin.ts:23
   - Admin endpoint lacks authentication middleware
   - Fix: Add requireAdmin middleware

## Medium Severity
1. **Unhandled Promise Rejection** - src/services/email.ts:89
   - async function without try/catch
   - Fix: Add error handling or let caller handle

## Low Severity / Suggestions
1. Consider extracting validation logic to shared utility
2. Magic string "active" should be a constant

## Files Reviewed
- src/api/users.ts (modified) - 2 issues
- src/api/admin.ts (modified) - 1 issue
- src/services/email.ts (modified) - 1 issue
- src/utils/helpers.ts (new) - OK
- src/types/index.ts (modified) - OK
```

---

## Error Handling

**Can't access git history:**
```
"The repository doesn't have git history available.
 Instead, review all files in src/api/ for the same criteria."
```

**Too many files to review:**
```
"There are 50+ files to review. Focus on:
 1. Files in src/api/ (public interface)
 2. Files in src/auth/ (security-critical)
 Skip test files and type definitions."
```

---

## Why Read-Only is Sufficient

Code review is purely analytical:
- Read source files
- Read git history (git log, git diff, git show)
- Produce a text report

Codex doesn't need to:
- Modify files
- Run tests
- Access network

Using `read-only` sandbox provides maximum security for review tasks.

---

Related: [sandbox config](../config.toml)
