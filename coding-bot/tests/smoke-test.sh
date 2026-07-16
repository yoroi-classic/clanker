#!/usr/bin/env bash
set -euo pipefail

BOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "coding-bot smoke-test: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local pattern="$2"

  grep -Fq "$pattern" "$file" || fail "expected $file to contain: $pattern"
}

FAKE_BIN="$TMP_ROOT/bin"
START_OUTPUT="$TMP_ROOT/start.out"
WORKER_OUTPUT="$TMP_ROOT/worker.out"
mkdir -p "$FAKE_BIN"

cat >"$FAKE_BIN/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == "auth" && "$2" == "status" ]]; then
  exit 0
fi

if [[ "$1" != "api" ]]; then
  echo "fake gh: unsupported arguments: $*" >&2
  exit 98
fi

case "$*" in
  *"search/issues"*"is:pr"*)
    printf 'yoroi-classic/clanker\t18\tSecurity hardening\thttps://example.invalid/pr/18\n'
    ;;
  *"search/issues"*"is:issue"*)
    printf '%s\n' '- yoroi-classic/clanker#15: Add CI https://example.invalid/issues/15'
    ;;
  *"repos/yoroi-classic/clanker/pulls/18/reviews"*)
    printf 'reviews=Crypto2099:APPROVED\n'
    ;;
  *"repos/yoroi-classic/clanker/pulls/18"*)
    printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\tfalse\tCrypto2099\n'
    ;;
  *"repos/yoroi-classic/clanker/commits/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/check-runs"*)
    printf 'checks=0 fail/0 pending/1 total\n'
    ;;
  *)
    echo "fake gh: unsupported api arguments: $*" >&2
    exit 98
    ;;
esac
FAKE_GH
chmod +x "$FAKE_BIN/gh"

PATH="$FAKE_BIN:$PATH" \
  CODING_BOT_RUNTIME_ROOT="$TMP_ROOT/runtime" \
  CODING_BOT_SKIP_UPDATE_CHECK=1 \
  "$BOT_DIR/bin/start.sh" >"$START_OUTPUT"

assert_contains "$START_OUTPUT" 'Self-update check skipped'
assert_contains "$START_OUTPUT" 'yoroi-classic/clanker#15: Add CI'
assert_contains "$START_OUTPUT" 'yoroi-classic/clanker#18: Security hardening'
assert_contains "$START_OUTPUT" 'checks=0 fail/0 pending/1 total'
assert_contains "$START_OUTPUT" 'reviews=Crypto2099:APPROVED'

PATH="$FAKE_BIN:$PATH" \
  CODING_BOT_RUNTIME_ROOT="$TMP_ROOT/runtime" \
  "$BOT_DIR/bin/worker-plan.sh" 4 2 >"$WORKER_OUTPUT"

assert_contains "$WORKER_OUTPUT" 'Start `2` additional worker(s).'
assert_contains "$WORKER_OUTPUT" 'yoroi-classic/clanker#15: Add CI'
assert_contains "$WORKER_OUTPUT" 'yoroi-classic/clanker#18: Security hardening'

set +e
"$BOT_DIR/bin/worker-plan.sh" invalid >"$WORKER_OUTPUT" 2>&1
rc="$?"
set -e
[[ "$rc" -eq 2 ]] || fail "invalid worker target should exit 2, got $rc"

echo "coding-bot smoke-test: ok"
