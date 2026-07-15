#!/usr/bin/env bash
set -euo pipefail

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
LOCK_FILE="${REVIEW_BOT_LOCK:-$RUNTIME_ROOT/run.lock}"
mkdir -p "$(dirname "$LOCK_FILE")"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "review-bot: another queue refresh is active; exiting"
  exit 0
fi

exec "$SCRIPT_DIR/watch.sh" once
