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

## Startup

Run the session launcher from the `clanker` checkout:

```sh
./coding-bot/bin/start.sh
```

Render a worker scaling plan whenever the target worker count changes:

```sh
./coding-bot/bin/worker-plan.sh TARGET_WORKERS CURRENT_WORKERS
```

Then follow the rendered queue. Refresh live GitHub state before acting; do not
trust old chat summaries or issue numbers without verification.

## Rules

Read and follow:

- `../standards/session.md`
- `../standards/review.md`
- `runbooks/queue.md`
- `runbooks/multi-agent.md`

If a repository has a closer `AGENTS.md` or local contribution guide, that local
instruction takes precedence for files in that repository.
