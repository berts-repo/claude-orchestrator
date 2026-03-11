#!/usr/bin/env bash
set -euo pipefail

if [[ $# -gt 1 ]]; then
  echo "Usage: bash watch-tasks.sh [batchId|auto]" >&2
  exit 1
fi

batch_arg="${1:-auto}"
current_batch_file="${HOME}/.claude/tmp/current-batch-id"
batch_id=""

if [[ -z "$batch_arg" || "$batch_arg" == "auto" ]]; then
  wait_start="$(date +%s%3N 2>/dev/null || python3 -c 'import time; print(int(time.time() * 1000))')"
  while true; do
    if [[ -f "$current_batch_file" ]]; then
      detected_batch_id="$(cat "$current_batch_file" 2>/dev/null || true)"
      detected_batch_id="${detected_batch_id//$'\n'/}"
      detected_batch_id="${detected_batch_id//$'\r'/}"
      if [[ -n "$detected_batch_id" ]]; then
        batch_id="$detected_batch_id"
        break
      fi
    fi

    now_ms="$(date +%s%3N 2>/dev/null || python3 -c 'import time; print(int(time.time() * 1000))')"
    if (( now_ms - wait_start >= 10000 )); then
      echo "Timed out waiting for batch id pointer: $current_batch_file" >&2
      exit 1
    fi
    sleep 0.2
  done
else
  batch_id="$batch_arg"
fi

status_file="${HOME}/.claude/tmp/${batch_id}.json"
has_jq=0
is_tty=0

command -v jq >/dev/null 2>&1 && has_jq=1
[[ -t 1 ]] && is_tty=1

epoch_ms() {
  date +%s%3N 2>/dev/null || python3 -c 'import time; print(int(time.time() * 1000))'
}

fmt_ms() {
  local ms="${1:-0}"
  [[ "$ms" =~ ^-?[0-9]+$ ]] || ms=0
  (( ms < 0 )) && ms=0
  local total_s=$((ms / 1000))
  local h=$((total_s / 3600))
  local m=$(((total_s % 3600) / 60))
  local s=$((total_s % 60))
  if (( h > 0 )); then
    printf '%02d:%02d:%02d' "$h" "$m" "$s"
  else
    printf '%02d:%02d' "$m" "$s"
  fi
}

truncate_text() {
  local text="$1"
  local max_len="$2"
  (( max_len <= 0 )) && { printf ''; return; }
  if (( ${#text} <= max_len )); then
    printf '%s' "$text"
    return
  fi
  if (( max_len <= 3 )); then
    printf '%s' "${text:0:max_len}"
    return
  fi
  printf '%s...' "${text:0:max_len-3}"
}

status_color() {
  local status="$1"
  local text="$2"
  if (( is_tty == 0 )); then
    printf '%s' "$text"
    return
  fi
  case "$status" in
    queued) printf '\033[2m%s\033[0m' "$text" ;;
    running) printf '\033[33m%s\033[0m' "$text" ;;
    done) printf '\033[32m%s\033[0m' "$text" ;;
    failed) printf '\033[31m%s\033[0m' "$text" ;;
    *) printf '%s' "$text" ;;
  esac
}

wait_start="$(epoch_ms)"
while [[ ! -f "$status_file" ]]; do
  now_ms="$(epoch_ms)"
  if (( now_ms - wait_start >= 5000 )); then
    echo "Status file not found: $status_file" >&2
    exit 1
  fi
  sleep 0.1
done

initial_now="$(epoch_ms)"
batch_started_ms="$initial_now"

trap 'exit 0' INT

parse_with_jq() {
  local file="$1"
  local now_ms="$2"
  jq -r --argjson now "$now_ms" '
    . as $root
    | ($root.tasks // []) as $tasks
    | "META\t\(($root.batchId // "")|tostring)\t\(($tasks | length))\t\(([ $tasks[]? | select((.status // "") == "done" or (.status // "") == "failed") ] | length))\t\(([ $tasks[]?.startedAt | numbers ] | min? // $now))",
      ($tasks[]? | "TASK\t\((.index // 0)|tostring)\t\((.status // "queued")|tostring)\t\((.project // "")|tostring)\t\((.promptSlug // "")|tostring)\t\(if (.endedAt|type) == "number" and (.startedAt|type) == "number" then (.endedAt - .startedAt) elif (.startedAt|type) == "number" then ($now - .startedAt) else 0 end)")
  ' "$file" 2>/dev/null || return 1
}

parse_with_python() {
  local file="$1"
  local now_ms="$2"
  python3 - "$file" "$now_ms" <<'PY'
import json
import sys

path = sys.argv[1]
now = int(sys.argv[2])
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(1)

tasks = data.get("tasks") or []
done = 0
starts = []
for t in tasks:
    status = str(t.get("status") or "queued")
    if status in ("done", "failed"):
        done += 1
    started = t.get("startedAt")
    if isinstance(started, (int, float)):
        starts.append(int(started))

batch_start = min(starts) if starts else now
print(f"META\t{str(data.get('batchId') or '')}\t{len(tasks)}\t{done}\t{batch_start}")
for t in tasks:
    index = str(t.get("index", 0))
    status = str(t.get("status") or "queued")
    project = str(t.get("project") or "")
    prompt = str(t.get("promptSlug") or "")
    started = t.get("startedAt")
    ended = t.get("endedAt")
    if isinstance(started, (int, float)) and isinstance(ended, (int, float)):
        elapsed = int(ended - started)
    elif isinstance(started, (int, float)):
        elapsed = int(now - started)
    else:
        elapsed = 0
    print(f"TASK\t{index}\t{status}\t{project}\t{prompt}\t{elapsed}")
PY
}

while true; do
  now_ms="$(epoch_ms)"
  if (( has_jq == 1 )); then
    parsed="$(parse_with_jq "$status_file" "$now_ms" || true)"
  else
    parsed="$(parse_with_python "$status_file" "$now_ms" || true)"
  fi

  [[ -n "$parsed" ]] || { sleep 0.5; continue; }

  total=0
  complete=0
  batch_started_candidate="$batch_started_ms"
  rows=()

  while IFS=$'\t' read -r kind c1 c2 c3 c4 c5; do
    if [[ "$kind" == "META" ]]; then
      total="${c2:-0}"
      complete="${c3:-0}"
      batch_started_candidate="${c4:-$batch_started_ms}"
    elif [[ "$kind" == "TASK" ]]; then
      rows+=("${c1}"$'\t'"${c2}"$'\t'"${c3}"$'\t'"${c4}"$'\t'"${c5}")
    fi
  done <<< "$parsed"

  if [[ "$batch_started_candidate" =~ ^[0-9]+$ ]]; then
    batch_started_ms="$batch_started_candidate"
  fi

  cols="${COLUMNS:-120}"
  (( cols < 60 )) && cols=60

  (( is_tty == 1 )) && printf '\033[H\033[2J'

  header="Codex batch ${batch_id:0:8} - ${complete}/${total} tasks complete"
  printf '%s\n' "$header"
  printf '%s\n' "Idx  Status   Project              Prompt                                Elapsed"
  printf '%s\n' "-------------------------------------------------------------------------------"

  for row in "${rows[@]}"; do
    IFS=$'\t' read -r idx status project prompt elapsed_ms <<< "$row"
    prompt="${prompt//$'\t'/ }"
    project="$(truncate_text "$project" 20)"
    elapsed_fmt="$(fmt_ms "${elapsed_ms:-0}")"

    # Fixed columns consume ~42 chars; remainder goes to prompt.
    prompt_width=$((cols - 42))
    (( prompt_width < 8 )) && prompt_width=8
    prompt_short="$(truncate_text "$prompt" "$prompt_width")"

    status_plain="$(truncate_text "$status" 7)"
    status_fmt="$(status_color "$status" "$(printf '%-7s' "$status_plain")")"

    printf '%-4s %b %-20s %-*s %8s\n' \
      "$idx" \
      "$status_fmt" \
      "$project" \
      "$prompt_width" \
      "$prompt_short" \
      "$elapsed_fmt"
  done

  total_elapsed="$(fmt_ms $((now_ms - batch_started_ms)))"
  printf '\n%s\n' "Total elapsed: ${total_elapsed}"

  if [[ "$total" =~ ^[0-9]+$ ]] && [[ "$complete" =~ ^[0-9]+$ ]] && (( total > 0 )) && (( complete >= total )); then
    exit 0
  fi

  sleep 0.5
done
