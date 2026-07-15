#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 2 ]]; then
  echo "usage: $0 <repo> <pr-number>" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${REVIEW_BOT_CONFIG:-$SCRIPT_DIR/config.json}"
source "$SCRIPT_DIR/lib/paths.sh"
REPO_ROOT="$(review_bot_repo_root "$SCRIPT_DIR")"
REPO="$1"
PR_NUMBER="$2"
POST="${REVIEW_BOT_POST:-0}"
FORCE="${REVIEW_BOT_FORCE:-0}"
RECORD_DRY_RUN="${REVIEW_BOT_RECORD_DRY_RUN:-0}"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "review-bot: missing required command: $1" >&2
    exit 2
  fi
}

require gh
require flock
require git
require jq
require timeout

OWNER="$(review_bot_owner "$CONFIG")"
REVIEWER="$(review_bot_reviewer "$CONFIG")"
WORKSPACE="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_WORKSPACE:-}" "$CONFIG" '.workspace' 'review-bot/.runtime/repos')"
WORKTREE_ROOT="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_WORKTREE_ROOT:-}" "$CONFIG" '.worktreeRoot' 'review-bot/.runtime/worktrees')"
RUNTIME_ROOT="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_RUNTIME_ROOT:-}" "$CONFIG" '.runtimeRoot' 'review-bot/.runtime')"
LOG_ROOT="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_LOG_ROOT:-}" "$CONFIG" '.logRoot' 'review-bot/logs')"
STATE_FILE="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_STATE_FILE:-}" "$CONFIG" '.stateFile' 'review-bot/state/reviews.json')"
STATE_LOCK_FILE="${REVIEW_BOT_STATE_LOCK:-$RUNTIME_ROOT/state.lock}"
COMMENT_MODE="$(jq -r '.commentMode // "comment"' "$CONFIG")"
INCLUDE_DRAFTS="$(jq -r '.includeDrafts // false' "$CONFIG")"
SKIP_SELF_AUTHORED="$(jq -r '.skipSelfAuthored // true' "$CONFIG")"
CHECK_TIMEOUT_SECONDS="${REVIEW_BOT_CHECK_TIMEOUT_SECONDS:-$(jq -r '.checkTimeoutSeconds // 3600' "$CONFIG")}"
WORKTREE_RETAIN="${REVIEW_BOT_WORKTREE_RETAIN:-$(jq -r '.worktreeRetain // 8' "$CONFIG")}"

mkdir -p "$WORKTREE_ROOT" "$RUNTIME_ROOT" "$LOG_ROOT" "$(dirname "$STATE_FILE")" "$(dirname "$STATE_LOCK_FILE")"
if [[ ! -f "$STATE_FILE" ]]; then
  printf '{}\n' >"$STATE_FILE"
fi

is_review_requested_for_bot() {
  local pull

  if ! pull="$(gh api "/repos/$OWNER/$REPO/pulls/$PR_NUMBER")"; then
    return 2
  fi

  jq -e --arg reviewer "$REVIEWER" \
    'any(.requested_reviewers[]?; .login == $reviewer)' <<<"$pull" >/dev/null
}

prune_old_review_worktrees() {
  local repo_worktree_dir="$WORKTREE_ROOT/$REPO"
  local retain="$WORKTREE_RETAIN"
  local index=0
  local old_worktree
  local old_worktrees=()

  [[ "$retain" =~ ^[0-9]+$ ]] || retain=8
  [[ "$retain" -gt 0 ]] || return 0
  [[ -d "$repo_worktree_dir" ]] || return 0

  mapfile -t old_worktrees < <(
    find "$repo_worktree_dir" -mindepth 1 -maxdepth 1 -type d -name 'pr-*' -printf '%T@ %p\n' 2>/dev/null |
      sort -nr |
      cut -d' ' -f2-
  )

  for old_worktree in "${old_worktrees[@]}"; do
    index="$((index + 1))"
    if [[ "$index" -le "$retain" || "$old_worktree" == "$WORKTREE" ]]; then
      continue
    fi

    if ! git -C "$REPO_DIR" worktree remove --force "$old_worktree" >/dev/null 2>&1; then
      printf 'review-bot: warning: failed to remove old worktree %s\n' "$old_worktree" >&2
    fi
  done
}

LOCK_ROOT="${REVIEW_BOT_LOCK_ROOT:-$RUNTIME_ROOT/locks}"
mkdir -p "$LOCK_ROOT"
PR_LOCK_FILE="$LOCK_ROOT/$OWNER-$REPO-$PR_NUMBER.lock"
exec 8>"$PR_LOCK_FILE"
if ! flock -n 8; then
  echo "review-bot: $OWNER/$REPO#$PR_NUMBER is already being reviewed; exiting"
  exit 0
fi

META="$(gh pr view "$PR_NUMBER" -R "$OWNER/$REPO" \
  --json number,title,url,headRefOid,headRefName,baseRefName,isDraft,author)"
HEAD_SHA="$(jq -r '.headRefOid' <<<"$META")"
HEAD_REF="$(jq -r '.headRefName' <<<"$META")"
BASE_REF="$(jq -r '.baseRefName' <<<"$META")"
TITLE="$(jq -r '.title' <<<"$META")"
URL="$(jq -r '.url' <<<"$META")"
IS_DRAFT="$(jq -r '.isDraft' <<<"$META")"
AUTHOR="$(jq -r '.author.login' <<<"$META")"
KEY="$OWNER/$REPO#$PR_NUMBER"

if [[ "$SKIP_SELF_AUTHORED" == "true" && "$AUTHOR" == "$REVIEWER" && "${REVIEW_BOT_INCLUDE_SELF_AUTHORED:-0}" != "1" ]]; then
  echo "review-bot: skipping self-authored PR $KEY"
  exit 0
fi

if [[ "$IS_DRAFT" == "true" && "$INCLUDE_DRAFTS" != "true" && "${REVIEW_BOT_INCLUDE_DRAFTS:-0}" != "1" ]]; then
  echo "review-bot: skipping draft PR $KEY"
  exit 0
fi

if is_review_requested_for_bot; then
  :
else
  requested_rc="$?"
  if [[ "$requested_rc" -eq 1 ]]; then
    echo "review-bot: skipping $KEY because $REVIEWER is not a requested reviewer"
    exit 0
  fi

  echo "review-bot: failed to verify requested reviewer for $KEY" >&2
  exit 1
fi

BASE_SHA="$(gh api "/repos/$OWNER/$REPO/pulls/$PR_NUMBER" --jq '.base.sha')"
LAST_REVIEWED="$(jq -r --arg key "$KEY" '.[$key].head_sha // empty' "$STATE_FILE")"
LAST_BASE_SHA="$(jq -r --arg key "$KEY" '.[$key].base_sha // empty' "$STATE_FILE")"
if [[ "$FORCE" != "1" && "$LAST_REVIEWED" == "$HEAD_SHA" && "$LAST_BASE_SHA" == "$BASE_SHA" ]]; then
  echo "review-bot: $KEY already reviewed at $HEAD_SHA"
  exit 0
fi

REPO_DIR="$WORKSPACE/$REPO"
if [[ ! -d "$REPO_DIR/.git" ]]; then
  mkdir -p "$WORKSPACE"
  git clone "git@github.com:$OWNER/$REPO.git" "$REPO_DIR"
fi

git -C "$REPO_DIR" fetch --prune origin \
  "+refs/heads/*:refs/remotes/origin/*" \
  "+refs/pull/$PR_NUMBER/head:refs/remotes/origin/pr/$PR_NUMBER"
git -C "$REPO_DIR" worktree prune

DIFF_BASE_SHA="$(git -C "$REPO_DIR" merge-base "$BASE_SHA" "$HEAD_SHA")"

SHORT_SHA="${HEAD_SHA:0:12}"
WORKTREE="$WORKTREE_ROOT/$REPO/pr-$PR_NUMBER-$SHORT_SHA"
if [[ -e "$WORKTREE" ]]; then
  if git -C "$WORKTREE" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    WORKTREE_HEAD="$(git -C "$WORKTREE" rev-parse HEAD)"
    if [[ "$WORKTREE_HEAD" != "$HEAD_SHA" ]]; then
      echo "review-bot: refusing to reuse worktree at unexpected head $WORKTREE" >&2
      exit 1
    fi
  else
    echo "review-bot: refusing to reuse non-worktree path $WORKTREE" >&2
    exit 1
  fi
else
  mkdir -p "$(dirname "$WORKTREE")"
  git -C "$REPO_DIR" worktree add --detach "$WORKTREE" "$HEAD_SHA"
fi
git -C "$WORKTREE" reset --hard "$HEAD_SHA" >/dev/null
git -C "$WORKTREE" clean -ffdx >/dev/null
prune_old_review_worktrees

CHECK_WORKDIR="$(jq -r --arg repo "$REPO" '.repos[$repo].workdir // "."' "$CONFIG")"
RUN_DIR="$WORKTREE/$CHECK_WORKDIR"
if [[ ! -d "$RUN_DIR" ]]; then
  echo "review-bot: configured workdir does not exist: $CHECK_WORKDIR" >&2
  exit 1
fi

mapfile -t LOCAL_CHECKS < <(
  jq -r --arg repo "$REPO" '
    if .repos[$repo].localChecks then
      .repos[$repo].localChecks[]
    else
      .localChecks[]?
    end
  ' "$CONFIG"
)

LOG_DIR="$LOG_ROOT/$REPO/pr-$PR_NUMBER-$SHORT_SHA"
mkdir -p "$LOG_DIR"
CHECK_ENV_ROOT="$RUNTIME_ROOT/check-env/$REPO/pr-$PR_NUMBER-$SHORT_SHA"
REPORT="$LOG_DIR/report.md"
RESULTS_JSON="$LOG_DIR/results.json"
CI_REPORT="$LOG_DIR/ci-status.json"
CI_ERROR_LOG="$LOG_DIR/ci-status.err"
CI_STATUS="unavailable"
CI_BLOCKS_APPROVAL=0
FAILED_LABELS=()
FAILED_LOGS=()
PASSED=()

safe_name() {
  printf '%s' "$1" | tr -cs '[:alnum:]_.=-' '_' | sed 's/^_//; s/_$//'
}

display_path() {
  case "$1" in
    "$WORKSPACE"/*)
      printf '%s' "${1#"$WORKSPACE"/}"
      ;;
    *)
      printf '%s' "$1"
      ;;
  esac
}

run_check() {
  local label="$1"
  local command="$2"
  local workdir="${3:-$WORKTREE}"
  local check_env="$CHECK_ENV_ROOT/$(safe_name "$label")"
  local log_file="$LOG_DIR/$(safe_name "$label").log"
  local rc

  printf 'review-bot: running %s\n' "$label"
  mkdir -p "$check_env/home" "$check_env/gh" "$check_env/xdg-config" "$check_env/xdg-cache"
  if (
    cd "$workdir"
    env \
      -u GH_TOKEN \
      -u GITHUB_TOKEN \
      -u GH_ENTERPRISE_TOKEN \
      -u GITHUB_ENTERPRISE_TOKEN \
      -u GIT_ASKPASS \
      -u GIT_SSH_COMMAND \
      -u SSH_ASKPASS \
      -u SSH_AUTH_SOCK \
      -u NPM_TOKEN \
      -u NODE_AUTH_TOKEN \
      -u YARN_NPM_AUTH_TOKEN \
      HOME="$check_env/home" \
      GH_CONFIG_DIR="$check_env/gh" \
      XDG_CONFIG_HOME="$check_env/xdg-config" \
      XDG_CACHE_HOME="$check_env/xdg-cache" \
      GIT_CONFIG_GLOBAL=/dev/null \
      GIT_TERMINAL_PROMPT=0 \
      timeout --kill-after=30s "${CHECK_TIMEOUT_SECONDS}s" /bin/bash -lc "$command"
  ) >"$log_file" 2>&1; then
    PASSED+=("$label")
  else
    rc="$?"
    if [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then
      printf '\nreview-bot: check timed out after %s seconds\n' "$CHECK_TIMEOUT_SECONDS" >>"$log_file"
    else
      printf '\nreview-bot: check exited with status %s\n' "$rc" >>"$log_file"
    fi
    FAILED_LABELS+=("$label")
    FAILED_LOGS+=("$log_file")
  fi
}

capture_ci_status() {
  local ci_json
  local summary
  local total
  local failing
  local pending
  local unknown

  if ! ci_json="$(gh pr view "$PR_NUMBER" -R "$OWNER/$REPO" --json statusCheckRollup --jq '.statusCheckRollup' 2>"$CI_ERROR_LOG")"; then
    CI_STATUS="unavailable"
    CI_BLOCKS_APPROVAL=1
    return 0
  fi

  if [[ -z "$ci_json" || "$ci_json" == "null" ]]; then
    printf '[]\n' >"$CI_REPORT"
  else
    jq 'if type == "array" then . else [] end' <<<"$ci_json" >"$CI_REPORT"
  fi

  summary="$(jq -r '
    def verdict:
      ((.conclusion // .state // .status // "") | ascii_downcase) as $value |
      if ($value == "success" or $value == "neutral" or $value == "skipped") then "pass"
      elif ($value == "failure" or $value == "error" or $value == "cancelled" or $value == "timed_out" or $value == "action_required") then "fail"
      elif ($value == "pending" or $value == "queued" or $value == "in_progress" or $value == "waiting" or $value == "requested" or $value == "expected") then "pending"
      else "unknown"
      end;
    [ .[]? | verdict ] as $verdicts |
    [
      ($verdicts | length),
      ($verdicts | map(select(. == "fail")) | length),
      ($verdicts | map(select(. == "pending")) | length),
      ($verdicts | map(select(. == "unknown")) | length)
    ] | @tsv
  ' "$CI_REPORT")"

  IFS=$'\t' read -r total failing pending unknown <<<"$summary"
  if [[ "$total" -eq 0 ]]; then
    CI_STATUS="no-checks"
  elif [[ "$failing" -gt 0 ]]; then
    CI_STATUS="failing"
    CI_BLOCKS_APPROVAL=1
  elif [[ "$pending" -gt 0 || "$unknown" -gt 0 ]]; then
    CI_STATUS="pending"
    CI_BLOCKS_APPROVAL=1
  else
    CI_STATUS="passing"
  fi
}

export REVIEW_BOT_BASE_SHA="$BASE_SHA"
export REVIEW_BOT_DIFF_BASE_SHA="$DIFF_BASE_SHA"
export REVIEW_BOT_HEAD_SHA="$HEAD_SHA"
export REVIEW_BOT_OWNER="$OWNER"
export REVIEW_BOT_REPO="$REPO"
export REVIEW_BOT_PR_NUMBER="$PR_NUMBER"
export REVIEW_BOT_RUNTIME_ROOT="$RUNTIME_ROOT"
export REVIEW_BOT_SCRIPT_DIR="$SCRIPT_DIR"
export REVIEW_BOT_WORKTREE="$WORKTREE"

capture_ci_status
run_check "git diff --check" "git diff --check $DIFF_BASE_SHA $HEAD_SHA" "$WORKTREE"
run_check "pedantic wallet diff check" "$SCRIPT_DIR/pedantic-diff-check.sh" "$WORKTREE"
for check in "${LOCAL_CHECKS[@]}"; do
  run_check "$check" "$check" "$RUN_DIR"
done

STATUS="clean"
if [[ "${#FAILED_LABELS[@]}" -gt 0 ]]; then
  STATUS="findings"
fi

{
  printf 'Review-bot evidence for `%s` at `%s`.\n\n' "$KEY" "$HEAD_SHA"
  printf 'PR: %s\n\n' "$URL"
  printf 'Title: %s\n\n' "$TITLE"
  printf 'Base/head: `%s` -> `%s`\n\n' "$BASE_REF" "$HEAD_REF"
  printf 'Diff base: `%s`\n\n' "$DIFF_BASE_SHA"
  printf 'GitHub CI/checks: `%s`.\n\n' "$CI_STATUS"
  if [[ -s "$CI_REPORT" ]]; then
    if jq -e 'length > 0' "$CI_REPORT" >/dev/null; then
      printf 'CI rollup from GitHub:\n'
      jq -r '
        .[] |
        "- `" + ((.name // .context // .workflowName // "unknown") | tostring) + "`: `" +
        ((.conclusion // .state // .status // "unknown") | tostring) + "`"
      ' "$CI_REPORT"
      printf '\n'
    else
      printf 'No GitHub check rollup entries were available.\n\n'
    fi
  else
    printf 'GitHub check rollup could not be fetched; see local error log `%s`.\n\n' "$(display_path "$CI_ERROR_LOG")"
  fi

  if [[ "$STATUS" == "clean" ]]; then
    printf 'No local review-specific issues found for `%s`.\n\n' "$HEAD_SHA"
    printf 'Local review-specific checks run:\n'
    printf -- '- `%s`\n' "${PASSED[@]}"
  else
    printf 'Local review-specific issues found for `%s`:\n\n' "$HEAD_SHA"
    for index in "${!FAILED_LABELS[@]}"; do
      label="${FAILED_LABELS[$index]}"
      log_file="${FAILED_LOGS[$index]}"
      printf -- '- Check failed: `%s`\n' "$label"
      printf '  Local log: `%s`\n' "$(display_path "$log_file")"
      printf '  Log output omitted from this report because checks run against PR-controlled code.\n\n'
    done
    if [[ "${#PASSED[@]}" -gt 0 ]]; then
      printf 'Local checks that passed:\n'
      printf -- '- `%s`\n' "${PASSED[@]}"
    fi
  fi
} >"$REPORT"

jq -n \
  --arg key "$KEY" \
  --arg head_sha "$HEAD_SHA" \
  --arg base_sha "$BASE_SHA" \
  --arg status "$STATUS" \
  --arg ci_status "$CI_STATUS" \
  --arg report "$REPORT" \
  --arg reviewed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{key:$key, head_sha:$head_sha, base_sha:$base_sha, review_kind:"check", status:$status, ci_status:$ci_status, report:$report, reviewed_at:$reviewed_at}' \
  >"$RESULTS_JSON"

COMMENT_URL=""
if [[ "$POST" == "1" ]]; then
  if [[ "$STATUS" == "clean" ]]; then
    if [[ "$CI_BLOCKS_APPROVAL" == "1" ]]; then
      COMMENT_URL="$(gh pr comment "$PR_NUMBER" -R "$OWNER/$REPO" --body-file "$REPORT")"
      echo "review-bot: not approving $KEY because GitHub CI/checks are $CI_STATUS"
    else
      COMMENT_URL="$(gh api -X POST "/repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews" \
        -f event=APPROVE \
        -F "body=@$REPORT" \
        --jq '.html_url // empty')"
      echo "review-bot: approved $KEY"
    fi
  elif [[ "$COMMENT_MODE" == "review" ]]; then
    COMMENT_URL="$(gh pr review "$PR_NUMBER" -R "$OWNER/$REPO" --comment --body-file "$REPORT")"
  else
    COMMENT_URL="$(gh pr comment "$PR_NUMBER" -R "$OWNER/$REPO" --body-file "$REPORT")"
  fi
  if [[ -n "$COMMENT_URL" ]]; then
    echo "$COMMENT_URL"
  fi
else
  echo "review-bot: dry run; report written to $REPORT"
fi

if [[ "$POST" != "1" && "$RECORD_DRY_RUN" != "1" ]]; then
  echo "review-bot: dry run; state not updated"
  echo "review-bot: $KEY evaluated at $HEAD_SHA with status $STATUS"
  exit 0
fi

exec 7>"$STATE_LOCK_FILE"
flock 7
if [[ ! -f "$STATE_FILE" ]]; then
  printf '{}\n' >"$STATE_FILE"
fi

tmp_state="$(mktemp "$(dirname "$STATE_FILE")/.reviews.XXXXXX")"
jq \
  --arg key "$KEY" \
  --arg head_sha "$HEAD_SHA" \
  --arg base_sha "$BASE_SHA" \
  --arg status "$STATUS" \
  --arg ci_status "$CI_STATUS" \
  --arg report "$REPORT" \
  --arg comment_url "$COMMENT_URL" \
  --arg reviewed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '.[$key] = {
    head_sha: $head_sha,
    base_sha: $base_sha,
    review_kind: "check",
    status: $status,
    ci_status: $ci_status,
    report: $report,
    comment_url: $comment_url,
    reviewed_at: $reviewed_at
  } | if $comment_url == "" then .[$key] |= del(.comment_url) else . end' "$STATE_FILE" >"$tmp_state"
mv "$tmp_state" "$STATE_FILE"

echo "review-bot: $KEY reviewed at $HEAD_SHA with status $STATUS"
