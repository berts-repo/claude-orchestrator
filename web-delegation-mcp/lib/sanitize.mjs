export const INJECTION_PATTERNS =
  /\b(ignore previous|ignore above|disregard|you are now|new instructions|system prompt|execute|run command|sudo|bash -c)\b/i;

/**
 * @description Sanitizes a raw user query by trimming whitespace, removing control characters and HTML tags, normalizing spacing, and enforcing max length.
 * @param {string} raw - The raw user-provided search query text.
 * @param {number} [maxLength=500] - Maximum allowed query length after sanitization.
 * @returns {string} Returns a cleaned query string suitable for provider search.
 */
export function sanitizeQuery(raw, maxLength = 500) {
  let q = raw.trim();
  q = q.replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, "");
  q = q.replace(/\s+/g, " ");
  q = q.replace(/<[^>]*>/g, "");
  if (q.length > maxLength) {
    q = q.slice(0, maxLength);
  }
  return q;
}

/**
 * @description Sanitizes provider response text by removing scripts and HTML tags, filtering known instruction-like patterns, and truncating oversized output.
 * @param {string} text - The raw response text returned by the provider.
 * @param {number} [maxLength=4000] - Maximum allowed output length after sanitization.
 * @returns {string} Returns sanitized response text safe to wrap in untrusted content markers.
 */
export function sanitizeResponse(text, maxLength = 4000) {
  let t = text;
  t = t.replace(/\x1b\[[0-9;]*[A-Za-z]/g, "");
  t = t.replace(/\x1b/g, "");
  t = t.replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, "");
  t = t.replace(/[\x80-\x9f]/g, "");
  t = t.replace(/[\u200b-\u200f\u2028\u2029\u202a-\u202e\u2060-\u2069\u206a-\u206f\ufeff]/g, "");
  t = t.replace(/<script[\s\S]*?<\/script>/gi, "");
  t = t.replace(/<[^>]*>/g, "");
  t = t.replace(
    /\b(IMPORTANT SYSTEM NOTE|INSTRUCTION FOR AGENT|EXECUTE COMMAND)[:\s].{0,200}/gi,
    "[content removed]",
  );
  if (t.length > maxLength) {
    t = t.slice(0, maxLength) + "\n[truncated]";
  }
  return t;
}
