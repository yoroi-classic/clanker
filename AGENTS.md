# AGENTS.md

Scope: the `clanker` superproject, every repository checked out under `repos/`,
and any additional repository the review bot checks out for the configured
GitHub organization.

## Workspace Role

- Treat `clanker` as the organization development hub, not only as a review-bot
  project. Organization repositories are pinned submodules under `repos/`.
- A submodule is an independent repository. Read its own `AGENTS.md`, docs,
  scripts, and existing patterns before editing; more local instructions take
  precedence inside that repository.
- Keep changes within the repository that owns the behavior. Do not copy source
  or configuration into `clanker` merely to coordinate a multi-repository task.
- Fresh submodule checkouts can be detached. Create or switch to the intended
  repository branch before committing. Never assume the superproject branch is
  also the correct submodule branch.
- For cross-repository work, verify and commit each submodule independently,
  then update and commit the `clanker` gitlinks last. Report the repository and
  commit/branch for every part of the change.
- Preserve unrelated work in the superproject and every submodule. Before broad
  operations, inspect `git status` at the top level and in affected submodules.
- `.gitmodules` tracks each repository's current default branch. Branch creation
  or default-branch migration on GitHub requires explicit authorization.
- Use `git submodule update --init --recursive` to materialize pinned checkouts.
  Treat `git submodule update --remote --recursive` as a deliberate snapshot
  update because it changes gitlinks recorded by `clanker`.

## Coding Standards

- Keep changes local to the requested behavior and preserve each repository's
  package-manager, language, generated-file, migration, and schema workflows.
- Do not introduce a new toolchain or broad refactor for a narrow change.
- Use exact integer or big-number types for Lovelace, token amounts, counters,
  and protocol quantities. Avoid floats and unsafe JavaScript `Number`
  conversion near money.
- Run the smallest meaningful verification first, then broaden tests for shared
  behavior, security-sensitive paths, build tooling, or user-facing wallet
  flows.
- Never log, persist, transmit, or expose private keys, mnemonics, passphrases,
  signing material, or other secrets. Test fixtures are acceptable only when
  their path and context make them clearly non-production and non-sensitive.

## Review Bot Operations

- The review bot lives in `review-bot/`. Its base checkouts default to the
  top-level `repos/` submodules; `clanker` itself maps to the superproject root.
  Override with `REVIEW_BOT_WORKSPACE=<path>` when appropriate.
- PR-specific and shallow/disposable checkouts belong under
  `review-bot/.runtime/` or another explicit runtime path, never in the base
  submodules.
- Before editing bot code or config, stop the watcher with
  `./review-bot/stop.sh`. After changes, run shell syntax checks and
  `./review-bot/tests/smoke-test.sh`, then restart with
  `./review-bot/start.sh`.
- Do not add systemd units, cron entries, or extra background supervisors unless
  explicitly requested. Use the provided shell controls.
- The default organization is in `review-bot/config.json`; override it with
  `REVIEW_BOT_OWNER=<org>`. The reviewer defaults to authenticated `gh`; use
  `REVIEW_BOT_REVIEWER=<login>` to override it.
- Review only open PRs where the configured reviewer is a requested reviewer.
  Do not use assignees as eligibility. Skip self-authored PRs unless explicitly
  instructed otherwise.
- The watcher only discovers pending work and writes queue/prompt files. It must
  not run code checks or post reviews.
- Use `./review-bot/list-queue.sh` for the queue and
  `./review-bot/agent-prompt.sh <repo> <pr>` to prepare a semantic review-agent
  prompt. The shell evidence harness is not itself a code review.
- Review agents consume a prompt, use GitHub CI as the build/test signal, run
  local review-specific evidence, inspect the diff and relevant files
  semantically, post findings or approval, and call
  `./review-bot/record-review.sh` for the reviewed head/base.
- A clean semantic review must approve with a body containing
  `No issues found for <sha>.` A run with findings must not approve.
- `review-bot/logs/` and `review-bot/state/` are ignored local runtime data.

## Review Standards

- Treat every `yoroi-classic` repository as blockchain wallet code. Be pedantic
  around private keys, mnemonics, passphrases, signing, address derivation,
  wallet storage, transaction construction, fees, token amounts, network IDs,
  and protocol parameters.
- Use CI results as evidence and concentrate semantic review on what CI cannot
  establish. For dependency bumps, inspect direct/transitive movement, build
  tooling, browser/mobile packaging, and runtime compatibility.
- For frontend and extension code, scrutinize XSS, `eval` or dynamic loading,
  `dangerouslySetInnerHTML`, CSP, extension permissions, unsafe URLs, and
  message-passing trust boundaries.
- For wallet and backend code, scrutinize integer precision, deterministic
  serialization, chain/network selection, errors, retries, pagination,
  timeouts, database migrations, and API compatibility.
- Prefer narrow, actionable findings with file and line references. If relevant
  checks and semantic inspection find no issue, say so directly instead of
  inventing low-signal concerns.
