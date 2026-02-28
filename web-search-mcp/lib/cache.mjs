/**
 * Simple in-memory LRU cache with TTL.
 * Disable via CACHE_ENABLED=false env var.
 */

const ENABLED = process.env.CACHE_ENABLED !== "false";
const MAX_ENTRIES = 100;
const TTL_MS = 5 * 60 * 1000; // 5 minutes

const store = new Map();

function normalizeKey(query) {
  return query.toLowerCase().trim().replace(/\s+/g, " ");
}

function evictExpired() {
  const now = Date.now();
  for (const [key, entry] of store) {
    if (now - entry.ts > TTL_MS) {
      store.delete(key);
    }
  }
}

function evictLRU() {
  if (store.size <= MAX_ENTRIES) return;
  // Map preserves insertion order; delete oldest
  const oldest = store.keys().next().value;
  store.delete(oldest);
}

export function get(query) {
  if (!ENABLED) return null;
  evictExpired();
  const key = normalizeKey(query);
  const entry = store.get(key);
  if (!entry) return null;
  if (Date.now() - entry.ts > TTL_MS) {
    store.delete(key);
    return null;
  }
  // Move to end (most recently used)
  store.delete(key);
  store.set(key, entry);
  return entry.value;
}

export function set(query, value) {
  if (!ENABLED) return;
  // Never cache error responses
  if (value?.isError) return;
  const key = normalizeKey(query);
  store.delete(key); // remove if exists to update position
  store.set(key, { ts: Date.now(), value });
  evictLRU();
}

export function size() {
  evictExpired();
  return store.size;
}

export function clear() {
  store.clear();
}
