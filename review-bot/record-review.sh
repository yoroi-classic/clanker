#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 6 ]]; then
  echo "usage: $0 <repo> <pr-number> <clean|findings> <review-url> <reviewed-head-sha> <reviewed-base-sha> [report-path]" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${REVIEW_BOT_CONFIG:-$SCRIPT_DIR/config.json}"
source "$SCRIPT_DIR/lib/paths.sh"
REPO_ROOT="$(review_bot_repo_root "$SCRIPT_DIR")"
REPO="$1"
PR_NUMBER="$2"
STATUS="$3"
REVIEW_URL="$4"
REVIEWED_HEAD_SHA="$5"
REVIEWED_BASE_SHA="$6"
REPORT="${7:-}"

case "$STATUS" in
  clean|findings)
    ;;
  *)
    echo "review-bot: status must be clean or findings, got: $STATUS" >&2
    exit 2
    ;;
esac

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "review-bot: missing required command: $1" >&2
    exit 2
  fi
}

require gh
require flock
require jq

OWNER="$(review_bot_owner "$CONFIG")"
RUNTIME_ROOT="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_RUNTIME_ROOT:-}" "$CONFIG" '.runtimeRoot' 'review-bot/.runtime')"
STATE_FILE="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_STATE_FILE:-}" "$CONFIG" '.stateFile' 'review-bot/state/reviews.json')"
STATE_LOCK_FILE="${REVIEW_BOT_STATE_LOCK:-$RUNTIME_ROOT/state.lock}"
PULL="$(gh api "/repos/$OWNER/$REPO/pulls/$PR_NUMBER")"
CURRENT_HEAD_SHA="$(jq -r '.head.sha' <<<"$PULL")"
CURRENT_BASE_SHA="$(jq -r '.base.sha' <<<"$PULL")"
KEY="$OWNER/$REPO#$PR_NUMBER"

if [[ "$CURRENT_HEAD_SHA" != "$REVIEWED_HEAD_SHA" ]]; then
  echo "review-bot: refusing to record $KEY; PR head moved from reviewed $REVIEWED_HEAD_SHA to $CURRENT_HEAD_SHA" >&2
  exit 1
fi

if [[ "$CURRENT_BASE_SHA" != "$REVIEWED_BASE_SHA" ]]; then
  echo "review-bot: refusing to record $KEY; PR base moved from reviewed $REVIEWED_BASE_SHA to $CURRENT_BASE_SHA" >&2
  exit 1
fi

mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$STATE_LOCK_FILE")"
exec 8>"$STATE_LOCK_FILE"
flock 8

if [[ ! -f "$STATE_FILE" ]]; then
  printf '{}\n' >"$STATE_FILE"
fi

tmp_state="$(mktemp "$(dirname "$STATE_FILE")/.reviews.XXXXXX")"
jq \
  --arg key "$KEY" \
  --arg head_sha "$REVIEWED_HEAD_SHA" \
  --arg base_sha "$REVIEWED_BASE_SHA" \
  --arg status "$STATUS" \
  --arg report "$REPORT" \
  --arg comment_url "$REVIEW_URL" \
  --arg reviewed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '.[$key] = {
    head_sha: $head_sha,
    base_sha: $base_sha,
    review_kind: "semantic",
    reviewed_by: "review-agent",
    status: $status,
    report: $report,
    comment_url: $comment_url,
    reviewed_at: $reviewed_at
  } | if $report == "" then .[$key] |= del(.report) else . end' "$STATE_FILE" >"$tmp_state"
mv "$tmp_state" "$STATE_FILE"

echo "review-bot: recorded semantic review for $KEY at $REVIEWED_HEAD_SHA with status $STATUS"
