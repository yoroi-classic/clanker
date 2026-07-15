#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${REVIEW_BOT_CONFIG:-$SCRIPT_DIR/config.json}"
source "$SCRIPT_DIR/lib/paths.sh"
REPO_ROOT="$(review_bot_repo_root "$SCRIPT_DIR")"
WATCH_SCRIPT="${REVIEW_BOT_WATCH_SCRIPT:-$SCRIPT_DIR/watch.sh}"
WATCH_SCRIPT_PATH="$(cd "$(dirname "$WATCH_SCRIPT")" && pwd)/$(basename "$WATCH_SCRIPT")"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "review-bot: missing required command: $1" >&2
    exit 2
  fi
}

require jq
require nohup

RUNTIME_ROOT="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_RUNTIME_ROOT:-}" "$CONFIG" '.runtimeRoot' 'review-bot/.runtime')"
LOG_ROOT="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_LOG_ROOT:-}" "$CONFIG" '.logRoot' 'review-bot/logs')"
PID_FILE="${REVIEW_BOT_PID_FILE:-$RUNTIME_ROOT/watch.pid}"
WATCH_LOG="${REVIEW_BOT_WATCH_LOG:-$LOG_ROOT/watch.log}"

mkdir -p "$RUNTIME_ROOT" "$LOG_ROOT" "$(dirname "$PID_FILE")" "$(dirname "$WATCH_LOG")"

pid_running() {
  local pid="$1"

  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1
}

find_watch_pid() {
  command -v ps >/dev/null 2>&1 || return 1
  ps -eo pid=,args= 2>/dev/null | awk -v script="$WATCH_SCRIPT_PATH" '
    {
      pid = $1
      sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", $0)
      if ($0 == "bash " script || $0 == script) {
        print pid
        exit
      }
    }
  '
}

if [[ -f "$PID_FILE" ]]; then
  old_pid="$(<"$PID_FILE")"
  if pid_running "$old_pid"; then
    echo "review-bot: watcher already running with pid $old_pid"
    exit 0
  fi
  rm -f "$PID_FILE"
fi

found_pid="$(find_watch_pid || true)"
if [[ -n "$found_pid" ]]; then
  printf '%s\n' "$found_pid" >"$PID_FILE"
  echo "review-bot: watcher already running with pid $found_pid"
  exit 0
fi

if command -v setsid >/dev/null 2>&1; then
  nohup setsid env REVIEW_BOT_CONFIG="$CONFIG" "$WATCH_SCRIPT_PATH" >>"$WATCH_LOG" 2>&1 &
else
  nohup env REVIEW_BOT_CONFIG="$CONFIG" "$WATCH_SCRIPT_PATH" >>"$WATCH_LOG" 2>&1 &
fi
pid="$!"
printf '%s\n' "$pid" >"$PID_FILE"

sleep 1
if ! pid_running "$pid"; then
  found_pid="$(find_watch_pid || true)"
  if [[ -z "$found_pid" ]]; then
    echo "review-bot: watcher failed to start; recent log:" >&2
    tail -40 "$WATCH_LOG" >&2 || true
    exit 1
  fi
  pid="$found_pid"
  printf '%s\n' "$pid" >"$PID_FILE"
fi

echo "review-bot: watcher started with pid $pid"
echo "review-bot: log $WATCH_LOG"
