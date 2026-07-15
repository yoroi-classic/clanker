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

if [[ -z "$TARGET" || ! "$TARGET" =~ ^[0-9]+$ ]]; then
  usage
  exit 2
fi

if [[ "$CURRENT" != "unknown" && ! "$CURRENT" =~ ^[0-9]+$ ]]; then
  usage
  exit 2
fi

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
  local issue_graphql
  local pr_graphql

  read -r -d '' issue_graphql <<'GRAPHQL' || true
query($q: String!) {
  search(query: $q, type: ISSUE, first: 100) {
    nodes {
      ... on Issue {
        number
        title
        url
        updatedAt
        repository { nameWithOwner }
      }
    }
  }
}
GRAPHQL

  read -r -d '' pr_graphql <<'GRAPHQL' || true
query($q: String!) {
  search(query: $q, type: ISSUE, first: 100) {
    nodes {
      ... on PullRequest {
        number
        title
        url
        updatedAt
        reviewDecision
        repository { nameWithOwner }
        commits(last: 1) {
          nodes {
            commit {
              oid
              statusCheckRollup { state }
            }
          }
        }
      }
    }
  }
}
GRAPHQL

  printf '\n## Authored Pull Requests\n\n'
  gh api graphql -f q="$prs_query" -f query="$pr_graphql" --jq '
    .data.search.nodes[]
    | "- \(.repository.nameWithOwner)#\(.number): \(.title) [review=\(.reviewDecision // "none"), checks=\(.commits.nodes[0].commit.statusCheckRollup.state // "unknown")] \(.url)"
  ' || printf 'Failed to fetch authored PRs.\n'

  printf '\n## Assigned Issues\n\n'
  gh api graphql -f q="$assigned_query" -f query="$issue_graphql" --jq '
    .data.search.nodes[]
    | "- \(.repository.nameWithOwner)#\(.number): \(.title) \(.url)"
  ' || printf 'Failed to fetch assigned issues.\n'
}

cat <<PLAN
# Coding Bot Worker Plan

- Organization: \`$ORG\`
- Target workers: \`$TARGET\`
- Current workers: \`$CURRENT\`

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
PLAN

if [[ "$INCLUDE_QUEUE" == "1" ]]; then
  print_live_queue
fi
