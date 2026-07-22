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

assert_not_contains() {
  local file="$1"
  local pattern="$2"

  if grep -Fq "$pattern" "$file"; then
    fail "expected $file not to contain: $pattern"
  fi
}

write_paginated_gh() {
  local bin_dir="$1"
  local call_log="$2"

  mkdir -p "$bin_dir"
  cat >"$bin_dir/gh" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$FAKE_GH_CALL_LOG"
mode="${FAKE_GH_MODE:-normal}"

if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
  exit 0
fi

if [[ "${1:-}" != "api" ]]; then
  echo "fake gh: unexpected command: $*" >&2
  exit 98
fi

if [[ "$*" == *"search/issues"* && "$*" == *"is:pr"* ]]; then
  [[ "$*" == *"--paginate"* && "$*" == *"--jq {total_count, incomplete_results, items}"* ]] || {
    echo "fake gh: search must retain totals with paginated items" >&2
    exit 97
  }
  if [[ "$mode" == "capped_search" ]]; then
    cat <<'JSON'
{"total_count":1001,"incomplete_results":false,"items":[{"repository_url":"https://api.github.com/repos/org/second","number":2,"title":"Partial result","html_url":"https://example.invalid/second/2"}]}
JSON
    exit 0
  fi
  if [[ "$mode" == "malformed_search" ]]; then
    printf '{"total_count":1,"incomplete_results":false,"items":[{"message":"unexpected item"}]}\n'
    exit 0
  fi
  if [[ "$mode" == "incomplete_search" ]]; then
    printf '{"total_count":1,"incomplete_results":true,"items":[{"repository_url":"https://api.github.com/repos/org/second","number":2,"title":"Partial result","html_url":"https://example.invalid/second/2"}]}\n'
    exit 0
  fi
  cat <<'JSON'
{
  "total_count": 2,
  "incomplete_results": false,
  "items": [{
    "repository_url": "https://api.github.com/repos/org/first",
    "number": 1,
    "title": "Unavailable details",
    "html_url": "https://example.invalid/first/1"
  }]
}
{
  "total_count": 2,
  "incomplete_results": false,
  "items": [{
    "repository_url": "https://api.github.com/repos/org/second",
    "number": 2,
    "title": "Stable second PR",
    "html_url": "https://example.invalid/second/2"
  }]
}
JSON
  exit 0
fi

if [[ "$*" == *"search/issues"* && "$*" == *"is:issue"* ]]; then
  [[ "$*" == *"--paginate"* && "$*" == *"--jq {total_count, incomplete_results, items}"* ]] || {
    echo "fake gh: search must retain totals with paginated items" >&2
    exit 97
  }
  cat <<'JSON'
{
  "total_count": 1,
  "incomplete_results": false,
  "items": [{
    "repository_url": "https://api.github.com/repos/org/work",
    "number": 3,
    "title": "Assigned work",
    "html_url": "https://example.invalid/work/3"
  }]
}
JSON
  exit 0
fi

if [[ "$*" == *"repos/org/first/pulls/1"* ]]; then
  exit 1
fi

if [[ "$*" == *"repos/org/second/pulls/2/reviews"* ]]; then
  [[ "$*" == *"--paginate"* && "$*" == *"--jq .[]"* ]] || exit 97
  if [[ "$mode" == "partial_review_failure" ]]; then
    for index in $(seq 1 101); do
      printf '{"user":{"login":"reviewer-%s"},"state":"COMMENTED","commit_id":"old-head","body":"note","html_url":"https://example.invalid/review/%s"}\n' "$index" "$index"
    done
    exit 1
  fi
  if [[ "$mode" == "malformed_reviews" ]]; then
    printf '{"message":"unexpected success body"}\n'
    exit 0
  fi
  if [[ "$mode" == "review_findings" ]]; then
    printf '{"user":{"login":"ember-review[bot]"},"state":"COMMENTED","commit_id":"abcdef1234567890","submitted_at":"2026-01-01T00:00:00Z","body":"P2: current finding","html_url":"https://example.invalid/review/current"}\n'
    exit 0
  fi
  if [[ "$mode" == "missing_review_timestamp" ]]; then
    printf '{"user":{"login":"ember-review[bot]"},"state":"COMMENTED","commit_id":"abcdef1234567890","body":"P2: current finding","html_url":"https://example.invalid/review/current"}\n'
    exit 0
  fi
  if [[ "$mode" == "review_stale" || "$mode" == "review_resolved" || "$mode" == "discussion_resolution" || "$mode" == "discussion_wrong_hash" ]]; then
    if [[ "$mode" == "review_resolved" ]]; then
      printf '%s\n' '{"user":{"login":"ember-review[bot]"},"state":"COMMENTED","commit_id":"old-head","submitted_at":"2026-01-01T00:00:00Z","body":"P3: stale finding","html_url":"https://example.invalid/review/stale"}' '{"user":{"login":"ember-review[bot]"},"state":"COMMENTED","commit_id":"abcdef1234567890","submitted_at":"2026-01-01T00:01:00Z","body":"The finding is resolved. Nothing outstanding.","html_url":"https://example.invalid/review/resolved"}'
    else
      printf '{"user":{"login":"ember-review[bot]"},"state":"COMMENTED","commit_id":"old-head","submitted_at":"2026-01-01T00:00:00Z","body":"P3: stale finding","html_url":"https://example.invalid/review/stale"}\n'
    fi
    exit 0
  fi
  if [[ "$mode" == "review_no_issues" ]]; then
    printf '{"user":{"login":"ember-review[bot]"},"state":"COMMENTED","commit_id":"abcdef1234567890","submitted_at":"2026-01-01T00:00:00Z","body":"No issues.","html_url":"https://example.invalid/review/clear"}\n'
    exit 0
  fi
  if [[ "$mode" == "review_cross_author_resolution" ]]; then
    printf '%s\n' '{"user":{"login":"ember-review[bot]"},"state":"CHANGES_REQUESTED","commit_id":"abcdef1234567890","submitted_at":"2026-01-01T00:00:00Z","body":"P1: current finding","html_url":"https://example.invalid/review/current"}' '{"user":{"login":"random-attacker"},"state":"COMMENTED","commit_id":"abcdef1234567890","submitted_at":"2026-01-01T00:01:00Z","body":"No issues.","html_url":"https://example.invalid/review/untrusted-clear"}'
    exit 0
  fi
  if [[ "$mode" == "review_non_resolution_suffix" ]]; then
    printf '%s\n' '{"user":{"login":"ember-review[bot]"},"state":"CHANGES_REQUESTED","commit_id":"abcdef1234567890","submitted_at":"2026-01-01T00:00:00Z","body":"P1: current finding","html_url":"https://example.invalid/review/current"}' '{"user":{"login":"ember-review[bot]"},"state":"COMMENTED","commit_id":"abcdef1234567890","submitted_at":"2026-01-01T00:01:00Z","body":"No issues were resolved; the finding remains.","html_url":"https://example.invalid/review/not-clear"}'
    exit 0
  fi
  if [[ "$mode" == "review_early_resolution" ]]; then
    printf '%s\n' '{"user":{"login":"ember-review[bot]"},"state":"COMMENTED","commit_id":"abcdef1234567890","submitted_at":"2026-01-01T00:00:00Z","body":"No issues.","html_url":"https://example.invalid/review/early-clear"}' '{"user":{"login":"ember-review[bot]"},"state":"CHANGES_REQUESTED","commit_id":"abcdef1234567890","submitted_at":"2026-01-01T00:01:00Z","body":"P1: later current finding","html_url":"https://example.invalid/review/later-finding"}'
    exit 0
  fi
  printf '{"user":{"login":"human"},"state":"APPROVED","commit_id":"abcdef1234567890","body":"","html_url":"https://example.invalid/review/approved"}\n'
  exit 0
fi

if [[ "$*" == *"repos/org/second/pulls/2/comments"* ]]; then
  [[ "$*" == *"--paginate"* && "$*" == *"--jq .[]"* ]] || exit 97
  if [[ "$mode" == "malformed_review_comments" ]]; then
    printf '{"message":"unexpected success body"}\n'
    exit 0
  fi
  if [[ "$mode" == "review_inline" ]]; then
    printf '{"user":{"login":"ember-review[bot]"},"commit_id":"abcdef1234567890","created_at":"2026-01-01T00:00:00Z","body":"P2: inline finding","html_url":"https://example.invalid/review/inline"}\n'
  fi
  exit 0
fi

if [[ "$*" == *"repos/org/second/issues/2/comments"* ]]; then
  [[ "$*" == *"--paginate"* && "$*" == *"--jq .[]"* ]] || exit 97
  if [[ "$mode" == "malformed_issue_comments" ]]; then
    printf '{"message":"unexpected success body"}\n'
    exit 0
  fi
  if [[ "$mode" == "review_discussion" ]]; then
    printf '{"user":{"login":"ember-review[bot]"},"created_at":"2026-01-01T00:00:00Z","body":"P3: discussion finding","html_url":"https://example.invalid/review/discussion"}\n'
  elif [[ "$mode" == "discussion_resolution" ]]; then
    printf '{"user":{"login":"ember-review[bot]"},"created_at":"2026-01-01T00:01:00Z","body":"No issues found for abcdef1234567890.","html_url":"https://example.invalid/review/discussion-clear"}\n'
  elif [[ "$mode" == "discussion_finding_resolved" ]]; then
    printf '%s\n' '{"user":{"login":"ember-review[bot]"},"created_at":"2026-01-01T00:00:00Z","body":"P3: discussion finding","html_url":"https://example.invalid/review/discussion"}' '{"user":{"login":"ember-review[bot]"},"created_at":"2026-01-01T00:01:00Z","body":"No issues found for abcdef1234567890.","html_url":"https://example.invalid/review/discussion-clear"}'
  elif [[ "$mode" == "discussion_wrong_hash" ]]; then
    printf '{"user":{"login":"ember-review[bot]"},"created_at":"2026-01-01T00:01:00Z","body":"No issues found for 0abcdef1234567890.","html_url":"https://example.invalid/review/wrong-hash"}\n'
  fi
  exit 0
fi

if [[ "$*" == *"repos/org/second/pulls/2"* ]]; then
  if [[ "$mode" == "malformed_pr" ]]; then
    printf '{"message":"unexpected success body"}\n'
    exit 0
  fi
  printf '{"head":{"sha":"abcdef1234567890"},"draft":false,"requested_reviewers":[{"login":"human"}]}\n'
  exit 0
fi

if [[ "$*" == *"repos/org/second/commits/abcdef1234567890/check-runs"* ]]; then
  if [[ "$mode" == "malformed_checks" ]]; then
    printf '{"message":"unexpected success body"}\n'
    exit 0
  fi
  if [[ "$mode" == "truncated_checks" ]]; then
    printf '{"total_count":3,"check_runs":[{"status":"completed","conclusion":"success"},{"status":"in_progress","conclusion":null}]}\n'
    exit 0
  fi
  printf '{"total_count":2,"check_runs":[{"status":"completed","conclusion":"success"},{"status":"in_progress","conclusion":null}]}\n'
  exit 0
fi

echo "fake gh: unsupported command: $*" >&2
exit 98
WRAPPER
  chmod +x "$bin_dir/gh"
  : >"$call_log"
}

test_start_and_shared_paginated_queue() {
  local fake_bin="$TMP_ROOT/paginated-bin"
  local calls="$TMP_ROOT/paginated-calls.log"
  local start_output="$TMP_ROOT/start.out"
  local first="$TMP_ROOT/worker-first.out"
  local second="$TMP_ROOT/worker-second.out"
  local rc

  write_paginated_gh "$fake_bin" "$calls"

  PATH="$fake_bin:$PATH" \
    FAKE_GH_CALL_LOG="$calls" \
    CODING_BOT_ORG=org \
    CODING_BOT_RUNTIME_ROOT="$TMP_ROOT/start-runtime" \
    CODING_BOT_SKIP_UPDATE_CHECK=1 \
    "$BOT_DIR/bin/start.sh" >"$start_output"

  assert_contains "$start_output" 'Self-update check skipped'
  assert_contains "$start_output" "## coding-bot/SKILL.md"
  assert_contains "$start_output" "## standards/session.md"
  assert_contains "$start_output" "## standards/review.md"
  assert_contains "$start_output" "org/first#1: Unavailable details [details=unavailable]"
  assert_contains "$start_output" "org/work#3: Assigned work"
  assert_contains "$start_output" "Queue REST fan-out: 9 HTTP request(s)"

  PATH="$fake_bin:$PATH" \
    FAKE_GH_CALL_LOG="$calls" \
    CODING_BOT_ORG=org \
    CODING_BOT_RUNTIME_ROOT="$TMP_ROOT/worker-runtime" \
    "$BOT_DIR/bin/worker-plan.sh" 4 1 >"$first"

  PATH="$fake_bin:$PATH" \
    FAKE_GH_CALL_LOG="$calls" \
    CODING_BOT_ORG=org \
    CODING_BOT_RUNTIME_ROOT="$TMP_ROOT/worker-runtime" \
    "$BOT_DIR/bin/worker-plan.sh" 4 1 >"$second"

  cmp -s "$first" "$second" || fail "queue output should be stable across identical responses"
  assert_contains "$first" 'Start `3` additional worker(s).'
  assert_contains "$first" "org/first#1: Unavailable details [details=unavailable]"
  assert_contains "$first" "org/second#2: Stable second PR [head=abcdef1, draft=false, requested=human, reviews=human:APPROVED, review-alerts=0 current/0 stale/0 discussion, notes=0, link=none, checks=0 fail/1 pending/2 total]"
  assert_contains "$first" "org/work#3: Assigned work"
  assert_contains "$first" "Queue REST fan-out: 9 HTTP request(s): 3 paginated search page(s) and 6 PR detail/check/review request(s) for 2 authored PR(s)."
  assert_contains "$calls" "api --paginate -X GET search/issues"

  "$BOT_DIR/bin/worker-plan.sh" --no-queue 1 4 >"$first"
  assert_contains "$first" 'Stop or do not replace `3` worker(s).'
  "$BOT_DIR/bin/worker-plan.sh" --no-queue 1 1 >"$first"
  assert_contains "$first" "Worker count is already at target."

  set +e
  "$BOT_DIR/bin/worker-plan.sh" invalid >"$first" 2>&1
  rc="$?"
  set -e
  [[ "$rc" -eq 2 ]] || fail "invalid worker target should exit 2, got $rc"
  assert_contains "$first" "usage:"
}

test_review_alert_classification() {
  local fake_bin="$TMP_ROOT/review-bin"
  local calls="$TMP_ROOT/review-calls.log"
  local output="$TMP_ROOT/review.out"

  write_paginated_gh "$fake_bin" "$calls"

  PATH="$fake_bin:$PATH" FAKE_GH_CALL_LOG="$calls" FAKE_GH_MODE=review_findings CODING_BOT_ORG=org \
    "$BOT_DIR/bin/worker-plan.sh" 1 1 >"$output"
  assert_contains "$output" "review-alerts=1 current/0 stale/0 discussion, notes=1, link=https://example.invalid/review/current"

  PATH="$fake_bin:$PATH" FAKE_GH_CALL_LOG="$calls" FAKE_GH_MODE=review_stale CODING_BOT_ORG=org \
    "$BOT_DIR/bin/worker-plan.sh" 1 1 >"$output"
  assert_contains "$output" "review-alerts=0 current/1 stale/0 discussion, notes=1, link=https://example.invalid/review/stale"

  PATH="$fake_bin:$PATH" FAKE_GH_CALL_LOG="$calls" FAKE_GH_MODE=review_resolved CODING_BOT_ORG=org \
    "$BOT_DIR/bin/worker-plan.sh" 1 1 >"$output"
  assert_contains "$output" "review-alerts=0 current/0 stale/0 discussion, notes=2, link=https://example.invalid/review/stale"

  PATH="$fake_bin:$PATH" FAKE_GH_CALL_LOG="$calls" FAKE_GH_MODE=review_no_issues CODING_BOT_ORG=org \
    "$BOT_DIR/bin/worker-plan.sh" 1 1 >"$output"
  assert_contains "$output" "review-alerts=0 current/0 stale/0 discussion, notes=1, link=https://example.invalid/review/clear"

  PATH="$fake_bin:$PATH" FAKE_GH_CALL_LOG="$calls" FAKE_GH_MODE=review_cross_author_resolution CODING_BOT_ORG=org \
    "$BOT_DIR/bin/worker-plan.sh" 1 1 >"$output"
  assert_contains "$output" "review-alerts=1 current/0 stale/0 discussion, notes=2, link=https://example.invalid/review/current"

  PATH="$fake_bin:$PATH" FAKE_GH_CALL_LOG="$calls" FAKE_GH_MODE=review_non_resolution_suffix CODING_BOT_ORG=org \
    "$BOT_DIR/bin/worker-plan.sh" 1 1 >"$output"
  assert_contains "$output" "review-alerts=2 current/0 stale/0 discussion, notes=2, link=https://example.invalid/review/current"

  PATH="$fake_bin:$PATH" FAKE_GH_CALL_LOG="$calls" FAKE_GH_MODE=review_early_resolution CODING_BOT_ORG=org \
    "$BOT_DIR/bin/worker-plan.sh" 1 1 >"$output"
  assert_contains "$output" "review-alerts=1 current/0 stale/0 discussion, notes=2, link=https://example.invalid/review/later-finding"

  PATH="$fake_bin:$PATH" FAKE_GH_CALL_LOG="$calls" FAKE_GH_MODE=review_inline CODING_BOT_ORG=org \
    "$BOT_DIR/bin/worker-plan.sh" 1 1 >"$output"
  assert_contains "$output" "review-alerts=1 current/0 stale/0 discussion, notes=1, link=https://example.invalid/review/inline"

  PATH="$fake_bin:$PATH" FAKE_GH_CALL_LOG="$calls" FAKE_GH_MODE=review_discussion CODING_BOT_ORG=org \
    "$BOT_DIR/bin/worker-plan.sh" 1 1 >"$output"
  assert_contains "$output" "review-alerts=0 current/0 stale/1 discussion, notes=1, link=https://example.invalid/review/discussion"

  PATH="$fake_bin:$PATH" FAKE_GH_CALL_LOG="$calls" FAKE_GH_MODE=discussion_resolution CODING_BOT_ORG=org \
    "$BOT_DIR/bin/worker-plan.sh" 1 1 >"$output"
  assert_contains "$output" "review-alerts=0 current/0 stale/0 discussion, notes=2, link=https://example.invalid/review/stale"

  PATH="$fake_bin:$PATH" FAKE_GH_CALL_LOG="$calls" FAKE_GH_MODE=discussion_finding_resolved CODING_BOT_ORG=org \
    "$BOT_DIR/bin/worker-plan.sh" 1 1 >"$output"
  assert_contains "$output" "review-alerts=0 current/0 stale/0 discussion, notes=2, link=https://example.invalid/review/discussion"

  PATH="$fake_bin:$PATH" FAKE_GH_CALL_LOG="$calls" FAKE_GH_MODE=discussion_wrong_hash CODING_BOT_ORG=org \
    "$BOT_DIR/bin/worker-plan.sh" 1 1 >"$output"
  assert_contains "$output" "review-alerts=0 current/1 stale/0 discussion, notes=2, link=https://example.invalid/review/stale"
}

test_unauthenticated_queue_fallback() {
  local fake_bin="$TMP_ROOT/unauthenticated-bin"
  local output="$TMP_ROOT/unauthenticated.out"

  mkdir -p "$fake_bin"
  cat >"$fake_bin/gh" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
  exit 1
fi

echo "fake gh: unexpected command: $*" >&2
exit 98
WRAPPER
  chmod +x "$fake_bin/gh"

  PATH="$fake_bin:$PATH" \
    CODING_BOT_RUNTIME_ROOT="$TMP_ROOT/unauthenticated-runtime" \
    CODING_BOT_SKIP_UPDATE_CHECK=1 \
    "$BOT_DIR/bin/start.sh" >"$output"
  assert_contains "$output" "GitHub CLI is not authenticated"
}

test_queue_response_validation_and_caps() {
  local fake_bin="$TMP_ROOT/response-bin"
  local calls="$TMP_ROOT/response-calls.log"
  local output="$TMP_ROOT/response.out"
  local mode

  write_paginated_gh "$fake_bin" "$calls"

  for mode in malformed_search incomplete_search malformed_pr malformed_checks malformed_reviews malformed_review_comments malformed_issue_comments missing_review_timestamp partial_review_failure truncated_checks capped_search; do
    PATH="$fake_bin:$PATH" \
      FAKE_GH_CALL_LOG="$calls" \
      FAKE_GH_MODE="$mode" \
      CODING_BOT_ORG=org \
      CODING_BOT_RUNTIME_ROOT="$TMP_ROOT/response-runtime" \
      "$BOT_DIR/bin/worker-plan.sh" 1 1 >"$output" 2>&1
    assert_contains "$output" "org/work#3: Assigned work"

    case "$mode" in
      malformed_search)
        assert_contains "$output" "GitHub Search returned an invalid response"
        ;;
      incomplete_search)
        assert_contains "$output" "GitHub Search reported incomplete results; retry or partition the query before acting"
        assert_not_contains "$output" "org/second#2: Partial result"
        ;;
      malformed_pr)
        assert_contains "$output" "org/second#2: Stable second PR [details=unavailable]"
        ;;
      malformed_checks)
        assert_contains "$output" "checks=unknown"
        ;;
      malformed_reviews)
        assert_contains "$output" "reviews=unknown"
        ;;
      partial_review_failure)
        assert_contains "$output" "reviews=unknown"
        assert_contains "$output" "Queue REST fan-out: 8 HTTP request(s): 3 paginated search page(s) and 5 PR detail/check/review request(s) for 2 authored PR(s)."
        ;;
      malformed_review_comments|malformed_issue_comments|missing_review_timestamp)
        assert_contains "$output" "review-alerts=unknown"
        ;;
      truncated_checks)
        assert_contains "$output" "checks=incomplete(2/3)"
        ;;
      capped_search)
        assert_contains "$output" "GitHub Search is incomplete (1 of 1001 results); partition the query before acting"
        assert_not_contains "$output" "org/second#2: Partial result"
        ;;
    esac
  done
}

create_remote_repo() {
  local bare="$1"
  local seed="$2"
  local with_agents="$3"

  git init -q --bare "$bare"
  git init -q "$seed"
  git -C "$seed" config user.email coding-bot@example.invalid
  git -C "$seed" config user.name coding-bot
  git -C "$seed" config commit.gpgsign false
  printf 'tracked\n' >"$seed/file.txt"
  if [[ "$with_agents" == "yes" ]]; then
    printf '# Local agent guidance\n' >"$seed/AGENTS.md"
  fi
  git -C "$seed" add .
  git -C "$seed" commit -q -m "initial"
  git -C "$seed" branch -M main
  git -C "$seed" remote add origin "$bare"
  git -C "$seed" push -q -u origin main
  git --git-dir="$bare" symbolic-ref HEAD refs/heads/main
}

test_workspace_status_json_and_stability() {
  local workspace="$TMP_ROOT/workspace-status"
  local remotes="$TMP_ROOT/workspace-remotes"
  local seeds="$TMP_ROOT/workspace-seeds"
  local first="$TMP_ROOT/workspace-first.json"
  local second="$TMP_ROOT/workspace-second.json"
  local dot_attached="$TMP_ROOT/workspace-dot-attached.json"
  local dot_detached="$TMP_ROOT/workspace-dot-detached.json"
  local escaped_output="$TMP_ROOT/workspace-escaped.out"
  local rc

  mkdir -p "$workspace" "$remotes" "$seeds"
  create_remote_repo "$remotes/sample.git" "$seeds/sample" yes
  create_remote_repo "$remotes/missing.git" "$seeds/missing" no

  git init -q "$workspace"
  git -C "$workspace" config user.email coding-bot@example.invalid
  git -C "$workspace" config user.name coding-bot
  git -C "$workspace" config commit.gpgsign false
  git -C "$workspace" branch -M main
  git -C "$workspace" -c protocol.file.allow=always submodule add -q "$remotes/sample.git" "repos/with space"
  git -C "$workspace" -c protocol.file.allow=always submodule add -q "$remotes/missing.git" repos/missing
  git -C "$workspace" config -f .gitmodules "submodule.repos/with space.branch" develop
  git -C "$workspace" config -f .gitmodules submodule.repos/missing.branch main
  cp "$BOT_DIR/../workspace-status.sh" "$workspace/workspace-status.sh"
  chmod +x "$workspace/workspace-status.sh"
  git -C "$workspace" add .
  git -C "$workspace" commit -q -m "pin repositories"

  git -C "$workspace/repos/with space" config user.email coding-bot@example.invalid
  git -C "$workspace/repos/with space" config user.name coding-bot
  git -C "$workspace/repos/with space" config commit.gpgsign false
  printf 'local commit\n' >>"$workspace/repos/with space/file.txt"
  git -C "$workspace/repos/with space" add file.txt
  git -C "$workspace/repos/with space" commit -q -m "local ahead commit"
  printf 'dirty\n' >>"$workspace/repos/with space/file.txt"
  git -C "$workspace" submodule deinit -q -f repos/missing

  "$workspace/workspace-status.sh" --json >"$first"
  "$workspace/workspace-status.sh" --json >"$second"

  cmp -s "$first" "$second" || fail "workspace status output should be stable"
  jq -e '
    map(select(.repository == "repos/with space"))[0]
    | .branch == "main"
      and .dirty == "yes"
      and .agents == "yes"
      and .recursive_missing == "0"
      and .configured_branch == "develop"
      and .default_branch == "main"
      and .branch_mismatch == "yes"
      and .ahead == "1"
      and .behind == "0"
      and .pin_mismatch == "yes"
  ' "$first" >/dev/null || fail "workspace status should report checked-out sample state"
  jq -e '
    map(select(.repository == "repos/missing"))[0]
    | .checked == "-"
      and .branch == "missing"
      and .recursive_missing == "1"
      and .pin_mismatch == "unknown"
  ' "$first" >/dev/null || fail "workspace status should report missing submodule state"

  git -C "$workspace" config -f .gitmodules "submodule.repos/with space.branch" .
  "$workspace/workspace-status.sh" --json >"$dot_attached"
  jq -e '
    map(select(.repository == "repos/with space"))[0]
    | .configured_branch == "." and .default_branch == "main" and .branch_mismatch == "no"
  ' "$dot_attached" >/dev/null ||
    fail "branch = . should resolve to the attached superproject branch"

  git -C "$workspace" switch --detach -q HEAD
  "$workspace/workspace-status.sh" --json >"$dot_detached"
  jq -e '
    map(select(.repository == "repos/with space"))[0]
    | .configured_branch == "." and .branch_mismatch == "unknown"
  ' "$dot_detached" >/dev/null ||
    fail "branch = . should be unknown for a detached superproject"

  git -C "$workspace" config -f .gitmodules submodule.escape.path ../outside
  set +e
  "$workspace/workspace-status.sh" --json >"$escaped_output" 2>&1
  rc="$?"
  set -e
  [[ "$rc" -eq 1 ]] || fail "workspace status should reject escaping submodule paths, got $rc"
  assert_contains "$escaped_output" "submodule path escapes workspace: ../outside"

  git -C "$workspace" config -f .gitmodules --unset submodule.escape.path
  mkdir -p "$TMP_ROOT/outside"
  ln -s "$TMP_ROOT/outside" "$workspace/repos/link-out"
  git -C "$workspace" config -f .gitmodules submodule.escape.path repos/link-out
  set +e
  "$workspace/workspace-status.sh" --json >"$escaped_output" 2>&1
  rc="$?"
  set -e
  [[ "$rc" -eq 1 ]] || fail "workspace status should reject symlink-escaping submodule paths, got $rc"
  assert_contains "$escaped_output" "submodule path escapes workspace: repos/link-out"

  printf '%s\n' '[submodule "broken"]' 'this is not valid config' >"$workspace/.gitmodules"
  set +e
  "$workspace/workspace-status.sh" --json >"$escaped_output" 2>&1
  rc="$?"
  set -e
  [[ "$rc" -eq 1 ]] || fail "workspace status should fail for malformed .gitmodules, got $rc"
  assert_contains "$escaped_output" "could not parse submodule paths"
  assert_not_contains "$escaped_output" "[]"

  : >"$workspace/.gitmodules"
  "$workspace/workspace-status.sh" --json >"$escaped_output"
  jq -e '. == []' "$escaped_output" >/dev/null ||
    fail "a valid .gitmodules with no submodule paths should report an empty workspace"
}

test_start_and_shared_paginated_queue
test_review_alert_classification
test_unauthenticated_queue_fallback
test_queue_response_validation_and_caps
test_workspace_status_json_and_stability

echo "coding-bot smoke-test: ok"
