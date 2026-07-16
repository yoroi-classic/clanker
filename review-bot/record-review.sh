#!/usr/bin/env bash
set -euo pipefail
umask 077

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
REVIEWER="$(review_bot_reviewer "$CONFIG")"
review_bot_validate_owner "$OWNER"
review_bot_validate_repo "$REPO"
review_bot_validate_pr_number "$PR_NUMBER"
review_bot_validate_sha reviewed-head "$REVIEWED_HEAD_SHA"
review_bot_validate_sha reviewed-base "$REVIEWED_BASE_SHA"
RUNTIME_ROOT="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_RUNTIME_ROOT:-}" "$CONFIG" '.runtimeRoot' 'review-bot/.runtime')"
STATE_FILE="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_STATE_FILE:-}" "$CONFIG" '.stateFile' 'review-bot/state/reviews.json')"
STATE_LOCK_FILE="${REVIEW_BOT_STATE_LOCK:-$RUNTIME_ROOT/state.lock}"
PULL="$(gh api "/repos/$OWNER/$REPO/pulls/$PR_NUMBER")"
CURRENT_HEAD_SHA="$(jq -r '.head.sha' <<<"$PULL")"
CURRENT_BASE_SHA="$(jq -r '.base.sha' <<<"$PULL")"
KEY="$OWNER/$REPO#$PR_NUMBER"
review_bot_validate_sha current-head "$CURRENT_HEAD_SHA"
review_bot_validate_sha current-base "$CURRENT_BASE_SHA"

case "$REVIEW_URL" in
  "https://github.com/$OWNER/$REPO/pull/$PR_NUMBER#"*)
    ;;
  *)
    echo "review-bot: review URL does not belong to $KEY: $REVIEW_URL" >&2
    exit 2
    ;;
esac

if [[ "$CURRENT_HEAD_SHA" != "$REVIEWED_HEAD_SHA" ]]; then
  echo "review-bot: refusing to record $KEY; PR head moved from reviewed $REVIEWED_HEAD_SHA to $CURRENT_HEAD_SHA" >&2
  exit 1
fi

if [[ "$CURRENT_BASE_SHA" != "$REVIEWED_BASE_SHA" ]]; then
  echo "review-bot: refusing to record $KEY; PR base moved from reviewed $REVIEWED_BASE_SHA to $CURRENT_BASE_SHA" >&2
  exit 1
fi

if [[ "$STATUS" == "clean" ]]; then
  if ! gh api "/repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews" --paginate |
    jq -s -e \
      --arg reviewer "$REVIEWER" \
      --arg head "$REVIEWED_HEAD_SHA" \
      --arg url "$REVIEW_URL" \
      'add
       | any(.[];
           .user.login == $reviewer
           and .state == "APPROVED"
           and .commit_id == $head
           and .html_url == $url
           and ((.body // "") | contains("No issues found for \($head)."))
         )' >/dev/null; then
    echo "review-bot: refusing to record clean review for $KEY; matching approval was not found" >&2
    exit 1
  fi
else
  review_match="$(
    {
      gh api "/repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews" --paginate
      gh api "/repos/$OWNER/$REPO/issues/$PR_NUMBER/comments" --paginate
    } | jq -s \
      --arg reviewer "$REVIEWER" \
      --arg head "$REVIEWED_HEAD_SHA" \
      --arg url "$REVIEW_URL" \
      'add
       | [
           .[]
           | select(
               .user.login == $reviewer
               and .html_url == $url
               and (
                 .commit_id == $head
                 or (
                   (.commit_id // "") == ""
                   and ((.body // "") | contains("Reviewed head: \($head)."))
                 )
               )
             )
         ]
       | length'
  )"
  if [[ "$review_match" -eq 0 ]]; then
    echo "review-bot: refusing to record findings for $KEY; matching review/comment was not found" >&2
    exit 1
  fi
fi

mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$STATE_LOCK_FILE")"
exec 8>"$STATE_LOCK_FILE"
flock 8

if [[ ! -f "$STATE_FILE" ]]; then
  printf '{}\n' >"$STATE_FILE"
fi
chmod 600 "$STATE_FILE"

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
