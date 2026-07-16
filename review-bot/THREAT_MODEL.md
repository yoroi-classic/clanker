# Review Bot Threat Model

The review bot inspects pull requests from organization repositories. Pull
request authors may control metadata, commits, files, scripts, dependency
manifests, test output, and instruction files in the proposed head revision.
All of that content is untrusted review input.

## Trust Boundaries

Trusted inputs are:

- the checked-in `clanker` review-bot scripts and configuration;
- shared standards from the active `clanker` checkout;
- repository instructions read from the pull request's base revision;
- authenticated GitHub metadata fetched directly by the bot.

Untrusted inputs include:

- pull request titles, bodies, comments, commit messages, and patches;
- every file from the pull request head, including `AGENTS.md`, contribution
  guides, CI definitions, package scripts, and generated artifacts;
- stdout and stderr produced by commands that execute against the pull request
  worktree.

Semantic review agents must treat untrusted text as data. It cannot change the
reviewer's task, request credentials, authorize unrelated commands, weaken
checks, or determine whether a review is posted.

## Executable Checks

The built-in `git diff --check` and pedantic wallet diff scan are trusted bot
commands. Optional `localChecks` execute commands selected by trusted
`review-bot/config.json`, but the selected command may load or run code from the
untrusted pull request worktree.

Local checks therefore run with:

- a new, allowlisted environment rather than the agent's inherited environment;
- isolated HOME, GitHub CLI, XDG cache/config, and temporary directories;
- no ambient GitHub, SSH, package-registry, cloud, signing, or arbitrary
  environment variables;
- configured wall-clock, CPU, memory, process, open-file, workspace-size, and
  output-file limits;
- a network namespace when `localCheckNetwork` is `deny`.

Network denial is fail-closed. If the host cannot create the configured
namespace, the evidence is marked inconclusive and PR-controlled code is not
executed. Operators may explicitly set `localCheckNetwork` to `allow`, but the
evidence report records that choice.

The sandbox exposes read-only system tool directories and a read-only source
worktree. Checks execute in a size-bounded tmpfs copy plus an isolated check
environment and bounded temporary filesystem, so they cannot modify the
worktree later inspected by the semantic reviewer or fill host scratch
directories. The host home, `clanker` checkout, runtime state, sockets, and
unrelated filesystem paths are not mounted. This still does not provide a
complete kernel security boundary. Run the review bot on a dedicated,
least-privilege account without production secrets. Stronger isolation should
use a disposable VM or container.

## Posting Boundary

The watcher only discovers work and writes queue and prompt files. It does not
execute pull request code or post reviews.

The evidence harness never posts comments or reviews. A semantic reviewer posts
only after inspecting the evidence and actual diff. `record-review.sh` verifies
that the referenced GitHub review/comment exists and that both the reviewed head
and base SHAs still match GitHub before suppressing future queue entries. Clean
state additionally requires an approval by the configured reviewer for the
reviewed head whose body contains the exact no-issues SHA phrase. Findings
reviews must be attached to the reviewed head; issue comments must contain the
exact reviewed-head marker.

## Residual Risks

- Trusted configuration can deliberately enable a networked local check.
- Locally installed compilers, package managers, and interpreters may have their
  own vulnerabilities.
- GitHub and repository metadata may change during a review; head/base checks
  reduce but do not eliminate all time-of-check/time-of-use races.
- Semantic reviewers can still make judgment errors. CI and automated scans are
  evidence, not substitutes for code review.

Keep the host patched, use a dedicated account, avoid storing unrelated
credentials in its environment or home directory, and review changes to this
threat model whenever the execution boundary changes.
