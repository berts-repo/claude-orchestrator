const USER_AGENT = "web-search-mcp/0.1 (MCP fetch tool)";

function errorWithCode(message, code) {
  const err = new Error(message);
  err.code = code;
  return err;
}

function isPrivateIpv4(hostname) {
  if (!/^\d{1,3}(\.\d{1,3}){3}$/.test(hostname)) return false;
  const parts = hostname.split(".").map(Number);
  if (parts.some((n) => Number.isNaN(n) || n < 0 || n > 255)) return false;
  const [a, b] = parts;
  if (a === 10) return true;
  if (a === 127) return true;
  if (a === 192 && b === 168) return true;
  if (a === 169 && b === 254) return true;
  if (a === 172 && b >= 16 && b <= 31) return true;
  return false;
}

function assertSafeUrl(urlObj) {
  const hostname = urlObj.hostname.toLowerCase();

  if (hostname === "localhost") {
    throw errorWithCode("URL not allowed: localhost is blocked", "ERR_URL_NOT_ALLOWED");
  }
  if (hostname.endsWith(".local") || hostname.endsWith(".internal")) {
    throw errorWithCode("URL not allowed: local/internal domains are blocked", "ERR_URL_NOT_ALLOWED");
  }
  if (hostname === "169.254.169.254") {
    throw errorWithCode("URL not allowed: metadata endpoint is blocked", "ERR_URL_NOT_ALLOWED");
  }
  if (hostname === "127.0.0.1" || hostname === "::1" || hostname === "[::1]") {
    throw errorWithCode("URL not allowed: loopback address is blocked", "ERR_URL_NOT_ALLOWED");
  }
  if (isPrivateIpv4(hostname)) {
    throw errorWithCode("URL not allowed: private/link-local IP is blocked", "ERR_URL_NOT_ALLOWED");
  }
  if (
    hostname.startsWith("[fc") ||
    hostname.startsWith("[fd") ||
    hostname.startsWith("[fe80")
  ) {
    throw errorWithCode("URL not allowed: private/link-local IPv6 is blocked", "ERR_URL_NOT_ALLOWED");
  }
}

export async function fetchUrl(rawUrl, { timeoutMs = 10_000, maxBytes = 5_242_880 } = {}) {
  let urlObj;
  try {
    urlObj = new URL(rawUrl);
  } catch {
    throw errorWithCode("Invalid URL", "ERR_INVALID_URL");
  }

  if (urlObj.protocol !== "http:" && urlObj.protocol !== "https:") {
    throw errorWithCode("URL scheme not allowed", "ERR_URL_NOT_ALLOWED");
  }

  assertSafeUrl(urlObj);

  const controller = new AbortController();
  let timedOut = false;
  const timeout = setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, timeoutMs);

  try {
    const response = await fetch(urlObj, {
      method: "GET",
      redirect: "follow",
      credentials: "omit",
      signal: controller.signal,
      headers: {
        "User-Agent": USER_AGENT,
      },
    });

    const finalUrl = response.url || urlObj.href;
    let finalUrlObj;
    try {
      finalUrlObj = new URL(finalUrl);
    } catch {
      throw errorWithCode("Invalid final URL", "ERR_INVALID_URL");
    }

    if (finalUrlObj.protocol !== "http:" && finalUrlObj.protocol !== "https:") {
      throw errorWithCode("Final URL scheme not allowed", "ERR_URL_NOT_ALLOWED");
    }
    assertSafeUrl(finalUrlObj);

    const contentType = response.headers.get("content-type") || "";
    const lowerType = contentType.toLowerCase();
    if (!lowerType.includes("text/html") && !lowerType.includes("text/plain")) {
      throw errorWithCode("unsupported content type", "ERR_UNSUPPORTED_CONTENT_TYPE");
    }

    if (!response.body) {
      return { html: "", contentType, finalUrl };
    }

    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let total = 0;
    let html = "";

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) {
        await reader.cancel();
        throw errorWithCode("Response exceeded size limit", "ERR_RESPONSE_TOO_LARGE");
      }
      html += decoder.decode(value, { stream: true });
    }

    html += decoder.decode();
    return { html, contentType, finalUrl };
  } catch (err) {
    if (timedOut || err?.name === "AbortError") {
      throw errorWithCode("request timed out", "ERR_TIMEOUT");
    }
    throw err;
  } finally {
    clearTimeout(timeout);
  }
}
