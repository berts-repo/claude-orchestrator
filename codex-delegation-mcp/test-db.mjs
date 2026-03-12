import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";

const require = createRequire(import.meta.url);
const BetterSqlite3 = require("better-sqlite3");

function runTest(name, fn) {
  try {
    fn();
    console.log(`PASS ${name}`);
    return true;
  } catch (error) {
    console.error(`FAIL ${name}`);
    console.error(error?.stack || String(error));
    return false;
  }
}

async function loadDbInternals() {
  const scriptDir = path.dirname(fileURLToPath(import.meta.url));
  const tempRoot = fs.mkdtempSync(path.join(scriptDir, ".db-test-module-"));
  const modulePath = path.join(tempRoot, "db-testable.mjs");
  const sourcePath = new URL("./db.js", import.meta.url);
  const source = fs.readFileSync(sourcePath, "utf8");
  const patchedSource = `${source}\nexport { initSchema, initDefaults };\n`;
  fs.writeFileSync(modulePath, patchedSource, "utf8");

  const originalHome = process.env.HOME;
  const originalConsoleError = console.error;
  process.env.HOME = path.join(tempRoot, "home");
  console.error = () => {};

  try {
    return await import(`${pathToFileURL(modulePath).href}?t=${Date.now()}`);
  } finally {
    console.error = originalConsoleError;
    if (originalHome === undefined) {
      delete process.env.HOME;
    } else {
      process.env.HOME = originalHome;
    }
  }
}

function getTableNames(conn) {
  return new Set(
    conn
      .prepare("SELECT name FROM sqlite_master WHERE type = 'table'")
      .all()
      .map((row) => row.name)
  );
}

function getTaskColumns(conn) {
  return new Set(conn.prepare("PRAGMA table_info(tasks)").all().map((col) => col.name));
}

const { initSchema, migrateSchema, initDefaults } = await loadDbInternals();

let failures = 0;

if (
  !runTest("initSchema creates expected tables", () => {
    const conn = new BetterSqlite3(":memory:");
    initSchema(conn);
    const tables = getTableNames(conn);
    const expected = ["sessions", "batches", "tasks", "task_tags", "tags", "config"];
    for (const table of expected) {
      assert.equal(tables.has(table), true, `Missing table: ${table}`);
    }
    conn.close();
  })
) {
  failures += 1;
}

if (
  !runTest("migrateSchema adds tasks.output_full when missing", () => {
    const conn = new BetterSqlite3(":memory:");
    conn.exec(`
      CREATE TABLE tasks (
        id INTEGER PRIMARY KEY,
        invocation_id TEXT UNIQUE
      );
    `);
    const before = getTaskColumns(conn);
    assert.equal(before.has("output_full"), false, "output_full should not exist before migration");

    migrateSchema(conn);

    const after = getTaskColumns(conn);
    assert.equal(after.has("output_full"), true, "output_full should exist after migration");
    conn.close();
  })
) {
  failures += 1;
}

if (
  !runTest("initDefaults populates expected config keys", () => {
    const conn = new BetterSqlite3(":memory:");
    initSchema(conn);
    initDefaults(conn);

    const rows = conn
      .prepare("SELECT key, value FROM config ORDER BY key ASC")
      .all();
    const actual = new Map(rows.map((row) => [row.key, row.value]));
    const expected = new Map([
      ["prompt_full_days", "7"],
      ["output_days", "3"],
      ["output_full_days", "3"],
      ["row_days", "365"],
      ["max_prompt_chars", "4000"],
      ["max_db_mb", "100"],
    ]);

    assert.equal(actual.size, expected.size, "Unexpected number of config rows");
    for (const [key, value] of expected.entries()) {
      assert.equal(actual.get(key), value, `Unexpected config value for ${key}`);
    }
    conn.close();
  })
) {
  failures += 1;
}

if (failures > 0) {
  process.exitCode = 1;
}
