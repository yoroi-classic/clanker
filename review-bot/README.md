# Yoroi Classic Review Bot

Small local review-bot scaffold for GitHub organizations. The checked-in
default owner is `yoroi-classic`, but `REVIEW_BOT_OWNER=<org>` or
`config.json` can point it at another org.

The bot polls for open pull requests where the configured reviewer is requested
for review. By default the reviewer is the authenticated `gh` user; set
`REVIEW_BOT_REVIEWER=<login>` or `reviewer` in `config.json` to override it.
It clones and updates repositories for the configured organization inside the
configured workspace, skips PR heads it has already reviewed, checks each new
head in an isolated worktree, and posts findings when checks fail. When checks
pass, it submits an approving PR review whose body says:

```text
No issues found for <sha>.
```

It intentionally avoids checking out pull requests in the main repo clones.
Direct single-PR runs also verify the PR requests review from the configured
reviewer before reviewing. Self-authored PRs are skipped by default even if
review is requested; set
`REVIEW_BOT_INCLUDE_SELF_AUTHORED=1` only for an explicit manual/internal pass.

Each review pass runs `git diff --check`, a built-in pedantic wallet diff scan,
and then the repo-specific checks in `config.json`. The wallet scan flags added
lines for low-noise hazards such as secret material in logs or telemetry, raw
HTML injection, dynamic code execution, TLS verification weakening, secret
material written to unsafe storage, hardcoded wallet secrets, browser extension
permission or CSP expansion, non-cryptographic randomness near wallet material,
and plain numeric conversion near token or ADA amounts.

## Usage

By default, `config.json` resolves relative paths against the `clanker`
checkout: logs and state live under `review-bot/`, runtime files live under
`review-bot/.runtime/`, and managed org repository clones live under
`review-bot/.runtime/repos/`.

Run one polling pass:

```sh
./review-bot/run-once.sh
```

Review a single PR:

```sh
./review-bot/review-one.sh cross-csl 15
```

Poll continuously:

```sh
./review-bot/watch.sh
```

Start, inspect, or stop the explicit background watcher:

```sh
./review-bot/start.sh
./review-bot/status.sh
./review-bot/stop.sh
```

`start.sh` writes a pid file under `runtimeRoot` and appends watcher output to
`review-bot/logs/watch.log`.

Set `REVIEW_BOT_POST=0` for a dry run that writes reports without posting to
GitHub or updating review state. Add `REVIEW_BOT_RECORD_DRY_RUN=1` only if you
want a dry run to mark the current PR head as reviewed.

Common overrides:

```sh
REVIEW_BOT_OWNER=some-org REVIEW_BOT_REVIEWER=alice ./review-bot/run-once.sh
REVIEW_BOT_WORKSPACE=/path/to/org-repos ./review-bot/run-once.sh
REVIEW_BOT_CONFIG=/path/to/config.json ./review-bot/start.sh
```

When using `start.sh`, environment overrides such as `REVIEW_BOT_OWNER`,
`REVIEW_BOT_REVIEWER`, and `REVIEW_BOT_WORKSPACE` are inherited by the watcher.

Run the local smoke test:

```sh
./review-bot/tests/smoke-test.sh
```

The smoke test uses temporary local git repositories and a mocked `gh` command.
It does not post to GitHub.

## Scheduling

For continuous operation, run `review-bot/watch.sh` from a terminal, or use the
explicit `start.sh`/`status.sh`/`stop.sh` pid-file controls. This directory only
contains shell-script controls.

The scripts use `flock` so overlapping runs do not review the same PR
concurrently. A polling pass keeps going when one PR fails before report
posting, so another review-requested PR is not blocked by the first one.

Each check is capped by `checkTimeoutSeconds` in `config.json`, or by
`REVIEW_BOT_CHECK_TIMEOUT_SECONDS` for a single run.

## State

State is stored in `review-bot/state/reviews.json`, keyed by
`owner/repo#number`. The bot updates state only after posting a finding comment
or clean approval succeeds, unless `REVIEW_BOT_POST=0
REVIEW_BOT_RECORD_DRY_RUN=1` is set explicitly.

The skip check compares both the PR head SHA and the base SHA. A new push, or a
base-branch movement under the same head, causes the PR to be reviewed again.
