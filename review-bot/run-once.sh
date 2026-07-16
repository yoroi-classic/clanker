#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${REVIEW_BOT_CONFIG:-$SCRIPT_DIR/config.json}"
source "$SCRIPT_DIR/lib/paths.sh"
REPO_ROOT="$(review_bot_repo_root "$SCRIPT_DIR")"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "review-bot: missing required command: $1" >&2
    exit 2
  fi
}

require flock
require jq

RUNTIME_ROOT="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_RUNTIME_ROOT:-}" "$CONFIG" '.runtimeRoot' 'review-bot/.runtime')"
QUEUE_LOCK_FILE="${REVIEW_BOT_QUEUE_LOCK:-$RUNTIME_ROOT/queue.lock}"
mkdir -p "$(dirname "$QUEUE_LOCK_FILE")"

exec 9>"$QUEUE_LOCK_FILE"
flock 9

REVIEW_BOT_QUEUE_LOCK_HELD=1 exec "$SCRIPT_DIR/watch.sh" once
