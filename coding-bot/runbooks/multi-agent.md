# Multi-Agent Runbook

Use workers only when explicitly asked to fan out.

Use the worker-plan helper when scaling:

```sh
./coding-bot/bin/worker-plan.sh TARGET_WORKERS CURRENT_WORKERS
```

## Worker Assignment

- Keep workers on disjoint repositories, PRs, or file sets.
- Assign each worker one bounded issue or PR.
- Tell each worker the exact repository, branch policy, issue/PR links, and
  write scope.
- Workers must use existing PR branches for review fixes.
- Workers must not revert other people's changes.
- Workers must keep generated scratch files inside their bot-owned runtime
  workspace so they can delete those files safely.

## Keeping A Fixed Worker Count

If the user asks for a fixed worker count:

1. Close completed workers.
2. Classify their item as closed, fixed, or blocked.
3. Spawn replacement workers only from assigned issues that are not already
   blocked.
4. Do not start new backlog work while assigned issues remain actionable.

## Scaling Down

When reducing worker count:

1. Close completed or blocked workers first.
2. Do not interrupt a worker during a commit, push, or test run unless the user
   explicitly asks for an immediate stop.
3. Preserve each worker's final status: cleared, blocked, or needs integration.

## Scaling Up

When increasing worker count:

1. Start from authored PRs with actionable checks or review comments.
2. Then use assigned issues without an open PR.
3. Keep write scopes disjoint.
4. Give every worker the shared standards plus the exact issue/PR target.
5. Tell each worker where its runtime workspace is for generated files.

## Worker Final Report

Require every worker to report:

- issue and PR links;
- branch and commit SHA, if changed;
- files changed;
- checks run;
- whether the item is cleared or blocked;
- what external review or decision is needed next.
