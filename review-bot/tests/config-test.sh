#!/usr/bin/env bash
set -euo pipefail

BOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "config-test: $*" >&2
  exit 1
}

"$BOT_DIR/validate-config.sh" "$BOT_DIR/config.json" >/dev/null

jq '.pollSeconds = 0' "$BOT_DIR/config.json" >"$TMP_ROOT/invalid-poll.json"
set +e
"$BOT_DIR/validate-config.sh" "$TMP_ROOT/invalid-poll.json" >"$TMP_ROOT/output" 2>&1
rc="$?"
set -e
[[ "$rc" -eq 2 ]] || fail "nonpositive pollSeconds should exit 2, got $rc"
grep -Fq 'invalid configuration values or types' "$TMP_ROOT/output" ||
  fail "invalid polling error should be actionable"

jq '.discoveryTimeoutSeconds = 0' "$BOT_DIR/config.json" >"$TMP_ROOT/invalid-discovery-timeout.json"
set +e
"$BOT_DIR/validate-config.sh" "$TMP_ROOT/invalid-discovery-timeout.json" >"$TMP_ROOT/output" 2>&1
rc="$?"
set -e
[[ "$rc" -eq 2 ]] || fail "nonpositive discoveryTimeoutSeconds should exit 2, got $rc"

jq '.discoveryBackoffBaseSeconds = 10 | .discoveryBackoffMaxSeconds = 5' \
  "$BOT_DIR/config.json" >"$TMP_ROOT/invalid-discovery-backoff.json"
set +e
"$BOT_DIR/validate-config.sh" "$TMP_ROOT/invalid-discovery-backoff.json" >"$TMP_ROOT/output" 2>&1
rc="$?"
set -e
[[ "$rc" -eq 2 ]] || fail "inverted discovery backoff should exit 2, got $rc"

jq '.watchLogRetain = -1' "$BOT_DIR/config.json" >"$TMP_ROOT/invalid-log-retention.json"
set +e
"$BOT_DIR/validate-config.sh" "$TMP_ROOT/invalid-log-retention.json" >"$TMP_ROOT/output" 2>&1
rc="$?"
set -e
[[ "$rc" -eq 2 ]] || fail "negative watchLogRetain should exit 2, got $rc"

jq '.localChecks = [1]' "$BOT_DIR/config.json" >"$TMP_ROOT/invalid-checks.json"
set +e
"$BOT_DIR/validate-config.sh" "$TMP_ROOT/invalid-checks.json" >"$TMP_ROOT/output" 2>&1
rc="$?"
set -e
[[ "$rc" -eq 2 ]] || fail "non-string localChecks should exit 2, got $rc"

echo "config-test: ok"
