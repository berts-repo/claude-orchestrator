#!/usr/bin/env bash
# UserPromptSubmit hook
# Detects delegation-worthy tasks and injects a sharp instruction to delegate
# to Codex instead of exploring files directly. Fires before any inference,
# so no tokens are wasted on Read/Glob/Grep calls Claude shouldn't make.
# HOOK_EVENT: UserPromptSubmit
# HOOK_TIMEOUT: 5
set -euo pipefail

payload="$(cat)"
prompt="$(echo "$payload" | jq -r '.prompt // ""')"

# Detect imperative prompts targeting code work that belongs in Codex.
# Patterns are intentionally specific to avoid false positives on questions
# like "explain how to implement X" or "show me the tests".
#
# Signals:
#   1. Imperative verb + code artifact  (implement a function, write tests for...)
#   2. Delegation-table keywords alone  (refactor, security audit, lint/format)
if echo "$prompt" | grep -Eiq \
  '(^|\b)(implement|build|create|write|generate)\b.{0,60}\b(function|class|module|script|service|component|feature|endpoint|cli|tool|helper|hook|middleware|plugin|schema|type|interface|test|spec)\b|
(^|\b)(refactor|restructure|rewrite)\b.{0,40}\b(the\s+)?(code|class|module|function|file|codebase|service|component)\b|
(^|\b)(write|add|generate|create)\b.{0,30}\b(unit\s+)?tests?\s+(for|to|in|covering)\b|
(^|\b)(add|generate|write)\b.{0,30}\b(docstring|docstrings|documentation|jsdoc|typedoc)\b.{0,30}\b(for|to|in)\b|
(^|\b)(security\s+audit|code\s+review|audit\s+the\s+code)\b|
(^|\b)(lint|fix\s+lint|autoformat|auto-format|fix\s+formatting)\b|
(^|\b)(migrate|convert|port)\b.{0,40}\b(the\s+)?(code|codebase|module|file|function|class)\b'; then

  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "This is a delegation task. Do NOT call Read, Glob, Grep, or Bash to explore files. Write a Codex prompt that embeds the exploration instructions and call mcp__delegate__codex directly. Claude's role is spec-writer, not implementer."
  }
}
EOF
  exit 0
fi

exit 0
