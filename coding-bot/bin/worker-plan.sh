#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: coding-bot/bin/worker-plan.sh [--no-queue] <target-workers> [current-workers]

Renders a worker-pool scaling plan plus the live assigned issue / authored PR
queue. The script does not spawn agents itself; it gives the orchestrating agent
the exact scale-up or scale-down action to take.

Environment:
  CODING_BOT_ORG   GitHub organization to inspect (default: yoroi-classic)
  CODING_BOT_RUNTIME_ROOT
                    Directory for coding-bot scratch files
                    (default: coding-bot/.runtime)
USAGE
}

INCLUDE_QUEUE=1

if [[ "${1:-}" == "--no-queue" ]]; then
  INCLUDE_QUEUE=0
  shift
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

TARGET="${1:-}"
CURRENT="${2:-unknown}"
ORG="${CODING_BOT_ORG:-yoroi-classic}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNTIME_ROOT="${CODING_BOT_RUNTIME_ROOT:-$ROOT/coding-bot/.runtime}"

if [[ -z "$TARGET" || ! "$TARGET" =~ ^[0-9]+$ ]]; then
  usage
  exit 2
fi

if [[ "$CURRENT" != "unknown" && ! "$CURRENT" =~ ^[0-9]+$ ]]; then
  usage
  exit 2
fi

mkdir -p "$RUNTIME_ROOT"

print_live_queue() {
  if ! command -v gh >/dev/null 2>&1; then
    printf 'GitHub CLI unavailable; refresh the queue manually.\n'
    return 0
  fi

  if ! gh auth status >/dev/null 2>&1; then
    printf 'GitHub CLI unauthenticated; refresh the queue manually.\n'
    return 0
  fi

  local assigned_query="org:$ORG is:issue is:open assignee:@me"
  local prs_query="org:$ORG is:pr is:open author:@me"
  local rows

  printf '\n## Authored Pull Requests\n\n'
  if ! rows="$(gh api -X GET search/issues -f q="$prs_query" -f per_page=100 --jq '
    .items[]
    | [
        (.repository_url | sub("^https://api.github.com/repos/"; "")),
        (.number | tostring),
        .title,
        .html_url
      ]
    | @tsv
  ')"; then
    printf 'Failed to fetch authored PRs.\n'
  elif [[ -z "$rows" ]]; then
    printf 'No matching pull requests found.\n'
  else
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
  fi

  printf '\n## Assigned Issues\n\n'
  gh api -X GET search/issues -f q="$assigned_query" -f per_page=100 --jq '
    .items[]
    | "- \(.repository_url | sub("^https://api.github.com/repos/"; ""))#\(.number): \(.title) \(.html_url)"
  ' || printf 'Failed to fetch assigned issues.\n'
}

cat <<PLAN
# Coding Bot Worker Plan

- Organization: \`$ORG\`
- Target workers: \`$TARGET\`
- Current workers: \`$CURRENT\`
- Runtime workspace: \`${RUNTIME_ROOT#"$ROOT/"}\`

PLAN

if [[ "$CURRENT" == "unknown" ]]; then
  cat <<'PLAN'
## Scale Action

Current worker count was not supplied. Count active worker agents, then rerun:

```sh
./coding-bot/bin/worker-plan.sh TARGET CURRENT
```

PLAN
elif (( CURRENT < TARGET )); then
  DELTA="$((TARGET - CURRENT))"
  cat <<PLAN
## Scale Action

Start \`$DELTA\` additional worker(s). Assign each new worker one unblocked item
from the queue below, preferring existing authored PRs with failing checks or
review comments, then assigned issues without an open PR.

PLAN
elif (( CURRENT > TARGET )); then
  DELTA="$((CURRENT - TARGET))"
  cat <<PLAN
## Scale Action

Stop or do not replace \`$DELTA\` worker(s). Prefer closing workers whose item is
already blocked on human review, product decision, or external CI. Do not
interrupt a worker in the middle of a push, commit, or test unless explicitly
asked.

PLAN
else
  cat <<'PLAN'
## Scale Action

Worker count is already at target. Replace completed workers only when assigned
queue items remain actionable.

PLAN
fi

cat <<'PLAN'
## Worker Assignment Rules

- One worker owns one issue or PR.
- Use an existing PR branch for review fixes.
- Do not assign two workers to the same repository files.
- New workers start from assigned issues; new backlog work waits until assigned
  work is closed or blocked.
- Completed workers should report the issue/PR, commit SHA, checks, and whether
  the item is cleared or blocked.
- Worker scratch files, review bodies, generated prompts, and temporary queues
  belong under the worker's bot-owned runtime workspace, not arbitrary `/tmp`
  paths.
PLAN

if [[ "$INCLUDE_QUEUE" == "1" ]]; then
  print_live_queue
fi
