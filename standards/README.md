# Shared Standards

`standards/` is the shared policy surface for agent work in the
`yoroi-classic` organization.

- `session.md` covers coding-session behavior, queue discipline, branches,
  issues, commits, product direction, and verification.
- `review.md` covers semantic review posture and wallet-specific review risks.

Both `coding-bot` and `review-bot` consume these files. Keep durable standards
and recurring gotchas here; keep runtime scripts, queues, prompts, logs, and
temporary checkouts in the bot-specific runtime directories.
