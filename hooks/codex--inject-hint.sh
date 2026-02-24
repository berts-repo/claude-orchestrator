#!/usr/bin/env bash
# UserPromptSubmit hook: Inject Codex delegation reminder
# Soft enforcement - guides Claude to use Codex for delegatable tasks
# HOOK_EVENT: UserPromptSubmit
# HOOK_TIMEOUT: 5
set -euo pipefail

payload="$(cat)"
prompt="$(echo "$payload" | jq -r '.prompt // ""' | tr '[:upper:]' '[:lower:]')"

# Emit a minimal hint; full params are in CLAUDE.md delegation table.
hint() {
  local task="$1" sandbox="$2" policy="$3"
  printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"[CODEX] %s → sandbox=%s policy=%s (see CLAUDE.md delegation table)"}}\n' \
    "$task" "$sandbox" "$policy"
}

# Patterns that should be delegated to Codex
# Order matters: more specific patterns must come before broader ones.

# New code generation (scraper, CLI, script, server, tool, etc.)
if echo "$prompt" | grep -Eiq '\b(write|build|create|implement|make|code)\b.{0,30}\b(scraper|crawler|script|cli|tool|server|service|bot|parser|api|app|plugin|extension|module|class|function)\b'; then
  hint "code-generation" "workspace-write" "on-failure"; exit 0
fi

# Test generation
if echo "$prompt" | grep -Eiq '\b(write|add|generate|create|implement)\b.{0,20}\btests?\b'; then
  hint "test-generation" "workspace-write" "on-failure"; exit 0
fi

# Dependency audit (before code review — "check packages for security" would otherwise match review)
if echo "$prompt" | grep -Eiq '\b(audit|check|scan|review)\s*(deps|dependencies|packages?|modules?|vulnerab)|\b(outdated|vulnerable|insecure)\s*(deps|dependencies|packages?)\b'; then
  hint "dependency-audit" "read-only" "never"; exit 0
fi

# Code review / security audit
if echo "$prompt" | grep -Eiq '\b(review|audit|check|analyze|scan)\b.{0,20}\b(code|security|vulnerab|auth|cred)\b'; then
  hint "code-review" "read-only" "never"; exit 0
fi

# Generic review (e.g., "review ~/Git/scripts", "review this project")
if echo "$prompt" | grep -Eiq '\breview\b.{0,30}(~/|/|\./|\bthis\b|\bthe\b)'; then
  hint "code-review" "read-only" "never"; exit 0
fi

# Refactoring
if echo "$prompt" | grep -Eiq '\b(refactor|restructure|reorganize|clean\s*up|simplify)\b.{0,20}\b(code|function|class|module|component)\b'; then
  hint "refactoring" "workspace-write" "on-failure"; exit 0
fi

# Documentation
if echo "$prompt" | grep -Eiq '\b(document|add\s*(docs?|docstrings?|comments?|jsdoc)|generate\s*docs?)\b'; then
  hint "documentation" "workspace-write" "on-failure"; exit 0
fi

# Changelog / release notes
if echo "$prompt" | grep -Eiq '\b(changelog|release\s*notes?|what\s*(changed|happened)|summarize\s*(changes|commits|history))\b'; then
  hint "changelog" "read-only" "never"; exit 0
fi

# Lint / format fixing (must come before error analysis — "fix lint errors" contains "error")
if echo "$prompt" | grep -Eiq '\b(fix\s*(lint|style|format)|run\s*(linter|eslint|prettier|black|ruff)|format\s*(the\s*)?(code|files?)|lint\s*(fix|errors?|warnings?))\b'; then
  hint "lint-fix" "workspace-write" "on-failure"; exit 0
fi

# Error / stack trace analysis
if echo "$prompt" | grep -Eiq '\b(investigate|debug|diagnose|stack\s*trace|why\s*(is|does|did)\s*(this|it)\s*(fail(ing)?|crash(ing)?|error(ing)?|break(ing)?))\b|\berror.{0,10}\b(in|at|from)\b'; then
  hint "error-analysis" "read-only" "never"; exit 0
fi

exit 0
