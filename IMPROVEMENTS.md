# Claude Orchestrator — Improvement Opportunities

> Generated 2026-03-14 based on project analysis and current AI agent security research.

## Project Overview

**claude-orchestrator** turns Claude Code into a secure, auditable AI orchestration platform via three local MCP servers:

| Server | Directory | Purpose |
|---|---|---|
| `delegate` | `codex-delegation-mcp/` | Spawns parallel `codex exec --ephemeral` subprocesses for code tasks |
| `delegate-web` | `web-delegation-mcp/` | Web search + URL fetch via Gemini/Brave with SSRF protection |
| `audit` | `audit-mcp/` | SQLite audit DB — logs all tool calls, token estimates, sessions |

The hook system (`hooks/*.sh`) enforces security at the shell level and is synced to `~/.claude/settings.json` via `scripts/sync.sh`. The core design philosophy is: **Claude writes specs and delegates — it never directly reads/writes code for tasks that Codex can handle**, saving 90–97% tokens.

---

## Suggested Improvements

### 1. Security

Aligned with the **OWASP Top 10 for LLMs 2025** — specifically "Excessive Agency" (LLM08) and prompt injection (LLM01).

#### 1.1 Excessive Agency Detection Hook
Add a `PreToolUse` hook that inspects outbound Codex prompts for scope creep — e.g., tasks requesting `danger-full-access` without an explicit user instruction, or prompts referencing paths outside the declared `cwd`.

#### ~~1.2 Prompt Injection Hardening at the Delegation Boundary~~ ✓ Done
~~Add a lightweight injection-pattern scan inside `codex-delegation-mcp/server.js` before spawning the subprocess.~~ Implemented as `scanPromptForInjection()` called inside `normalizeTask()`, covering both `codex` and `codex_parallel`. Patterns target imperative override phrases (`ignore previous instructions`, `you are now`, `new system prompt:`, `<system>` tags, backtick/`$()` shell substitution, exfiltration instructions) with allowlists for legitimate uses. Opt-out via `CODEX_INJECTION_SCAN=0`.

#### 1.3 Short-Lived / Scoped Credentials
Auth is handled via Codex CLI (`~/.codex/auth.json`) rather than a raw `OPENAI_API_KEY`. Options:
- Add a pre-spawn check that validates the Codex auth token is still fresh before each subprocess call
- Scope auth per project root so a compromised Codex subprocess cannot be reused across projects

#### ~~1.4 Post-Task Output Scanning~~ ✓ Done
~~Add a `PostToolUse` hook that scans Codex subprocess responses for credential patterns.~~ Implemented as `hooks/security--scan-codex-output.sh`: scans for AWS keys, GitHub PATs, OpenAI keys, bearer tokens, private key headers, npm/Slack tokens, and generic secret assignments. Logs a `high`-severity security event to the audit DB and emits a structured warning to Claude on detection.

---

### 2. Audit & Observability

#### ~~2.1 Structured Log Export~~ ✓ Done
~~Add an `audit-mcp` tool (`export_jsonl`) that streams the audit DB as newline-delimited JSON.~~ Implemented: `export_jsonl` tool accepts `days`, `tool_type`, `table` (`tasks` or `security_events`), and `limit` (max 5000). Appends a `{"truncated":true}` sentinel when the row limit is reached.

#### 2.2 Per-Task Cost Tracking for Codex
`audit-mcp` tracks `prompt_tokens_est` / `response_token_est` for Claude calls. Extend this to Codex subprocess calls by parsing the `usage` field from Codex stdout and writing it back to the audit DB.

#### ~~2.3 SQL-Based Anomaly Alert Queries~~ ✓ Done
~~Ship a set of canned alert queries in `audit-mcp` that flag suspicious patterns.~~ Implemented as `get_alerts` tool with four configurable queries: high-call-count sessions (`max_calls_per_session`, default 50), token overspend in a rolling window (`max_tokens_per_session`, `token_window_hours`), repeated identical Codex prompts (`repeat_prompt_threshold`, default 3), and `danger-full-access` sandbox usage.

#### 2.4 Full Session Replay
Store complete prompt + response pairs per Codex task in the audit DB (currently truncated at 2 MB output cap). Pair with the existing `/history` command for a full replay capability.

---

### 3. Rate Limiting

Identified as a top gap in 2026 — current limits are request-count-based only.

#### ~~3.1 Token-Bucket Rate Limiter Across All MCP Servers~~ ✓ Done
~~Replace the simple 30 req/min counter in `web-delegation-mcp` with a shared token-bucket limiter.~~ Implemented: sliding-window token bucket in `web-delegation-mcp/server.mjs` tracking request count (`RATE_LIMIT_MAX`) and estimated token consumption (`RATE_LIMIT_TOKEN_MAX`); configurable window via `RATE_LIMIT_WINDOW_MS`. Concurrency gate added to `codex-delegation-mcp/server.js` via `MAX_CONCURRENT_CODEX_SPAWNS` env var with `activeSpawns` counter decremented in both `close` and `error` handlers.

#### ~~3.2 Per-Session Codex Spawn Cap~~ ✓ Done
~~Add a configurable `MAX_CODEX_SPAWNS_PER_SESSION` environment variable to `codex-delegation-mcp/server.js`.~~ Implemented: both `codex` and `codex_parallel` check against the cap before spawning. `codex_parallel` rejects early if the full batch would exceed the remaining budget. Default `0` = unlimited (no behavior change without the env var).

#### ~~3.3 Structured `retry-after` Responses~~ ✓ Done
~~Return a structured error with a `retry_after_ms` field instead of a hard failure.~~ All rate-limit responses now include a JSON prefix: `{"error":"rate_limit","retry_after_ms":N,"limit_axis":"requests"|"tokens"|"concurrency"}` followed by a human-readable message. Shipped alongside 3.1.

---

### 4. Delegation Improvements

#### 4.1 Task Dependency Graph (DAG Scheduler)
`codex_parallel` currently fans out all tasks simultaneously via `Promise.all`. A lightweight DAG scheduler would allow tasks to declare dependencies (`depends_on: ["task_id"]`), enabling chained parallel workflows where later tasks consume earlier results.

#### 4.2 Prompt-Level Result Caching
Hash each Codex prompt + sandbox mode. On a cache hit, return the stored result without spawning a subprocess. Configurable TTL. Significant savings for repeated exploratory calls (e.g., repeated `read-only` analysis of the same file set).

#### ~~4.3 Partial Failure Handling in `codex_parallel`~~ ✓ Done
~~Currently, if 1 of 5 parallel tasks fails, `Promise.all` rejects and all results are lost.~~ Switched to `Promise.allSettled`; each result carries `status: "fulfilled"/"rejected"` and the response always succeeds at the MCP level with a summary line (`X/Y tasks succeeded`).

#### 4.4 Streaming Subprocess Output
Codex subprocess output is fully buffered before being returned to Claude. Piping stdout through a streaming MCP response would improve UX on long-running tasks and allow the output cap (2 MB) to be replaced with a smarter truncation strategy.

---

### 5. Web Delegation

#### ~~5.1 Provider Fallback Chain~~ ✓ Done
~~If the primary search provider (Gemini) fails or rate-limits, automatically retry with the secondary provider (Brave) before returning an error.~~ Implemented: Gemini→Brave fallback with `provider_used` metadata on success and structured dual-failure errors (includes both failure reasons). Cache and rate limiter preserved.

#### 5.2 Content Freshness Metadata
Surface publish dates and domain names from search results as structured metadata. This lets Claude judge recency without burning inference tokens on date extraction.

#### 5.3 Citation Deduplication
Multiple search calls in the same session frequently return overlapping URLs. Deduplicate at the MCP layer and track which URLs have already been fetched this session to avoid redundant fetches.

---

## Priority Matrix

| Feature | Impact | Effort | Priority |
|---|---|---|---|
| ~~Partial failure in `codex_parallel`~~ | ~~High~~ | ~~Low~~ | ~~**P0**~~ ✓ |
| ~~Provider fallback chain (web)~~ | ~~High~~ | ~~Low~~ | ~~**P0**~~ ✓ |
| ~~Prompt injection scan at delegation boundary~~ | ~~High~~ | ~~Medium~~ | ~~**P1**~~ ✓ |
| ~~Token-bucket rate limiter~~ | ~~High~~ | ~~Medium~~ | ~~**P1**~~ ✓ |
| ~~Per-session Codex spawn cap~~ | ~~Medium~~ | ~~Low~~ | ~~**P1**~~ ✓ |
| ~~Post-task output credential scan~~ | ~~High~~ | ~~Low~~ | ~~**P1**~~ ✓ |
| ~~Structured `retry-after` responses~~ | ~~Medium~~ | ~~Low~~ | ~~**P2**~~ ✓ |
| Prompt-level result caching | Medium | Medium | **P2** |
| ~~JSONL audit export~~ | ~~Medium~~ | ~~Low~~ | ~~**P2**~~ ✓ |
| ~~SQL anomaly alert queries~~ | ~~Medium~~ | ~~Medium~~ | ~~**P2**~~ ✓ |
| Streaming subprocess output | Medium | High | **P3** |
| DAG scheduler for `codex_parallel` | High | High | **P3** |
| Per-task Codex cost tracking | Low | Medium | **P3** |
| Session replay | Low | Medium | **P3** |

---

## Sources

- IBM, CyCognito, Knostic — AI Agent Security 2025/2026
- OWASP Top 10 for LLM Applications 2025 — owasp.org
- "AI Agent Rate Limiting is Broken" — Medium, Feb 2026
- "Rate Limiting LLM Token Usage With Agentgateway" — Cloud Native Deep Dive, Nov 2025
- "Securing Multi-Agent AI Development Systems" — Knostic, 2025
