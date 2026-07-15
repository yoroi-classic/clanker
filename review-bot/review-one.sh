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
POST="${REVIEW_BOT_POST:-1}"
FORCE="${REVIEW_BOT_FORCE:-0}"
RECORD_DRY_RUN="${REVIEW_BOT_RECORD_DRY_RUN:-0}"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "review-bot: missing required command: $1" >&2
    exit 2
  fi
}

require gh
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
COMMENT_MODE="$(jq -r '.commentMode // "comment"' "$CONFIG")"
INCLUDE_DRAFTS="$(jq -r '.includeDrafts // false' "$CONFIG")"
SKIP_SELF_AUTHORED="$(jq -r '.skipSelfAuthored // true' "$CONFIG")"
CHECK_TIMEOUT_SECONDS="${REVIEW_BOT_CHECK_TIMEOUT_SECONDS:-$(jq -r '.checkTimeoutSeconds // 3600' "$CONFIG")}"

mkdir -p "$WORKTREE_ROOT" "$RUNTIME_ROOT" "$LOG_ROOT" "$(dirname "$STATE_FILE")"
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

CHECK_WORKDIR="$(jq -r --arg repo "$REPO" '.repos[$repo].workdir // "."' "$CONFIG")"
RUN_DIR="$WORKTREE/$CHECK_WORKDIR"
if [[ ! -d "$RUN_DIR" ]]; then
  echo "review-bot: configured workdir does not exist: $CHECK_WORKDIR" >&2
  exit 1
fi

mapfile -t CHECKS < <(
  jq -r --arg repo "$REPO" '
    if .repos[$repo].checks then
      .repos[$repo].checks[]
    else
      .defaultChecks[]
    end
  ' "$CONFIG"
)

LOG_DIR="$LOG_ROOT/$REPO/pr-$PR_NUMBER-$SHORT_SHA"
mkdir -p "$LOG_DIR"
REPORT="$LOG_DIR/report.md"
RESULTS_JSON="$LOG_DIR/results.json"
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
  local log_file="$LOG_DIR/$(safe_name "$label").log"
  local rc

  printf 'review-bot: running %s\n' "$label"
  if (cd "$RUN_DIR" && timeout --kill-after=30s "${CHECK_TIMEOUT_SECONDS}s" /bin/bash -lc "$command") >"$log_file" 2>&1; then
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

export REVIEW_BOT_BASE_SHA="$BASE_SHA"
export REVIEW_BOT_DIFF_BASE_SHA="$DIFF_BASE_SHA"
export REVIEW_BOT_HEAD_SHA="$HEAD_SHA"
export REVIEW_BOT_OWNER="$OWNER"
export REVIEW_BOT_REPO="$REPO"
export REVIEW_BOT_PR_NUMBER="$PR_NUMBER"
export REVIEW_BOT_RUNTIME_ROOT="$RUNTIME_ROOT"
export REVIEW_BOT_SCRIPT_DIR="$SCRIPT_DIR"
export REVIEW_BOT_WORKTREE="$WORKTREE"

run_check "git diff --check" "git diff --check $DIFF_BASE_SHA $HEAD_SHA"
run_check "pedantic wallet diff check" "$SCRIPT_DIR/pedantic-diff-check.sh"
for check in "${CHECKS[@]}"; do
  run_check "$check" "$check"
done

STATUS="clean"
if [[ "${#FAILED_LABELS[@]}" -gt 0 ]]; then
  STATUS="findings"
fi

{
  printf 'Local review-bot pass for `%s` at `%s`.\n\n' "$KEY" "$HEAD_SHA"
  printf 'PR: %s\n\n' "$URL"
  printf 'Title: %s\n\n' "$TITLE"
  printf 'Base/head: `%s` -> `%s`\n\n' "$BASE_REF" "$HEAD_REF"
  printf 'Diff base: `%s`\n\n' "$DIFF_BASE_SHA"

  if [[ "$STATUS" == "clean" ]]; then
    printf 'No issues found for `%s`.\n\n' "$HEAD_SHA"
    printf 'Checks run:\n'
    printf -- '- `%s`\n' "${PASSED[@]}"
  else
    printf 'Issues found for `%s`:\n\n' "$HEAD_SHA"
    for index in "${!FAILED_LABELS[@]}"; do
      label="${FAILED_LABELS[$index]}"
      log_file="${FAILED_LOGS[$index]}"
      printf -- '- Check failed: `%s`\n' "$label"
      printf '  Local log: `%s`\n' "$(display_path "$log_file")"
      printf '  Tail:\n\n'
      printf '```text\n'
      tail -40 "$log_file" || true
      printf '```\n\n'
    done
    if [[ "${#PASSED[@]}" -gt 0 ]]; then
      printf 'Checks that passed:\n'
      printf -- '- `%s`\n' "${PASSED[@]}"
    fi
  fi
} >"$REPORT"

jq -n \
  --arg key "$KEY" \
  --arg head_sha "$HEAD_SHA" \
  --arg base_sha "$BASE_SHA" \
  --arg status "$STATUS" \
  --arg report "$REPORT" \
  --arg reviewed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{key:$key, head_sha:$head_sha, base_sha:$base_sha, status:$status, report:$report, reviewed_at:$reviewed_at}' \
  >"$RESULTS_JSON"

COMMENT_URL=""
if [[ "$POST" == "1" ]]; then
  if [[ "$STATUS" == "clean" ]]; then
    COMMENT_URL="$(gh api -X POST "/repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews" \
      -f event=APPROVE \
      -F "body=@$REPORT" \
      --jq '.html_url // empty')"
    echo "review-bot: approved $KEY"
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

tmp_state="$(mktemp "$(dirname "$STATE_FILE")/.reviews.XXXXXX")"
jq \
  --arg key "$KEY" \
  --arg head_sha "$HEAD_SHA" \
  --arg base_sha "$BASE_SHA" \
  --arg status "$STATUS" \
  --arg report "$REPORT" \
  --arg comment_url "$COMMENT_URL" \
  --arg reviewed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '.[$key] = {
    head_sha: $head_sha,
    base_sha: $base_sha,
    status: $status,
    report: $report,
    comment_url: $comment_url,
    reviewed_at: $reviewed_at
  } | if $comment_url == "" then .[$key] |= del(.comment_url) else . end' "$STATE_FILE" >"$tmp_state"
mv "$tmp_state" "$STATE_FILE"

echo "review-bot: $KEY reviewed at $HEAD_SHA with status $STATUS"
