#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${REVIEW_BOT_CONFIG:-$SCRIPT_DIR/config.json}"
source "$SCRIPT_DIR/lib/paths.sh"
REPO_ROOT="$(review_bot_repo_root "$SCRIPT_DIR")"
WATCH_SCRIPT="${REVIEW_BOT_WATCH_SCRIPT:-$SCRIPT_DIR/watch.sh}"
WATCH_SCRIPT_PATH="$(cd "$(dirname "$WATCH_SCRIPT")" && pwd)/$(basename "$WATCH_SCRIPT")"

if ! command -v jq >/dev/null 2>&1; then
  echo "review-bot: missing required command: jq" >&2
  exit 2
fi

RUNTIME_ROOT="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_RUNTIME_ROOT:-}" "$CONFIG" '.runtimeRoot' 'review-bot/.runtime')"
PID_FILE="${REVIEW_BOT_PID_FILE:-$RUNTIME_ROOT/watch.pid}"

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

watch_pattern() {
  local escaped

  escaped="$(printf '%s' "$WATCH_SCRIPT_PATH" | sed 's/[][\\.^$*+?{}|()]/\\&/g')"
  printf '(^|.*/)bash %s$|^%s$' "$escaped" "$escaped"
}

if [[ ! -f "$PID_FILE" ]]; then
  found_pid="$(find_watch_pid || true)"
  if [[ -z "$found_pid" ]]; then
    echo "review-bot: watcher is not running"
    exit 0
  fi
  pid="$found_pid"
else
  pid="$(<"$PID_FILE")"
fi

pid_running() {
  local pid="$1"

  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1
}

terminate_watch() {
  kill "$pid" >/dev/null 2>&1 || true
  if command -v pkill >/dev/null 2>&1; then
    pkill -TERM -f "$(watch_pattern)" >/dev/null 2>&1 || true
  fi
}

watch_present() {
  pid_running "$pid" || [[ -n "$(find_watch_pid || true)" ]]
}

if ! pid_running "$pid"; then
  found_pid="$(find_watch_pid || true)"
  if [[ -z "$found_pid" ]]; then
    rm -f "$PID_FILE"
    echo "review-bot: removed stale pid file"
    exit 0
  fi
  pid="$found_pid"
fi

terminate_watch
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if ! watch_present; then
    rm -f "$PID_FILE"
    echo "review-bot: watcher stopped"
    exit 0
  fi
  sleep 1
done

echo "review-bot: watcher did not stop after SIGTERM; pid $pid still running" >&2
exit 1
