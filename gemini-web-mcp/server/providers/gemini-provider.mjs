import { GoogleGenerativeAI } from "@google/generative-ai";
import { BaseProvider } from "./base-provider.mjs";

const DEFAULT_MODEL = "gemini-2.5-flash";
const DEFAULT_TIMEOUT_MS = 15_000;

export class GeminiProvider extends BaseProvider {
  constructor({ apiKey, model, timeoutMs } = {}) {
    super("gemini");
    this._apiKey = apiKey || process.env.GEMINI_API_KEY;
    this._modelName = model || process.env.GEMINI_MODEL || DEFAULT_MODEL;
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

    const model = this._genAI.getGenerativeModel({
      model: this._modelName,
      tools: [{ google_search: {} }],
    });

    const prompt = [
      `Search the web for: ${query}`,
      "",
      "Respond with:",
      "1. A 1-paragraph factual summary grounded in search results",
      `2. A numbered list of up to ${maxResults} sources (title and URL)`,
      "",
      "Only include claims directly supported by sources.",
    ].join("\n");

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

    return { summary, sources };
  }
}
