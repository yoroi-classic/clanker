# Review Standards

Treat every `yoroi-classic` repository as blockchain wallet code.

## Required Posture

- Do not approve from green checks alone.
- Use CI as evidence, then inspect the semantic diff.
- Prefer narrow, actionable findings with file and line references.
- If relevant checks and semantic inspection find no issue, say so directly.
- Do not invent low-signal concerns.
- Always verify review bots' claims before acting on them.

## Wallet-Critical Areas

Be pedantic around:

- private keys, mnemonics, passphrases, signing, derivation, address handling;
- transaction construction, fees, UTxO handling, token amounts, Lovelace
  precision;
- network IDs, protocol parameters, deterministic serialization;
- storage, logging, telemetry, clipboard, URL surfaces;
- pagination, retries, timeouts, database migrations, API compatibility.

## Frontend And Extension Areas

Scrutinize:

- extension permissions and CSP;
- message-passing trust boundaries;
- injected HTML and unsafe URL handling;
- dynamic code execution, `eval`, and remote script loading;
- dependency bumps that affect bundling, browser support, or React Native.

## Dependency Updates

For dependency updates, inspect direct and transitive movement, runtime
compatibility, lockfile churn, security impact, and whether meaningful package
tests cover the behavior Yoroi actually uses.
