#!/usr/bin/env bash
# UserPromptSubmit hook
# Detects task types that should be delegated to Codex and injects enforcement context.
set -euo pipefail

payload="$(cat)"
prompt="$(echo "$payload" | jq -r '.prompt // ""')"

# Test generation triggers
# Matches: "write tests", "add tests for @path", "test coverage", "integration tests", etc.
if echo "$prompt" | grep -Eiq '(write tests?|add tests?|generate tests?|create tests?|unit tests?|tests? (for )?(@|\.?/?[a-z])|test coverage|improve.*coverage|integration tests?|regression tests?)'; then
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "DELEGATION REQUIRED: This is a test generation task. You MUST delegate to Codex using mcp__codex__codex with sandbox='workspace-write' and approval-policy='on-failure'. Do NOT write tests directly."
  }
}
EOF
  exit 0
fi

# Code review / security audit triggers
# Matches: "review @path", "review ./path", "review this code", "PR review", "audit", etc.
if echo "$prompt" | grep -Eiq '(review (@|\.?/?[a-z])|review (this |the )?(code|PR|pull request)|PR review|security review|security audit|audit (this|the|@)|code review|quality (check|review)|check for (security |vulnerabilities|bugs))'; then
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "DELEGATION REQUIRED: This is a code review/audit task. You MUST delegate to Codex using mcp__codex__codex with sandbox='read-only' and approval-policy='never'. Do NOT perform the review directly."
  }
}
EOF
  exit 0
fi

# Refactoring triggers
# Matches: "refactor", "rename X to Y", "extract function", "migrate to async", "consolidate", etc.
if echo "$prompt" | grep -Eiq '(refactor|rename .* to|extract (function|method|class|module|into)|clean up (this |the )?code|restructure|reorganize|migrate (to |from )|consolidate|move .* to)'; then
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "DELEGATION REQUIRED: This is a refactoring task. You MUST delegate to Codex using mcp__codex__codex with sandbox='workspace-write' and approval-policy='on-failure'. Do NOT refactor directly."
  }
}
EOF
  exit 0
fi

# Documentation triggers
# Matches: "document @path", "add docstrings", "generate docs", "write documentation", etc.
if echo "$prompt" | grep -Eiq '(document (this|the|@|\.?/?[a-z])|add (jsdoc|docstrings?|documentation)|generate docs?|write documentation|create (readme|docs)|api docs?)'; then
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "DELEGATION REQUIRED: This is a documentation task. You MUST delegate to Codex using mcp__codex__codex with sandbox='workspace-write' and approval-policy='on-failure'. Do NOT write documentation directly."
  }
}
EOF
  exit 0
fi

exit 0
