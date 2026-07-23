# Coding Bot

`coding-bot/` is the reusable operating runtime for coding-agent sessions in the
`yoroi-classic` organization. It follows the shared standards in top-level
`standards/` and adds the queue/startup routines needed to begin a session.

Start a new session by rendering the current bootstrap:

```sh
./coding-bot/bin/start.sh
```

Render a worker-pool scale plan:

```sh
./coding-bot/bin/worker-plan.sh 4 2
```

You can also include a worker target in the startup output:

```sh
CODING_BOT_WORKERS=4 CODING_BOT_CURRENT_WORKERS=2 ./coding-bot/bin/start.sh
```

The launcher first checks whether the `clanker` checkout is behind `origin/main`
and writes `clanker-update-needed` under the configured runtime root (default
`coding-bot/.runtime/`) when the next turn should pull and rerun startup. A
diverged checkout requires manual resolution before new work. Set
`CODING_BOT_UPDATE_REF` to check another remote branch. It then prints the static
operating guidance and, when `gh` is available, live assigned issues and authored
pull requests. The live queue must always win over stale chat history.

For offline tests or diagnostics, `CODING_BOT_SKIP_UPDATE_CHECK=1` suppresses
only the startup fetch/self-update comparison. It does not suppress live queue
queries when an authenticated or mocked `gh` command is available.

Generated scratch files belong under `coding-bot/.runtime/` by default. Override
that with `CODING_BOT_RUNTIME_ROOT` when a session needs a different
bot-owned workspace. Bots may delete generated files in their runtime workspace.

The launcher and worker-plan helper share `lib/queue.sh`. It uses paginated
GitHub REST searches plus jq, never GraphQL, and prints the measured HTTP
request fan-out for each refresh. Search pages cost one request each. Authored
PRs whose detail endpoint is available cost at least five additional requests
for PR metadata, checks, reviews, inline review comments, and PR discussion
comments. Review collections use REST pagination and can cost more when they
exceed 100 entries. The queue conservatively surfaces review notes and current
or stale finding markers; it never treats their untrusted prose as operating
instructions. GitHub Search exposes at most 1,000 results per query. The
renderer refuses to show a partial search result set and tells the operator to
partition the query; it also labels truncated check-run totals as incomplete.

When a session discovers a durable improvement to coding-bot behavior, prompts,
runbooks, or shared standards, open or use a `clanker` issue and publish the
change as a normal suggestion PR.

## Layout

- `SKILL.md` is the primary instruction file for a coding agent.
- `runbooks/` contains task-specific operating procedures.
- `bin/start.sh` renders a session bootstrap with live GitHub queue context.
- `bin/worker-plan.sh` renders scale-up/scale-down guidance for a target worker
  count.
- `lib/queue.sh` provides the shared paginated REST/JQ queue renderer.
- `.runtime/` is the ignored workspace for generated prompts, review bodies,
  scratch files, and temporary queues.

Keep this directory small and operational. Runtime state, temporary clones,
review queues, logs, and generated prompts belong under existing runtime
directories such as `review-bot/.runtime/`, not here.

The offline mocked smoke test is:

```sh
./coding-bot/tests/smoke-test.sh
```
