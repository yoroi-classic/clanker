#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${REVIEW_BOT_CONFIG:-$SCRIPT_DIR/config.json}"
source "$SCRIPT_DIR/lib/paths.sh"
source "$SCRIPT_DIR/lib/github.sh"
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
POLL_SECONDS="${REVIEW_BOT_POLL_SECONDS:-$(jq -r '.pollSeconds // 300' "$CONFIG")}"
DISCOVERY_TIMEOUT_SECONDS="${REVIEW_BOT_DISCOVERY_TIMEOUT_SECONDS:-$(jq -r '.discoveryTimeoutSeconds // 30' "$CONFIG")}"
DISCOVERY_RETRIES="${REVIEW_BOT_DISCOVERY_RETRIES:-$(jq -r '.discoveryRetries // 3' "$CONFIG")}"
DISCOVERY_RETRY_BASE_SECONDS="${REVIEW_BOT_DISCOVERY_RETRY_BASE_SECONDS:-$(jq -r '.discoveryRetryBaseSeconds // 2' "$CONFIG")}"
DISCOVERY_RETRY_JITTER_SECONDS="${REVIEW_BOT_DISCOVERY_RETRY_JITTER_SECONDS:-$(jq -r '.discoveryRetryJitterSeconds // 1' "$CONFIG")}"
WATCH_LOG_MAX_BYTES="${REVIEW_BOT_WATCH_LOG_MAX_BYTES:-$(jq -r '.watchLogMaxBytes // 5242880' "$CONFIG")}"
WATCH_LOG_RETAIN="${REVIEW_BOT_WATCH_LOG_RETAIN:-$(jq -r '.watchLogRetain // 3' "$CONFIG")}"

mkdir -p "$RUNTIME_ROOT" "$LOG_ROOT" "$(dirname "$PID_FILE")" "$(dirname "$WATCH_LOG")"

review_bot_validate_discovery_config \
  "$POLL_SECONDS" \
  "$DISCOVERY_TIMEOUT_SECONDS" \
  "$DISCOVERY_RETRIES" \
  "$DISCOVERY_RETRY_BASE_SECONDS" \
  "$DISCOVERY_RETRY_JITTER_SECONDS"
review_bot_positive_integer "$WATCH_LOG_MAX_BYTES" || {
  echo "review-bot: watchLogMaxBytes must be a positive integer, got: $WATCH_LOG_MAX_BYTES" >&2
  exit 2
}
[[ "$WATCH_LOG_RETAIN" =~ ^[0-9]+$ ]] || {
  echo "review-bot: watchLogRetain must be a non-negative integer, got: $WATCH_LOG_RETAIN" >&2
  exit 2
}

if [[ -f "$WATCH_LOG" ]] && (( $(wc -c <"$WATCH_LOG") >= WATCH_LOG_MAX_BYTES )); then
  if (( WATCH_LOG_RETAIN > 0 )); then
    for ((index = WATCH_LOG_RETAIN; index >= 2; index--)); do
      [[ -f "$WATCH_LOG.$((index - 1))" ]] && mv "$WATCH_LOG.$((index - 1))" "$WATCH_LOG.$index"
    done
    mv "$WATCH_LOG" "$WATCH_LOG.1"
  else
    : >"$WATCH_LOG"
  fi
fi

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

if command -v setsid >/dev/null 2>&1; then
  nohup setsid env REVIEW_BOT_CONFIG="$CONFIG" "$WATCH_SCRIPT_PATH" >>"$WATCH_LOG" 2>&1 &
else
  nohup env REVIEW_BOT_CONFIG="$CONFIG" "$WATCH_SCRIPT_PATH" >>"$WATCH_LOG" 2>&1 &
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
