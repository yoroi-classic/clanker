# AGENTS.md

Scope: this repository and any repositories that the review bot checks out for
the configured GitHub organization.

## Review Bot Operations

- `README.md` files are for humans. Keep agent-only instructions, operating
  rules, and review standards in `AGENTS.md`.
- The review bot lives in `review-bot/` and manages clones for the configured
  GitHub organization. The default workspace is `review-bot/.runtime/repos/`;
  override it with `REVIEW_BOT_WORKSPACE=<path>` when a machine already has a
  shared checkout directory.
- Before editing bot code or config, stop the watcher with
  `./review-bot/stop.sh`. After changes, run syntax checks and
  `./review-bot/tests/smoke-test.sh`, then restart with `./review-bot/start.sh`.
- Do not add systemd units, cron entries, or extra background supervisors unless
  explicitly requested. Use the provided shell controls.
- The default organization is configured in `review-bot/config.json`; override
  it with `REVIEW_BOT_OWNER=<org>` for another organization. The reviewer
  defaults to the authenticated `gh` user; override it with
  `REVIEW_BOT_REVIEWER=<login>`.
- The bot must review only open PRs where the configured reviewer is a requested
  reviewer. Do not use GitHub assignees as review eligibility. Skip
  self-authored PRs unless explicitly instructed otherwise.
- The shell scripts are prompt-generation and local evidence harnesses. Do not
  treat green checks as code review. Use `./review-bot/agent-prompt.sh <repo> <pr>`
  to prepare a semantic review subagent prompt.
- Use `./review-bot/list-queue.sh` to get the current review-requested queue.
  The orchestrator should assign queue items to review agents and track which
  head SHA each agent reviewed.
- The watcher only discovers pending review work and writes prompt files under
  `review-bot/.runtime/prompts/`; it must not run code checks or post reviews.
- Review agents drive the process: consume a generated prompt, use GitHub CI as
  the build/test signal, run the local evidence harness, inspect the diff/files
  semantically, post findings or approval, then call
  `./review-bot/record-review.sh` for the reviewed head/base.
- Clean semantic review runs must submit an approving PR review whose body
  includes `No issues found for <sha>.` Runs with findings must not approve.
- `review-bot/logs/` and `review-bot/state/` are local runtime data and are
  intentionally ignored by git.

## Review Standards

- For `yoroi-classic`, treat all repositories as blockchain wallet code. Be
  pedantic around private keys, mnemonics, passphrases, signing flows, address
  derivation, wallet storage, transaction construction, fees, token amounts,
  network IDs, and protocol parameters.
- Do not duplicate work CI already does. Use CI results as evidence, then do the
  semantic review CI cannot do. For dependency bumps, inspect direct and
  transitive changes, lockfile movement, build tooling impact, browser/mobile
  packaging, and runtime compatibility.
- For frontend and extension code, scrutinize XSS surfaces, `eval` or dynamic
  code loading, `dangerouslySetInnerHTML`, CSP changes, extension permissions,
  unsafe URL handling, and message-passing trust boundaries.
- For wallet and backend code, scrutinize integer precision, serialization
  determinism, chain/network selection, error handling, retry behavior,
  pagination, timeouts, database migrations, and API compatibility.
- Never log, persist, transmit, or expose secret material. This includes test
  fixtures unless the file path and context make it clearly non-production and
  non-sensitive.
- Prefer narrow, actionable findings with file and line references. If no issue
  is found after the relevant checks, say so directly rather than inventing
  low-signal concerns.

## Coding Standards

- Read the target repository's own docs, scripts, and existing patterns before
  editing. Keep changes local to the requested behavior.
- Preserve package-manager and language conventions already used by the repo.
  Do not introduce new toolchains or broad refactors for a narrow fix.
- Use exact integer or big-number types for Lovelace, token amounts, counters,
  and protocol quantities. Avoid floats and unsafe JavaScript `Number`
  conversion near money.
- Keep generated files, lockfiles, migrations, and API schemas consistent with
  the repo's documented workflow.
- Run the smallest meaningful verification first, then broaden tests when the
  change touches shared behavior, security-sensitive paths, build tooling, or
  user-facing wallet flows.
