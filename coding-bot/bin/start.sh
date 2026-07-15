#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ORG="${CODING_BOT_ORG:-yoroi-classic}"
TARGET_WORKERS="${CODING_BOT_WORKERS:-}"
CURRENT_WORKERS="${CODING_BOT_CURRENT_WORKERS:-unknown}"
RUNTIME_ROOT="${CODING_BOT_RUNTIME_ROOT:-$ROOT/coding-bot/.runtime}"
UPDATE_REF="${CODING_BOT_UPDATE_REF:-origin/main}"

mkdir -p "$RUNTIME_ROOT"

print_file() {
  local path="$1"
  if [[ -f "$path" ]]; then
    printf '\n## %s\n\n' "${path#"$ROOT/"}"
    cat "$path"
    printf '\n'
  fi
}

print_issue_search() {
  local title="$1"
  local query_text="$2"
  local rows

  printf '\n## %s\n\n' "$title"
  if ! command -v gh >/dev/null 2>&1; then
    printf 'GitHub CLI is unavailable; run this query manually later.\n'
    return 0
  fi

  if ! gh auth status >/dev/null 2>&1; then
    printf 'GitHub CLI is not authenticated; run this query manually later.\n'
    return 0
  fi

  if ! rows="$(gh api -X GET search/issues -f q="$query_text" -f per_page=100 --jq '
    .items[]
    | "- \(.repository_url | sub("^https://api.github.com/repos/"; ""))#\(.number): \(.title) \(.html_url)"
  ')"; then
    printf 'Failed to fetch live GitHub queue.\n'
    return 0
  fi

  if [[ -z "$rows" ]]; then
    printf 'No matching issues found.\n'
    return 0
  fi

  printf '%s\n' "$rows"
}

print_pr_search() {
  local title="$1"
  local query_text="$2"
  local rows

  printf '\n## %s\n\n' "$title"
  if ! command -v gh >/dev/null 2>&1; then
    printf 'GitHub CLI is unavailable; run this query manually later.\n'
    return 0
  fi

  if ! gh auth status >/dev/null 2>&1; then
    printf 'GitHub CLI is not authenticated; run this query manually later.\n'
    return 0
  fi

  if ! rows="$(gh api -X GET search/issues -f q="$query_text" -f per_page=100 --jq '
    .items[]
    | [
        (.repository_url | sub("^https://api.github.com/repos/"; "")),
        (.number | tostring),
        .title,
        .html_url
      ]
    | @tsv
  ')"; then
    printf 'Failed to fetch live GitHub queue.\n'
    return 0
  fi

  if [[ -z "$rows" ]]; then
    printf 'No matching pull requests found.\n'
    return 0
  fi

  while IFS=$'\t' read -r repo number pr_title url; do
    local pr_details head_sha draft reviewers checks reviews head_short
    if ! pr_details="$(gh api "repos/$repo/pulls/$number" --jq '
      [
        .head.sha,
        (.draft | tostring),
        ([.requested_reviewers[].login] | if length == 0 then "none" else join(",") end)
      ]
      | @tsv
    ' 2>/dev/null)"; then
      printf -- '- %s#%s: %s [details=unavailable] %s\n' "$repo" "$number" "$pr_title" "$url"
      continue
    fi

    IFS=$'\t' read -r head_sha draft reviewers <<<"$pr_details"
    head_short="${head_sha:0:7}"
    checks="$(gh api "repos/$repo/commits/$head_sha/check-runs" --jq '
      (.check_runs | map(.conclusion // .status)) as $states
      | "checks="
        + (([$states[] | select(. == "failure" or . == "cancelled" or . == "timed_out" or . == "action_required")] | length) | tostring)
        + " fail/"
        + (([$states[] | select(. == "queued" or . == "in_progress" or . == "waiting" or . == "requested" or . == "pending")] | length) | tostring)
        + " pending/"
        + (($states | length) | tostring)
        + " total"
    ' 2>/dev/null || printf 'checks=unknown')"
    reviews="$(gh api "repos/$repo/pulls/$number/reviews" --jq '
      [.[] | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED") | "\(.user.login):\(.state)"]
      | unique
      | if length == 0 then "reviews=none" else "reviews=" + join(",") end
    ' 2>/dev/null || printf 'reviews=unknown')"

    printf -- '- %s#%s: %s [head=%s, draft=%s, requested=%s, %s, %s] %s\n' \
      "$repo" "$number" "$pr_title" "$head_short" "$draft" "$reviewers" "$reviews" "$checks" "$url"
  done <<<"$rows"
}

print_self_update_status() {
  printf '\n## Clanker Self-Update\n\n'

  local marker="$RUNTIME_ROOT/clanker-update-needed"
  local update_ref="$UPDATE_REF"
  local update_remote update_branch remote_ref
  if [[ "$update_ref" == */* ]]; then
    update_remote="${update_ref%%/*}"
    update_branch="${update_ref#*/}"
  else
    update_remote="origin"
    update_branch="$update_ref"
    update_ref="$update_remote/$update_branch"
  fi
  remote_ref="refs/remotes/$update_ref"

  if ! git -C "$ROOT" config --get "remote.$update_remote.url" >/dev/null; then
    rm -f "$marker"
    printf 'Remote `%s` is not configured; skipping self-update check.\n' "$update_remote"
    return 0
  fi

  if ! git -C "$ROOT" fetch --quiet "$update_remote" "refs/heads/$update_branch:$remote_ref"; then
    printf 'Could not fetch `%s`; check manually before relying on local bot instructions.\n' "$update_ref"
    return 0
  fi

  local local_sha upstream_sha merge_base
  local_sha="$(git -C "$ROOT" rev-parse HEAD)"
  upstream_sha="$(git -C "$ROOT" rev-parse "$remote_ref")"
  merge_base="$(git -C "$ROOT" merge-base HEAD "$remote_ref")"

  if [[ "$local_sha" == "$upstream_sha" ]]; then
    rm -f "$marker"
    printf 'This clanker checkout is current with `%s`.\n' "$update_ref"
  elif [[ "$local_sha" == "$merge_base" ]]; then
    {
      printf 'git pull --ff-only\n'
      printf './coding-bot/bin/start.sh\n'
    } >"$marker"
    printf 'This clanker checkout is behind `%s`.\n' "$update_ref"
    printf 'Next turn first action: run `git pull --ff-only`, then rerun `./coding-bot/bin/start.sh`.\n'
    printf 'Marker written to `%s`.\n' "${marker#"$ROOT/"}"
  elif [[ "$upstream_sha" == "$merge_base" ]]; then
    rm -f "$marker"
    printf 'This clanker checkout is ahead of `%s`; push or finish local work before updating.\n' "$update_ref"
  else
    {
      printf 'git status --short --branch\n'
      printf 'git fetch --all --prune\n'
      printf 'git log --oneline --left-right HEAD...%s\n' "$remote_ref"
    } >"$marker"
    printf 'This clanker checkout has diverged from `%s`; resolve manually before taking new work.\n' "$update_ref"
    printf 'Marker written to `%s`.\n' "${marker#"$ROOT/"}"
  fi
}

cat <<'HEADER'
# Yoroi Classic Coding Bot Bootstrap

Use this as the starting context for a coding-agent session. Refresh live state
before changing code, and keep assigned work moving before taking new work.
HEADER

print_self_update_status

printf '\n## Workspace Status\n\n'
git -C "$ROOT" status --short --branch || true

printf '\n## Runtime Workspace\n\n'
printf 'Coding-bot scratch files should stay under `%s`.\n' "${RUNTIME_ROOT#"$ROOT/"}"
printf 'Generated prompts, review bodies, queues, and scratch files there may be deleted by the bot.\n'

print_file "$ROOT/coding-bot/SKILL.md"
print_file "$ROOT/standards/session.md"
print_file "$ROOT/standards/review.md"
print_file "$ROOT/coding-bot/runbooks/queue.md"
print_file "$ROOT/coding-bot/runbooks/multi-agent.md"

if [[ -n "$TARGET_WORKERS" ]]; then
  printf '\n## Worker Scaling Plan\n\n'
  "$ROOT/coding-bot/bin/worker-plan.sh" --no-queue "$TARGET_WORKERS" "$CURRENT_WORKERS"
fi

ASSIGNED_QUERY="org:$ORG is:issue is:open assignee:@me"
PRS_QUERY="org:$ORG is:pr is:open author:@me"

print_issue_search "Live Assigned Issues" "$ASSIGNED_QUERY"
print_pr_search "Live Authored Pull Requests" "$PRS_QUERY"

cat <<'FOOTER'

## First Actions

1. Classify authored PRs as merge-ready, needs-fix, or blocked on review.
2. Fix actionable review comments and failing checks before new work.
3. Pick the next assigned issue only when existing PRs are clear or blocked.
4. Keep temporary clones and caches out of the repository and clean them up.
FOOTER
