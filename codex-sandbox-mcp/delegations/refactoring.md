# Refactoring Delegation — Claude to Codex

## When to Use

- Renaming classes, functions, or variables across the codebase
- Extracting code into new modules or functions
- Changing function signatures and updating callers
- Migrating to new patterns (callbacks → async/await, class → hooks)
- Consolidating duplicate code

**Token savings**: ~85% — Mechanical refactors touch many files but follow predictable patterns.

## Prerequisites

- **Sandbox mode**: `workspace-write` (needs to modify files)
- **Approval policy**: `on-failure` (auto-approve unless something breaks)
- **Project setup**: Tests should exist to verify refactor didn't break anything

---

## MCP Call Template

```json
{
  "tool": "mcp__codex__codex",
  "parameters": {
    "prompt": "Rename the 'UserService' class to 'AccountService' across the entire codebase.\n\nSteps:\n1. Rename the class definition\n2. Update all imports\n3. Update all references\n4. Update test files\n5. Run tests to verify\n\nReport: files changed, references updated, test results.",
    "sandbox": "workspace-write",
    "approval-policy": "on-failure",
    "cwd": "/path/to/project"
  }
}
```

---

## Prompt Variations

### Variant A: Rename Across Codebase

```json
{
  "tool": "mcp__codex__codex",
  "parameters": {
    "prompt": "Rename '{{OLD_NAME}}' to '{{NEW_NAME}}' everywhere in the codebase.\n\nInclude:\n- Class/function/variable definitions\n- All imports and exports\n- All usage sites\n- Test files\n- Type definitions\n\nRun: {{TEST_COMMAND}}\n\nReport: files changed, occurrences updated, test results.",
    "sandbox": "workspace-write",
    "approval-policy": "on-failure",
    "cwd": "/path/to/project"
  }
}
```

### Variant B: Extract Function/Module

```json
{
  "tool": "mcp__codex__codex",
  "parameters": {
    "prompt": "Extract the validation logic from src/api/users.ts (lines 45-89) into a new file src/utils/userValidation.ts.\n\nSteps:\n1. Create the new file with the extracted functions\n2. Add proper exports\n3. Update src/api/users.ts to import from the new file\n4. Update any other files that might benefit from the shared validation\n5. Run tests\n\nConstraints:\n- Preserve all existing behavior\n- Maintain type safety\n- Don't change public API",
    "sandbox": "workspace-write",
    "approval-policy": "on-failure",
    "cwd": "/path/to/project"
  }
}
```

### Variant C: Change Function Signature

```json
{
  "tool": "mcp__codex__codex",
  "parameters": {
    "prompt": "Change the signature of 'processOrder' from:\n  processOrder(orderId: string, userId: string)\nto:\n  processOrder(options: { orderId: string; userId: string; priority?: number })\n\nSteps:\n1. Update the function definition\n2. Update all call sites to use the new object syntax\n3. Update tests\n4. Run tests\n\nFor call sites, convert:\n  processOrder('abc', 'user1') → processOrder({ orderId: 'abc', userId: 'user1' })",
    "sandbox": "workspace-write",
    "approval-policy": "on-failure",
    "cwd": "/path/to/project"
  }
}
```

### Variant D: Migrate Pattern

```json
{
  "tool": "mcp__codex__codex",
  "parameters": {
    "prompt": "Migrate callback-style functions in src/services/ to async/await.\n\nConvert patterns like:\n  function getData(id, callback) {\n    db.query(..., (err, result) => callback(err, result));\n  }\n\nTo:\n  async function getData(id) {\n    return await db.query(...);\n  }\n\nSteps:\n1. Convert each function\n2. Update callers to use await\n3. Add error handling where callbacks had error params\n4. Run tests after each file\n\nSkip: Functions that are part of public API (would break consumers)",
    "sandbox": "workspace-write",
    "approval-policy": "on-failure",
    "cwd": "/path/to/project"
  }
}
```

### Variant E: Consolidate Duplicates

```json
{
  "tool": "mcp__codex__codex",
  "parameters": {
    "prompt": "Find and consolidate duplicate code in src/api/.\n\nSteps:\n1. Identify functions/blocks that are duplicated or near-duplicated\n2. Create shared utilities in src/utils/ for common patterns\n3. Replace duplicates with calls to shared utilities\n4. Run tests\n\nConstraints:\n- Only consolidate true duplicates (same logic, not just similar structure)\n- Preserve all existing behavior\n- Document new utilities with JSDoc\n\nReport: duplicates found, utilities created, files updated",
    "sandbox": "workspace-write",
    "approval-policy": "on-failure",
    "cwd": "/path/to/project"
  }
}
```

### Variant F: File/Directory Restructure

```json
{
  "tool": "mcp__codex__codex",
  "parameters": {
    "prompt": "Restructure src/components/ from flat to feature-based:\n\nCurrent:\n  src/components/\n    Button.tsx\n    Input.tsx\n    UserCard.tsx\n    UserList.tsx\n    ProductCard.tsx\n\nTarget:\n  src/components/\n    common/\n      Button.tsx\n      Input.tsx\n    users/\n      UserCard.tsx\n      UserList.tsx\n    products/\n      ProductCard.tsx\n\nSteps:\n1. Create new directories\n2. Move files\n3. Update all imports throughout the codebase\n4. Update barrel exports (index.ts)\n5. Run tests",
    "sandbox": "workspace-write",
    "approval-policy": "on-failure",
    "cwd": "/path/to/project"
  }
}
```

---

## Expected Return Format

```
## Summary
Renamed 'UserService' to 'AccountService' across 12 files.

## Files Modified
- src/services/AccountService.ts (renamed from UserService.ts)
- src/api/users.ts (3 import updates, 5 usage updates)
- src/api/admin.ts (1 import update, 2 usage updates)
- src/controllers/auth.ts (1 import update, 1 usage update)
- tests/services/AccountService.test.ts (renamed, 8 references updated)
- tests/api/users.test.ts (2 references updated)

## Changes
- 1 file renamed
- 11 files modified
- 24 references updated

## Test Results
✓ npm test
45 tests passed, 0 failed

## Notes
- Also updated JSDoc comments referencing UserService
- Found 2 comments mentioning "user service" — left as-is (human review recommended)
```

---

## Error Handling

**Tests fail after refactor:**
```
"Tests failed after renaming. Rolling back changes.

Failed test: tests/api/users.test.ts
Error: Cannot find module '../services/UserService'

Investigation: The test file has a hardcoded path.
Fix: Update line 5 to import from '../services/AccountService'"
```

**Circular dependency introduced:**
```
"Circular dependency detected after extraction.

src/utils/validation.ts imports from src/services/user.ts
src/services/user.ts imports from src/utils/validation.ts

Recommendation: Move shared types to src/types/ to break the cycle."
```

**Too many files to change:**
```
"Refactor would modify 50+ files. Breaking into batches.

Batch 1: src/services/ (5 files)
Batch 2: src/api/ (12 files)
Batch 3: src/controllers/ (8 files)
Batch 4: tests/ (25 files)

Running batch 1, will verify tests before proceeding..."
```

---

## Best Practices

1. **Run tests after each batch** — Catch failures early
2. **Use version control** — Commit before starting, can easily revert
3. **Verify with grep** — After refactor, grep for old name to catch stragglers
4. **Review string literals** — Automated refactors may miss strings ("UserService" in logs)
5. **Check configuration files** — May have references not caught by code analysis

---

Related: [sandbox config](../config.toml)
