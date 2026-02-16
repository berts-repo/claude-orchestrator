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
    "additionalContext": "This looks like a CODE REVIEW task. Delegate to Codex: mcp__codex__codex with sandbox='read-only', approval-policy='never'. Consider parallel delegation: split into multiple focused Codex calls (security + bugs/logic + quality) and optionally a Gemini web_search for latest best practices. See codex-delegations/templates/parallel-review.txt."
  }
}
EOF
  exit 0
fi

# Generic review (e.g., "review ~/Git/scripts", "review this project")
if echo "$prompt" | grep -Eiq '\breview\b.{0,30}(~/|/|\./|\bthis\b|\bthe\b)'; then
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "This looks like a CODE REVIEW task. Delegate to Codex: mcp__codex__codex with sandbox='read-only', approval-policy='never'. Consider parallel delegation: split into multiple focused Codex calls (security + bugs/logic + quality) and optionally a Gemini web_search for latest best practices. See codex-delegations/templates/parallel-review.txt."
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
