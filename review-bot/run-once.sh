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

require gh
require jq

OWNER="$(review_bot_owner "$CONFIG")"
REVIEWER="$(review_bot_reviewer "$CONFIG")"
RUNTIME_ROOT="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_RUNTIME_ROOT:-}" "$CONFIG" '.runtimeRoot' 'review-bot/.runtime')"
LOCK_FILE="${REVIEW_BOT_LOCK:-$RUNTIME_ROOT/run.lock}"
mkdir -p "$(dirname "$LOCK_FILE")"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "review-bot: another run is active; exiting"
  exit 0
fi

INCLUDE_DRAFTS="$(jq -r '.includeDrafts // false' "$CONFIG")"
SKIP_SELF_AUTHORED="$(jq -r '.skipSelfAuthored // true' "$CONFIG")"

review_requested_query="is:pr is:open org:$OWNER review-requested:$REVIEWER archived:false"

is_review_requested_for_bot() {
  local repo="$1"
  local number="$2"
  local pull

  if ! pull="$(gh api "/repos/$OWNER/$repo/pulls/$number")"; then
    return 2
  fi

  jq -e --arg reviewer "$REVIEWER" \
    'any(.requested_reviewers[]?; .login == $reviewer)' <<<"$pull" >/dev/null
}

mapfile -t prs < <(
  gh api -X GET /search/issues -f "q=$review_requested_query" -f per_page=100 --paginate --jq \
    '.items[] | [(.repository_url | split("/")[-1]), (.number | tostring), .html_url, .user.login] | @tsv'
)

if [[ "${#prs[@]}" -eq 0 ]]; then
  echo "review-bot: no review-requested open PRs found for $REVIEWER in $OWNER"
  exit 0
fi

run_status=0
for row in "${prs[@]}"; do
  IFS=$'\t' read -r repo number url author <<<"$row"
  if [[ "$SKIP_SELF_AUTHORED" == "true" && "$author" == "$REVIEWER" && "${REVIEW_BOT_INCLUDE_SELF_AUTHORED:-0}" != "1" ]]; then
    echo "review-bot: skipping self-authored PR $OWNER/$repo#$number"
    continue
  fi
  if is_review_requested_for_bot "$repo" "$number"; then
    :
  else
    requested_rc="$?"
    if [[ "$requested_rc" -eq 1 ]]; then
      echo "review-bot: skipping $OWNER/$repo#$number because $REVIEWER is not a requested reviewer"
      continue
    fi

    run_status=1
    echo "review-bot: failed to verify requested reviewer for $OWNER/$repo#$number" >&2
    continue
  fi
  if [[ "$INCLUDE_DRAFTS" != "true" ]]; then
    is_draft="$(gh pr view "$number" -R "$OWNER/$repo" --json isDraft --jq '.isDraft')"
    if [[ "$is_draft" == "true" ]]; then
      echo "review-bot: skipping draft PR $OWNER/$repo#$number"
      continue
    fi
  fi
  echo "review-bot: reviewing $OWNER/$repo#$number ($url)"
  if "$SCRIPT_DIR/review-one.sh" "$repo" "$number"; then
    continue
  fi

  rc="$?"
  run_status=1
  echo "review-bot: $OWNER/$repo#$number failed with exit code $rc" >&2
done

exit "$run_status"
