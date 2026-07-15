#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ORG="${CODING_BOT_ORG:-yoroi-classic}"
TARGET_WORKERS="${CODING_BOT_WORKERS:-}"
CURRENT_WORKERS="${CODING_BOT_CURRENT_WORKERS:-unknown}"

print_file() {
  local path="$1"
  if [[ -f "$path" ]]; then
    printf '\n## %s\n\n' "${path#"$ROOT/"}"
    cat "$path"
    printf '\n'
  fi
}

print_graphql() {
  local title="$1"
  local query_text="$2"
  local graphql="$3"

  printf '\n## %s\n\n' "$title"
  if ! command -v gh >/dev/null 2>&1; then
    printf 'GitHub CLI is unavailable; run this query manually later.\n'
    return 0
  fi

  if ! gh auth status >/dev/null 2>&1; then
    printf 'GitHub CLI is not authenticated; run this query manually later.\n'
    return 0
  fi

  gh api graphql -f q="$query_text" -f query="$graphql" --jq '
    .data.search.nodes[]
    | if has("reviewDecision") then
        "- \(.repository.nameWithOwner)#\(.number): \(.title) [review=\(.reviewDecision // "none"), checks=\(.commits.nodes[0].commit.statusCheckRollup.state // "unknown")] \(.url)"
      else
        "- \(.repository.nameWithOwner)#\(.number): \(.title) \(.url)"
      end
  ' || printf 'Failed to fetch live GitHub queue.\n'
}

cat <<'HEADER'
# Yoroi Classic Coding Bot Bootstrap

Use this as the starting context for a coding-agent session. Refresh live state
before changing code, and keep assigned work moving before taking new work.
HEADER

printf '\n## Workspace Status\n\n'
git -C "$ROOT" status --short --branch || true

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

read -r -d '' ISSUE_GRAPHQL <<'GRAPHQL' || true
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

read -r -d '' PR_GRAPHQL <<'GRAPHQL' || true
query($q: String!) {
  search(query: $q, type: ISSUE, first: 100) {
    nodes {
      ... on PullRequest {
        number
        title
        url
        updatedAt
        reviewDecision
        headRefName
        baseRefName
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

print_graphql "Live Assigned Issues" "$ASSIGNED_QUERY" "$ISSUE_GRAPHQL"
print_graphql "Live Authored Pull Requests" "$PRS_QUERY" "$PR_GRAPHQL"

cat <<'FOOTER'

## First Actions

1. Classify authored PRs as merge-ready, needs-fix, or blocked on review.
2. Fix actionable review comments and failing checks before new work.
3. Pick the next assigned issue only when existing PRs are clear or blocked.
4. Keep temporary clones and caches out of the repository and clean them up.
FOOTER
