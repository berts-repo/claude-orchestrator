import { resolve4, resolve6 } from "node:dns/promises";
import { isIP } from "node:net";

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

function extractMappedIpv4(hostname) {
  const match = hostname.match(/^::ffff:(.+)$/i);
  if (!match) return null;
  const tail = match[1];

  if (/^\d{1,3}(?:\.\d{1,3}){3}$/.test(tail)) {
    return tail;
  }

  const parts = tail.split(":");
  if (parts.length !== 2) return null;
  const hextets = parts.map((part) => Number.parseInt(part, 16));
  if (hextets.some((n) => Number.isNaN(n) || n < 0 || n > 0xffff)) return null;

  const [a, b] = hextets;
  const octets = [(a >> 8) & 0xff, a & 0xff, (b >> 8) & 0xff, b & 0xff];
  return octets.join(".");
}

async function assertSafeUrl(urlObj) {
  const hostname = urlObj.hostname.toLowerCase().replace(/\.+$/, "");
  const ipv6Hostname = hostname.startsWith("[") && hostname.endsWith("]") ? hostname.slice(1, -1) : hostname;
  const mappedIpv4 = extractMappedIpv4(ipv6Hostname);

  if (hostname === "localhost") {
    throw errorWithCode("URL not allowed: localhost is blocked", "ERR_URL_NOT_ALLOWED");
  }
  if (hostname.endsWith(".local") || hostname.endsWith(".internal")) {
    throw errorWithCode("URL not allowed: local/internal domains are blocked", "ERR_URL_NOT_ALLOWED");
  }
  if (hostname === "169.254.169.254") {
    throw errorWithCode("URL not allowed: metadata endpoint is blocked", "ERR_URL_NOT_ALLOWED");
  }
  if (hostname === "127.0.0.1" || hostname === "::1" || hostname === "[::1]" || ipv6Hostname === "::1") {
    throw errorWithCode("URL not allowed: loopback address is blocked", "ERR_URL_NOT_ALLOWED");
  }
  if (mappedIpv4 && isPrivateIpv4(mappedIpv4)) {
    throw errorWithCode("URL not allowed: private/link-local IP is blocked", "ERR_URL_NOT_ALLOWED");
  }
  if (isPrivateIpv4(hostname)) {
    throw errorWithCode("URL not allowed: private/link-local IP is blocked", "ERR_URL_NOT_ALLOWED");
  }
  if (
    hostname.startsWith("[fc") ||
    hostname.startsWith("[fd") ||
    hostname.startsWith("[fe80") ||
    ipv6Hostname.startsWith("fc") ||
    ipv6Hostname.startsWith("fd") ||
    ipv6Hostname.startsWith("fe80")
  ) {
    throw errorWithCode("URL not allowed: private/link-local IPv6 is blocked", "ERR_URL_NOT_ALLOWED");
  }

  if (isIP(ipv6Hostname) !== 0) return;

  const [v4Result, v6Result] = await Promise.allSettled([
    resolve4(hostname),
    resolve6(hostname),
  ]);

  const resolvedAddresses = [];
  if (v4Result.status === "fulfilled") {
    resolvedAddresses.push(...v4Result.value);
  }
  if (v6Result.status === "fulfilled") {
    resolvedAddresses.push(...v6Result.value);
  }

  if (resolvedAddresses.length === 0) {
    throw errorWithCode("URL not allowed: DNS resolution failed", "ERR_URL_NOT_ALLOWED");
  }

  for (const resolvedAddressRaw of resolvedAddresses) {
    const resolvedAddress = resolvedAddressRaw.toLowerCase();
    const resolvedMappedIpv4 = extractMappedIpv4(resolvedAddress);
    if (
      isPrivateIpv4(resolvedAddress) ||
      resolvedAddress === "::1" ||
      resolvedAddress.startsWith("fc") ||
      resolvedAddress.startsWith("fd") ||
      resolvedAddress.startsWith("fe80") ||
      (resolvedMappedIpv4 && isPrivateIpv4(resolvedMappedIpv4))
    ) {
      throw errorWithCode("URL not allowed: resolved to a private/loopback IP", "ERR_URL_NOT_ALLOWED");
    }
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

  await assertSafeUrl(urlObj);

  const controller = new AbortController();
  let timedOut = false;
  const timeout = setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, timeoutMs);

  try {
    let response;
    let currentUrlObj = urlObj;
    let redirectCount = 0;
    while (true) {
      response = await fetch(currentUrlObj, {
        method: "GET",
        redirect: "manual",
        credentials: "omit",
        signal: controller.signal,
        headers: {
          "User-Agent": USER_AGENT,
        },
      });

      if (
        (response.status === 301 ||
          response.status === 302 ||
          response.status === 303 ||
          response.status === 307 ||
          response.status === 308) &&
        response.headers.get("location")
      ) {
        if (redirectCount >= 10) {
          throw errorWithCode("Too many redirects", "ERR_TOO_MANY_REDIRECTS");
        }
        redirectCount += 1;
        const nextUrlObj = new URL(response.headers.get("location"), currentUrlObj);
        if (nextUrlObj.protocol !== "http:" && nextUrlObj.protocol !== "https:") {
          throw errorWithCode("URL scheme not allowed", "ERR_URL_NOT_ALLOWED");
        }
        await assertSafeUrl(nextUrlObj);
        currentUrlObj = nextUrlObj;
        continue;
      }

      break;
    }

    const finalUrl = response.url || currentUrlObj.href;
    let finalUrlObj;
    try {
      finalUrlObj = new URL(finalUrl);
    } catch {
      throw errorWithCode("Invalid final URL", "ERR_INVALID_URL");
    }

    if (finalUrlObj.protocol !== "http:" && finalUrlObj.protocol !== "https:") {
      throw errorWithCode("Final URL scheme not allowed", "ERR_URL_NOT_ALLOWED");
    }
    await assertSafeUrl(finalUrlObj);

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
