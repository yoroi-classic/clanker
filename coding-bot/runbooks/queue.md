# Queue Runbook

At session start, refresh live state. Do not rely on stale issue numbers from a
previous chat session.

## Assigned Issues

```sh
gh api graphql \
  -f q='org:yoroi-classic is:issue is:open assignee:@me' \
  -f query='query($q: String!) {
    search(query: $q, type: ISSUE, first: 100) {
      nodes {
        ... on Issue {
          number
          title
          url
          updatedAt
          repository { nameWithOwner }
          labels(first: 20) { nodes { name } }
        }
      }
    }
  }'
```

## Authored Pull Requests

```sh
gh api graphql \
  -f q='org:yoroi-classic is:pr is:open author:@me' \
  -f query='query($q: String!) {
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
  }'
```

## Work Order

1. Inspect open PRs authored by you.
2. Fix failing checks and unresolved review comments.
3. If a PR is approved by `crypto2099` and checks are green, squash merge it
   when allowed.
4. If a PR is green but lacks required human approval, mark it blocked on
   review and move to the next assigned issue.
5. Only after assigned issues and authored PRs are closed or blocked, pick new
   work from the org backlog.
