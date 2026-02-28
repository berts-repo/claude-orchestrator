import test from "node:test";
import assert from "node:assert/strict";

import { fetchUrl } from "./lib/fetcher.mjs";

function sanitizeResponse(text) {
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
  if (t.length > 4000) {
    t = t.slice(0, 4000) + "\n[truncated]";
  }
  return t;
}

async function assertRejectsCode(promiseFactory, code) {
  await assert.rejects(
    promiseFactory(),
    (err) => {
      assert.equal(err?.code, code);
      return true;
    },
  );
}

function redirectResponse(location) {
  return {
    status: 302,
    headers: {
      get(name) {
        return name.toLowerCase() === "location" ? location : null;
      },
    },
  };
}

function plainResponse({ url = "https://example.com/final", contentType = "text/plain", body = "ok" } = {}) {
  return new Response(body, {
    status: 200,
    headers: { "content-type": contentType },
  });
}

test("fetchUrl rejects blocked URL patterns with ERR_URL_NOT_ALLOWED", async () => {
  const urls = [
    "http://localhost./",
    "http://[::ffff:127.0.0.1]/",
    "http://[::ffff:10.0.0.1]/",
    "http://[::1]/",
    "http://10.0.0.1/",
    "http://192.168.1.1/",
    "http://172.16.0.1/",
    "http://169.254.169.254/",
    "http://[fc00::1]/",
    "http://[fe80::1]/",
    "file:///etc/passwd",
  ];

  for (const url of urls) {
    await assertRejectsCode(() => fetchUrl(url), "ERR_URL_NOT_ALLOWED");
  }
});

test("fetchUrl blocks redirect chain when redirected to private IP", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => redirectResponse("http://127.0.0.1/secret");

  try {
    await assertRejectsCode(() => fetchUrl("http://example.com/start"), "ERR_URL_NOT_ALLOWED");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("fetchUrl rejects too many redirects with ERR_TOO_MANY_REDIRECTS", async () => {
  const originalFetch = globalThis.fetch;
  let hop = 0;
  globalThis.fetch = async () => {
    hop += 1;
    return redirectResponse(`https://example.com/hop-${hop}`);
  };

  try {
    await assertRejectsCode(() => fetchUrl("https://example.com/start"), "ERR_TOO_MANY_REDIRECTS");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("sanitizeResponse strips ANSI color code", () => {
  assert.equal(sanitizeResponse("a\x1b[31mb"), "ab");
});

test("sanitizeResponse strips ANSI cursor control", () => {
  assert.equal(sanitizeResponse("a\x1b[2Jb"), "ab");
});

test("sanitizeResponse strips bare ESC", () => {
  assert.equal(sanitizeResponse("a\x1bb"), "ab");
});

test("sanitizeResponse strips null byte", () => {
  assert.equal(sanitizeResponse("a\x00b"), "ab");
});

test("sanitizeResponse strips VT", () => {
  assert.equal(sanitizeResponse("a\x0bb"), "ab");
});

test("sanitizeResponse strips DEL", () => {
  assert.equal(sanitizeResponse("a\x7fb"), "ab");
});

test("sanitizeResponse strips C1 range byte", () => {
  assert.equal(sanitizeResponse(`a${String.fromCharCode(0x80)}b`), "ab");
});

test("sanitizeResponse strips RTL override", () => {
  assert.equal(sanitizeResponse("a\u202eb"), "ab");
});

test("sanitizeResponse strips BOM", () => {
  assert.equal(sanitizeResponse("a\ufeffb"), "ab");
});

test("sanitizeResponse preserves tab, LF, and CR", () => {
  assert.equal(sanitizeResponse("a\tb\nc\rd"), "a\tb\nc\rd");
});

test("sanitizeResponse preserves normal ASCII", () => {
  assert.equal(sanitizeResponse("Hello, world! 123"), "Hello, world! 123");
});
