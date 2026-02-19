# Test Generation Delegation — Claude to Codex

## When to Use

- Adding unit tests for existing code
- Adding tests for a new feature
- Improving test coverage
- Creating integration or snapshot tests
- Writing regression tests for bugs

**Token savings**: ~97% — Instead of Claude reading source files and generating tests, Codex does the work and returns a summary.

## Prerequisites

- **Sandbox mode**: `workspace-write` (needs to create/modify test files and run tests)
- **Approval policy**: `on-failure` (auto-approve unless something breaks)
- **Project setup**: Test framework installed and configured

---

## Why Delegate Test Generation?

Test generation is a high-token, low-reasoning task:
- **Token-heavy**: Requires reading source files, understanding patterns, writing boilerplate
- **Mechanical**: Tests follow predictable patterns (arrange/act/assert)
- **Verifiable**: Success = tests pass, coverage increases
- **Bounded**: Output is deterministic given clear input

---

## MCP Call Templates

### Template 1: Unit Tests for Specific Files

```json
{
  "tool": "mcp__codex__codex",
  "parameters": {
    "prompt": "Generate unit tests for the following files:\n- src/utils/validation.ts\n- src/utils/formatting.ts\n\nRequirements:\n1. Use the existing test framework (detect from package.json or existing tests)\n2. Match the test file naming convention in the codebase\n3. Cover: happy path, edge cases, error cases\n4. Each test should have a descriptive name\n5. Run the test command and report pass/fail\n\nReturn:\n- Files created\n- Test count\n- Coverage summary (if available)\n- Any functions that couldn't be tested (and why)",
    "sandbox": "workspace-write",
    "approval-policy": "on-failure",
    "cwd": "/path/to/project"
  }
}
```

### Template 2: Tests for New Feature

```json
{
  "tool": "mcp__codex__codex",
  "parameters": {
    "prompt": "Add tests for the new feature in src/features/auth/login.ts\n\nContext: This feature implements user login with email/password.\nThe function should:\n- Return a token on success\n- Throw AuthError on invalid credentials\n- Throw ValidationError on malformed input\n\nGenerate tests covering:\n1. Successful login returns token\n2. Invalid password throws AuthError\n3. Unknown user throws AuthError\n4. Empty email throws ValidationError\n5. Malformed email throws ValidationError\n\nUse existing mocks in __mocks__/ if available.\nRun: npm test -- --coverage src/features/auth/",
    "sandbox": "workspace-write",
    "approval-policy": "on-failure",
    "cwd": "/path/to/project"
  }
}
```

### Template 3: Coverage Gap Analysis + Tests

```json
{
  "tool": "mcp__codex__codex",
  "parameters": {
    "prompt": "Task: Improve test coverage for src/services/\n\nSteps:\n1. Run coverage: npm test -- --coverage src/services/\n2. Identify files with <80% coverage\n3. For each low-coverage file, add tests for uncovered branches\n4. Re-run coverage and report improvement\n\nConstraints:\n- Don't modify source files, only test files\n- Match existing test patterns\n- Focus on uncovered branches, not redundant happy-path tests\n\nReturn:\n- Before/after coverage percentages\n- Tests added per file\n- Any code that's untestable (dead code, etc.)",
    "sandbox": "workspace-write",
    "approval-policy": "on-failure",
    "cwd": "/path/to/project"
  }
}
```

### Template 4: Integration Tests

```json
{
  "tool": "mcp__codex__codex",
  "parameters": {
    "prompt": "Generate integration tests for the API endpoints in src/api/routes/\n\nRequirements:\n1. Test each endpoint: GET, POST, PUT, DELETE\n2. Test authentication (valid token, invalid token, no token)\n3. Test validation (missing fields, invalid types)\n4. Test error responses (404, 400, 401, 500)\n5. Use the test database config (test.env or jest.config)\n\nRun: npm run test:integration\n\nReturn:\n- Endpoints tested\n- Test count per endpoint\n- Any endpoints that need manual setup (external deps)",
    "sandbox": "workspace-write",
    "approval-policy": "on-failure",
    "cwd": "/path/to/project"
  }
}
```

### Template 5: Snapshot Tests

```json
{
  "tool": "mcp__codex__codex",
  "parameters": {
    "prompt": "Add snapshot tests for React components in src/components/\n\nFor each component:\n1. Create a test file if it doesn't exist\n2. Add snapshot test for default props\n3. Add snapshot test for key prop variations\n4. Run: npm test -- -u to generate initial snapshots\n\nSkip components that:\n- Have complex external dependencies (mock them instead)\n- Are purely layout (no meaningful snapshot)\n\nReturn:\n- Components with new snapshots\n- Components skipped (and why)",
    "sandbox": "workspace-write",
    "approval-policy": "on-failure",
    "cwd": "/path/to/project"
  }
}
```

---

## Prompt Variations

### Framework-Specific Prompts

**Jest (JavaScript/TypeScript)**
```
Use Jest. Place tests in __tests__/ or *.test.ts next to source files.
Run: npm test -- --coverage <path>
```

**Vitest**
```
Use Vitest. Place tests in __tests__/ or *.test.ts.
Run: npm test -- --coverage <path>
```

**pytest (Python)**
```
Use pytest. Place tests in tests/ directory, named test_*.py.
Run: pytest --cov=<module> tests/
```

**Go**
```
Use Go testing. Place tests in *_test.go next to source files.
Run: go test -v -cover ./...
```

**Rust**
```
Use Rust's built-in test framework. Add #[cfg(test)] module or tests/ directory.
Run: cargo test
```

---

## Expected Return Format

Codex should return results in this structure:

```
## Summary
Added 12 unit tests for src/utils/validation.ts

## Files Created/Modified
- src/utils/__tests__/validation.test.ts (new)

## Tests Added
- validateEmail: 4 tests (valid, invalid, empty, null)
- validatePhone: 3 tests (valid, invalid formats, empty)
- validatePassword: 5 tests (valid, too short, no number, no special, empty)

## Test Results
✓ npm test -- src/utils/__tests__/validation.test.ts
12 tests passed, 0 failed

## Coverage
validation.ts: 45% → 92% (+47%)

## Notes
- Skipped validateCustomField — requires external API mock
- Found potential bug: validateEmail accepts "test@" as valid
```

---

## Multi-Turn Test Generation

For complex test suites, use `codex-reply` to continue the conversation:

```json
// Step 1: Initial test generation
{
  "tool": "mcp__codex__codex",
  "parameters": {
    "prompt": "Generate unit tests for src/utils/validation.ts. Run npm test.",
    "sandbox": "workspace-write",
    "cwd": "/path/to/project"
  }
}
// Returns: { "threadId": "abc123", "content": "Created 5 tests, 3 passing, 2 failing..." }

// Step 2: Fix failing tests
{
  "tool": "mcp__codex__codex-reply",
  "parameters": {
    "threadId": "abc123",
    "prompt": "Fix the 2 failing tests. The validateEmail function expects lowercase input."
  }
}
// Returns: { "threadId": "abc123", "content": "Fixed tests, all 5 now passing..." }

// Step 3: Add edge cases
{
  "tool": "mcp__codex__codex-reply",
  "parameters": {
    "threadId": "abc123",
    "prompt": "Add edge case tests for null, undefined, and empty string inputs."
  }
}
```

---

## Error Handling

If Codex returns with failures:

1. **Tests fail** — Claude reviews the failure summary, delegates fix:
   ```
   "Fix the failing test in validation.test.ts:42.
    Error: Expected 'valid' but got 'invalid'.
    The validateEmail function returns 'invalid' for 'test@example.com'.
    Investigate and fix either the test or file a bug report."
   ```

2. **Can't determine framework** — Claude provides explicit instructions:
   ```
   "Use Jest with TypeScript. Test files go in __tests__/.
    Import with: import { fn } from '../filename'
    Run with: npm test"
   ```

3. **External dependencies** — Claude provides mock instructions:
   ```
   "Mock the database using jest.mock('../db').
    The db.query function should return: [{ id: 1, name: 'test' }]"
   ```

---

## Claude's Pre-Delegation Checklist

Before delegating test generation, Claude should:

1. **Identify the test framework** — Is it Jest, Vitest, pytest, Go testing?
2. **Check for existing patterns** — Are there existing tests to follow?
3. **Scope the work** — Specific files > entire directories > whole codebase
4. **Define acceptance** — What test command proves success?
5. **Set constraints** — "Don't modify source files", "Match existing style"

---

## Token Preservation Pattern

```
┌─────────────────────────────────────────────────────────┐
│ WITHOUT DELEGATION (Claude does everything)             │
├─────────────────────────────────────────────────────────┤
│ Claude reads: 10 source files (4000 tokens)             │
│ Claude reads: 5 existing test files (2000 tokens)       │
│ Claude generates: 500 lines of tests (3000 tokens)      │
│ Claude reads: test output (500 tokens)                  │
│ Total: ~9500 tokens                                     │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│ WITH DELEGATION (Codex does the work)                   │
├─────────────────────────────────────────────────────────┤
│ Claude sends: delegation prompt (200 tokens)            │
│ Codex: reads files, generates tests, runs tests         │
│ Claude receives: summary (100 tokens)                   │
│ Total: ~300 tokens                                      │
│ Savings: 97%                                            │
└─────────────────────────────────────────────────────────┘
```

---

Related: [sandbox config](../config.toml) | [templates](templates/)
