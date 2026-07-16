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
HEALTH_FILE="${REVIEW_BOT_HEALTH_FILE:-$RUNTIME_ROOT/health.json}"
HEALTH_STALE_SECONDS="${REVIEW_BOT_HEALTH_STALE_SECONDS:-$(jq -r '.healthStaleSeconds // 900' "$CONFIG")}"
health_rc=0

review_bot_require_positive_integer healthStaleSeconds "$HEALTH_STALE_SECONDS"

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
if [[ ! -f "$HEALTH_FILE" ]]; then
  echo "review-bot: health unavailable; no completed poll recorded at $HEALTH_FILE"
  health_rc=1
elif ! review_bot_health_file_is_valid "$HEALTH_FILE"; then
  echo "review-bot: health error; invalid health file at $HEALTH_FILE"
  health_rc=1
else
  health_status="$(jq -r '.status // "unknown"' "$HEALTH_FILE")"
  last_success_at="$(jq -r '.last_success_at // "never"' "$HEALTH_FILE")"
  last_success_epoch="$(jq -r '.last_success_epoch // 0' "$HEALTH_FILE")"
  last_attempt_at="$(jq -r '.last_attempt_at // "unknown"' "$HEALTH_FILE")"
  consecutive_failures="$(jq -r '.consecutive_failures // 0' "$HEALTH_FILE")"
  queue_count="$(jq -r '.queue_count // 0' "$HEALTH_FILE")"
  last_error="$(jq -r '.last_error // empty' "$HEALTH_FILE")"
  health_label="healthy"

  if [[ "$health_status" == "error" ]]; then
    health_label="error"
    health_rc=1
  elif [[ "$last_success_epoch" -eq 0 ]] || [[ "$(( $(date +%s) - last_success_epoch ))" -gt "$HEALTH_STALE_SECONDS" ]]; then
    health_label="stale"
    health_rc=1
  fi

  echo "review-bot: health $health_label; queue=$queue_count; failures=$consecutive_failures"
  echo "review-bot: last attempt $last_attempt_at; last success $last_success_at"
  if [[ -n "$last_error" ]]; then
    echo "review-bot: last error $last_error"
  fi
fi
if [[ -f "$WATCH_LOG" ]]; then
  echo "review-bot: recent log:"
  tail -20 "$WATCH_LOG"
fi

exit "$health_rc"
