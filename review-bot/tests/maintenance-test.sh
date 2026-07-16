#!/usr/bin/env bash
set -euo pipefail

BOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
WATCH_PID=""

cleanup() {
  if [[ -n "$WATCH_PID" ]]; then
    kill "$WATCH_PID" >/dev/null 2>&1 || true
    wait "$WATCH_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  echo "maintenance-test: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local pattern="$2"

  grep -Fq "$pattern" "$file" || fail "expected $file to contain: $pattern"
}

write_fake_gh() {
  local bin_dir="$1"

  mkdir -p "$bin_dir"
  cat >"$bin_dir/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == "auth" && "$2" == "status" ]]; then
  exit 0
fi

if [[ "$1" == "api" && "$*" == *"rate_limit"* ]]; then
  printf 'remaining=4999 limit=5000 reset=9999999999\n'
  exit 0
fi

if [[ "$1" == "api" && "$*" == *"/pulls/1"* ]]; then
  printf 'closed\n'
  exit 0
fi

echo "fake gh: unsupported arguments: $*" >&2
exit 98
FAKE_GH
  chmod +x "$bin_dir/gh"
}

write_config() {
  local config="$1"
  local root="$2"

  cat >"$config" <<JSON
{
  "owner": "org",
  "reviewer": "doctor-reviewer",
  "workspace": "$root/workspace",
  "worktreeRoot": "$root/runtime/worktrees",
  "runtimeRoot": "$root/runtime",
  "logRoot": "$root/logs",
  "stateFile": "$root/state/reviews.json",
  "pollSeconds": 300,
  "discoveryTimeoutSeconds": 1,
  "discoveryMaxAttempts": 1,
  "discoveryBackoffBaseSeconds": 1,
  "discoveryBackoffMaxSeconds": 1,
  "healthStaleSeconds": 900,
  "watchLogMaxBytes": 1024,
  "watchLogRetain": 1,
  "maintenanceWorktreeDays": 1,
  "maintenanceCheckEnvDays": 1,
  "maintenancePromptDays": 1,
  "maintenanceLogDays": 1,
  "maintenanceLegacyCloneDays": 1,
  "maintenanceClosedStateDays": 1,
  "maintenanceTempHours": 1,
  "localCheckNetwork": "deny",
  "repos": {},
  "localChecks": []
}
JSON
}

test_doctor() {
  local root="$TMP_ROOT/doctor"
  local config="$root/config.json"
  local fake_bin="$root/bin"
  local output="$root/doctor.out"
  local status_output="$root/status.out"
  local git_root="$root/git-root"
  local fake_watch="$root/fake-watch.sh"
  local pid_file="$root/runtime/watch.pid"
  local health_file="$root/runtime/health.json"
  local stale_pid
  local rc

  mkdir -p "$root/workspace" "$root/runtime/worktrees" "$root/logs" "$root/state" "$git_root"
  git init -q "$git_root"
  write_config "$config" "$root"
  write_fake_gh "$fake_bin"
  jq -n '{
    "org/sample#1": {
      head_sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      base_sha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      status:"clean",
      reviewed_at:"2026-07-01T00:00:00Z"
    }
  }' >"$root/state/reviews.json"

  PATH="$fake_bin:$PATH" \
    REVIEW_BOT_CONFIG="$config" \
    REVIEW_BOT_DOCTOR_REPO_ROOT="$git_root" \
    "$BOT_DIR/doctor.sh" >"$output"
  assert_contains "$output" "PASS config:"
  assert_contains "$output" "PASS reviewer: doctor-reviewer"
  assert_contains "$output" "PASS rate-limit: remaining=4999"
  assert_contains "$output" "WARN watcher: not running"
  assert_contains "$output" "review-bot doctor: 0 failure(s), 1 warning(s)"

  printf '[]\n' >"$root/state/reviews.json"
  set +e
  PATH="$fake_bin:$PATH" \
    REVIEW_BOT_CONFIG="$config" \
    REVIEW_BOT_DOCTOR_REPO_ROOT="$git_root" \
    "$BOT_DIR/doctor.sh" >"$output"
  rc="$?"
  set -e
  [[ "$rc" -eq 1 ]] || fail "doctor should fail for invalid state, got $rc"
  assert_contains "$output" "FAIL state: invalid record structure"

  jq -n '{
    "org/sample#1": {
      head_sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      base_sha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      status:"clean",
      reviewed_at:"2026-07-01T00:00:00Z"
    }
  }' >"$root/state/reviews.json"
  cat >"$fake_watch" <<'FAKE_WATCH'
#!/usr/bin/env bash
set -euo pipefail
trap 'exit 0' TERM INT
while true; do
  sleep 1
done
FAKE_WATCH
  chmod +x "$fake_watch"
  "$fake_watch" &
  WATCH_PID="$!"
  jq -n --argjson now "$(date +%s)" '{
    status:"ok",
    last_attempt_at:"now",
    last_attempt_epoch:$now,
    last_success_at:"now",
    last_success_epoch:$now,
    last_error:null,
    consecutive_failures:0,
    queue_count:0
  }' >"$health_file"

  rm -f "$pid_file"
  PATH="$fake_bin:$PATH" \
    REVIEW_BOT_CONFIG="$config" \
    REVIEW_BOT_DOCTOR_REPO_ROOT="$git_root" \
    REVIEW_BOT_WATCH_SCRIPT="$fake_watch" \
    "$BOT_DIR/doctor.sh" >"$output"
  assert_contains "$output" "PASS watcher: pid $WATCH_PID"
  [[ "$(<"$pid_file")" == "$WATCH_PID" ]] ||
    fail "doctor should restore a missing watcher pid file"

  stale_pid=999999
  while kill -0 "$stale_pid" >/dev/null 2>&1; do
    stale_pid="$((stale_pid - 1))"
  done
  printf '%s\n' "$stale_pid" >"$pid_file"
  PATH="$fake_bin:$PATH" \
    REVIEW_BOT_CONFIG="$config" \
    REVIEW_BOT_DOCTOR_REPO_ROOT="$git_root" \
    REVIEW_BOT_WATCH_SCRIPT="$fake_watch" \
    "$BOT_DIR/doctor.sh" >"$output"
  assert_contains "$output" "PASS watcher: pid $WATCH_PID"
  [[ "$(<"$pid_file")" == "$WATCH_PID" ]] ||
    fail "doctor should replace a stale watcher pid file"

  printf '{\n' >"$health_file"
  set +e
  PATH="$fake_bin:$PATH" \
    REVIEW_BOT_CONFIG="$config" \
    REVIEW_BOT_DOCTOR_REPO_ROOT="$git_root" \
    REVIEW_BOT_WATCH_SCRIPT="$fake_watch" \
    "$BOT_DIR/doctor.sh" >"$output"
  rc="$?"
  set -e
  [[ "$rc" -eq 1 ]] || fail "doctor should fail for malformed watcher health, got $rc"
  assert_contains "$output" "FAIL watcher: invalid health file"
  assert_contains "$output" "review-bot doctor: 1 failure(s), 0 warning(s)"

  jq -n --argjson now "$(date +%s)" '{
    status:"ok",
    last_success_epoch:$now,
    consecutive_failures:0,
    queue_count:0
  }' >"$health_file"
  set +e
  PATH="$fake_bin:$PATH" \
    REVIEW_BOT_CONFIG="$config" \
    REVIEW_BOT_DOCTOR_REPO_ROOT="$git_root" \
    REVIEW_BOT_WATCH_SCRIPT="$fake_watch" \
    "$BOT_DIR/doctor.sh" >"$output"
  rc="$?"
  set -e
  [[ "$rc" -eq 1 ]] || fail "doctor should fail for truncated watcher health, got $rc"
  assert_contains "$output" "FAIL watcher: invalid health file"

  jq -n --argjson now "$(date +%s)" '{
    status:"ok",
    last_attempt_at:"now",
    last_attempt_epoch:$now,
    last_success_at:"now",
    last_success_epoch:1.5,
    last_error:null,
    consecutive_failures:0,
    queue_count:0
  }' >"$health_file"
  set +e
  PATH="$fake_bin:$PATH" \
    REVIEW_BOT_CONFIG="$config" \
    REVIEW_BOT_DOCTOR_REPO_ROOT="$git_root" \
    REVIEW_BOT_WATCH_SCRIPT="$fake_watch" \
    "$BOT_DIR/doctor.sh" >"$output"
  rc="$?"
  set -e
  [[ "$rc" -eq 1 ]] || fail "doctor should fail for fractional watcher epoch, got $rc"
  assert_contains "$output" "FAIL watcher: invalid health file"
  assert_contains "$output" "review-bot doctor: 1 failure(s), 0 warning(s)"

  jq -n '{
    status:"ok",
    last_attempt_at:"now",
    last_attempt_epoch:1e100,
    last_success_at:"now",
    last_success_epoch:1e100,
    last_error:null,
    consecutive_failures:0,
    queue_count:0
  }' >"$health_file"
  set +e
  PATH="$fake_bin:$PATH" \
    REVIEW_BOT_CONFIG="$config" \
    REVIEW_BOT_DOCTOR_REPO_ROOT="$git_root" \
    REVIEW_BOT_WATCH_SCRIPT="$fake_watch" \
    "$BOT_DIR/doctor.sh" >"$output" 2>&1
  rc="$?"
  set -e
  [[ "$rc" -eq 1 ]] || fail "doctor should fail for oversized watcher epochs, got $rc"
  assert_contains "$output" "FAIL watcher: invalid health file"
  assert_contains "$output" "review-bot doctor: 1 failure(s), 0 warning(s)"

  set +e
  REVIEW_BOT_CONFIG="$config" \
    REVIEW_BOT_WATCH_SCRIPT="$fake_watch" \
    "$BOT_DIR/status.sh" >"$status_output" 2>&1
  rc="$?"
  set -e
  [[ "$rc" -eq 1 ]] || fail "status should fail for oversized watcher epochs, got $rc"
  assert_contains "$status_output" "health error; invalid health file"
  if grep -Fq "value too great for base" "$status_output"; then
    fail "status must reject oversized epochs before Bash arithmetic"
  fi

  kill "$WATCH_PID"
  wait "$WATCH_PID"
  WATCH_PID=""
}

test_maintenance() {
  local root="$TMP_ROOT/maintenance"
  local config="$root/config.json"
  local fake_bin="$root/bin"
  local runtime="$root/runtime"
  local logs="$root/logs"
  local state="$root/state/reviews.json"
  local queue="$runtime/queue.jsonl"
  local current_prompt="$runtime/prompts/current.md"
  local old_prompt="$runtime/prompts/old.md"
  local active_worktree="$runtime/worktrees/sample/pr-3-active"
  local protected_worktree_temp="$active_worktree/.reviews.keep"
  local active_check_env="$runtime/check-env/sample/pr-3-active"
  local protected_check_env_temp="$active_check_env/.prompt.keep"
  local active_log="$logs/sample/pr-3-active"
  local escaped_prompt_dir="$root/outside-prompts"
  local escaped_prompt="$escaped_prompt_dir/old.md"
  local output="$root/maintenance.out"
  local lock_marker="$root/lock-held"
  local lock_pid
  local rc

  mkdir -p \
    "$root/workspace/sample" "$runtime/prompts" "$runtime/check-env/sample/pr-2-old" \
    "$active_check_env" "$runtime/worktrees/sample" "$active_worktree" \
    "$runtime/repos/legacy" "$runtime/locks/worktree-leases/org-sample" \
    "$logs/sample/pr-1-state" "$logs/sample/pr-2-old" "$active_log" \
    "$escaped_prompt_dir" "$root/state"
  git init -q "$root/workspace/sample"
  write_config "$config" "$root"
  write_fake_gh "$fake_bin"

  printf 'current prompt\n' >"$current_prompt"
  printf 'old prompt\n' >"$old_prompt"
  printf 'old temp\n' >"$runtime/.queue.orphan"
  printf 'old health temp\n' >"$runtime/.health.orphan"
  printf 'old prompt temp\n' >"$runtime/prompts/.prompt.orphan"
  printf 'old state temp\n' >"$root/state/.reviews.orphan"
  printf 'protected worktree temp\n' >"$protected_worktree_temp"
  printf 'legacy\n' >"$runtime/repos/legacy/data"
  printf 'old check env\n' >"$runtime/check-env/sample/pr-2-old/data"
  printf 'active check env\n' >"$active_check_env/data"
  printf 'protected check env temp\n' >"$protected_check_env_temp"
  printf 'state log\n' >"$logs/sample/pr-1-state/report.md"
  printf 'old log\n' >"$logs/sample/pr-2-old/report.md"
  printf 'active log\n' >"$active_log/report.md"
  printf 'escaped prompt\n' >"$escaped_prompt"
  printf '%s\t%s\n' "$$" "$active_worktree" \
    >"$runtime/locks/worktree-leases/org-sample/pr-3-active.lease"
  printf '999999\t%s\n' "$runtime/worktrees/sample/pr-9-stale" \
    >"$runtime/locks/worktree-leases/org-sample/pr-9-stale.lease"

  jq -cn --arg prompt "$current_prompt" \
    '{owner:"org",repo:"sample",number:4,head_sha:"cccccccccccccccccccccccccccccccccccccccc",prompt:$prompt}' \
    >"$queue"
  jq -n --arg report "$logs/sample/pr-1-state/report.md" '{
    "org/sample#1": {
      head_sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      base_sha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      status:"clean",
      report:$report,
      reviewed_at:"2020-01-01T00:00:00Z"
    }
  }' >"$state"

  find \
    "$old_prompt" "$runtime/.queue.orphan" "$runtime/.health.orphan" \
    "$runtime/prompts/.prompt.orphan" "$root/state/.reviews.orphan" \
    "$protected_worktree_temp" "$protected_check_env_temp" \
    "$escaped_prompt" "$runtime/repos/legacy" \
    "$runtime/check-env/sample/pr-2-old" "$logs/sample/pr-1-state" \
    "$logs/sample/pr-2-old" \
    -exec touch -d '3 days ago' {} +

  PATH="$fake_bin:$PATH" REVIEW_BOT_CONFIG="$config" \
    "$BOT_DIR/maintain.sh" >"$output"
  assert_contains "$output" "would remove closed state entry: org/sample#1"
  assert_contains "$output" "would remove prompt: $old_prompt"
  assert_contains "$output" "would remove check environment: $runtime/check-env/sample/pr-2-old"
  assert_contains "$output" "would remove legacy runtime clone: $runtime/repos/legacy"
  [[ -e "$old_prompt" && -e "$runtime/repos/legacy" ]] ||
    fail "dry-run must not remove artifacts"
  jq -e 'has("org/sample#1")' "$state" >/dev/null ||
    fail "dry-run must not modify state"

  PATH="$fake_bin:$PATH" REVIEW_BOT_CONFIG="$config" \
    "$BOT_DIR/maintain.sh" --apply >"$output"
  [[ ! -e "$old_prompt" ]] || fail "apply should remove old unqueued prompts"
  [[ ! -e "$runtime/check-env/sample/pr-2-old" ]] || fail "apply should remove old check environments"
  [[ ! -e "$logs/sample/pr-1-state" && ! -e "$logs/sample/pr-2-old" ]] ||
    fail "apply should remove obsolete logs after closed state pruning"
  [[ ! -e "$runtime/repos/legacy" ]] || fail "apply should remove old legacy runtime clones"
  [[ ! -e "$runtime/.queue.orphan" ]] || fail "apply should remove old temporary files"
  [[ ! -e "$runtime/.health.orphan" && ! -e "$runtime/prompts/.prompt.orphan" &&
    ! -e "$root/state/.reviews.orphan" ]] ||
    fail "apply should prune bot temporary files only from their owning directories"
  [[ ! -e "$runtime/locks/worktree-leases/org-sample/pr-9-stale.lease" ]] ||
    fail "apply should remove stale leases"
  [[ -e "$current_prompt" && -e "$queue" && -e "$state" ]] ||
    fail "maintenance must preserve the current queue and state files"
  [[ -e "$active_worktree" && -e "$active_check_env" && -e "$active_log" ]] ||
    fail "maintenance must preserve active leased artifacts"
  [[ -e "$protected_worktree_temp" ]] ||
    fail "maintenance must not recursively delete temporary-looking files in worktrees"
  [[ -e "$protected_check_env_temp" ]] ||
    fail "maintenance must not recursively delete temporary-looking files in check environments"
  jq -e 'has("org/sample#1") | not' "$state" >/dev/null ||
    fail "apply should prune old closed PR state"

  (
    exec 9>"$runtime/maintenance.lock"
    flock 9
    touch "$lock_marker"
    sleep 30
  ) &
  lock_pid="$!"
  for _ in {1..30}; do
    [[ -f "$lock_marker" ]] && break
    sleep 0.1
  done
  [[ -f "$lock_marker" ]] || fail "maintenance lock holder did not start"
  set +e
  PATH="$fake_bin:$PATH" REVIEW_BOT_CONFIG="$config" \
    "$BOT_DIR/maintain.sh" >"$output" 2>&1
  rc="$?"
  set -e
  kill "$lock_pid" >/dev/null 2>&1 || true
  wait "$lock_pid" >/dev/null 2>&1 || true
  [[ "$rc" -eq 1 ]] || fail "second maintenance process should fail on lock contention, got $rc"
  assert_contains "$output" "maintenance is already running"

  set +e
  PATH="$fake_bin:$PATH" REVIEW_BOT_CONFIG="$config" \
    REVIEW_BOT_PROMPT_DIR="$runtime/../outside-prompts" \
    "$BOT_DIR/maintain.sh" --apply >"$output" 2>&1
  rc="$?"
  set -e
  [[ "$rc" -eq 2 ]] || fail "escaped prompt root should be rejected, got $rc"
  assert_contains "$output" "runtime cleanup path must stay under runtimeRoot"
  [[ -e "$escaped_prompt" ]] ||
    fail "maintenance must not delete through a cleanup root that escapes runtimeRoot"

  ln -s "$escaped_prompt_dir" "$runtime/alias-prompts"
  set +e
  PATH="$fake_bin:$PATH" REVIEW_BOT_CONFIG="$config" \
    REVIEW_BOT_PROMPT_DIR="$runtime/alias-prompts" \
    "$BOT_DIR/maintain.sh" --apply >"$output" 2>&1
  rc="$?"
  set -e
  [[ "$rc" -eq 2 ]] || fail "symlink-escaped prompt root should be rejected, got $rc"
  assert_contains "$output" "runtime cleanup path must stay under runtimeRoot"
  [[ -e "$escaped_prompt" ]] ||
    fail "maintenance must not delete through a symlinked cleanup root"
}

test_maintenance_fail_closed() {
  local root="$TMP_ROOT/fail-closed"
  local config="$root/config.json"
  local fake_bin="$root/bin"
  local runtime="$root/runtime"
  local logs="$root/logs"
  local state="$root/state/reviews.json"
  local queue="$runtime/queue.jsonl"
  local old_prompt="$runtime/prompts/old.md"
  local queued_check_env="$runtime/check-env/sample/pr-1-aaaaaaaaaaaa"
  local linked_log="$logs/sample/pr-1-current/report.md"
  local stale_lease="$runtime/locks/worktree-leases/org-sample/pr-9-stale.lease"
  local output="$root/maintenance.out"
  local rc

  mkdir -p \
    "$root/workspace/sample" "$runtime/prompts" "$queued_check_env" \
    "$(dirname "$stale_lease")" "$(dirname "$linked_log")" "$root/state"
  git init -q "$root/workspace/sample"
  write_config "$config" "$root"
  write_fake_gh "$fake_bin"
  printf 'old prompt\n' >"$old_prompt"
  printf 'queued check environment\n' >"$queued_check_env/data"
  printf 'linked report\n' >"$linked_log"
  printf '999999\t%s\n' "$runtime/worktrees/sample/pr-9-stale" >"$stale_lease"
  touch -d '3 days ago' \
    "$old_prompt" "$queued_check_env" "$(dirname "$linked_log")" "$stale_lease"

  jq -n --arg report "$linked_log" '{
    "org/sample#1": {
      status:"clean",
      report:$report,
      reviewed_at:"2020-01-01T00:00:00Z"
    }
  }' >"$state"
  set +e
  PATH="$fake_bin:$PATH" REVIEW_BOT_CONFIG="$config" \
    "$BOT_DIR/maintain.sh" --apply >"$output" 2>&1
  rc="$?"
  set -e
  [[ "$rc" -eq 1 ]] || fail "invalid state should abort maintenance, got $rc"
  assert_contains "$output" "invalid state file; refusing maintenance"
  [[ -e "$old_prompt" && -e "$queued_check_env" && -e "$linked_log" && -e "$stale_lease" ]] ||
    fail "invalid state must preserve all maintenance candidates"

  jq -n --arg report "$linked_log" '{
    "org/sample#1": {
      head_sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      base_sha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      status:"clean",
      report:$report,
      reviewed_at:"2020-01-01T00:00:00Z"
    }
  }' >"$state"
  {
    printf '%s\n' '{"invalid":true}'
    jq -cn --arg prompt "$old_prompt" '{
      owner:"org",
      repo:"sample",
      number:1,
      head_sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      prompt:$prompt
    }'
  } >"$queue"
  set +e
  PATH="$fake_bin:$PATH" REVIEW_BOT_CONFIG="$config" \
    "$BOT_DIR/maintain.sh" --apply >"$output" 2>&1
  rc="$?"
  set -e
  [[ "$rc" -eq 1 ]] || fail "invalid queue should abort maintenance, got $rc"
  assert_contains "$output" "invalid queue; refusing maintenance"
  jq -e 'has("org/sample#1")' "$state" >/dev/null ||
    fail "invalid queue must preserve queued PR state"
  [[ -e "$old_prompt" && -e "$queued_check_env" && -e "$linked_log" && -e "$stale_lease" ]] ||
    fail "invalid queue must preserve all maintenance candidates"

  jq -cn --arg prompt "$old_prompt" '{
    owner:"org",
    repo:"sample",
    number:1,
    head_sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    prompt:$prompt
  }' | tr -d '\n' >"$queue"
  PATH="$fake_bin:$PATH" REVIEW_BOT_CONFIG="$config" \
    "$BOT_DIR/maintain.sh" --apply >"$output" 2>&1
  [[ -e "$old_prompt" && -e "$queued_check_env" && -e "$linked_log" ]] ||
    fail "an unterminated valid queue record must protect its run artifacts"
  jq -e 'has("org/sample#1")' "$state" >/dev/null ||
    fail "an unterminated valid queue record must protect its PR state"
}

test_doctor
test_maintenance
test_maintenance_fail_closed

echo "maintenance-test: ok"
