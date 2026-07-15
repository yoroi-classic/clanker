#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${REVIEW_BOT_CONFIG:-$SCRIPT_DIR/config.json}"
POLL_SECONDS="${REVIEW_BOT_POLL_SECONDS:-$(jq -r '.pollSeconds // 300' "$CONFIG")}"
child_pid=""

stop_child() {
  if [[ -n "$child_pid" ]] && kill -0 "$child_pid" >/dev/null 2>&1; then
    kill "$child_pid" >/dev/null 2>&1 || true
    wait "$child_pid" >/dev/null 2>&1 || true
  fi
}

shutdown() {
  printf '%s review-bot: watcher stopping\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  stop_child
  exit 0
}

trap shutdown INT TERM

while true; do
  printf '%s review-bot: poll starting\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  "$SCRIPT_DIR/run-once.sh" &
  child_pid="$!"
  set +e
  wait "$child_pid"
  rc="$?"
  set -e
  if [[ "$rc" -ne 0 ]]; then
    printf '%s review-bot: poll finished with failures\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
  else
    printf '%s review-bot: poll finished\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
  child_pid=""

  sleep "$POLL_SECONDS" &
  child_pid="$!"
  set +e
  wait "$child_pid"
  rc="$?"
  set -e
  if [[ "$rc" -ne 0 ]]; then
    child_pid=""
    continue
  fi
  child_pid=""
done
