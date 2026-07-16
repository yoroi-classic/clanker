#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${REVIEW_BOT_CONFIG:-$SCRIPT_DIR/config.json}"
source "$SCRIPT_DIR/lib/paths.sh"
source "$SCRIPT_DIR/lib/github.sh"
REPO_ROOT="$(review_bot_repo_root "$SCRIPT_DIR")"
MODE="${1:-pending}"

case "$MODE" in
  pending|--pending)
    MODE="pending"
    ;;
  all|--all)
    MODE="all"
    ;;
  *)
    echo "usage: $0 [pending|all]" >&2
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
require base64
require jq
require timeout

OWNER="$(review_bot_owner "$CONFIG")"
review_bot_configure_github_get "$CONFIG"

REVIEWER="$(review_bot_resolve_reviewer_bounded "$CONFIG")" || {
  echo "review-bot: failed to resolve the authenticated GitHub reviewer" >&2
  exit 1
}
review_bot_validate_owner "$OWNER"
STATE_FILE="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_STATE_FILE:-}" "$CONFIG" '.stateFile' 'review-bot/state/reviews.json')"
INCLUDE_DRAFTS="$(jq -r '.includeDrafts // false' "$CONFIG")"
SKIP_SELF_AUTHORED="$(jq -r '.skipSelfAuthored // true' "$CONFIG")"
QUERY="is:pr is:open org:$OWNER review-requested:$REVIEWER archived:false"

if [[ ! -f "$STATE_FILE" ]]; then
  state='{}'
else
  state="$(<"$STATE_FILE")"
fi

search_output="$(review_bot_gh_get /search/issues -f "q=$QUERY" -f per_page=100 --paginate --jq \
  '.items[] | {repo:(.repository_url | split("/")[-1]), number, url:.html_url, author:.user.login, title:.title} | @base64')" || {
  echo "review-bot: failed to search review-requested PRs for $REVIEWER in $OWNER" >&2
  exit 1
}
if [[ -n "$search_output" ]]; then
  mapfile -t rows <<<"$search_output"
else
  rows=()
fi

for row in "${rows[@]}"; do
  item="$(base64 -d <<<"$row")"
  repo="$(jq -r '.repo' <<<"$item")"
  number="$(jq -r '.number' <<<"$item")"
  url="$(jq -r '.url' <<<"$item")"
  author="$(jq -r '.author' <<<"$item")"
  title="$(jq -r '.title' <<<"$item")"
  review_bot_validate_repo "$repo"
  review_bot_validate_pr_number "$number"

  if [[ "$SKIP_SELF_AUTHORED" == "true" && "$author" == "$REVIEWER" && "${REVIEW_BOT_INCLUDE_SELF_AUTHORED:-0}" != "1" ]]; then
    continue
  fi

  pull="$(review_bot_gh_get "/repos/$OWNER/$repo/pulls/$number")" || {
    echo "review-bot: failed to load $OWNER/$repo#$number" >&2
    exit 1
  }
  if ! jq -e --arg reviewer "$REVIEWER" \
    'any(.requested_reviewers[]?; .login == $reviewer)' <<<"$pull" >/dev/null; then
    continue
  fi

  if [[ "$INCLUDE_DRAFTS" != "true" && "$(jq -r '.draft' <<<"$pull")" == "true" ]]; then
    continue
  fi

  head_sha="$(jq -r '.head.sha' <<<"$pull")"
  base_sha="$(jq -r '.base.sha' <<<"$pull")"
  head_ref="$(jq -r '.head.ref' <<<"$pull")"
  base_ref="$(jq -r '.base.ref' <<<"$pull")"
  is_draft="$(jq -r '.draft' <<<"$pull")"
  requested_reviewers="$(jq -r '[.requested_reviewers[]?.login] | join(", ")' <<<"$pull")"
  key="$OWNER/$repo#$number"
  state_status="$(jq -r --arg key "$key" '.[$key].status // empty' <<<"$state")"
  state_review_kind="$(jq -r --arg key "$key" '.[$key].review_kind // empty' <<<"$state")"
  state_head="$(jq -r --arg key "$key" '.[$key].head_sha // empty' <<<"$state")"
  state_base="$(jq -r --arg key "$key" '.[$key].base_sha // empty' <<<"$state")"
  needs_review=true
  if [[ "$state_review_kind" == "semantic" && "$state_head" == "$head_sha" && "$state_base" == "$base_sha" ]]; then
    needs_review=false
  fi

  if [[ "$MODE" == "pending" && "$needs_review" != "true" ]]; then
    continue
  fi

  jq -c -n \
    --arg owner "$OWNER" \
    --arg repo "$repo" \
    --argjson number "$number" \
    --arg url "$url" \
    --arg author "$author" \
    --arg title "$title" \
    --arg head_sha "$head_sha" \
    --arg base_sha "$base_sha" \
    --arg head_ref "$head_ref" \
    --arg base_ref "$base_ref" \
    --arg is_draft "$is_draft" \
    --arg requested_reviewers "$requested_reviewers" \
    --arg reviewer "$REVIEWER" \
    --arg state_status "$state_status" \
    --arg state_review_kind "$state_review_kind" \
    --argjson needs_review "$needs_review" \
    '{
      owner:$owner,
      repo:$repo,
      number:$number,
      url:$url,
      author:$author,
      title:$title,
      head_sha:$head_sha,
      base_sha:$base_sha,
      head_ref:$head_ref,
      base_ref:$base_ref,
      is_draft:$is_draft,
      requested_reviewers:$requested_reviewers,
      reviewer:$reviewer,
      state_status:$state_status,
      state_review_kind:$state_review_kind,
      needs_review:$needs_review
    }'
done
