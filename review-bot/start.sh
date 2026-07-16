#!/usr/bin/env bash
set -euo pipefail
umask 077

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
require flock

"$SCRIPT_DIR/validate-config.sh" "$CONFIG" >/dev/null

RUNTIME_ROOT="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_RUNTIME_ROOT:-}" "$CONFIG" '.runtimeRoot' 'review-bot/.runtime')"
LOG_ROOT="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_LOG_ROOT:-}" "$CONFIG" '.logRoot' 'review-bot/logs')"
PID_FILE="${REVIEW_BOT_PID_FILE:-$RUNTIME_ROOT/watch.pid}"
WATCH_LOG="${REVIEW_BOT_WATCH_LOG:-$LOG_ROOT/watch.log}"
START_LOCK_FILE="${REVIEW_BOT_START_LOCK_FILE:-$RUNTIME_ROOT/start.lock}"
WATCH_LOG_MAX_BYTES="${REVIEW_BOT_WATCH_LOG_MAX_BYTES:-$(jq -r '.watchLogMaxBytes // 5242880' "$CONFIG")}"
WATCH_LOG_RETAIN="${REVIEW_BOT_WATCH_LOG_RETAIN:-$(jq -r '.watchLogRetain // 3' "$CONFIG")}"
POLL_SECONDS="${REVIEW_BOT_POLL_SECONDS:-$(jq -r '.pollSeconds // 300' "$CONFIG")}"
DISCOVERY_TIMEOUT_SECONDS="${REVIEW_BOT_DISCOVERY_TIMEOUT_SECONDS:-$(jq -r '.discoveryTimeoutSeconds // 30' "$CONFIG")}"
DISCOVERY_MAX_ATTEMPTS="${REVIEW_BOT_DISCOVERY_MAX_ATTEMPTS:-$(jq -r '.discoveryMaxAttempts // 4' "$CONFIG")}"
DISCOVERY_BACKOFF_BASE_SECONDS="${REVIEW_BOT_DISCOVERY_BACKOFF_BASE_SECONDS:-$(jq -r '.discoveryBackoffBaseSeconds // 2' "$CONFIG")}"
DISCOVERY_BACKOFF_MAX_SECONDS="${REVIEW_BOT_DISCOVERY_BACKOFF_MAX_SECONDS:-$(jq -r '.discoveryBackoffMaxSeconds // 30' "$CONFIG")}"
HEALTH_STALE_SECONDS="${REVIEW_BOT_HEALTH_STALE_SECONDS:-$(jq -r '.healthStaleSeconds // 900' "$CONFIG")}"

review_bot_require_positive_integer pollSeconds "$POLL_SECONDS"
review_bot_require_positive_integer discoveryTimeoutSeconds "$DISCOVERY_TIMEOUT_SECONDS"
review_bot_require_positive_integer discoveryMaxAttempts "$DISCOVERY_MAX_ATTEMPTS"
review_bot_require_positive_integer discoveryBackoffBaseSeconds "$DISCOVERY_BACKOFF_BASE_SECONDS"
review_bot_require_positive_integer discoveryBackoffMaxSeconds "$DISCOVERY_BACKOFF_MAX_SECONDS"
review_bot_require_positive_integer healthStaleSeconds "$HEALTH_STALE_SECONDS"
review_bot_require_positive_integer watchLogMaxBytes "$WATCH_LOG_MAX_BYTES"
review_bot_require_nonnegative_integer watchLogRetain "$WATCH_LOG_RETAIN"
if [[ "$DISCOVERY_BACKOFF_MAX_SECONDS" -lt "$DISCOVERY_BACKOFF_BASE_SECONDS" ]]; then
  echo "review-bot: discoveryBackoffMaxSeconds must be at least discoveryBackoffBaseSeconds" >&2
  exit 2
fi

mkdir -p "$RUNTIME_ROOT" "$LOG_ROOT" "$(dirname "$PID_FILE")" "$(dirname "$WATCH_LOG")" "$(dirname "$START_LOCK_FILE")"
exec 9>"$START_LOCK_FILE"
flock 9

touch "$WATCH_LOG"
chmod 600 "$WATCH_LOG"

if [[ -f "$PID_FILE" ]]; then
  old_pid="$(<"$PID_FILE")"
  if review_bot_pid_is_watch "$old_pid" "$WATCH_SCRIPT_PATH"; then
    echo "review-bot: watcher already running with pid $old_pid"
    exit 0
  fi
  rm -f "$PID_FILE"
fi

found_pid="$(review_bot_find_watch_pid "$WATCH_SCRIPT_PATH" || true)"
if [[ -n "$found_pid" ]]; then
  printf '%s\n' "$found_pid" >"$PID_FILE"
  echo "review-bot: watcher already running with pid $found_pid"
  exit 0
fi

review_bot_rotate_log "$WATCH_LOG" "$WATCH_LOG_MAX_BYTES" "$WATCH_LOG_RETAIN"

if command -v setsid >/dev/null 2>&1; then
  nohup setsid env \
    REVIEW_BOT_CONFIG="$CONFIG" \
    REVIEW_BOT_WATCH_LOG="$WATCH_LOG" \
    REVIEW_BOT_WATCH_LOG_MAX_BYTES="$WATCH_LOG_MAX_BYTES" \
    REVIEW_BOT_WATCH_LOG_RETAIN="$WATCH_LOG_RETAIN" \
    "$WATCH_SCRIPT_PATH" >>"$WATCH_LOG" 2>&1 9>&- &
else
  nohup env \
    REVIEW_BOT_CONFIG="$CONFIG" \
    REVIEW_BOT_WATCH_LOG="$WATCH_LOG" \
    REVIEW_BOT_WATCH_LOG_MAX_BYTES="$WATCH_LOG_MAX_BYTES" \
    REVIEW_BOT_WATCH_LOG_RETAIN="$WATCH_LOG_RETAIN" \
    "$WATCH_SCRIPT_PATH" >>"$WATCH_LOG" 2>&1 9>&- &
fi
pid="$!"
printf '%s\n' "$pid" >"$PID_FILE"

sleep 1
if ! review_bot_pid_is_watch "$pid" "$WATCH_SCRIPT_PATH"; then
  found_pid="$(review_bot_find_watch_pid "$WATCH_SCRIPT_PATH" || true)"
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
