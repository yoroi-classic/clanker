#!/usr/bin/env bash
set -euo pipefail
umask 077

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
LOG_ROOT="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_LOG_ROOT:-}" "$CONFIG" '.logRoot' 'review-bot/logs')"
PID_FILE="${REVIEW_BOT_PID_FILE:-$RUNTIME_ROOT/watch.pid}"
WATCH_LOG="${REVIEW_BOT_WATCH_LOG:-$LOG_ROOT/watch.log}"

if [[ ! -f "$PID_FILE" ]]; then
  found_pid="$(review_bot_find_watch_pid "$WATCH_SCRIPT_PATH" || true)"
  if [[ -n "$found_pid" ]]; then
    mkdir -p "$(dirname "$PID_FILE")"
    printf '%s\n' "$found_pid" >"$PID_FILE"
    pid="$found_pid"
  else
    echo "review-bot: watcher is not running; no pid file at $PID_FILE"
    exit 1
  fi
else
  pid="$(<"$PID_FILE")"
fi

if [[ -z "$pid" ]] || ! review_bot_pid_is_watch "$pid" "$WATCH_SCRIPT_PATH"; then
  found_pid="$(review_bot_find_watch_pid "$WATCH_SCRIPT_PATH" || true)"
  if [[ -z "$found_pid" ]]; then
    rm -f "$PID_FILE"
    echo "review-bot: watcher is not running; stale pid file at $PID_FILE"
    exit 1
  fi
  pid="$found_pid"
  printf '%s\n' "$pid" >"$PID_FILE"
fi

echo "review-bot: watcher running with pid $pid"
echo "review-bot: log $WATCH_LOG"
if [[ -f "$WATCH_LOG" ]]; then
  echo "review-bot: recent log:"
  tail -20 "$WATCH_LOG"
fi
