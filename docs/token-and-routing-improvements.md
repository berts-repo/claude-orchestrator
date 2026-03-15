# Token & Routing Improvements — Analysis Report

_Date: 2026-03-15_

## Overview

Four candidate improvements for the `codex-delegation-mcp` server, evaluated against three goals: **save tokens**, **use the best model per task**, and **stay secure**.

---

## A. Semantic Prompt Cache

### Current State

`toPromptCacheKey` in `server.js:153` computes `sha256(sandbox + ":" + prompt)` — exact match only.
The cache is an **in-memory `Map` with TTL** (`CODEX_CACHE_TTL_MS`, default `0` = disabled).
It is destroyed on every MCP server restart.

### Issues Before Semantic Matters

1. **Persistence gap.** An in-memory cache is lost on every restart. The audit DB already stores every prompt slug — a SQLite-backed persistent cache is the higher-leverage fix first.

2. **Cache key bug.** The `model` param is not included in the cache key (`server.js:153-155`). Two calls with different `-m` values but identical prompts incorrectly share a cache entry. Fix this regardless of semantic upgrade.

3. **Embedding latency.** Every cache miss requires an embedding API call (~50–100 ms, ~$0.02/1M tokens). On a miss this adds latency before spawning Codex.

4. **False-hit risk on write tasks.** Semantic similarity can produce false positives — a prompt close enough at cosine 0.92 returns stale output instead of running the task. The server already skips cache for `danger-full-access`; the same caution applies to `workspace-write`.

### Recommended Path

1. Fix cache key to include `model`.
2. Persist hash cache to SQLite across restarts.
3. Measure actual hit rate. If prompts are rarely verbatim repeated, add embedding similarity on top.

### References

- https://arxiv.org/html/2504.02268v1 — Domain-specific embeddings for semantic caching
- https://arxiv.org/html/2411.05276v2 — GPT Semantic Cache: cost and latency via embedding caching

---

## B. Model Cascade Routing

### Current State

`TaskSchema` already has `model: z.string().optional()` (`server.js:257`), passed to `codex exec -m <model>` (`server.js:321`). The infrastructure is complete. This is a **caller-side decision gap**.

### Problem

Claude has no structured signal to choose a model. It either omits `model` or the caller writes it manually per prompt. CLAUDE.md has prose guidance but no enforced mapping.

### Three Approaches

| Approach | Effort | Notes |
|----------|--------|-------|
| CLAUDE.md rule table only | Zero code | Works now; relies on Claude following instructions |
| `complexity` enum param (server-side) | Low | Recommended — decouples task classification from model names |
| Prompt-length heuristic (server-side) | Low | Rough but zero client change |

### Recommended: Add `complexity` Enum

Add `complexity: z.enum(["light", "standard", "heavy"]).optional()` to `TaskSchema`.
Server maps to a default model when `model` is not explicitly set:

```
light    → o4-mini
standard → o3  (or configured default)
heavy    → o3  (with higher token budget)
```

This decouples "how complex is this task" (Claude decides) from "which model is light/standard/heavy" (server config). Changing the model list later requires no CLAUDE.md update.

### Suggested CLAUDE.md Table

| Task Type | Tool | Sandbox | Complexity |
|-----------|------|---------|------------|
| Read-only analysis / audit | codex | read-only | light |
| Code generation | codex | workspace-write | standard |
| Refactoring | codex | workspace-write | standard |
| Complex multi-file reasoning | codex | workspace-write | heavy |

### Reference

- https://callsphere.tech/blog/claude-opus-sonnet-haiku-choosing-right-model — Cascade pattern: 60–70% light, 25–30% mid, 3–5% top → 50–60% lower average cost

---

## C. Prompt Compression Before Codex Delegation

### Current State

`TaskSchema` enforces `prompt.max(50000)` chars. No other compression. The server passes the prompt verbatim to `codex exec`.

### Root Cause of Bloat

Claude sometimes pastes full file contents inline when building a Codex prompt (e.g., "Here is server.js: [5000 lines]..."). This is a **prompt-assembly problem**, not a server problem. Codex already has `cat`, `rg`, `find`, `grep` pre-approved in `AGENTS.md` and can read files itself.

### Approaches

| Approach | Effort | Risk |
|----------|--------|------|
| CLAUDE.md rule: "give file paths, not contents" | Zero code | None — this is the right fix |
| Warning hook on prompt size | ~15 lines shell | None — warns, doesn't truncate |
| `max_prompt_chars` server param with truncation | Low | High — silent truncation causes task failures |

### Recommended

Add to `CLAUDE.md` delegation rules:

> When delegating to Codex, do not paste file contents inline. Give Codex the file path and let it read with `cat`/`rg`. Reserve inline content for short snippets under 50 lines.

Add a `PreToolUse` warning hook on `mcp__delegate__codex` that logs a warning when `prompt.length > 8000` chars.

### Reference

- https://propelius.ai/blogs/llm-cost-optimization-strategies/ — Prompt compression: 15–30% savings; model selection is higher-leverage (40–60%)

---

## D. MCP Response Truncation Audit

### Current State

- Hard cap: `MAX_OUTPUT_BYTES = 2 * 1024 * 1024` (2 MB) at `server.js:52`
- `response_token_est` is stored per task in audit DB (computed as `stdoutBytes / 4`)
- `output_truncated` column exists but `/report` does not surface output size distribution

### Proposed SQL Addition to `/report`

```sql
SELECT
  sandbox,
  COUNT(*) as tasks,
  CAST(AVG(response_token_est) AS INTEGER) as avg_tokens,
  CAST(MAX(response_token_est) AS INTEGER) as max_tokens,
  SUM(CASE WHEN output_truncated IS NOT NULL THEN 1 ELSE 0 END) as truncated_count
FROM tasks
WHERE tool_type = 'codex'
  AND <scope>
GROUP BY sandbox
ORDER BY avg_tokens DESC
```

This reveals whether the 2 MB cap is protecting against real outliers or set 100× too high. It also provides the empirical baseline needed to evaluate whether prompt compression (C) is worth pursuing.

### Assessment

Lowest effort of the four. Single SQL query addition to `/report`. No server changes required. Immediate actionable data.

---

## Priority Order

| Priority | Feature | Goal | Effort | First Step |
|----------|---------|------|--------|-----------|
| **P1** | D — Output size audit | Learn | Trivial | Add SQL to `/report` |
| **P1** | B — Model cascade (`complexity` param) | Best model / Tokens | Low | Add enum to `TaskSchema` |
| **P2** | A — Fix cache key bug (`model` not included) | Correctness | Trivial | Add `model` to hash input |
| **P2** | A — Persist hash cache to SQLite | Tokens | Medium | Add cache table to audit DB |
| **P3** | C — CLAUDE.md prompt discipline rule | Tokens | Zero code | Edit `CLAUDE.md` |
| **P3** | C — Warning hook on large prompts | Tokens | Low | New `PreToolUse` hook |
| **P4** | A — Semantic / embedding cache | Tokens | High | After persistence is proven |
