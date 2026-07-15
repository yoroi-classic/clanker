# clanker

Portable review-bot runner for GitHub organizations.

Clanker watches pull requests where a configured reviewer has been requested,
runs local checks in isolated worktrees, posts findings when checks fail, and
approves clean PRs with a `No issues found for <sha>.` review body.

## Quick Start

Requirements:

- `gh` authenticated with access to the target organization
- `git`, `jq`, `flock`, and `timeout`
- the language/toolchain dependencies required by the repositories being
  reviewed

Run one polling pass:

```sh
./review-bot/run-once.sh
```

Start continuous polling:

```sh
./review-bot/start.sh
./review-bot/status.sh
```

Stop continuous polling:

```sh
./review-bot/stop.sh
```

## Configuration

Defaults are clone-local:

- `owner`: `yoroi-classic`, overridable with `REVIEW_BOT_OWNER=<org>`
- `reviewer`: authenticated `gh` user, overridable with
  `REVIEW_BOT_REVIEWER=<login>`
- managed repo workspace: `review-bot/.runtime/repos/`, overridable with
  `REVIEW_BOT_WORKSPACE=<path>`

Common examples:

```sh
REVIEW_BOT_OWNER=some-org ./review-bot/run-once.sh
REVIEW_BOT_REVIEWER=alice ./review-bot/run-once.sh
REVIEW_BOT_WORKSPACE=/path/to/org-repos ./review-bot/start.sh
```

See `review-bot/README.md` for detailed operation notes.
