# Session Standards

## Branches And Issues

- Always work in branches.
- Never use `codex` in branch names.
- Create or use an issue for every code or docs change.
- Assign the issue to yourself before starting.
- Prefer existing assigned issues over new work.
- Start new work only when assigned issues and authored PRs are closed or
  blocked on someone else.
- Create PRs for changes as you go.
- Do not merge normal PRs without approved human review or a clear bot review.
- Dependabot PRs may be merged after you validate and approve them.

## Commits And Worktrees

- Skip GPG for commits:
  `git -c commit.gpgsign=false commit --no-gpg-sign ...`.
- Check `git status --short --branch` before editing, before committing, and
  before final reporting.
- Never revert user or coworker changes unless explicitly asked.
- Keep refactor edits small, direct, and reviewable.
- Do not leave generated artifacts, coverage output, tarballs, caches, or temp
  clones in the working tree.
- Put generated bot files under the bot-owned runtime workspace, such as
  `coding-bot/.runtime/` or `review-bot/.runtime/`, so the bot can delete its
  own prompts, review bodies, queues, scratch files, and temporary checkouts.
- Use `/tmp` only for external tooling that truly needs it, and clean those
  paths immediately. Do not touch `/tmp/yoroi-review-bot`.

## Bot Self-Improvement

- When `coding-bot` or `review-bot` identifies a durable improvement to its own
  prompts, standards, runbooks, scripts, or docs, open or use a `clanker` issue
  and make the update through a normal suggestion PR.
- Do not silently mutate bot runtime behavior outside review. Runtime scratch
  files remain deletable implementation details; durable bot changes belong in
  tracked files and reviewed branches.

## Product Direction

- Stability comes first: clean builds, meaningful tests, secure dependency
  updates, and modern toolchains across all repos.
- Extension and mobile should move toward `cardano-wallet-backend` as their
  backend API.
- `cardano-wallet-backend` is the new backend track for this system.
- Owned infrastructure should use `blinklabs.cloud` domains for now.
- Remove active runtime/build dependencies on old EMURGO/YoroiWallet-hosted
  infrastructure. Treat `yoroi-wallet.com`, `yoroiwallet.com`,
  `emurgornd.com`, and `github.com/Emurgo` as references to eliminate unless
  historical or clearly inert.
- Token metadata work should consider Cardano Foundation's token registry.
- Pool metadata work should consider IOHK's SMASH server.
- Prefer dcSpark `cardano-multiplatform-lib` over maintaining our own CSL fork
  for future migration work.
- `yoroi-classic/trezor-suite` is the active fork for Trezor Connect packages;
  the archived `trezor/connect` repository is not the target for new work.
- The Trezor CML migration path runs through
  `trezor-connect-flow -> @trezor/connect-web -> @trezor/connect -> @trezor/network-cardano -> coin-selection`.
  Prefer fixing `yoroi-classic/coin-selection` and then wiring that through
  `trezor-suite`, `trezor-connect-flow`, and `yoroi-frontend`.
- Support CIP-0103 where relevant in extension and mobile signing flows.

## Verification

- Run the smallest meaningful check first.
- Broaden checks when touching shared behavior, build tooling, wallet flows,
  security-sensitive code, or public APIs.
- Verify review-bot claims before changing code.
- Report checks that were run and checks that could not be run.
