#!/usr/bin/env bash
# UserPromptSubmit hook
# Detects task types that should be delegated to Codex and injects enforcement context.
set -euo pipefail

payload="$(cat)"
prompt="$(echo "$payload" | jq -r '.prompt // ""')"

# Test generation triggers
if echo "$prompt" | grep -Eiq '(write tests?|add tests?|generate tests?|create tests?|unit tests?|test coverage)'; then
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
# Matches: "review @path", "review ./path", "review this code", "code review", etc.
if echo "$prompt" | grep -Eiq '(review (@|\.?/?[a-z])|review (this |the )?code|security review|security audit|audit (this|the)|code review|check for (security |vulnerabilities|bugs))'; then
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
if echo "$prompt" | grep -Eiq '(refactor|clean up (this |the )?code|restructure|reorganize (this |the )?code)'; then
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
if echo "$prompt" | grep -Eiq '(document this|add docstrings?|generate docs?|add documentation|write documentation)'; then
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
