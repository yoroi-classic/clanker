# Clanker

Clanker is the top-level development workspace for the `yoroi-classic`
organization. It pins every other organization repository as a submodule under
`repos/`, giving humans and coding agents one checkout for cross-repository
discovery, implementation, testing, and review.

The repository also contains `review-bot/`, the local pull-request discovery
and evidence tooling used by semantic review agents.

It also contains shared `standards/` plus `coding-bot/`, the reusable runtime
instructions and launcher for starting coding-agent sessions with the same queue
policy and review posture.

## Get the complete workspace

For a new checkout:

```sh
git clone --recurse-submodules git@github.com:yoroi-classic/clanker.git
cd clanker
```

For an existing checkout:

```sh
git submodule sync --recursive
git submodule update --init --recursive
```

Submodules are pinned by the `clanker` commit, so every checkout starts from a
reproducible organization-wide snapshot. Their `branch` entries in
`.gitmodules` track `main` for repositories whose default branch is `main` and
otherwise follow the repository's current default branch:

| Branch | Repositories |
| --- | --- |
| `development` | `cardano-wallet-backend` |
| `develop` | `trezor-suite`, `yoroi`, `yoroi-frontend` |
| `master` | `CIP4`, `cardano-serialization-lib`, `cip14-js`, `coin-selection`, `message-signing`, `webpack-httpolyglot-server`, `yoroi-graphql-migration-backend` |

All other submodules track `main`.

## Work across repositories

Each directory under `repos/` is an independent Git repository with its own
history, branches, tooling, and contribution rules. Before changing one, read
its local documentation and `AGENTS.md`, if present.

Freshly initialized submodules may be in detached-HEAD state. Switch to a local
branch before committing:

```sh
git -C repos/yoroi switch develop
git -C repos/cross-csl switch main
```

For a cross-repository change:

1. Create an appropriate branch in every affected submodule.
2. Implement and verify each repository according to its own workflow.
3. Commit and publish changes in each submodule repository.
4. Commit the updated submodule pointers in `clanker` last.

Useful workspace commands:

```sh
# Show the pinned commit and checkout state for every repository.
git submodule status --recursive

# Find uncommitted work throughout the workspace.
git submodule foreach --recursive 'git status --short'

# Advance submodules to the configured remote tracking branches.
git submodule update --remote --recursive
```

`git submodule update --remote` changes the organization snapshot recorded by
`clanker`. Review those pointer changes and commit them intentionally; do not
run it as a routine prerequisite for unrelated work.

## Review bot

The checked-in review-bot configuration uses `repos/` as its base-checkout
workspace. Pull-request worktrees and other disposable data stay under
`review-bot/.runtime/`, keeping the submodules suitable for normal development.

Requirements include authenticated `gh`, plus `git`, `jq`, `flock`, and
`timeout`. Hosts that configure `localChecks` with the default denied-network
policy also need `bwrap` and permission to create an unprivileged network
namespace.

```sh
# Refresh the requested-review queue once.
./review-bot/run-once.sh

# Run the watcher in the background and inspect it.
./review-bot/start.sh
./review-bot/status.sh

# Stop it explicitly.
./review-bot/stop.sh
```

The default organization is `yoroi-classic`, and the default reviewer is the
authenticated GitHub user. Common overrides are:

```sh
REVIEW_BOT_OWNER=some-org ./review-bot/run-once.sh
REVIEW_BOT_REVIEWER=alice ./review-bot/run-once.sh
REVIEW_BOT_WORKSPACE=/path/to/org-repos ./review-bot/start.sh
```

See [`review-bot/README.md`](review-bot/README.md) for the evidence harness,
queue, posting, state, and operating details.

## Coding bot

Render a new coding-agent session bootstrap:

```sh
./coding-bot/bin/start.sh
```

Render a worker-pool scaling plan:

```sh
./coding-bot/bin/worker-plan.sh 4 2
```

The coding bot prints the static operating guidance and, when `gh` is
authenticated, the live assigned issue and authored PR queues. Keep top-level
`standards/` current as operating practices and recurring gotchas evolve; both
`coding-bot` and `review-bot` consume those files.

By default, coding-bot scratch files live under `coding-bot/.runtime/`.
Override with `CODING_BOT_RUNTIME_ROOT` if a session needs another bot-owned
workspace.

## Quality checks

Run the same offline checks used by CI:

```sh
./scripts/quality-check.sh
```

The command validates Bash syntax, runs ShellCheck at warning severity, validates
review-bot configuration values and JSON, and runs the review-bot and coding-bot
smoke suites. It does not initialize submodules, contact GitHub, or post
anything.
