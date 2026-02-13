#!/usr/bin/env node
/**
 * Standalone test — calls Gemini directly (bypasses MCP transport).
 * Usage: GEMINI_API_KEY="..." node test-search.mjs [query]
 */
import { GoogleGenerativeAI } from "@google/generative-ai";

const apiKey = process.env.GEMINI_API_KEY;
if (!apiKey) {
  console.error("Set GEMINI_API_KEY to run this test");
  process.exit(1);
}

const query = process.argv[2] || "latest Node.js LTS release";
const model = process.env.GEMINI_MODEL || "gemini-2.5-flash";

console.log(`Testing Gemini web search grounding`);
console.log(`  Model: ${model}`);
console.log(`  Query: ${query}`);
console.log();

const genAI = new GoogleGenerativeAI(apiKey);
const genModel = genAI.getGenerativeModel({
  model,
  tools: [{ google_search: {} }],
});

try {
  const result = await genModel.generateContent({
    contents: [{ role: "user", parts: [{ text: `Search the web for: ${query}` }] }],
  }, {
    timeout: 15_000,
  });

  const response = result.response;
  const text = response.text();
  console.log("--- Response ---");
  console.log(text);
  console.log();

  const candidate = response.candidates?.[0];
  const metadata = candidate?.groundingMetadata;
  if (metadata?.groundingChunks?.length) {
    console.log("--- Grounding Sources ---");
    for (const chunk of metadata.groundingChunks) {
      if (chunk.web) {
        console.log(`  ${chunk.web.title || "Untitled"} — ${chunk.web.uri}`);
      }
    }
  } else {
    console.log("(no grounding chunks returned)");
  }

  console.log();
  console.log("PASS");
  process.exit(0);
} catch (err) {
  console.error("FAIL:", err.message || err);
  process.exit(1);
}
