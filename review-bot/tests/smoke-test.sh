#!/usr/bin/env bash
set -euo pipefail

BOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "smoke-test: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local pattern="$2"

  grep -Fq "$pattern" "$file" || fail "expected $file to contain: $pattern"
}

assert_not_contains() {
  local file="$1"
  local pattern="$2"

  if grep -Fq "$pattern" "$file"; then
    fail "expected $file not to contain: $pattern"
  fi
}

init_repo() {
  local repo="$1"

  git init -q "$repo"
  git -C "$repo" config user.email review-bot@example.invalid
  git -C "$repo" config user.name review-bot
  git -C "$repo" config commit.gpgsign false
}

commit_all() {
  local repo="$1"
  local message="$2"

  git -C "$repo" add .
  git -C "$repo" commit -q -m "$message"
}

test_pedantic_diff_check() {
  local repo="$TMP_ROOT/pedantic"
  local output="$TMP_ROOT/pedantic.out"
  local rc
  local base
  local head

  init_repo "$repo"
  printf 'export const ok = 1;\n' >"$repo/wallet.ts"
  commit_all "$repo" "base"
  base="$(git -C "$repo" rev-parse HEAD)"

  mkdir -p "$repo/docs"
  {
    printf 'console.error("wrong password", err);\n'
    printf 'console.log("mnemonic", userMnemonic);\n'
    printf 'console.log({\n'
    printf '  mnemonic: userMnemonic,\n'
    printf '});\n'
    printf 'localStorage.setItem("seed", seedPhrase);\n'
    printf 'const fee = Number(lovelaceAmount);\n'
    printf 'const assetQuantity = tokenAmount.toNumber(lovelaceAmount);\n'
    printf 'dangerouslySetInnerHTML={{__html: html}};\n'
  } >>"$repo/wallet.ts"
  printf 'const mnemonic = "test test test test test test test test test test test junk";\n' >"$repo/docs/security.md"
  printf '{"permissions":["<all_urls>"]}\n' >"$repo/manifest.json"
  commit_all "$repo" "head"
  head="$(git -C "$repo" rev-parse HEAD)"

  set +e
  (
    cd "$repo"
    REVIEW_BOT_BASE_SHA="$base" REVIEW_BOT_HEAD_SHA="$head" "$BOT_DIR/pedantic-diff-check.sh"
  ) >"$output" 2>&1
  rc="$?"
  set -e

  [[ "$rc" -eq 1 ]] || fail "pedantic diff check should fail on wallet hazards, got $rc"
  assert_contains "$output" "possible sensitive wallet material in logging or telemetry"
  assert_contains "$output" "secret material written to unsafe storage, clipboard, or URL surface"
  assert_contains "$output" "plain numeric conversion near monetary value"
  assert_contains "$output" "raw HTML injection surface added"
  assert_contains "$output" "extension permission or CSP surface expanded"
  assert_contains "$output" "hardcoded wallet secret material added"
  assert_not_contains "$output" "wrong password"
}

test_pedantic_diff_check_ignores_low_signal_paths() {
  local repo="$TMP_ROOT/pedantic-skip"
  local output="$TMP_ROOT/pedantic-skip.out"
  local rc
  local base
  local head

  init_repo "$repo"
  printf '{}\n' >"$repo/package.json"
  commit_all "$repo" "base"
  base="$(git -C "$repo" rev-parse HEAD)"

  mkdir -p "$repo/docs" "$repo/tests/fixtures"
  printf 'dangerouslySetInnerHTML={{__html: html}}\n' >"$repo/docs/example.md"
  printf '{"privateKey":"not-real"}\n' >"$repo/package-lock.json"
  printf 'const mnemonic = "test test test test test test test test test test test junk";\n' >"$repo/tests/fixtures/wallet.ts"
  commit_all "$repo" "head"
  head="$(git -C "$repo" rev-parse HEAD)"

  set +e
  (
    cd "$repo"
    REVIEW_BOT_BASE_SHA="$base" REVIEW_BOT_HEAD_SHA="$head" "$BOT_DIR/pedantic-diff-check.sh"
  ) >"$output" 2>&1
  rc="$?"
  set -e

  [[ "$rc" -eq 0 ]] || fail "pedantic diff check should ignore low-signal paths, got $rc"
  assert_not_contains "$output" "pedantic wallet diff check"
}

write_fake_gh() {
  local bin_dir="$1"

  mkdir -p "$bin_dir"
  cat >"$bin_dir/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == "pr" && "$2" == "view" ]]; then
  if [[ "$*" == *"statusCheckRollup"* ]]; then
    printf '[{"name":"ci","conclusion":"SUCCESS"}]\n'
    exit 0
  fi
  printf '{"number":1,"title":"Smoke PR","url":"https://example.invalid/pr/1","headRefOid":"%s","headRefName":"feature","baseRefName":"main","isDraft":false,"author":{"login":"tester"}}\n' "$FAKE_HEAD_SHA"
  exit 0
fi

if [[ "$1" == "api" ]]; then
  if [[ "$2" == "user" ]]; then
    printf 'fake-reviewer\n'
    exit 0
  fi

  if [[ "$*" == *"/search/issues"* ]]; then
    printf '%s\n' "${FAKE_SEARCH_ROW:-}"
    exit 0
  fi

  if [[ "$*" == *"/repos/org/sample/issues/1"* ]]; then
    printf '{"user":{"login":"tester"},"assignees":[]}\n'
    exit 0
  fi

  if [[ "$*" == *"/repos/org/sample/pulls/1/reviews"* ]]; then
    if [[ "${FAKE_ALLOW_POST:-0}" != "1" ]]; then
      echo "fake gh should not approve during dry-run" >&2
      exit 99
    fi
    : "${FAKE_GH_CALL_LOG:?FAKE_GH_CALL_LOG is required when posting}"
    printf '%s\n' "$*" >>"$FAKE_GH_CALL_LOG"
    if [[ "$*" != *"event=APPROVE"* ]]; then
      echo "fake gh: clean reviews must use event=APPROVE" >&2
      exit 97
    fi
    printf 'https://example.invalid/reviews/approve\n'
    exit 0
  fi

  if [[ "$*" == *"/repos/org/sample/pulls/1"* ]]; then
    if [[ "$*" == *"--jq .base.sha"* ]]; then
      printf '%s\n' "$FAKE_BASE_SHA"
    else
      if [[ "${FAKE_REVIEW_REQUESTED:-1}" == "1" ]]; then
        printf '{"head":{"sha":"%s"},"base":{"sha":"%s"},"requested_reviewers":[{"login":"wolf31o2"}]}\n' "$FAKE_HEAD_SHA" "$FAKE_BASE_SHA"
      else
        printf '{"head":{"sha":"%s"},"base":{"sha":"%s"},"requested_reviewers":[]}\n' "$FAKE_HEAD_SHA" "$FAKE_BASE_SHA"
      fi
    fi
    exit 0
  fi

  echo "fake gh: unsupported api arguments: $*" >&2
  exit 98
fi

if [[ "$1" == "pr" && { "$2" == "comment" || "$2" == "review"; } ]]; then
  echo "fake gh should not post during dry-run" >&2
  exit 99
fi

echo "fake gh: unsupported arguments: $*" >&2
exit 98
FAKE_GH
  chmod +x "$bin_dir/gh"
}

test_review_one_dry_run_and_timeout() {
  local origin="$TMP_ROOT/origin/sample.git"
  local seed="$TMP_ROOT/seed"
  local workspace="$TMP_ROOT/workspace"
  local config="$TMP_ROOT/config.json"
  local state="$TMP_ROOT/state.json"
  local output="$TMP_ROOT/review-one.out"
  local fake_bin="$TMP_ROOT/bin"
  local base
  local head
  local new_head
  local clean_head
  local expected_report_line
  local calls="$TMP_ROOT/gh-calls.log"
  local rc

  mkdir -p "$(dirname "$origin")"
  git init -q --bare "$origin"
  init_repo "$seed"
  git -C "$seed" remote add origin "$origin"
  printf 'export const ok = 1;\n' >"$seed/index.ts"
  commit_all "$seed" "base"
  base="$(git -C "$seed" rev-parse HEAD)"
  git -C "$seed" push -q origin HEAD:refs/heads/main
  git --git-dir="$origin" symbolic-ref HEAD refs/heads/main
  printf 'export const stillOk = 2;\n' >>"$seed/index.ts"
  commit_all "$seed" "head"
  head="$(git -C "$seed" rev-parse HEAD)"
  git -C "$seed" push -q origin HEAD:refs/heads/feature
  git -C "$seed" push -q origin HEAD:refs/pull/1/head

  mkdir -p "$workspace"
  git clone -q "$origin" "$workspace/sample"
  write_fake_gh "$fake_bin"

  cat >"$config" <<JSON
{
  "owner": "org",
  "reviewer": "wolf31o2",
  "workspace": "$workspace",
  "worktreeRoot": "$TMP_ROOT/worktrees",
  "logRoot": "$TMP_ROOT/logs",
  "stateFile": "$state",
  "pollSeconds": 300,
  "checkTimeoutSeconds": 1,
  "commentMode": "comment",
  "includeDrafts": false,
  "repos": {
    "sample": {
      "localChecks": ["sleep 5"]
    }
  },
  "localChecks": ["true"]
}
JSON
  printf '{}\n' >"$state"

  set +e
  PATH="$fake_bin:$PATH" \
    FAKE_REVIEW_REQUESTED=0 \
    FAKE_BASE_SHA="$base" \
    FAKE_HEAD_SHA="$head" \
    REVIEW_BOT_CONFIG="$config" \
    REVIEW_BOT_POST=0 \
    REVIEW_BOT_LOCK_ROOT="$TMP_ROOT/locks" \
    "$BOT_DIR/review-one.sh" sample 1 >"$output" 2>&1
  rc="$?"
  set -e

  [[ "$rc" -eq 0 ]] || fail "not-requested review-one should exit 0, got $rc"
  assert_contains "$output" "skipping org/sample#1 because wolf31o2 is not a requested reviewer"
  jq -e 'length == 0' "$state" >/dev/null || fail "not-requested PR should not update state"

  set +e
  PATH="$fake_bin:$PATH" \
    FAKE_BASE_SHA="$base" \
    FAKE_HEAD_SHA="$head" \
    REVIEW_BOT_CONFIG="$config" \
    REVIEW_BOT_POST=0 \
    REVIEW_BOT_LOCK_ROOT="$TMP_ROOT/locks" \
    "$BOT_DIR/review-one.sh" sample 1 >"$output" 2>&1
  rc="$?"
  set -e

  [[ "$rc" -eq 0 ]] || fail "review-one dry-run should exit 0, got $rc"
  assert_contains "$output" "dry run; state not updated"
  jq -e 'length == 0' "$state" >/dev/null || fail "dry-run without opt-in should not update state"
  assert_contains "$TMP_ROOT/logs/sample/pr-1-${head:0:12}/sleep_5.log" "check timed out after 1 seconds"

  PATH="$fake_bin:$PATH" \
    FAKE_BASE_SHA="$base" \
    FAKE_HEAD_SHA="$head" \
    REVIEW_BOT_CONFIG="$config" \
    REVIEW_BOT_POST=0 \
    REVIEW_BOT_RECORD_DRY_RUN=1 \
    REVIEW_BOT_LOCK_ROOT="$TMP_ROOT/locks" \
    "$BOT_DIR/review-one.sh" sample 1 >"$output" 2>&1

  jq -e --arg head "$head" '."org/sample#1".head_sha == $head and ."org/sample#1".status == "findings"' "$state" >/dev/null ||
    fail "dry-run with REVIEW_BOT_RECORD_DRY_RUN=1 should update state"

  PATH="$fake_bin:$PATH" \
    FAKE_BASE_SHA="$base" \
    FAKE_HEAD_SHA="$head" \
    REVIEW_BOT_CONFIG="$config" \
    REVIEW_BOT_POST=0 \
    REVIEW_BOT_RECORD_DRY_RUN=1 \
    REVIEW_BOT_LOCK_ROOT="$TMP_ROOT/locks" \
    "$BOT_DIR/review-one.sh" sample 1 >"$output" 2>&1
  assert_contains "$output" "already reviewed at $head"

  printf 'export const afterPush = 3;\n' >>"$seed/index.ts"
  commit_all "$seed" "new head"
  new_head="$(git -C "$seed" rev-parse HEAD)"
  git -C "$seed" push -q origin HEAD:refs/heads/feature
  git -C "$seed" push -q origin HEAD:refs/pull/1/head

  PATH="$fake_bin:$PATH" \
    FAKE_BASE_SHA="$base" \
    FAKE_HEAD_SHA="$new_head" \
    REVIEW_BOT_CONFIG="$config" \
    REVIEW_BOT_POST=0 \
    REVIEW_BOT_RECORD_DRY_RUN=1 \
    REVIEW_BOT_LOCK_ROOT="$TMP_ROOT/locks" \
    "$BOT_DIR/review-one.sh" sample 1 >"$output" 2>&1

  jq -e --arg head "$new_head" '."org/sample#1".head_sha == $head and ."org/sample#1".status == "findings"' "$state" >/dev/null ||
    fail "new PR head should be reviewed again and update state"
  assert_contains "$TMP_ROOT/logs/sample/pr-1-${new_head:0:12}/sleep_5.log" "check timed out after 1 seconds"

  cat >"$config" <<JSON
{
  "owner": "org",
  "reviewer": "wolf31o2",
  "workspace": "$workspace",
  "worktreeRoot": "$TMP_ROOT/worktrees",
  "logRoot": "$TMP_ROOT/logs",
  "stateFile": "$state",
  "pollSeconds": 300,
  "checkTimeoutSeconds": 1,
  "commentMode": "comment",
  "includeDrafts": false,
  "repos": {
    "sample": {
      "localChecks": ["true"]
    }
  },
  "localChecks": ["true"]
}
JSON

  printf 'export const cleanOk = 4;\n' >>"$seed/index.ts"
  commit_all "$seed" "clean head"
  clean_head="$(git -C "$seed" rev-parse HEAD)"
  git -C "$seed" push -q origin HEAD:refs/heads/feature
  git -C "$seed" push -q origin HEAD:refs/pull/1/head

  PATH="$fake_bin:$PATH" \
    FAKE_BASE_SHA="$base" \
    FAKE_HEAD_SHA="$clean_head" \
    REVIEW_BOT_CONFIG="$config" \
    REVIEW_BOT_POST=0 \
    REVIEW_BOT_RECORD_DRY_RUN=1 \
    REVIEW_BOT_LOCK_ROOT="$TMP_ROOT/locks" \
    "$BOT_DIR/review-one.sh" sample 1 >"$output" 2>&1

  jq -e --arg head "$clean_head" '."org/sample#1".head_sha == $head and ."org/sample#1".status == "clean"' "$state" >/dev/null ||
    fail "clean new PR head should update state with clean status"
  printf -v expected_report_line 'No local review-specific issues found for `%s`.' "$clean_head"
  assert_contains "$TMP_ROOT/logs/sample/pr-1-${clean_head:0:12}/report.md" "$expected_report_line"
  assert_contains "$TMP_ROOT/logs/sample/pr-1-${clean_head:0:12}/report.md" "GitHub CI/checks: \`passing\`."

  : >"$calls"
  PATH="$fake_bin:$PATH" \
    FAKE_ALLOW_POST=1 \
    FAKE_BASE_SHA="$base" \
    FAKE_HEAD_SHA="$clean_head" \
    FAKE_GH_CALL_LOG="$calls" \
    REVIEW_BOT_CONFIG="$config" \
    REVIEW_BOT_FORCE=1 \
    REVIEW_BOT_POST=1 \
    REVIEW_BOT_LOCK_ROOT="$TMP_ROOT/locks" \
    "$BOT_DIR/review-one.sh" sample 1 >"$output" 2>&1

  assert_contains "$output" "https://example.invalid/reviews/approve"
  assert_contains "$output" "review-bot: approved org/sample#1"
  assert_contains "$calls" "/repos/org/sample/pulls/1/reviews"
  assert_contains "$calls" "event=APPROVE"
  jq -e '."org/sample#1".comment_url == "https://example.invalid/reviews/approve"' "$state" >/dev/null ||
	    fail "clean posted review should record approval URL"
}

test_list_queue_json_and_prompt_base_key() {
  local config="$TMP_ROOT/queue-config.json"
  local fake_bin="$TMP_ROOT/queue-bin"
  local output="$TMP_ROOT/list-queue.out"
  local runtime="$TMP_ROOT/queue-runtime"
  local state="$TMP_ROOT/queue-state.json"
  local title
  local row
  local base="baseabcdef1234567890"
  local head="headabcdef1234567890"

  write_fake_gh "$fake_bin"
  title=$'Bump odd\\title with tab\tand newline\ninside'
  row="$(jq -cn --arg title "$title" \
    '{repo:"sample", number:1, url:"https://example.invalid/pr/1", author:"tester", title:$title}' |
    base64 |
    tr -d '\n')"

  cat >"$config" <<JSON
{
  "owner": "org",
  "reviewer": "wolf31o2",
  "runtimeRoot": "$runtime",
  "worktreeRoot": "$TMP_ROOT/queue-worktrees",
  "logRoot": "$TMP_ROOT/queue-logs",
  "stateFile": "$state",
  "pollSeconds": 300,
  "includeDrafts": false,
  "repos": {},
  "localChecks": []
}
JSON
  jq -n --arg head "$head" --arg base "$base" \
    '{"org/sample#1":{head_sha:$head, base_sha:$base, review_kind:"check", status:"findings"}}' >"$state"

  PATH="$fake_bin:$PATH" \
    FAKE_SEARCH_ROW="$row" \
    FAKE_BASE_SHA="$base" \
    FAKE_HEAD_SHA="$head" \
    REVIEW_BOT_CONFIG="$config" \
    "$BOT_DIR/list-queue.sh" pending >"$output"

  jq -e --arg title "$title" '.title == $title and .needs_review == true' "$output" >/dev/null ||
    fail "list-queue should preserve escaped JSON title and keep check-only state pending"

  PATH="$fake_bin:$PATH" \
    FAKE_SEARCH_ROW="$row" \
    FAKE_BASE_SHA="$base" \
    FAKE_HEAD_SHA="$head" \
    REVIEW_BOT_CONFIG="$config" \
    "$BOT_DIR/run-once.sh" >"$output"
  assert_contains "$output" "org-sample-1-${base:0:12}-${head:0:12}.md"
  assert_contains "$runtime/queue.jsonl" "org-sample-1-${base:0:12}-${head:0:12}.md"

  jq -n --arg head "$head" --arg base "$base" \
    '{"org/sample#1":{head_sha:$head, base_sha:$base, review_kind:"semantic", status:"findings"}}' >"$state"

  PATH="$fake_bin:$PATH" \
    FAKE_SEARCH_ROW="$row" \
    FAKE_BASE_SHA="$base" \
    FAKE_HEAD_SHA="$head" \
    REVIEW_BOT_CONFIG="$config" \
    "$BOT_DIR/list-queue.sh" pending >"$output"
  [[ ! -s "$output" ]] || fail "semantic state for same head/base should suppress pending queue"
}

test_record_review_rejects_moved_pr() {
  local config="$TMP_ROOT/record-config.json"
  local fake_bin="$TMP_ROOT/record-bin"
  local state="$TMP_ROOT/record-state.json"
  local output="$TMP_ROOT/record.out"
  local current_head="current-head-sha"
  local reviewed_head="reviewed-head-sha"
  local base="base-sha"
  local rc

  write_fake_gh "$fake_bin"
  cat >"$config" <<JSON
{
  "owner": "org",
  "reviewer": "wolf31o2",
  "runtimeRoot": "$TMP_ROOT/record-runtime",
  "stateFile": "$state"
}
JSON

  set +e
  PATH="$fake_bin:$PATH" \
    FAKE_BASE_SHA="$base" \
    FAKE_HEAD_SHA="$current_head" \
    REVIEW_BOT_CONFIG="$config" \
    "$BOT_DIR/record-review.sh" sample 1 clean https://example.invalid/review "$reviewed_head" "$base" >"$output" 2>&1
  rc="$?"
  set -e

  [[ "$rc" -eq 1 ]] || fail "record-review should reject moved PR head, got $rc"
  assert_contains "$output" "refusing to record org/sample#1; PR head moved"
  [[ ! -f "$state" ]] || jq -e 'length == 0' "$state" >/dev/null || fail "moved PR should not update state"

  PATH="$fake_bin:$PATH" \
    FAKE_BASE_SHA="$base" \
    FAKE_HEAD_SHA="$current_head" \
    REVIEW_BOT_CONFIG="$config" \
    "$BOT_DIR/record-review.sh" sample 1 clean https://example.invalid/review "$current_head" "$base" >"$output" 2>&1

  jq -e --arg head "$current_head" --arg base "$base" \
    '."org/sample#1".head_sha == $head and ."org/sample#1".base_sha == $base and ."org/sample#1".review_kind == "semantic"' "$state" >/dev/null ||
    fail "record-review should record matching reviewed head/base"
}

test_portable_config_helpers() {
  local config="$TMP_ROOT/portable-config.json"
  local fake_bin="$TMP_ROOT/portable-bin"
  local repo_root="$TMP_ROOT/clanker"
  local resolved
  local reviewer
  local owner

  mkdir -p "$repo_root" "$fake_bin"
  cat >"$fake_bin/gh" <<'FAKE_GH_USER'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == "api" && "$2" == "user" ]]; then
  printf 'fake-reviewer\n'
  exit 0
fi

echo "fake gh: unsupported arguments: $*" >&2
exit 98
FAKE_GH_USER
  chmod +x "$fake_bin/gh"

  cat >"$config" <<JSON
{
  "owner": "configured-org",
  "reviewer": "",
  "workspace": "repos",
  "runtimeRoot": "review-bot/.runtime",
  "logRoot": "review-bot/logs",
  "stateFile": "review-bot/state/reviews.json",
  "repos": {
    "clanker": {
      "path": "."
    }
  }
}
JSON

  # shellcheck source=/dev/null
  source "$BOT_DIR/lib/paths.sh"

  resolved="$(review_bot_env_path "$repo_root" "" "$config" '.workspace' 'unused')"
  [[ "$resolved" == "$repo_root/repos" ]] ||
    fail "relative workspace should resolve under repo root, got $resolved"

  resolved="$(review_bot_repo_dir "$repo_root" "$repo_root/repos" "$config" 'clanker')"
  [[ "$resolved" == "$repo_root" ]] ||
    fail "configured repo path should resolve under repo root, got $resolved"

  resolved="$(review_bot_repo_dir "$repo_root" "$repo_root/repos" "$config" 'sample')"
  [[ "$resolved" == "$repo_root/repos/sample" ]] ||
    fail "unconfigured repo should resolve under workspace, got $resolved"

  resolved="$(review_bot_env_path "$repo_root" "$TMP_ROOT/external-repos" "$config" '.workspace' 'unused')"
  [[ "$resolved" == "$TMP_ROOT/external-repos" ]] ||
    fail "workspace env override should win, got $resolved"

  owner="$(REVIEW_BOT_OWNER=override-org review_bot_owner "$config")"
  [[ "$owner" == "override-org" ]] || fail "owner env override should win, got $owner"

  reviewer="$(PATH="$fake_bin:$PATH" review_bot_reviewer "$config")"
  [[ "$reviewer" == "fake-reviewer" ]] ||
    fail "blank reviewer should default to gh user, got $reviewer"

  reviewer="$(REVIEW_BOT_REVIEWER=override-reviewer PATH="$fake_bin:$PATH" review_bot_reviewer "$config")"
  [[ "$reviewer" == "override-reviewer" ]] ||
    fail "reviewer env override should win, got $reviewer"
}

test_agent_prompt_shared_standards_and_fallback() {
  local config="$TMP_ROOT/prompt-config.json"
  local fake_bin="$TMP_ROOT/prompt-bin"
  local output="$TMP_ROOT/prompt.out"
  local isolated_root="$TMP_ROOT/prompt-isolated"
  local base="baseabcdef1234567890"
  local head="headabcdef1234567890"

  write_fake_gh "$fake_bin"
  cat >"$config" <<JSON
{
  "owner": "org",
  "reviewer": "wolf31o2",
  "workspace": "$TMP_ROOT/prompt-workspace",
  "worktreeRoot": "$TMP_ROOT/prompt-worktrees",
  "logRoot": "$TMP_ROOT/prompt-logs",
  "stateFile": "$TMP_ROOT/prompt-state.json",
  "repos": {},
  "localChecks": []
}
JSON

  PATH="$fake_bin:$PATH" \
    FAKE_BASE_SHA="$base" \
    FAKE_HEAD_SHA="$head" \
    REVIEW_BOT_CONFIG="$config" \
    "$BOT_DIR/agent-prompt.sh" sample 1 >"$output"
  assert_contains "$output" "Treat every \`yoroi-classic\` repository as blockchain wallet code."
  assert_contains "$output" "Shared review standards:"

  mkdir -p "$isolated_root"
  cp -R "$BOT_DIR" "$isolated_root/review-bot"

  PATH="$fake_bin:$PATH" \
    FAKE_BASE_SHA="$base" \
    FAKE_HEAD_SHA="$head" \
    REVIEW_BOT_CONFIG="$config" \
    "$isolated_root/review-bot/agent-prompt.sh" sample 1 >"$output"
  assert_contains "$output" "Unavailable: standards/review.md was not found."
}

test_invalid_json_config_fails_closed() {
  local config="$TMP_ROOT/invalid-config.json"
  local output="$TMP_ROOT/invalid-config.out"
  local rc

  printf '{"owner":"org",\n' >"$config"

  set +e
  REVIEW_BOT_CONFIG="$config" "$BOT_DIR/watch.sh" once >"$output" 2>&1
  rc="$?"
  set -e

  [[ "$rc" -ne 0 ]] || fail "invalid JSON configuration should fail"
  assert_contains "$output" "parse error"
}

test_watch_interrupt_stops_active_poll() {
  local isolated_root="$TMP_ROOT/interrupt-root"
  local isolated_bot="$isolated_root/review-bot"
  local config="$TMP_ROOT/interrupt-config.json"
  local output="$TMP_ROOT/interrupt-watch.out"
  local child_pid_file="$TMP_ROOT/interrupt-child.pid"
  local watcher_pid
  local child_pid=""
  local rc

  mkdir -p "$isolated_root"
  cp -R "$BOT_DIR" "$isolated_bot"
  cat >"$isolated_bot/list-queue.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail
trap 'exit 0' TERM INT
printf '%s\n' "\$\$" >"$child_pid_file"
while true; do
  sleep 60 &
  wait "\$!"
done
SH
  chmod +x "$isolated_bot/list-queue.sh"

  cat >"$config" <<JSON
{
  "owner": "org",
  "reviewer": "wolf31o2",
  "runtimeRoot": "$TMP_ROOT/interrupt-runtime",
  "worktreeRoot": "$TMP_ROOT/interrupt-worktrees",
  "logRoot": "$TMP_ROOT/interrupt-logs",
  "stateFile": "$TMP_ROOT/interrupt-state.json",
  "pollSeconds": 300,
  "repos": {},
  "localChecks": []
}
JSON

  REVIEW_BOT_CONFIG="$config" "$isolated_bot/watch.sh" >"$output" 2>&1 &
  watcher_pid="$!"

  for _ in $(seq 1 50); do
    if [[ -s "$child_pid_file" ]]; then
      child_pid="$(<"$child_pid_file")"
      break
    fi
    sleep 0.1
  done

  if [[ -z "$child_pid" ]]; then
    kill -TERM "$watcher_pid" >/dev/null 2>&1 || true
    wait "$watcher_pid" >/dev/null 2>&1 || true
    fail "watcher did not start an active poll"
  fi

  kill -TERM "$watcher_pid"
  set +e
  wait "$watcher_pid"
  rc="$?"
  set -e

  [[ "$rc" -eq 0 ]] || fail "interrupted watcher should exit 0, got $rc"
  assert_contains "$output" "review-bot: watcher stopping"
  if kill -0 "$child_pid" >/dev/null 2>&1; then
    fail "interrupted watcher left poll child $child_pid running"
  fi
}

test_github_retry_backoff() {
  local fake_bin="$TMP_ROOT/retry-bin"
  local calls="$TMP_ROOT/retry-calls"
  local output="$TMP_ROOT/retry.out"

  mkdir -p "$fake_bin"
  printf '0\n' >"$calls"
  cat >"$fake_bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
count="$(<"$FAKE_RETRY_CALLS")"
count="$((count + 1))"
printf '%s\n' "$count" >"$FAKE_RETRY_CALLS"
if (( count < 3 )); then
  exit 1
fi
printf 'ok\n'
SH
  chmod +x "$fake_bin/gh"

  # shellcheck source=/dev/null
  source "$BOT_DIR/lib/github.sh"
  PATH="$fake_bin:$PATH" \
    FAKE_RETRY_CALLS="$calls" \
    REVIEW_BOT_DISCOVERY_TIMEOUT_SECONDS=1 \
    REVIEW_BOT_DISCOVERY_RETRIES=3 \
    REVIEW_BOT_DISCOVERY_RETRY_BASE_SECONDS=1 \
    REVIEW_BOT_DISCOVERY_RETRY_JITTER_SECONDS=0 \
    review_bot_gh api test >"$output" 2>&1

  assert_contains "$output" "attempt 1/3"
  assert_contains "$output" "attempt 2/3"
  assert_contains "$output" "ok"
  [[ "$(<"$calls")" == "3" ]] || fail "GitHub wrapper should retry twice before success"
}

test_watcher_preserves_queue_and_reports_stale_health() {
  local isolated_root="$TMP_ROOT/stale-root"
  local isolated_bot="$isolated_root/review-bot"
  local runtime="$TMP_ROOT/stale-runtime"
  local config="$TMP_ROOT/stale-config.json"
  local mode_file="$TMP_ROOT/stale-mode"
  local output="$TMP_ROOT/stale-watch.out"
  local saved_queue="$TMP_ROOT/stale-saved-queue"
  local rc

  mkdir -p "$isolated_root"
  cp -R "$BOT_DIR" "$isolated_bot"
  printf 'success\n' >"$mode_file"
  cat >"$isolated_bot/list-queue.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$(<"$FAKE_QUEUE_MODE")" == "fail" ]]; then
  exit 1
fi
printf '%s\n' '{"owner":"org","repo":"sample","number":1,"head_sha":"head","base_sha":"base","title":"Sample","url":"https://example.invalid/1","author":"tester","needs_review":true}'
SH
  cat >"$isolated_bot/agent-prompt.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'prompt for %s#%s\n' "$1" "$2"
SH
  chmod +x "$isolated_bot/list-queue.sh" "$isolated_bot/agent-prompt.sh"

  cat >"$config" <<JSON
{
  "owner": "org",
  "reviewer": "wolf31o2",
  "runtimeRoot": "$runtime",
  "pollSeconds": 1,
  "discoveryTimeoutSeconds": 1,
  "discoveryRetries": 1,
  "discoveryRetryBaseSeconds": 1,
  "discoveryRetryJitterSeconds": 0,
  "repos": {},
  "localChecks": []
}
JSON

  FAKE_QUEUE_MODE="$mode_file" REVIEW_BOT_CONFIG="$config" "$isolated_bot/watch.sh" once >"$output"
  assert_contains "$output" "queue changed: +1 -0 (1 pending)"
  cp "$runtime/queue.jsonl" "$saved_queue"
  jq -e '.status == "healthy" and .queue_count == 1 and .added == 1' "$runtime/health.json" >/dev/null ||
    fail "successful refresh should write healthy queue state"

  FAKE_QUEUE_MODE="$mode_file" REVIEW_BOT_CONFIG="$config" "$isolated_bot/watch.sh" once >"$output"
  assert_contains "$output" "queue unchanged (1 pending)"

  printf 'fail\n' >"$mode_file"
  set +e
  FAKE_QUEUE_MODE="$mode_file" REVIEW_BOT_CONFIG="$config" "$isolated_bot/watch.sh" once >"$output" 2>&1
  rc="$?"
  set -e
  [[ "$rc" -eq 1 ]] || fail "failed queue refresh should exit 1, got $rc"
  cmp -s "$runtime/queue.jsonl" "$saved_queue" || fail "failed refresh should preserve last valid queue"
  jq -e '.status == "stale" and .queue_count == 1 and .last_success != null and .error != null' "$runtime/health.json" >/dev/null ||
    fail "failed refresh should write stale health with last success"
  if find "$runtime" -maxdepth 1 -type f \( -name '.queue.*' -o -name '.health.*' \) | grep -q .; then
    fail "failed refresh left temporary queue or health files"
  fi
  if find "$runtime/prompts" -maxdepth 1 -type f -name '.prompt.*' | grep -q .; then
    fail "failed refresh left temporary prompt files"
  fi
}

test_control_scripts() {
  local config="$TMP_ROOT/control-config.json"
  local runtime="$TMP_ROOT/control-runtime"
  local logs="$TMP_ROOT/control-logs"
  local pid_file="$runtime/watch.pid"
  local watch_log="$logs/watch.log"
  local fake_watch="$TMP_ROOT/fake-watch.sh"
  local start_out="$TMP_ROOT/control-start.out"
  local status_out="$TMP_ROOT/control-status.out"
  local stop_out="$TMP_ROOT/control-stop.out"
  local bogus_pid
  local rc

  mkdir -p "$runtime" "$logs"
  cat >"$config" <<JSON
{
  "owner": "org",
  "reviewer": "wolf31o2",
  "workspace": "$TMP_ROOT/control-workspace",
  "worktreeRoot": "$TMP_ROOT/control-worktrees",
  "runtimeRoot": "$runtime",
  "logRoot": "$logs",
  "stateFile": "$TMP_ROOT/control-state.json",
  "pollSeconds": 300,
  "checkTimeoutSeconds": 1,
  "commentMode": "comment",
  "includeDrafts": false,
  "repos": {},
  "localChecks": []
}
JSON

  cat >"$fake_watch" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
trap 'echo fake watcher stopping; exit 0' TERM INT
echo fake watcher started
while true; do
  sleep 60 &
  wait "$!"
done
SH
  chmod +x "$fake_watch"

  printf '0123456789abcdef\n' >"$watch_log"
  REVIEW_BOT_CONFIG="$config" \
    REVIEW_BOT_WATCH_SCRIPT="$fake_watch" \
    REVIEW_BOT_PID_FILE="$pid_file" \
    REVIEW_BOT_WATCH_LOG="$watch_log" \
    REVIEW_BOT_WATCH_LOG_MAX_BYTES=8 \
    REVIEW_BOT_WATCH_LOG_RETAIN=2 \
    "$BOT_DIR/start.sh" >"$start_out" 2>&1

  assert_contains "$start_out" "watcher started with pid"
  assert_contains "$watch_log" "fake watcher started"
  assert_contains "$watch_log.1" "0123456789abcdef"

  cat >"$runtime/health.json" <<'JSON'
{"status":"stale","checked_at":"2026-01-01T00:00:00Z","last_success":"2025-12-31T23:59:00Z","queue_count":2,"added":0,"removed":0,"error":"test failure"}
JSON

  bogus_pid=999999
  while kill -0 "$bogus_pid" >/dev/null 2>&1; do
    bogus_pid="$((bogus_pid - 1))"
  done
  printf '%s\n' "$bogus_pid" >"$pid_file"

  REVIEW_BOT_CONFIG="$config" \
    REVIEW_BOT_WATCH_SCRIPT="$fake_watch" \
    REVIEW_BOT_PID_FILE="$pid_file" \
    REVIEW_BOT_WATCH_LOG="$watch_log" \
    "$BOT_DIR/status.sh" >"$status_out" 2>&1
  assert_contains "$status_out" "watcher running with pid"
  assert_contains "$status_out" "queue health stale; pending=2"
  assert_contains "$status_out" "error=test failure"
  [[ "$(<"$pid_file")" != "$bogus_pid" ]] || fail "status should replace stale pid file using watch command fallback"

  REVIEW_BOT_CONFIG="$config" \
    REVIEW_BOT_WATCH_SCRIPT="$fake_watch" \
    REVIEW_BOT_PID_FILE="$pid_file" \
    "$BOT_DIR/stop.sh" >"$stop_out" 2>&1
  assert_contains "$stop_out" "watcher stopped"
  [[ ! -s "$pid_file" ]] || fail "stop should remove or clear pid file"

  set +e
  REVIEW_BOT_CONFIG="$config" \
    REVIEW_BOT_WATCH_SCRIPT="$fake_watch" \
    REVIEW_BOT_PID_FILE="$pid_file" \
    REVIEW_BOT_WATCH_LOG="$watch_log" \
    "$BOT_DIR/status.sh" >"$status_out" 2>&1
  rc="$?"
  set -e
  [[ "$rc" -eq 1 ]] || fail "status should report stopped watcher after stop, got $rc"

  set +e
  REVIEW_BOT_CONFIG="$config" \
    REVIEW_BOT_POLL_SECONDS=invalid \
    REVIEW_BOT_WATCH_SCRIPT="$fake_watch" \
    REVIEW_BOT_PID_FILE="$pid_file" \
    REVIEW_BOT_WATCH_LOG="$watch_log" \
    "$BOT_DIR/start.sh" >"$start_out" 2>&1
  rc="$?"
  set -e
  [[ "$rc" -eq 2 ]] || fail "invalid poll configuration should exit 2, got $rc"
  assert_contains "$start_out" "pollSeconds must be a positive integer"
}

test_pedantic_diff_check
test_pedantic_diff_check_ignores_low_signal_paths
test_list_queue_json_and_prompt_base_key
test_record_review_rejects_moved_pr
test_portable_config_helpers
test_agent_prompt_shared_standards_and_fallback
test_invalid_json_config_fails_closed
test_review_one_dry_run_and_timeout
test_watch_interrupt_stops_active_poll
test_github_retry_backoff
test_watcher_preserves_queue_and_reports_stale_health
test_control_scripts

echo "smoke-test: ok"
