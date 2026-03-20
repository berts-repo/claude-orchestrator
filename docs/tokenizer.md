# Token Counting in claude-orchestrator

## The Problem with char/4

The original token estimation used `Math.ceil(text.length / 4)` — a rough heuristic based on the observation that English text averages ~4 characters per token. This breaks down in several ways:

- **Code is denser than prose.** Identifiers, operators, and syntax tokens are short. `Math.ceil("const x = require('fs')".length / 4)` gives 6, but the actual token count is closer to 9.
- **Multi-byte characters (Unicode, CJK, emoji) are wildly off.** A single emoji is 2 bytes in JS string length but 1–3 tokens depending on the model.
- **Model-specific tokenizers differ.** GPT-4/o-series use `cl100k_base`; older Codex models used `p50k_base`. The same string tokenizes differently.
- **Cost estimates are wrong.** Pricing is per-token, not per-character. A 10% error in token counting is a 10% error in cost.

## What We Use Now: js-tiktoken

`codex-delegation-mcp/server.js` now uses [`js-tiktoken`](https://github.com/dqbd/tiktoken) — a pure JavaScript port of OpenAI's tiktoken library. It encodes text to tokens using the same BPE (Byte-Pair Encoding) vocabulary as the actual model.

```js
import { get_encoding } from 'js-tiktoken';
let _enc = null;
function countTokens(text) {
  if (!text) return 0;
  try {
    if (!_enc) _enc = get_encoding('cl100k_base');
    return _enc.encode(String(text)).length;
  } catch {
    return Math.ceil(String(text).length / 4); // fallback if tiktoken unavailable
  }
}
```

**Encoding used:** `cl100k_base` — the tokenizer for `gpt-4`, `gpt-4o`, `o3`, `o4-mini`, and all current Codex/o-series models. If OpenAI releases a model with a new tokenizer, this may need updating.

**Lazy initialization:** The encoder is loaded once on first call and reused. BPE encoding is CPU-bound but fast (~microseconds per token for typical prompts).

**Fallback:** If `js-tiktoken` fails to load (missing install, WASM issue), it silently falls back to char/4 so the server keeps running.

## Cost Estimation

Token counts feed into `estimateCost(model, promptTokens, responseTokens)`:

```js
const MODEL_PRICING = {
  'o4-mini':            [1.10,  4.40],   // $1.10/1M input, $4.40/1M output
  'o3':                 [10.00, 40.00],
  'gpt-4o':             [2.50,  10.00],
  'gpt-4o-mini':        [0.15,   0.60],
  'codex-mini-latest':  [1.50,   6.00],
  'gpt-5.4':            [2.50,  10.00],
  // ...
};
```

Prices are in USD per 1M tokens. Returns `null` if the model is not in the table. The result is stored as `cost_est_usd` on each task row and summed in `/report`.

**Keeping pricing current:** Update `MODEL_PRICING` in `codex-delegation-mcp/server.js` when OpenAI changes pricing or you add new models. The object is near the top of the file after the imports.

## Web Tasks

Web task token estimates (`web_tasks.prompt_tokens_est`) use the simpler char/4 heuristic for now — web prompts are typically short search queries where the error is small and tiktoken isn't worth the dependency in a bash hook. The response (`output_full`) is stored as text but not token-counted.

## Limitations

- `prompt_tokens_est` is computed from the **prompt string** only, not the full context window Claude sends to Codex (system prompt, base instructions, etc.). Actual API costs include those too.
- `response_token_est` counts Codex's stdout as tokens — this approximates output tokens but Codex's internal chain-of-thought/reasoning tokens are not visible and not counted.
- Cost estimates are therefore a **lower bound**, not an exact figure.
