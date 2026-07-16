#!/usr/bin/env bash
set -euo pipefail
umask 077

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
FORCE="${REVIEW_BOT_FORCE:-0}"
RECORD_DRY_RUN="${REVIEW_BOT_RECORD_DRY_RUN:-0}"

if [[ "${REVIEW_BOT_POST:-0}" != "0" ]]; then
  echo "review-bot: REVIEW_BOT_POST is ignored; review-one.sh is permanently evidence-only" >&2
fi

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
review_bot_validate_owner "$OWNER"
review_bot_validate_repo "$REPO"
review_bot_validate_pr_number "$PR_NUMBER"
WORKSPACE="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_WORKSPACE:-}" "$CONFIG" '.workspace' 'repos')"
WORKTREE_ROOT="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_WORKTREE_ROOT:-}" "$CONFIG" '.worktreeRoot' 'review-bot/.runtime/worktrees')"
RUNTIME_ROOT="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_RUNTIME_ROOT:-}" "$CONFIG" '.runtimeRoot' 'review-bot/.runtime')"
LOG_ROOT="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_LOG_ROOT:-}" "$CONFIG" '.logRoot' 'review-bot/logs')"
STATE_FILE="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_STATE_FILE:-}" "$CONFIG" '.stateFile' 'review-bot/state/reviews.json')"
STATE_LOCK_FILE="${REVIEW_BOT_STATE_LOCK:-$RUNTIME_ROOT/state.lock}"
MAINTENANCE_LOCK_FILE="${REVIEW_BOT_MAINTENANCE_LOCK:-$RUNTIME_ROOT/maintenance.lock}"
INCLUDE_DRAFTS="$(jq -r '.includeDrafts // false' "$CONFIG")"
SKIP_SELF_AUTHORED="$(jq -r '.skipSelfAuthored // true' "$CONFIG")"
CHECK_TIMEOUT_SECONDS="${REVIEW_BOT_CHECK_TIMEOUT_SECONDS:-$(jq -r '.checkTimeoutSeconds // 3600' "$CONFIG")}"
WORKTREE_RETAIN="${REVIEW_BOT_WORKTREE_RETAIN:-$(jq -r '.worktreeRetain // 8' "$CONFIG")}"
LOCAL_CHECK_NETWORK="${REVIEW_BOT_LOCAL_CHECK_NETWORK:-$(jq -r '.localCheckNetwork // "deny"' "$CONFIG")}"
LOCAL_CHECK_CPU_SECONDS="${REVIEW_BOT_LOCAL_CHECK_CPU_SECONDS:-$(jq -r '.localCheckCpuSeconds // 600' "$CONFIG")}"
LOCAL_CHECK_MEMORY_BYTES="${REVIEW_BOT_LOCAL_CHECK_MEMORY_BYTES:-$(jq -r '.localCheckMemoryBytes // 1073741824' "$CONFIG")}"
LOCAL_CHECK_WORKSPACE_BYTES="${REVIEW_BOT_LOCAL_CHECK_WORKSPACE_BYTES:-$(jq -r '.localCheckWorkspaceBytes // 2147483648' "$CONFIG")}"
LOCAL_CHECK_SCRATCH_BYTES="${REVIEW_BOT_LOCAL_CHECK_SCRATCH_BYTES:-$(jq -r '.localCheckScratchBytes // 268435456' "$CONFIG")}"
LOCAL_CHECK_MAX_PROCESSES="${REVIEW_BOT_LOCAL_CHECK_MAX_PROCESSES:-$(jq -r '.localCheckMaxProcesses // 128' "$CONFIG")}"
LOCAL_CHECK_MAX_OPEN_FILES="${REVIEW_BOT_LOCAL_CHECK_MAX_OPEN_FILES:-$(jq -r '.localCheckMaxOpenFiles // 256' "$CONFIG")}"
LOCAL_CHECK_MAX_OUTPUT_BYTES="${REVIEW_BOT_LOCAL_CHECK_MAX_OUTPUT_BYTES:-$(jq -r '.localCheckMaxOutputBytes // 10485760' "$CONFIG")}"
BWRAP="${REVIEW_BOT_BWRAP:-bwrap}"

mkdir -p \
  "$WORKTREE_ROOT" "$RUNTIME_ROOT" "$LOG_ROOT" "$(dirname "$STATE_FILE")" \
  "$(dirname "$STATE_LOCK_FILE")" "$(dirname "$MAINTENANCE_LOCK_FILE")"
exec 5>"$MAINTENANCE_LOCK_FILE"
flock -s 5
if [[ ! -f "$STATE_FILE" ]]; then
  printf '{}\n' >"$STATE_FILE"
fi
chmod 600 "$STATE_FILE"

is_review_requested_for_bot() {
  local pull

  if ! pull="$(gh api "/repos/$OWNER/$REPO/pulls/$PR_NUMBER")"; then
    return 2
  fi

  jq -e --arg reviewer "$REVIEWER" \
    'any(.requested_reviewers[]?; .login == $reviewer)' <<<"$pull" >/dev/null
}

active_worktree_leased() {
  local candidate="$1"
  local lease
  local lease_pid
  local leased_worktree

  [[ -d "${WORKTREE_LEASE_DIR:-}" ]] || return 1

  for lease in "$WORKTREE_LEASE_DIR"/*.lease; do
    [[ -e "$lease" ]] || continue
    IFS=$'\t' read -r lease_pid leased_worktree <"$lease" || true
    if review_bot_pid_running "$lease_pid"; then
      [[ "$leased_worktree" == "$candidate" ]] && return 0
    else
      rm -f "$lease"
    fi
  done

  return 1
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
    if active_worktree_leased "$old_worktree"; then
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
REPO_WORKTREE_LOCK_FILE="$LOCK_ROOT/$OWNER-$REPO-worktrees.lock"
WORKTREE_LEASE_DIR="$LOCK_ROOT/worktree-leases/$OWNER-$REPO"
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
review_bot_validate_sha head "$HEAD_SHA"

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
review_bot_validate_sha base "$BASE_SHA"
LAST_REVIEWED="$(jq -r --arg key "$KEY" '.[$key].head_sha // empty' "$STATE_FILE")"
LAST_BASE_SHA="$(jq -r --arg key "$KEY" '.[$key].base_sha // empty' "$STATE_FILE")"
if [[ "$FORCE" != "1" && "$LAST_REVIEWED" == "$HEAD_SHA" && "$LAST_BASE_SHA" == "$BASE_SHA" ]]; then
  echo "review-bot: $KEY already reviewed at $HEAD_SHA"
  exit 0
fi

SHORT_SHA="${HEAD_SHA:0:12}"
REPO_DIR="$(review_bot_repo_dir "$REPO_ROOT" "$WORKSPACE" "$CONFIG" "$REPO")"
WORKTREE="$WORKTREE_ROOT/$REPO/pr-$PR_NUMBER-$SHORT_SHA"
WORKTREE_LEASE_FILE="$WORKTREE_LEASE_DIR/pr-$PR_NUMBER-$SHORT_SHA.lease"

cleanup_worktree_lease() {
  rm -f "${WORKTREE_LEASE_FILE:-}"
}

mkdir -p "$WORKTREE_LEASE_DIR"
printf '%s\t%s\n' "$$" "$WORKTREE" >"$WORKTREE_LEASE_FILE"
trap cleanup_worktree_lease EXIT

{
  flock 6
  if ! git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    mkdir -p "$(dirname "$REPO_DIR")"
    git clone "git@github.com:$OWNER/$REPO.git" "$REPO_DIR"
  fi

  git -C "$REPO_DIR" fetch --prune origin \
    "+refs/heads/*:refs/remotes/origin/*" \
    "+refs/pull/$PR_NUMBER/head:refs/remotes/origin/pr/$PR_NUMBER"
  git -C "$REPO_DIR" worktree prune

  DIFF_BASE_SHA="$(git -C "$REPO_DIR" merge-base "$BASE_SHA" "$HEAD_SHA")"

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
} 6>"$REPO_WORKTREE_LOCK_FILE"

CHECK_WORKDIR="$(jq -r --arg repo "$REPO" '.repos[$repo].workdir // "."' "$CONFIG")"
RUN_DIR="$(review_bot_safe_workdir "$WORKTREE" "$CHECK_WORKDIR")"

mapfile -t LOCAL_CHECKS < <(
  jq -r --arg repo "$REPO" '
    if .repos[$repo].localChecks then
      .repos[$repo].localChecks[]
    else
      .localChecks[]?
    end
  ' "$CONFIG"
)

case "$LOCAL_CHECK_NETWORK" in
  deny|allow)
    ;;
  *)
    echo "review-bot: localCheckNetwork must be deny or allow, got: $LOCAL_CHECK_NETWORK" >&2
    exit 2
    ;;
esac

for limit_name in \
  CHECK_TIMEOUT_SECONDS \
  LOCAL_CHECK_CPU_SECONDS \
  LOCAL_CHECK_MEMORY_BYTES \
  LOCAL_CHECK_WORKSPACE_BYTES \
  LOCAL_CHECK_SCRATCH_BYTES \
  LOCAL_CHECK_MAX_PROCESSES \
  LOCAL_CHECK_MAX_OPEN_FILES \
  LOCAL_CHECK_MAX_OUTPUT_BYTES; do
  limit_value="${!limit_name}"
  if [[ ! "$limit_value" =~ ^[1-9][0-9]*$ ]]; then
    echo "review-bot: $limit_name must be a positive integer, got: $limit_value" >&2
    exit 2
  fi
done

LOG_DIR="$LOG_ROOT/$REPO/pr-$PR_NUMBER-$SHORT_SHA"
mkdir -p "$LOG_DIR"
REPORT="$LOG_DIR/report.md"
RESULTS_JSON="$LOG_DIR/results.json"
CI_REPORT="$LOG_DIR/ci-status.json"
CI_ERROR_LOG="$LOG_DIR/ci-status.err"
CI_STATUS="unavailable"
FAILED_LABELS=()
FAILED_LOGS=()
INFRA_LABELS=()
INFRA_LOGS=()
PASSED=()
UNTRUSTED_CHECKS_RAN=0
NETWORK_ISOLATION="not-needed"

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

run_builtin_check() {
  local label="$1"
  local command="$2"
  local workdir="${3:-$WORKTREE}"
  local log_file
  local output_blocks="$(( (LOCAL_CHECK_MAX_OUTPUT_BYTES + 511) / 512 ))"
  local rc

  log_file="$LOG_DIR/$(safe_name "$label").log"
  printf 'review-bot: running %s\n' "$label"
  if (
    cd "$workdir"
    ulimit -f "$output_blocks" || exit 125
    timeout --kill-after=30s "${CHECK_TIMEOUT_SECONDS}s" /bin/bash --noprofile --norc -c "$command"
  ) >"$log_file" 2>&1; then
    PASSED+=("$label")
  else
    rc="$?"
    if [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then
      printf '\nreview-bot: trusted evidence check timed out after %s seconds\n' "$CHECK_TIMEOUT_SECONDS" >>"$log_file"
      INFRA_LABELS+=("$label")
      INFRA_LOGS+=("$log_file")
    elif [[ "$rc" -eq 125 || "$rc" -eq 153 ]]; then
      printf '\nreview-bot: trusted evidence output limit could not be applied or was exceeded\n' >>"$log_file"
      INFRA_LABELS+=("$label")
      INFRA_LOGS+=("$log_file")
    else
      printf '\nreview-bot: check exited with status %s\n' "$rc" >>"$log_file"
      FAILED_LABELS+=("$label")
      FAILED_LOGS+=("$log_file")
    fi
  fi
}

run_local_check() {
  local label="$1"
  local command="$2"
  local workdir="${3:-$WORKTREE}"
  local log_file
  local output_blocks="$(( (LOCAL_CHECK_MAX_OUTPUT_BYTES + 511) / 512 ))"
  local memory_kib="$(( (LOCAL_CHECK_MEMORY_BYTES + 1023) / 1024 ))"
  local sandbox_workdir="/worktree${workdir#"$WORKTREE"}"
  local rc
  local sandbox=(
    "$BWRAP"
    --die-with-parent
    --new-session
    --unshare-pid
    --unshare-ipc
    --unshare-uts
    --size 16777216
    --tmpfs /
    --ro-bind /usr /usr
    --symlink usr/bin /bin
    --symlink usr/lib /lib
    --symlink usr/sbin /sbin
    --proc /proc
    --dev /dev
    --size "$LOCAL_CHECK_SCRATCH_BYTES"
    --tmpfs /tmp
    --ro-bind "$WORKTREE" /source
    --size "$LOCAL_CHECK_WORKSPACE_BYTES"
    --tmpfs /worktree
    --size "$LOCAL_CHECK_SCRATCH_BYTES"
    --tmpfs /check-env
  )

  log_file="$LOG_DIR/$(safe_name "$label").log"
  UNTRUSTED_CHECKS_RAN=1
  printf 'review-bot: running untrusted local check %s\n' "$label"

  if ! command -v "$BWRAP" >/dev/null 2>&1; then
    printf 'review-bot: filesystem isolation requires bwrap; refusing to execute PR-controlled code\n' >"$log_file"
    INFRA_LABELS+=("$label")
    INFRA_LOGS+=("$log_file")
    NETWORK_ISOLATION="unavailable"
    return
  fi
  if [[ -e /lib64 ]]; then
    sandbox+=(--ro-bind /lib64 /lib64)
  fi
  if [[ "$LOCAL_CHECK_NETWORK" == "deny" ]]; then
    sandbox+=(--unshare-net)
    NETWORK_ISOLATION="denied"
  else
    NETWORK_ISOLATION="explicitly-allowed"
  fi
  sandbox+=(-- /bin/true)
  if ! "${sandbox[@]}" >/dev/null 2>&1; then
    printf 'review-bot: configured filesystem/network isolation is unavailable; refusing to execute PR-controlled code\n' >"$log_file"
    INFRA_LABELS+=("$label")
    INFRA_LOGS+=("$log_file")
    NETWORK_ISOLATION="unavailable"
    return
  fi
  sandbox=("${sandbox[@]:0:${#sandbox[@]}-2}")

  if (
    env -i \
      PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      LANG=C.UTF-8 \
      LC_ALL=C.UTF-8 \
      HOME=/check-env/home \
      TMPDIR=/check-env/tmp \
      GH_CONFIG_DIR=/check-env/gh \
      XDG_CONFIG_HOME=/check-env/xdg-config \
      XDG_CACHE_HOME=/check-env/xdg-cache \
      GIT_CONFIG_GLOBAL=/dev/null \
      GIT_TERMINAL_PROMPT=0 \
      REVIEW_BOT_BASE_SHA="$BASE_SHA" \
      REVIEW_BOT_DIFF_BASE_SHA="$DIFF_BASE_SHA" \
      REVIEW_BOT_HEAD_SHA="$HEAD_SHA" \
      REVIEW_BOT_OWNER="$OWNER" \
      REVIEW_BOT_REPO="$REPO" \
      REVIEW_BOT_PR_NUMBER="$PR_NUMBER" \
      REVIEW_BOT_WORKTREE=/worktree \
      REVIEW_BOT_CHECK_COMMAND="$command" \
      REVIEW_BOT_CHECK_WORKDIR="$sandbox_workdir" \
      REVIEW_BOT_CPU_SECONDS="$LOCAL_CHECK_CPU_SECONDS" \
      REVIEW_BOT_MEMORY_KIB="$memory_kib" \
      REVIEW_BOT_MAX_PROCESSES="$LOCAL_CHECK_MAX_PROCESSES" \
      REVIEW_BOT_MAX_OPEN_FILES="$LOCAL_CHECK_MAX_OPEN_FILES" \
      REVIEW_BOT_MAX_OUTPUT_BLOCKS="$output_blocks" \
      timeout --kill-after=30s "${CHECK_TIMEOUT_SECONDS}s" \
      "${sandbox[@]}" \
      /bin/bash --noprofile --norc -c '
        mkdir -p /check-env/home /check-env/gh /check-env/xdg-config /check-env/xdg-cache /check-env/tmp ||
          { echo "review-bot: failed to prepare isolated scratch directories"; exit 125; }
        cp -a /source/. /worktree/ || { echo "review-bot: failed to prepare isolated worktree"; exit 125; }
        cd "$REVIEW_BOT_CHECK_WORKDIR" || { echo "review-bot: isolated workdir is unavailable"; exit 125; }
        ulimit -c 0 || { echo "review-bot: failed to disable core dumps"; exit 125; }
        ulimit -t "$REVIEW_BOT_CPU_SECONDS" || { echo "review-bot: failed to set CPU limit"; exit 125; }
        ulimit -v "$REVIEW_BOT_MEMORY_KIB" || { echo "review-bot: failed to set memory limit"; exit 125; }
        ulimit -u "$REVIEW_BOT_MAX_PROCESSES" || { echo "review-bot: failed to set process limit"; exit 125; }
        ulimit -n "$REVIEW_BOT_MAX_OPEN_FILES" || { echo "review-bot: failed to set open-file limit"; exit 125; }
        ulimit -f "$REVIEW_BOT_MAX_OUTPUT_BLOCKS" || { echo "review-bot: failed to set output limit"; exit 125; }
        exec /bin/bash --noprofile --norc -c "$REVIEW_BOT_CHECK_COMMAND"
      '
  ) >"$log_file" 2>&1; then
    PASSED+=("$label")
  else
    rc="$?"
    if [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then
      printf '\nreview-bot: check timed out after %s seconds\n' "$CHECK_TIMEOUT_SECONDS" >>"$log_file"
      INFRA_LABELS+=("$label")
      INFRA_LOGS+=("$log_file")
    elif [[ "$rc" -eq 125 || "$rc" -eq 152 || "$rc" -eq 153 ]]; then
      printf '\nreview-bot: a configured isolation or resource limit could not be applied or was exceeded\n' >>"$log_file"
      INFRA_LABELS+=("$label")
      INFRA_LOGS+=("$log_file")
    else
      printf '\nreview-bot: check exited with status %s\n' "$rc" >>"$log_file"
      FAILED_LABELS+=("$label")
      FAILED_LOGS+=("$log_file")
    fi
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
  elif [[ "$pending" -gt 0 || "$unknown" -gt 0 ]]; then
    CI_STATUS="pending"
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
run_builtin_check "git diff --check" "git diff --check $DIFF_BASE_SHA $HEAD_SHA" "$WORKTREE"
run_builtin_check "pedantic wallet diff check" "$SCRIPT_DIR/pedantic-diff-check.sh" "$WORKTREE"
for check in "${LOCAL_CHECKS[@]}"; do
  run_local_check "$check" "$check" "$RUN_DIR"
done

STATUS="clean"
if [[ "${#INFRA_LABELS[@]}" -gt 0 ]]; then
  STATUS="inconclusive"
elif [[ "${#FAILED_LABELS[@]}" -gt 0 ]]; then
  STATUS="findings"
fi

{
  printf 'Review-bot evidence for `%s` at `%s`.\n\n' "$KEY" "$HEAD_SHA"
  printf 'PR: %s\n\n' "$URL"
  printf 'Title: %s\n\n' "$TITLE"
  printf 'Base/head: `%s` -> `%s`\n\n' "$BASE_REF" "$HEAD_REF"
  printf 'Diff base: `%s`\n\n' "$DIFF_BASE_SHA"
  printf 'GitHub CI/checks: `%s`.\n\n' "$CI_STATUS"
  if [[ "$UNTRUSTED_CHECKS_RAN" == "1" ]]; then
    printf 'PR-controlled local checks: enabled; network isolation: `%s`.\n\n' "$NETWORK_ISOLATION"
  else
    printf 'PR-controlled local checks: none configured.\n\n'
  fi
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
  elif [[ "$STATUS" == "findings" ]]; then
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
  else
    printf 'Review evidence is inconclusive for `%s` because required isolation or resource controls failed:\n\n' "$HEAD_SHA"
    for index in "${!INFRA_LABELS[@]}"; do
      label="${INFRA_LABELS[$index]}"
      log_file="${INFRA_LOGS[$index]}"
      printf -- '- Infrastructure failure: `%s`\n' "$label"
      printf '  Local log: `%s`\n\n' "$(display_path "$log_file")"
    done
  fi
} >"$REPORT"

jq -n \
  --arg key "$KEY" \
  --arg head_sha "$HEAD_SHA" \
  --arg base_sha "$BASE_SHA" \
  --arg status "$STATUS" \
  --arg ci_status "$CI_STATUS" \
  --arg network_isolation "$NETWORK_ISOLATION" \
  --arg report "$REPORT" \
  --arg reviewed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{key:$key, head_sha:$head_sha, base_sha:$base_sha, review_kind:"check", status:$status, ci_status:$ci_status, network_isolation:$network_isolation, report:$report, reviewed_at:$reviewed_at}' \
  >"$RESULTS_JSON"

echo "review-bot: evidence-only report written to $REPORT"

if [[ "$RECORD_DRY_RUN" != "1" ]]; then
  echo "review-bot: evidence-only run; state not updated"
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
  --arg reviewed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '.[$key] = {
    head_sha: $head_sha,
    base_sha: $base_sha,
    review_kind: "check",
    status: $status,
    ci_status: $ci_status,
    report: $report,
    reviewed_at: $reviewed_at
  }' "$STATE_FILE" >"$tmp_state"
mv "$tmp_state" "$STATE_FILE"

echo "review-bot: $KEY reviewed at $HEAD_SHA with status $STATUS"
