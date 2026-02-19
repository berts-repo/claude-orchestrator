# Documentation Delegation — Claude to Codex

## When to Use

- Generating JSDoc/docstrings for existing code
- Creating API documentation
- Writing README files for modules
- Generating type documentation
- Creating usage examples from code

**Token savings**: ~95% — Documentation requires reading many files but produces structured output.

## Prerequisites

- **Sandbox mode**: `workspace-write` (needs to write doc files or add inline docs)
- **Approval policy**: `on-failure` (auto-approve unless something breaks)
- **Project setup**: None required

---

## MCP Call Template

```json
{
  "tool": "mcp__codex__codex",
  "parameters": {
    "prompt": "Add JSDoc comments to all exported functions in src/utils/.\n\nFor each function:\n1. Document parameters with @param\n2. Document return value with @returns\n3. Add @example with realistic usage\n4. Note any thrown exceptions with @throws\n\nMatch the documentation style of existing comments in the codebase.",
    "sandbox": "workspace-write",
    "approval-policy": "on-failure",
    "cwd": "/path/to/project"
  }
}
```

---

## Prompt Variations

### Variant A: JSDoc/TSDoc for Functions

```json
{
  "tool": "mcp__codex__codex",
  "parameters": {
    "prompt": "Add JSDoc comments to all exported functions in src/utils/.\n\nFor each function, include:\n- Brief description (1-2 sentences)\n- @param for each parameter with type and description\n- @returns with type and description\n- @example with realistic usage\n- @throws if the function throws errors\n\nStyle guide:\n- Use present tense ('Returns the...', not 'Return the...')\n- Start with a verb\n- Keep descriptions concise\n\nDon't modify function bodies, only add comments.",
    "sandbox": "workspace-write",
    "approval-policy": "on-failure",
    "cwd": "/path/to/project"
  }
}
```

### Variant B: Python Docstrings

```json
{
  "tool": "mcp__codex__codex",
  "parameters": {
    "prompt": "Add docstrings to all public functions and classes in src/.\n\nUse Google-style docstrings:\n\ndef function_name(param1: str, param2: int) -> bool:\n    \"\"\"Brief description of what the function does.\n\n    Args:\n        param1: Description of param1.\n        param2: Description of param2.\n\n    Returns:\n        Description of what is returned.\n\n    Raises:\n        ValueError: When param1 is empty.\n    \"\"\"\n\nSkip private functions (prefixed with _) unless they're complex.",
    "sandbox": "workspace-write",
    "approval-policy": "on-failure",
    "cwd": "/path/to/project"
  }
}
```

### Variant C: API Documentation

```json
{
  "tool": "mcp__codex__codex",
  "parameters": {
    "prompt": "Generate API documentation for src/api/routes/.\n\nFor each endpoint, document:\n- HTTP method and path\n- Brief description\n- Request parameters (path, query, body)\n- Response format (success and error cases)\n- Authentication requirements\n- Example request/response\n\nOutput format: Markdown file at docs/api.md\n\nUse this structure:\n## Endpoint Name\n`METHOD /path`\nDescription...\n### Request\n### Response\n### Example",
    "sandbox": "workspace-write",
    "approval-policy": "on-failure",
    "cwd": "/path/to/project"
  }
}
```

### Variant D: Module README

```json
{
  "tool": "mcp__codex__codex",
  "parameters": {
    "prompt": "Create a README.md for the src/services/ directory.\n\nInclude:\n1. Overview - What this module does\n2. Architecture - How the services relate to each other\n3. Usage - How to import and use the main services\n4. Services - Brief description of each service file\n5. Dependencies - What external dependencies are used\n\nKeep it concise and practical. Focus on 'how to use' not 'how it works'.",
    "sandbox": "workspace-write",
    "approval-policy": "on-failure",
    "cwd": "/path/to/project"
  }
}
```

### Variant E: Type Documentation

```json
{
  "tool": "mcp__codex__codex",
  "parameters": {
    "prompt": "Document the types in src/types/.\n\nFor each interface/type:\n1. Add a JSDoc comment explaining what it represents\n2. Document each property with its purpose\n3. Note any constraints or valid values\n4. Add @example showing a valid instance\n\nExample:\n/**\n * Represents a user account in the system.\n * @example\n * const user: User = {\n *   id: '123',\n *   email: 'user@example.com',\n *   role: 'admin'\n * };\n */\ninterface User {\n  /** Unique identifier (UUID format) */\n  id: string;\n  /** User's email address (validated on creation) */\n  email: string;\n  /** User's role - determines permissions */\n  role: 'admin' | 'user' | 'guest';\n}",
    "sandbox": "workspace-write",
    "approval-policy": "on-failure",
    "cwd": "/path/to/project"
  }
}
```

### Variant F: Usage Examples

```json
{
  "tool": "mcp__codex__codex",
  "parameters": {
    "prompt": "Create usage examples for the public API in src/lib/.\n\nFor each exported function/class:\n1. Create a realistic usage example\n2. Show common patterns and edge cases\n3. Include error handling examples\n\nOutput: docs/examples.md\n\nFormat:\n## Function Name\n```typescript\n// Example: Basic usage\nconst result = functionName(...);\n\n// Example: With error handling\ntry {\n  const result = functionName(...);\n} catch (error) {\n  // Handle error\n}\n```",
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
Added JSDoc comments to 15 functions in src/utils/.

## Files Modified
- src/utils/validation.ts (5 functions documented)
- src/utils/formatting.ts (4 functions documented)
- src/utils/helpers.ts (6 functions documented)

## Documentation Added
- validateEmail: params, returns, example, throws
- validatePhone: params, returns, example
- formatDate: params, returns, 2 examples (different formats)
- formatCurrency: params, returns, example
- parseJSON: params, returns, throws
- [... 10 more functions]

## Notes
- Skipped 3 private functions (prefixed with _)
- Added @deprecated tag to formatDateLegacy (found TODO comment)
- Found 2 functions with unclear behavior — added TODO for human review
```

---

## Error Handling

**Existing docs conflict:**
```
"Some functions already have JSDoc comments.
Options:
1. Skip already-documented functions (recommended)
2. Overwrite existing docs
3. Merge (add missing fields only)

Proceeding with option 1 — skipping 4 already-documented functions."
```

**Can't infer purpose:**
```
"Unable to determine purpose of 'processXYZ' function.
The function body is complex and has no existing documentation.

Added placeholder:
/**
 * TODO: Document this function
 * @param data - Unknown purpose
 * @returns Unknown
 */

Human review recommended."
```

---

## Best Practices

1. **Match existing style** — If the codebase uses a specific doc style, follow it
2. **Don't over-document** — Simple functions don't need lengthy explanations
3. **Focus on "why" not "what"** — The code shows what, docs should explain why
4. **Keep examples realistic** — Use values that make sense in context
5. **Document edge cases** — What happens with null, empty, or invalid input?

---

## Read-Only Alternative

For documentation that doesn't modify source files (external docs only):

```json
{
  "tool": "mcp__codex__codex",
  "parameters": {
    "prompt": "Analyze src/api/ and produce API documentation.\n\nOutput to stdout (don't create files).\n\nFor each endpoint, list:\n- Method and path\n- Parameters\n- Response format",
    "sandbox": "read-only",
    "approval-policy": "never",
    "cwd": "/path/to/project"
  }
}
```

Claude can then create the documentation file from Codex's output.

---

Related: [sandbox config](../config.toml)
