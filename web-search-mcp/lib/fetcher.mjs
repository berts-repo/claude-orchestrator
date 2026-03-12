import { lookup, resolve4, resolve6 } from "node:dns/promises";
import { request as httpRequest } from "node:http";
import { request as httpsRequest } from "node:https";
import { isIP } from "node:net";

const USER_AGENT = "web-search-mcp/0.1 (MCP fetch tool)";

function errorWithCode(message, code) {
  const err = new Error(message);
  err.code = code;
  return err;
}

const IPV4_DENY_CIDRS = [
  "0.0.0.0/8",
  "10.0.0.0/8",
  "100.64.0.0/10",
  "127.0.0.0/8",
  "169.254.0.0/16",
  "172.16.0.0/12",
  "192.0.0.0/24",
  "192.0.2.0/24",
  "192.168.0.0/16",
  "198.18.0.0/15",
  "198.51.100.0/24",
  "203.0.113.0/24",
  "224.0.0.0/4",
  "240.0.0.0/4",
  "255.255.255.255/32",
];

const IPV6_DENY_CIDRS = [
  "::/128",
  "::1/128",
  "fc00::/7",
  "fec0::/10",
  "fe80::/10",
  "ff00::/8",
  "::ffff:0:0/96",
  "64:ff9b::/96",
  "100::/64",
  "2001::/23",
  "2001:db8::/32",
];

const BLOCKED_HOSTNAMES = new Set([
  "localhost",
  "localhost.localdomain",
  "localhost6",
  "localhost6.localdomain6",
  "ip6-localhost",
  "ip6-loopback",
  "metadata.google.internal",
]);

function isBlockedHostname(hostname) {
  return (
    BLOCKED_HOSTNAMES.has(hostname) ||
    hostname.endsWith(".localhost") ||
    hostname.endsWith(".local") ||
    hostname.endsWith(".internal")
  );
}

function normalizeIpLiteral(ip) {
  return ip.toLowerCase().replace(/^\[|\]$/g, "");
}

function parseIpv4ToBytes(ip) {
  if (!/^\d{1,3}(?:\.\d{1,3}){3}$/.test(ip)) return null;
  const parts = ip.split(".").map(Number);
  if (parts.some((n) => Number.isNaN(n) || n < 0 || n > 255)) return null;
  return Uint8Array.from(parts);
}

function parseIpv6ToBytes(ip) {
  const parts = ip.split("::");
  if (parts.length > 2) return null;
  const [leftRaw, rightRaw] = parts;

  const parseSide = (side) => {
    if (!side) return [];
    const groups = [];
    for (const part of side.split(":")) {
      if (part.includes(".")) {
        const ipv4Bytes = parseIpv4ToBytes(part);
        if (!ipv4Bytes) return null;
        groups.push((ipv4Bytes[0] << 8) | ipv4Bytes[1], (ipv4Bytes[2] << 8) | ipv4Bytes[3]);
        continue;
      }
      if (!/^[0-9a-f]{1,4}$/i.test(part)) return null;
      groups.push(Number.parseInt(part, 16));
    }
    return groups;
  };

  const left = parseSide(leftRaw);
  const right = parseSide(rightRaw);
  if (!left || !right) return null;

  const hasCompression = ip.includes("::");
  if (!hasCompression && left.length !== 8) return null;
  if (hasCompression && left.length + right.length > 8) return null;

  const missing = hasCompression ? 8 - (left.length + right.length) : 0;
  const groups = [...left, ...Array(missing).fill(0), ...right];
  if (groups.length !== 8) return null;

  const bytes = new Uint8Array(16);
  for (let i = 0; i < groups.length; i += 1) {
    bytes[i * 2] = (groups[i] >> 8) & 0xff;
    bytes[i * 2 + 1] = groups[i] & 0xff;
  }
  return bytes;
}

function parseIpToBytes(ipRaw) {
  const ip = normalizeIpLiteral(ipRaw);
  if (isIP(ip) === 4) return parseIpv4ToBytes(ip);
  if (isIP(ip) === 6) return parseIpv6ToBytes(ip);
  return null;
}

function cidrContains(ipRaw, cidr) {
  const [network, prefixLengthRaw] = cidr.split("/");
  const prefixLength = Number(prefixLengthRaw);
  if (!Number.isInteger(prefixLength)) return false;

  const ipBytes = parseIpToBytes(ipRaw);
  const networkBytes = parseIpToBytes(network);
  if (!ipBytes || !networkBytes || ipBytes.length !== networkBytes.length) return false;

  const totalBits = ipBytes.length * 8;
  if (prefixLength < 0 || prefixLength > totalBits) return false;

  const fullBytes = Math.floor(prefixLength / 8);
  const remainderBits = prefixLength % 8;

  for (let i = 0; i < fullBytes; i += 1) {
    if (ipBytes[i] !== networkBytes[i]) return false;
  }

  if (remainderBits === 0) return true;

  const mask = (0xff << (8 - remainderBits)) & 0xff;
  return (ipBytes[fullBytes] & mask) === (networkBytes[fullBytes] & mask);
}

function isDeniedIpAddress(addressRaw) {
  const address = normalizeIpLiteral(addressRaw);
  const family = isIP(address);
  if (family === 4) return IPV4_DENY_CIDRS.some((cidr) => cidrContains(address, cidr));
  if (family === 6) return IPV6_DENY_CIDRS.some((cidr) => cidrContains(address, cidr));
  return false;
}

function assertPublicAddress(addressRaw) {
  if (isDeniedIpAddress(addressRaw)) {
    throw errorWithCode("URL not allowed: resolved to a private/loopback IP", "ERR_URL_NOT_ALLOWED");
  }
}

function createPinnedLookup(hostname, pinnedAddress) {
  const normalizedHostname = hostname.toLowerCase().replace(/\.+$/, "");
  const normalizedPinnedAddress = normalizeIpLiteral(pinnedAddress);

  return (requestedHostname, _options, callback) => {
    const normalizedRequested = requestedHostname.toLowerCase().replace(/\.+$/, "");
    if (normalizedRequested !== normalizedHostname) {
      callback(errorWithCode("URL not allowed: unexpected DNS lookup target", "ERR_URL_NOT_ALLOWED"));
      return;
    }
    callback(null, normalizedPinnedAddress, isIP(normalizedPinnedAddress));
  };
}

async function resolveSafeFetchAddress(urlObj) {
  const hostname = urlObj.hostname.toLowerCase().replace(/\.+$/, "");
  const ipv6Hostname = hostname.startsWith("[") && hostname.endsWith("]") ? hostname.slice(1, -1) : hostname;

  let resolvedAddress;
  if (isIP(ipv6Hostname) !== 0) {
    resolvedAddress = ipv6Hostname;
  } else {
    const lookupResult = await lookup(hostname, { verbatim: true });
    resolvedAddress = lookupResult.address;
  }

  assertPublicAddress(resolvedAddress);

  const pinnedUrlObj = new URL(urlObj);
  let pinnedLookup;
  const shouldPinIp = urlObj.protocol === "http:" && isIP(ipv6Hostname) === 0;
  if (shouldPinIp) {
    pinnedUrlObj.hostname = resolvedAddress;
  }
  if (urlObj.protocol === "https:" && isIP(ipv6Hostname) === 0) {
    pinnedLookup = createPinnedLookup(hostname, resolvedAddress);
  }

  return {
    hostHeader: shouldPinIp ? urlObj.host : undefined,
    pinnedLookup,
    pinnedUrlObj,
  };
}

async function sendRequest(urlObj, { signal, headers, pinnedLookup }) {
  const requestFn = urlObj.protocol === "https:" ? httpsRequest : httpRequest;
  const normalizedHostname = normalizeIpLiteral(urlObj.hostname);
  const servername = normalizeIpLiteral(urlObj.hostname).replace(/\.+$/, "");
  const requestOptions = {
    method: "GET",
    hostname: normalizedHostname,
    ...(urlObj.port ? { port: Number(urlObj.port) } : {}),
    path: `${urlObj.pathname}${urlObj.search}`,
    headers,
    signal,
    ...(pinnedLookup ? { lookup: pinnedLookup } : {}),
    ...(urlObj.protocol === "https:" && pinnedLookup ? { servername } : {}),
  };

  return new Promise((resolve, reject) => {
    const req = requestFn(requestOptions, (res) => resolve(res));
    req.on("error", reject);
    req.end();
  });
}

async function assertSafeUrl(urlObj) {
  const hostname = urlObj.hostname.toLowerCase().replace(/\.+$/, "");
  const ipv6Hostname = hostname.startsWith("[") && hostname.endsWith("]") ? hostname.slice(1, -1) : hostname;

  if (isBlockedHostname(hostname)) {
    throw errorWithCode("URL not allowed: local/internal domains are blocked", "ERR_URL_NOT_ALLOWED");
  }
  if (hostname === "169.254.169.254") {
    throw errorWithCode("URL not allowed: metadata endpoint is blocked", "ERR_URL_NOT_ALLOWED");
  }
  if (hostname === "127.0.0.1" || hostname === "::1" || hostname === "[::1]" || ipv6Hostname === "::1") {
    throw errorWithCode("URL not allowed: loopback address is blocked", "ERR_URL_NOT_ALLOWED");
  }
  if (isDeniedIpAddress(hostname) || isDeniedIpAddress(ipv6Hostname)) {
    throw errorWithCode("URL not allowed: private/link-local IP is blocked", "ERR_URL_NOT_ALLOWED");
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

  for (const resolvedAddress of resolvedAddresses) {
    assertPublicAddress(resolvedAddress);
  }
}

export async function fetchUrl(rawUrl, { timeoutMs = 10_000, maxBytes = 5_242_880, requestImpl = sendRequest } = {}) {
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
      const { pinnedUrlObj, hostHeader, pinnedLookup } = await resolveSafeFetchAddress(currentUrlObj);
      response = await requestImpl(pinnedUrlObj, {
        signal: controller.signal,
        pinnedLookup,
        headers: {
          "User-Agent": USER_AGENT,
          ...(hostHeader ? { Host: hostHeader } : {}),
        },
      });

      if (
        (response.statusCode === 301 ||
          response.statusCode === 302 ||
          response.statusCode === 303 ||
          response.statusCode === 307 ||
          response.statusCode === 308) &&
        response.headers.location
      ) {
        if (redirectCount >= 10) {
          throw errorWithCode("Too many redirects", "ERR_TOO_MANY_REDIRECTS");
        }
        response.destroy();
        redirectCount += 1;
        const nextUrlObj = new URL(response.headers.location, currentUrlObj);
        if (nextUrlObj.protocol !== "http:" && nextUrlObj.protocol !== "https:") {
          throw errorWithCode("URL scheme not allowed", "ERR_URL_NOT_ALLOWED");
        }
        await assertSafeUrl(nextUrlObj);
        currentUrlObj = nextUrlObj;
        continue;
      }

      break;
    }

    const finalUrl = currentUrlObj.href;
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

    const contentType = typeof response.headers["content-type"] === "string" ? response.headers["content-type"] : "";
    const lowerType = contentType.toLowerCase();
    if (!lowerType.includes("text/html") && !lowerType.includes("text/plain")) {
      throw errorWithCode("unsupported content type", "ERR_UNSUPPORTED_CONTENT_TYPE");
    }

    const decoder = new TextDecoder();
    let total = 0;
    let html = "";

    for await (const chunk of response) {
      const value = chunk instanceof Uint8Array ? chunk : Buffer.from(chunk);
      total += value.byteLength;
      if (total > maxBytes) {
        response.destroy();
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
