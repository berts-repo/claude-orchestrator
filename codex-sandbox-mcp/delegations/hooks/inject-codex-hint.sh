#!/usr/bin/env bash
# UserPromptSubmit hook: Inject Codex delegation reminder
# Soft enforcement - guides Claude to use Codex for delegatable tasks
set -euo pipefail

payload="$(cat)"
prompt="$(echo "$payload" | jq -r '.prompt // ""' | tr '[:upper:]' '[:lower:]')"

# Patterns that should be delegated to Codex
# Order matters: more specific patterns must come before broader ones.

# Test generation
if echo "$prompt" | grep -Eiq '\b(write|add|generate|create|implement)\b.{0,20}\btests?\b'; then
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "This looks like a TEST GENERATION task. Delegate to Codex: mcp__codex__codex with sandbox='workspace-write', approval-policy='on-failure'. Include test command in prompt. Evaluate parallel fan-out: if multiple modules, split one Codex call per module. If best practices matter, add a Gemini web_search."
  }
}
EOF
  exit 0
fi

# Dependency audit (before code review — "check packages for security" would otherwise match review)
if echo "$prompt" | grep -Eiq '\b(audit|check|scan|review)\s*(deps|dependencies|packages?|modules?|vulnerab)|\b(outdated|vulnerable|insecure)\s*(deps|dependencies|packages?)\b'; then
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "This looks like a DEPENDENCY AUDIT task. Evaluate parallel fan-out: Codex read-only scans lockfiles and dependency tree + Gemini web_search checks for known CVEs and advisories. Both in one message, then synthesize findings."
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
    "additionalContext": "This looks like a CODE REVIEW task. Delegate to Codex: mcp__codex__codex with sandbox='read-only', approval-policy='never'. Evaluate parallel fan-out: split by concern (security + bugs + quality). If framework-specific, add a Gemini web_search. See codex-sandbox-mcp/delegations/templates/parallel-review.txt."
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
    "additionalContext": "This looks like a CODE REVIEW task. Delegate to Codex: mcp__codex__codex with sandbox='read-only', approval-policy='never'. Evaluate parallel fan-out: split by concern (security + bugs + quality). If framework-specific, add a Gemini web_search. See codex-sandbox-mcp/delegations/templates/parallel-review.txt."
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
    "additionalContext": "This looks like a REFACTORING task. Delegate to Codex: mcp__codex__codex with sandbox='workspace-write', approval-policy='on-failure'. Include test command in prompt. Evaluate parallel fan-out: Codex read-only analysis + Gemini best practices research in parallel first, then sequential write."
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
    "additionalContext": "This looks like a DOCUMENTATION task. Delegate to Codex: mcp__codex__codex with sandbox='workspace-write', approval-policy='on-failure'. Evaluate parallel fan-out: if multiple modules, split one Codex call per module."
  }
}
EOF
  exit 0
fi

# Changelog / release notes
if echo "$prompt" | grep -Eiq '\b(changelog|release\s*notes?|what\s*(changed|happened)|summarize\s*(changes|commits|history))\b'; then
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "This looks like a CHANGELOG GENERATION task. Delegate to Codex: mcp__codex__codex with sandbox='read-only', approval-policy='never'. Codex reads git log and diffs externally, keeping full commit history out of Claude's context."
  }
}
EOF
  exit 0
fi

# Lint / format fixing (must come before error analysis — "fix lint errors" contains "error")
if echo "$prompt" | grep -Eiq '\b(fix\s*(lint|style|format)|run\s*(linter|eslint|prettier|black|ruff)|format\s*(the\s*)?(code|files?)|lint\s*(fix|errors?|warnings?))\b'; then
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "This looks like a LINT/FORMAT FIXING task. Delegate to Codex: mcp__codex__codex with sandbox='workspace-write', approval-policy='on-failure'. Codex runs the linter and auto-fixes externally, returning only a summary of changes."
  }
}
EOF
  exit 0
fi

# Error / stack trace analysis
if echo "$prompt" | grep -Eiq '\b(investigate|debug|diagnose|stack\s*trace|why\s*(is|does|did)\s*(this|it)\s*(fail(ing)?|crash(ing)?|error(ing)?|break(ing)?))\b|\berror.{0,10}\b(in|at|from)\b'; then
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "This looks like an ERROR ANALYSIS task. Delegate to Codex: mcp__codex__codex with sandbox='read-only', approval-policy='never'. Codex investigates the codebase against the error externally, keeping stack traces and source files out of Claude's context."
  }
}
EOF
  exit 0
fi

exit 0
