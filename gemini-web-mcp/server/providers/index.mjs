import { GeminiProvider } from "./gemini-provider.mjs";

const providers = {
  gemini: () => new GeminiProvider(),
};

export function getProvider(name = "gemini") {
  const factory = providers[name];
  if (!factory) {
    throw new Error(`Unknown provider: ${name}. Available: ${Object.keys(providers).join(", ")}`);
  }
  const provider = factory();
  if (!provider.isAvailable()) {
    throw new Error(`Provider "${name}" is not available (missing API key or not implemented)`);
  }
  return provider;
}

export function listProviders() {
  return Object.entries(providers).map(([name, factory]) => {
    const p = factory();
    return { name, available: p.isAvailable() };
  });
}
