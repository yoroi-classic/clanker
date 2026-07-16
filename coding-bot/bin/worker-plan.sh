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
source "$ROOT/coding-bot/lib/queue.sh"
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
  local assigned_query="org:$ORG is:issue is:open assignee:@me"
  local prs_query="org:$ORG is:pr is:open author:@me"

  coding_bot_queue_begin
  coding_bot_print_authored_prs "Authored Pull Requests" "$prs_query"
  coding_bot_print_assigned_issues "Assigned Issues" "$assigned_query"
  coding_bot_print_queue_metrics
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
