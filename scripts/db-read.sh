#!/usr/bin/env bash
# db-read.sh — safe sqlite3 bypass for large audit DB reads
#
# Usage:
#   db-read.sh view <batch_id> [task_index]
#   db-read.sh query <sql>
#   db-read.sh export [--table tasks|security_events|web_tasks] [--days N]
#   db-read.sh search <keyword> [limit]
#
# Validates all inputs before touching sqlite3. Exits non-zero on bad input.
# On success, writes output to /tmp/audit-*.json (or .txt for view) and prints the path.

set -euo pipefail

DB="${HOME}/.claude/audit.db"
ALLOWED_TABLES=("tasks" "security_events" "web_tasks")

die() { echo "Error: $*" >&2; exit 1; }

require_sqlite3() {
  command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 not found in PATH"
  [[ -f "$DB" ]] || die "audit DB not found at $DB"
}

is_integer() { [[ "$1" =~ ^[0-9]+$ ]]; }

is_valid_table() {
  local t="$1"
  for allowed in "${ALLOWED_TABLES[@]}"; do
    [[ "$t" == "$allowed" ]] && return 0
  done
  return 1
}

# Escape single quotes for SQL string literals
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

# Reject shell metacharacters that could escape the sqlite3 argument
check_no_shell_meta() {
  local val="$1" label="$2"
  if printf '%s' "$val" | grep -qE '[$`\"]|\\\\'; then
    die "$label contains unsafe shell metacharacters"
  fi
}

subcommand="${1:-}"
shift || true

case "$subcommand" in

  # ── view ──────────────────────────────────────────────────────────────────
  view)
    batch_id="${1:-}"
    task_index="${2:-0}"

    [[ -n "$batch_id" ]] || die "usage: db-read.sh view <batch_id> [task_index]"
    [[ "$batch_id" =~ ^[0-9a-f-]{36}$ ]] || die "invalid batch_id (expected UUID)"
    is_integer "$task_index"            || die "task_index must be a non-negative integer"

    require_sqlite3
    out="/tmp/codex-output.txt"
    sqlite3 "$DB" \
      "SELECT output_full FROM tasks WHERE batch_id = '$(sql_escape "$batch_id")' AND task_index = ${task_index}" \
      > "$out"
    [[ -s "$out" ]] || die "no output stored for batch $batch_id task $task_index"
    echo "$out"
    ;;

  # ── query ─────────────────────────────────────────────────────────────────
  query)
    sql="${1:-}"
    [[ -n "$sql" ]] || die "usage: db-read.sh query <sql>"

    sql_upper="$(printf '%s' "$sql" | tr '[:lower:]' '[:upper:]')"

    # Must start with SELECT (case-insensitive, allow leading whitespace)
    [[ "$sql_upper" =~ ^[[:space:]]*SELECT ]] || die "only SELECT statements are allowed"

    # Block DML/DDL keywords and multiple statements via Python (needs word boundaries + lookbehind)
    python3 - "$sql_upper" "$sql" <<'PYEOF'
import re, sys
sql_upper, sql_orig = sys.argv[1], sys.argv[2]
if re.search(r'\b(INSERT|UPDATE|DELETE|DROP|CREATE|ALTER|ATTACH|DETACH|PRAGMA|VACUUM)\b', sql_upper):
    print("Error: unsafe SQL rejected", file=sys.stderr); sys.exit(1)
# Strip string literals then check for semicolons (multiple statements)
cleaned = re.sub(r"'[^']*'", '', sql_orig)
if ';' in cleaned:
    print("Error: multiple statements not allowed", file=sys.stderr); sys.exit(1)
PYEOF

    check_no_shell_meta "$sql" "sql"

    require_sqlite3
    out="/tmp/audit-query.json"
    sqlite3 -json "$DB" "$sql" > "$out"
    echo "$out"
    ;;

  # ── export ────────────────────────────────────────────────────────────────
  export)
    table="tasks"
    days="7"

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --table) table="${2:-}"; shift 2 ;;
        --days)  days="${2:-}";  shift 2 ;;
        *) die "unknown argument: $1" ;;
      esac
    done

    is_valid_table "$table" || die "table must be one of: tasks, security_events, web_tasks"
    is_integer "$days"      || die "days must be a positive integer"
    (( days >= 1 && days <= 365 )) || die "days must be between 1 and 365"

    require_sqlite3
    out="/tmp/audit-export.json"

    case "$table" in
      tasks)
        sqlite3 -json "$DB" \
          "SELECT * FROM tasks WHERE started_at > (strftime('%s','now','-${days} days') * 1000) ORDER BY started_at DESC" \
          > "$out"
        ;;
      security_events)
        sqlite3 -json "$DB" \
          "SELECT * FROM security_events WHERE timestamp_ms > (strftime('%s','now','-${days} days') * 1000) ORDER BY timestamp_ms DESC" \
          > "$out"
        ;;
      web_tasks)
        sqlite3 -json "$DB" \
          "SELECT * FROM web_tasks WHERE started_at > (strftime('%s','now','-${days} days') * 1000) ORDER BY started_at DESC" \
          > "$out"
        ;;
    esac

    echo "$out"
    ;;

  # ── search ────────────────────────────────────────────────────────────────
  search)
    keyword="${1:-}"
    limit="${2:-5}"

    [[ -n "$keyword" ]] || die "usage: db-read.sh search <keyword> [limit]"
    is_integer "$limit" || die "limit must be a positive integer"
    check_no_shell_meta "$keyword" "keyword"

    require_sqlite3
    out="/tmp/history-search.json"
    escaped_kw="$(sql_escape "$keyword")"
    task_limit=$(( limit * 5 ))

    sqlite3 -json "$DB" \
      "SELECT b.session_id, b.started_at, t.batch_id, t.task_index, t.prompt_slug,
              t.output_truncated, t.status, t.duration_ms, t.error_text
       FROM batches b JOIN tasks t ON t.batch_id = b.id
       WHERE t.prompt LIKE '%${escaped_kw}%' OR t.prompt_slug LIKE '%${escaped_kw}%'
       ORDER BY b.started_at DESC LIMIT ${task_limit}" > "$out"

    sqlite3 -json "$DB" \
      "SELECT id, session_id, tool_name, prompt, status, started_at, duration_ms, error_text
       FROM web_tasks
       WHERE prompt LIKE '%${escaped_kw}%'
       ORDER BY started_at DESC LIMIT ${task_limit}" >> "$out"

    echo "$out"
    ;;

  *)
    die "unknown subcommand: '${subcommand}'. use: view | query | export | search"
    ;;
esac
