# Yoroi Classic Coding Bot

Use this skill when starting or resuming a coding-agent session for the
`yoroi-classic` organization.

## Purpose

The coding bot keeps a session aligned with the organization's current operating
model:

- reduce assigned work before taking new work;
- keep build and test stability ahead of feature breadth;
- preserve small, reviewable branches and pull requests;
- follow the same shared standards as `review-bot`.
- propose updates to its own behavior through `clanker` issues and suggestion
  PRs.

## Startup

Run the session launcher from the `clanker` checkout:

```sh
./coding-bot/bin/start.sh
```

If startup says the checkout is behind `origin/main`, make the next turn update
`clanker` with `git pull --ff-only` and rerun startup before taking new work.
If startup says the checkout has diverged, resolve the local branch manually
before taking new work. Set `CODING_BOT_UPDATE_REF` only when a different remote
branch is the intended runtime source.

Render a worker scaling plan whenever the target worker count changes:

```sh
./coding-bot/bin/worker-plan.sh TARGET_WORKERS CURRENT_WORKERS
```

Then follow the rendered queue. Refresh live GitHub state before acting; do not
trust old chat summaries or issue numbers without verification.

Use `./workspace-status.sh` when organization repository checkout state matters.
It reports pinned/checked commits, branches, dirty and upstream state, missing
recursive submodules, repository-local agent guidance, and discoverable default
branch mismatches without fetching remotes.

Use `coding-bot/.runtime/` for generated scratch files, review bodies, temporary
queues, and prompts. Override with `CODING_BOT_RUNTIME_ROOT` only when the
session has another bot-owned workspace. Do not leave bot scratch files in
arbitrary `/tmp` paths.

## Rules

Read and follow:

- `../standards/session.md`
- `../standards/review.md`
- `runbooks/queue.md`
- `runbooks/multi-agent.md`

If a repository has a closer `AGENTS.md` or local contribution guide, that local
instruction takes precedence for files in that repository.
