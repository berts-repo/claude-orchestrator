import { GoogleGenerativeAI } from "@google/generative-ai";
import { BaseProvider } from "./base-provider.mjs";

const DEFAULT_MODELS = ["gemini-2.5-flash"];
const DEFAULT_TIMEOUT_MS = 15_000;

function isQuotaError(err) {
  const msg = err?.message || String(err);
  return msg.includes("429") || msg.includes("quota") || msg.includes("RESOURCE_EXHAUSTED");
}

export class GeminiProvider extends BaseProvider {
  constructor({ apiKey, model, timeoutMs } = {}) {
    super("gemini");
    this._apiKey = apiKey || process.env.GEMINI_API_KEY;
    const modelEnv = model || process.env.GEMINI_MODEL || DEFAULT_MODELS.join(",");
    this._models = modelEnv.split(",").map((m) => m.trim()).filter(Boolean);
    this._timeoutMs = timeoutMs || DEFAULT_TIMEOUT_MS;
    this._genAI = this._apiKey ? new GoogleGenerativeAI(this._apiKey) : null;
  }

  isAvailable() {
    return Boolean(this._apiKey);
  }

  async search(query, maxResults = 5) {
    if (!this._genAI) {
      throw new Error("Gemini API key not configured");
    }

    const prompt = [
      `Search the web for: ${query}`,
      "",
      "Respond with:",
      "1. A 1-paragraph factual summary grounded in search results",
      `2. A numbered list of up to ${maxResults} sources (title and URL)`,
      "",
      "Only include claims directly supported by sources.",
    ].join("\n");

    let lastErr;
    let notice;

    for (const modelName of this._models) {
      try {
        const model = this._genAI.getGenerativeModel({
          model: modelName,
          tools: [{ google_search: {} }],
        });

        const result = await model.generateContent(
          { contents: [{ role: "user", parts: [{ text: prompt }] }] },
          { timeout: this._timeoutMs },
        );

        const response = result.response;
        const summary = response.text();

        // Extract structured sources from grounding metadata
        const sources = [];
        const candidate = response.candidates?.[0];
        const metadata = candidate?.groundingMetadata;
        if (metadata?.groundingChunks) {
          for (const chunk of metadata.groundingChunks) {
            if (chunk.web?.uri) {
              sources.push({
                title: chunk.web.title || "Untitled",
                url: chunk.web.uri,
              });
            }
          }
        }

        return { summary, sources, notice };
      } catch (err) {
        if (isQuotaError(err)) {
          const next = this._models[this._models.indexOf(modelName) + 1];
          if (next) {
            notice = `[Note: ${modelName} quota exceeded, switched to ${next}]`;
          }
          lastErr = err;
          continue;
        }
        throw err;
      }
    }

    throw lastErr;
  }
}
