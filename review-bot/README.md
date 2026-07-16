# Yoroi Classic Review Bot

Small local review-bot scaffold for GitHub organizations. The checked-in
default owner is `yoroi-classic`, but `REVIEW_BOT_OWNER=<org>` or
`config.json` can point it at another org.

The bot polls for open pull requests where the configured reviewer is requested
for review. By default the reviewer is the authenticated `gh` user; set
`REVIEW_BOT_REVIEWER=<login>` or `reviewer` in `config.json` to override it.
It updates repositories for the configured organization inside the configured
workspace, cloning a missing repository when necessary, skips PR heads it has
already reviewed, generates review agent prompts, and provides a local evidence
harness. The harness reads GitHub
CI/check status instead of re-running CI jobs locally, runs only local
review-specific scans, and writes a report for the review agent. A semantic
review agent posts findings or submits an approving PR review whose body says:

```text
No issues found for <sha>.
```

It intentionally avoids checking out pull requests in the main repo clones.
Direct single-PR runs also verify the PR requests review from the configured
reviewer before reviewing. Self-authored PRs are skipped by default even if
review is requested; set
`REVIEW_BOT_INCLUDE_SELF_AUTHORED=1` only for an explicit manual/internal pass.

Each evidence pass captures GitHub CI/check rollup, then runs `git diff --check`
and a built-in pedantic wallet diff scan. Optional `localChecks` in
`config.json` are for review-specific probes only; do not duplicate normal CI
build/test jobs there. The wallet scan flags added lines for low-noise hazards
such as secret material in logs or telemetry, raw HTML injection, dynamic code
execution, TLS verification weakening, secret material written to unsafe
storage, hardcoded wallet secrets, browser extension permission or CSP
expansion, non-cryptographic randomness near wallet material, and plain numeric
conversion near token or ADA amounts.

Optional local checks may execute code from the pull request. They run with a
minimal environment, isolated tool configuration/cache directories, resource
limits, and network access denied by default. Network denial is fail-closed:
when the host cannot create the required namespace, the check fails without
executing PR-controlled code. Set `localCheckNetwork` to `allow` only as an
explicit trusted-configuration choice. See
[`THREAT_MODEL.md`](THREAT_MODEL.md) for the trust boundaries and residual
risks.

The relevant trusted configuration keys are `localCheckNetwork`,
`localCheckCpuSeconds`, `localCheckMemoryBytes`, `localCheckMaxProcesses`,
`localCheckWorkspaceBytes`, `localCheckScratchBytes`, `localCheckMaxOpenFiles`, and
`localCheckMaxOutputBytes`. Environment overrides use the corresponding
`REVIEW_BOT_LOCAL_CHECK_*` names. Filesystem isolation is always required for
local checks; setting the network policy to `allow` does not disable filesystem
confinement.

## Usage

By default, `config.json` resolves relative paths against the `clanker`
checkout: logs and state live under `review-bot/`, runtime files live under
`review-bot/.runtime/`, and organization base checkouts are the submodules in
top-level `repos/`. PR worktrees remain disposable runtime data under
`review-bot/.runtime/worktrees/`. A repository can set `repos.<name>.path` in
the config when its base checkout is elsewhere; `clanker` maps to the top-level
checkout itself.

Refresh the review queue and generate prompts once:

```sh
./review-bot/run-once.sh
```

Review a single PR:

```sh
./review-bot/review-one.sh cross-csl 15
```

Generate a prompt for a semantic code-review subagent:

```sh
./review-bot/agent-prompt.sh cross-csl 15
```

List the current review-requested queue as JSON lines:

```sh
./review-bot/list-queue.sh
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

`review-one.sh` is permanently evidence-only: it writes reports without posting
comments or reviews to GitHub. A semantic review agent should run it for CI
status and local review-specific evidence, inspect the patch, and then decide
whether to post findings or approve. Add
`REVIEW_BOT_RECORD_DRY_RUN=1` only if you want a dry run to mark the current PR
head as checked. Posting remains a separate semantic-review action.

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

## Self-Improvement

When a review pass identifies a durable improvement to review-bot behavior,
prompts, scans, state handling, or shared standards, track it with a `clanker`
issue and publish the update as a normal suggestion PR. Do not silently mutate
review-bot runtime behavior outside the reviewed branch.

## Scheduling

For continuous operation, run `review-bot/watch.sh` from a terminal, or use the
explicit `start.sh`/`status.sh`/`stop.sh` pid-file controls. This directory only
contains shell-script controls.

The watcher does not perform code review or post to GitHub. It writes the
pending review queue to `review-bot/.runtime/queue.jsonl` and generated
subagent prompts to `review-bot/.runtime/prompts/`. A review agent consumes
those prompts, runs the harness, inspects the code, posts the GitHub review, and
records completion with `review-bot/record-review.sh`. Generated prompts embed
the shared review standards from `standards/review.md`.

Each optional local review-specific check is capped by `checkTimeoutSeconds` in
`config.json`, or by `REVIEW_BOT_CHECK_TIMEOUT_SECONDS` for a single run.

## State

State is stored in `review-bot/state/reviews.json`, keyed by
`owner/repo#number`. Local evidence runs record `review_kind: "check"` only when
`REVIEW_BOT_RECORD_DRY_RUN=1` is set. Semantic review agents must call
`record-review.sh`, which verifies and records `review_kind: "semantic"` after
the GitHub review/comment is posted. Clean state requires a matching approval
for the reviewed head with the exact no-issues SHA phrase. Findings reviews
must be attached to the reviewed head; findings posted as issue comments must
include the exact `Reviewed head: <sha>.` marker generated by the agent prompt.

The pending queue suppresses only semantic records for the same PR head SHA and
base SHA. A new push, or a base-branch movement under the same head, causes the
PR to be reviewed again.
