import { BaseProvider } from "./base-provider.mjs";

export class BraveProvider extends BaseProvider {
  constructor({ apiKey } = {}) {
    super("brave");
    this._apiKey = apiKey || process.env.BRAVE_API_KEY;
  }

  isAvailable() {
    return Boolean(this._apiKey);
  }

  async search(query, maxResults = 5) {
    if (!this._apiKey) {
      throw new Error("Brave API key not configured");
    }

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 10_000);

    try {
      const url = new URL("https://api.search.brave.com/res/v1/web/search");
      url.searchParams.set("q", query);
      url.searchParams.set("count", String(maxResults));
      url.searchParams.set("safesearch", "moderate");
      url.searchParams.set("text_decorations", "0");

      const response = await fetch(url, {
        method: "GET",
        signal: controller.signal,
        headers: {
          Accept: "application/json",
          "Accept-Encoding": "gzip",
          "X-Subscription-Token": this._apiKey,
        },
      });

      if (!response.ok) {
        throw new Error(`Brave API request failed with status ${response.status}`);
      }

      const data = await response.json();
      const results = Array.isArray(data?.web?.results) ? data.web.results : [];

      const sources = results
        .map((r) => ({ title: r?.title || "Untitled", url: r?.url || "" }))
        .filter((s) => s.url);

      const summary = results
        .map((r) => (typeof r?.description === "string" ? r.description.trim() : ""))
        .filter(Boolean)
        .join(" ");

      return { summary, sources };
    } catch (err) {
      if (err?.name === "AbortError") {
        throw new Error("request timed out");
      }
      throw err;
    } finally {
      clearTimeout(timeout);
    }
  }
}
