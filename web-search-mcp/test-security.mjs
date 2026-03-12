import test from "node:test";
import assert from "node:assert/strict";

import { fetchUrl } from "./lib/fetcher.mjs";
import { sanitizeResponse } from "./lib/sanitize.mjs";

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
  let hop = 0;
  const requestImpl = async () => {
    hop += 1;
    return {
      statusCode: 302,
      headers: { location: `https://1.2.3.4/hop-${hop}` },
      destroy() {},
    };
  };

  await assertRejectsCode(
    () => fetchUrl("https://1.2.3.4/start", { requestImpl }),
    "ERR_TOO_MANY_REDIRECTS",
  );
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
