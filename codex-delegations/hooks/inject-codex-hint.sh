#!/usr/bin/env bash
# UserPromptSubmit hook: Inject Codex delegation reminder
# Soft enforcement - guides Claude to use Codex for delegatable tasks
set -euo pipefail

payload="$(cat)"
prompt="$(echo "$payload" | jq -r '.prompt // ""' | tr '[:upper:]' '[:lower:]')"

# Patterns that should be delegated to Codex
# Test generation
if echo "$prompt" | grep -Eiq '\b(write|add|generate|create|implement)\b.{0,20}\btests?\b'; then
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "This looks like a TEST GENERATION task. Delegate to Codex: mcp__codex__codex with sandbox='workspace-write', approval-policy='on-failure'. Include test command in prompt."
  }
}
EOF
  exit 0
fi

# Code review / security audit
if echo "$prompt" | grep -Eiq '\b(review|audit|check|analyze|scan)\b.{0,20}\b(code|security|vulnerab|auth|cred)\b'; then
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "This looks like a CODE REVIEW task. Delegate to Codex: mcp__codex__codex with sandbox='read-only', approval-policy='never'."
  }
}
EOF
  exit 0
fi

# Refactoring
if echo "$prompt" | grep -Eiq '\b(refactor|restructure|reorganize|clean\s*up|simplify)\b.{0,20}\b(code|function|class|module|component)\b'; then
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "This looks like a REFACTORING task. Delegate to Codex: mcp__codex__codex with sandbox='workspace-write', approval-policy='on-failure'. Include test command in prompt."
  }
}
EOF
  exit 0
fi

# Documentation
if echo "$prompt" | grep -Eiq '\b(document|add\s*(docs?|docstrings?|comments?|jsdoc)|generate\s*docs?)\b'; then
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "This looks like a DOCUMENTATION task. Delegate to Codex: mcp__codex__codex with sandbox='workspace-write', approval-policy='on-failure'."
  }
}
EOF
  exit 0
fi

exit 0
