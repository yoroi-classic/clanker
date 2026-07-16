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

test_worker_plan_validation_and_scale_actions() {
  local output="$TMP_ROOT/worker-plan.out"
  local rc

  set +e
  "$BOT_DIR/bin/worker-plan.sh" invalid >"$output" 2>&1
  rc="$?"
  set -e
  [[ "$rc" -eq 2 ]] || fail "invalid worker target should exit 2, got $rc"
  assert_contains "$output" "usage:"

  "$BOT_DIR/bin/worker-plan.sh" --no-queue 1 4 >"$output"
  assert_contains "$output" 'Stop or do not replace `3` worker(s).'

  "$BOT_DIR/bin/worker-plan.sh" --no-queue 4 1 >"$output"
  assert_contains "$output" 'Start `3` additional worker(s).'

  "$BOT_DIR/bin/worker-plan.sh" --no-queue 1 1 >"$output"
  assert_contains "$output" "Worker count is already at target."
}

write_offline_wrappers() {
  local bin_dir="$1"
  local real_git

  real_git="$(command -v git)"
  mkdir -p "$bin_dir"

cat >"$bin_dir/git" <<WRAPPER
#!/usr/bin/env bash
set -euo pipefail

args=("\$@")
for index in "\${!args[@]}"; do
  if [[ "\${args[\$index]}" == "fetch" ]]; then
    exit 0
  fi
  if [[ "\${args[\$index]}" == "refs/remotes/origin/main" ]]; then
    args[\$index]="HEAD"
  fi
done

exec "$real_git" "\${args[@]}"
WRAPPER

  cat >"$bin_dir/gh" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
  exit 1
fi

echo "fake gh: unexpected command: $*" >&2
exit 98
WRAPPER

  chmod +x "$bin_dir/git" "$bin_dir/gh"
}

test_start_is_offline_and_injects_shared_guidance() {
  local fake_bin="$TMP_ROOT/bin"
  local runtime="$TMP_ROOT/runtime"
  local output="$TMP_ROOT/start.out"

  write_offline_wrappers "$fake_bin"

  PATH="$fake_bin:$PATH" \
    CODING_BOT_RUNTIME_ROOT="$runtime" \
    CODING_BOT_WORKERS=1 \
    CODING_BOT_CURRENT_WORKERS=1 \
    "$BOT_DIR/bin/start.sh" >"$output"

  assert_contains "$output" "# Yoroi Classic Coding Bot Bootstrap"
  assert_contains "$output" "## coding-bot/SKILL.md"
  assert_contains "$output" "## standards/session.md"
  assert_contains "$output" "## standards/review.md"
  assert_contains "$output" "Worker count is already at target."
  assert_contains "$output" "GitHub CLI is not authenticated"
  [[ ! -e "$runtime/clanker-update-needed" ]] ||
    fail "current checkout should not produce an update marker"
}

test_worker_plan_validation_and_scale_actions
test_start_is_offline_and_injects_shared_guidance

echo "coding-bot smoke-test: ok"
