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
- Clean your own `/tmp` directories. Do not touch `/tmp/yoroi-review-bot`.

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
- Support CIP-0103 where relevant in extension and mobile signing flows.

## Verification

- Run the smallest meaningful check first.
- Broaden checks when touching shared behavior, build tooling, wallet flows,
  security-sensitive code, or public APIs.
- Verify review-bot claims before changing code.
- Report checks that were run and checks that could not be run.
