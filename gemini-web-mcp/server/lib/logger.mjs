/**
 * Structured JSON logger — writes to stderr only.
 * stdout is reserved for MCP stdio transport.
 */

const LEVELS = { debug: 0, info: 1, warn: 2, error: 3 };
const currentLevel = LEVELS[process.env.LOG_LEVEL?.toLowerCase()] ?? LEVELS.info;

export function log(level, msg, meta = {}) {
  if ((LEVELS[level] ?? 0) < currentLevel) return;
  const entry = {
    ts: new Date().toISOString(),
    level,
    msg,
    ...meta,
  };
  process.stderr.write(JSON.stringify(entry) + "\n");
}

export const debug = (msg, meta) => log("debug", msg, meta);
export const info = (msg, meta) => log("info", msg, meta);
export const warn = (msg, meta) => log("warn", msg, meta);
export const error = (msg, meta) => log("error", msg, meta);
