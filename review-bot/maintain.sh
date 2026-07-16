#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${REVIEW_BOT_CONFIG:-$SCRIPT_DIR/config.json}"
source "$SCRIPT_DIR/lib/paths.sh"
source "$SCRIPT_DIR/lib/github.sh"
REPO_ROOT="$(review_bot_repo_root "$SCRIPT_DIR")"
MODE="dry-run"
state_tmp=""

cleanup() {
  [[ -z "$state_tmp" ]] || rm -f "$state_tmp"
}
trap cleanup EXIT INT TERM

case "${1:-}" in
  "")
    ;;
  --apply)
    MODE="apply"
    ;;
  --dry-run)
    ;;
  -h|--help)
    echo "usage: $0 [--dry-run|--apply]"
    exit 0
    ;;
  *)
    echo "usage: $0 [--dry-run|--apply]" >&2
    exit 2
    ;;
esac

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "review-bot: missing required command: $1" >&2
    exit 2
  fi
}

require date
require find
require flock
require git
require jq
require realpath
require stat

"$SCRIPT_DIR/validate-config.sh" "$CONFIG" >/dev/null

WORKSPACE="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_WORKSPACE:-}" "$CONFIG" '.workspace' 'repos')"
WORKTREE_ROOT="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_WORKTREE_ROOT:-}" "$CONFIG" '.worktreeRoot' 'review-bot/.runtime/worktrees')"
RUNTIME_ROOT="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_RUNTIME_ROOT:-}" "$CONFIG" '.runtimeRoot' 'review-bot/.runtime')"
LOG_ROOT="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_LOG_ROOT:-}" "$CONFIG" '.logRoot' 'review-bot/logs')"
STATE_FILE="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_STATE_FILE:-}" "$CONFIG" '.stateFile' 'review-bot/state/reviews.json')"
PROMPT_DIR="${REVIEW_BOT_PROMPT_DIR:-$RUNTIME_ROOT/prompts}"
CHECK_ENV_ROOT="${REVIEW_BOT_CHECK_ENV_ROOT:-$RUNTIME_ROOT/check-env}"
LEGACY_REPO_ROOT="${REVIEW_BOT_LEGACY_REPO_ROOT:-$RUNTIME_ROOT/repos}"
LOCK_ROOT="${REVIEW_BOT_LOCK_ROOT:-$RUNTIME_ROOT/locks}"
LEASE_ROOT="$LOCK_ROOT/worktree-leases"
QUEUE_FILE="${REVIEW_BOT_QUEUE_FILE:-$RUNTIME_ROOT/queue.jsonl}"
QUEUE_LOCK_FILE="${REVIEW_BOT_QUEUE_LOCK:-$RUNTIME_ROOT/queue.lock}"
STATE_LOCK_FILE="${REVIEW_BOT_STATE_LOCK:-$RUNTIME_ROOT/state.lock}"
MAINTENANCE_LOCK_FILE="${REVIEW_BOT_MAINTENANCE_LOCK:-$RUNTIME_ROOT/maintenance.lock}"

WORKTREE_DAYS="${REVIEW_BOT_MAINTENANCE_WORKTREE_DAYS:-$(jq -r '.maintenanceWorktreeDays // 14' "$CONFIG")}"
CHECK_ENV_DAYS="${REVIEW_BOT_MAINTENANCE_CHECK_ENV_DAYS:-$(jq -r '.maintenanceCheckEnvDays // 7' "$CONFIG")}"
PROMPT_DAYS="${REVIEW_BOT_MAINTENANCE_PROMPT_DAYS:-$(jq -r '.maintenancePromptDays // 14' "$CONFIG")}"
LOG_DAYS="${REVIEW_BOT_MAINTENANCE_LOG_DAYS:-$(jq -r '.maintenanceLogDays // 30' "$CONFIG")}"
LEGACY_CLONE_DAYS="${REVIEW_BOT_MAINTENANCE_LEGACY_CLONE_DAYS:-$(jq -r '.maintenanceLegacyCloneDays // 30' "$CONFIG")}"
CLOSED_STATE_DAYS="${REVIEW_BOT_MAINTENANCE_CLOSED_STATE_DAYS:-$(jq -r '.maintenanceClosedStateDays // 90' "$CONFIG")}"
TEMP_HOURS="${REVIEW_BOT_MAINTENANCE_TEMP_HOURS:-$(jq -r '.maintenanceTempHours // 24' "$CONFIG")}"

WORKSPACE="$(realpath -m "$WORKSPACE")"
WORKTREE_ROOT="$(realpath -m "$WORKTREE_ROOT")"
RUNTIME_ROOT="$(realpath -m "$RUNTIME_ROOT")"
LOG_ROOT="$(realpath -m "$LOG_ROOT")"
STATE_FILE="$(realpath -m "$STATE_FILE")"
PROMPT_DIR="$(realpath -m "$PROMPT_DIR")"
CHECK_ENV_ROOT="$(realpath -m "$CHECK_ENV_ROOT")"
LEGACY_REPO_ROOT="$(realpath -m "$LEGACY_REPO_ROOT")"
LOCK_ROOT="$(realpath -m "$LOCK_ROOT")"
LEASE_ROOT="$(realpath -m "$LEASE_ROOT")"
QUEUE_FILE="$(realpath -m "$QUEUE_FILE")"
QUEUE_LOCK_FILE="$(realpath -m "$QUEUE_LOCK_FILE")"
STATE_LOCK_FILE="$(realpath -m "$STATE_LOCK_FILE")"
MAINTENANCE_LOCK_FILE="$(realpath -m "$MAINTENANCE_LOCK_FILE")"

for retention_name in \
  WORKTREE_DAYS CHECK_ENV_DAYS PROMPT_DAYS LOG_DAYS LEGACY_CLONE_DAYS CLOSED_STATE_DAYS TEMP_HOURS; do
  review_bot_require_nonnegative_integer "$retention_name" "${!retention_name}"
done

for cleanup_root in "$WORKTREE_ROOT" "$LOG_ROOT" "$PROMPT_DIR" "$CHECK_ENV_ROOT" "$LEGACY_REPO_ROOT"; do
  if [[ "$cleanup_root" == "/" || "$cleanup_root" == "$REPO_ROOT" ]]; then
    echo "review-bot: refusing unsafe cleanup root: $cleanup_root" >&2
    exit 2
  fi
done
for runtime_child in "$PROMPT_DIR" "$CHECK_ENV_ROOT" "$LEGACY_REPO_ROOT"; do
  case "$runtime_child" in
    "$RUNTIME_ROOT"/*)
      ;;
    *)
      echo "review-bot: runtime cleanup path must stay under runtimeRoot: $runtime_child" >&2
      exit 2
      ;;
  esac
done

mkdir -p \
  "$RUNTIME_ROOT" "$LOCK_ROOT" "$(dirname "$QUEUE_LOCK_FILE")" \
  "$(dirname "$STATE_LOCK_FILE")" "$(dirname "$MAINTENANCE_LOCK_FILE")"
if [[ "$MODE" == "apply" ]]; then
  mkdir -p "$PROMPT_DIR" "$CHECK_ENV_ROOT" "$LOG_ROOT" "$(dirname "$STATE_FILE")"
fi

exec 9>"$MAINTENANCE_LOCK_FILE"
if ! flock -n 9; then
  echo "review-bot: maintenance is already running" >&2
  exit 1
fi
exec 7>"$QUEUE_LOCK_FILE"
flock 7
exec 8>"$STATE_LOCK_FILE"
flock 8

NOW_EPOCH="$(date +%s)"
declare -A PROTECTED_PROMPTS=()
declare -A PROTECTED_RUNS=()
declare -A QUEUED_KEYS=()
declare -A PROTECTED_LOG_DIRS=()
STATE_REMOVE_KEYS=()
QUEUE_VALID=1

mtime_epoch() {
  local path="$1"
  local value

  if value="$(stat -c '%Y' "$path" 2>/dev/null)"; then
    printf '%s\n' "$value"
  elif value="$(stat -f '%m' "$path" 2>/dev/null)"; then
    printf '%s\n' "$value"
  else
    return 1
  fi
}

older_than_seconds() {
  local path="$1"
  local seconds="$2"
  local modified

  modified="$(mtime_epoch "$path")" || return 1
  [[ "$((NOW_EPOCH - modified))" -ge "$seconds" ]]
}

report_action() {
  local category="$1"
  local target="$2"

  if [[ "$MODE" == "apply" ]]; then
    printf 'removed %s: %s\n' "$category" "$target"
  else
    printf 'would remove %s: %s\n' "$category" "$target"
  fi
}

safe_remove_path() {
  local category="$1"
  local target="$2"
  local allowed_root="$3"
  local canonical_root
  local canonical_target

  canonical_root="$(realpath -m "$allowed_root")"
  canonical_target="$(realpath -m "$target")"

  case "$canonical_target" in
    "$canonical_root"/*)
      ;;
    *)
      printf 'review-bot: refusing to remove %s outside %s: %s\n' \
        "$category" "$canonical_root" "$canonical_target" >&2
      return 1
      ;;
  esac

  if [[ "$MODE" == "apply" ]]; then
    rm -rf -- "$canonical_target"
  fi
  report_action "$category" "$canonical_target"
}

run_key_for_path() {
  local path="$1"
  local root="$2"
  local relative="${path#"$root"/}"
  local repo="${relative%%/*}"
  local run="${relative#*/}"

  printf '%s/%s\n' "$repo" "$run"
}

run_is_actively_leased() {
  local candidate="$1"
  local lease
  local lease_pid
  local leased_path

  [[ -d "$LEASE_ROOT" ]] || return 1
  while IFS= read -r -d '' lease; do
    IFS=$'\t' read -r lease_pid leased_path <"$lease" || true
    if review_bot_pid_running "$lease_pid" && [[ "$leased_path" == "$candidate" ]]; then
      return 0
    fi
  done < <(find "$LEASE_ROOT" -type f -name '*.lease' -print0 2>/dev/null)
  return 1
}

if [[ -f "$QUEUE_FILE" ]]; then
  while IFS= read -r item || [[ -n "$item" ]]; do
    [[ -n "$item" ]] || continue
    if ! jq -e '
      def owner: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9-]{0,38}$");
      def repo:
        type == "string"
        and test("^[A-Za-z0-9._-]{1,100}$")
        and . != "."
        and . != "..";
      def sha: type == "string" and test("^[0-9a-fA-F]{40}$");
      type == "object"
      and (.owner | owner)
      and (.repo | repo)
      and (.number | type == "number" and . == floor and . >= 1)
      and (.head_sha | sha)
      and (.prompt | type == "string")
    ' <<<"$item" >/dev/null; then
      QUEUE_VALID=0
      break
    fi
    queue_repo="$(jq -r '.repo' <<<"$item")"
    queue_number="$(jq -r '.number' <<<"$item")"
    queue_head="$(jq -r '.head_sha' <<<"$item")"
    queue_owner="$(jq -r '.owner' <<<"$item")"
    queue_prompt="$(realpath -m "$(jq -r '.prompt' <<<"$item")")"
    PROTECTED_PROMPTS["$queue_prompt"]=1
    PROTECTED_RUNS["$queue_repo/pr-$queue_number-${queue_head:0:12}"]=1
    QUEUED_KEYS["$queue_owner/$queue_repo#$queue_number"]=1
  done <"$QUEUE_FILE"
fi
if [[ "$QUEUE_VALID" -ne 1 ]]; then
  echo "review-bot: invalid queue; refusing maintenance: $QUEUE_FILE" >&2
  exit 1
fi

if [[ ! -f "$STATE_FILE" ]]; then
  STATE_JSON='{}'
elif ! jq -e '
  def sha: type == "string" and test("^[0-9a-fA-F]{40}$");
  type == "object"
  and all(
    to_entries[];
    (.key | test("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+#[1-9][0-9]*$"))
    and (.value | type == "object")
    and (.value.head_sha | sha)
    and (.value.base_sha | sha)
    and ((.value.status // "") | . == "clean" or . == "findings" or . == "inconclusive")
    and ((.value.review_kind // "semantic") | . == "semantic" or . == "check")
    and (.value.reviewed_at | type == "string")
    and ((.value.report // null) | . == null or type == "string")
  )
' "$STATE_FILE" >/dev/null 2>&1; then
  echo "review-bot: invalid state file; refusing maintenance: $STATE_FILE" >&2
  exit 1
else
  STATE_JSON="$(<"$STATE_FILE")"
fi

if [[ -d "$LEASE_ROOT" ]]; then
  while IFS= read -r -d '' lease; do
    IFS=$'\t' read -r lease_pid leased_path <"$lease" || true
    leased_path="$(realpath -m "$leased_path")"
    if review_bot_pid_running "$lease_pid"; then
      case "$leased_path" in
        "$WORKTREE_ROOT"/*/*)
          PROTECTED_RUNS["$(run_key_for_path "$leased_path" "$WORKTREE_ROOT")"]=1
          ;;
      esac
    else
      safe_remove_path "stale lease" "$lease" "$LEASE_ROOT"
    fi
  done < <(find "$LEASE_ROOT" -type f -name '*.lease' -print0 2>/dev/null)
fi

if command -v gh >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
  review_bot_configure_github_get "$CONFIG"
  while IFS=$'\t' read -r state_key reviewed_at; do
    [[ -n "$reviewed_at" && -z "${QUEUED_KEYS[$state_key]:-}" ]] || continue
    reviewed_epoch="$(date -u -d "$reviewed_at" +%s 2>/dev/null || true)"
    [[ "$reviewed_epoch" =~ ^[0-9]+$ ]] || continue
    [[ "$((NOW_EPOCH - reviewed_epoch))" -ge "$((CLOSED_STATE_DAYS * 86400))" ]] || continue
    if [[ "$state_key" =~ ^([^/]+)/([^#]+)#([1-9][0-9]*)$ ]]; then
      state_owner="${BASH_REMATCH[1]}"
      state_repo="${BASH_REMATCH[2]}"
      state_number="${BASH_REMATCH[3]}"
    else
      continue
    fi
    if pull_state="$(review_bot_gh_get "/repos/$state_owner/$state_repo/pulls/$state_number" --jq '.state')" &&
      [[ "$pull_state" == "closed" ]]; then
      STATE_REMOVE_KEYS+=("$state_key")
      if [[ "$MODE" == "dry-run" ]]; then
        report_action "closed state entry" "$state_key"
      fi
    fi
  done < <(jq -r 'to_entries[] | [.key, (.value.reviewed_at // "")] | @tsv' <<<"$STATE_JSON")
else
  echo "review-bot: warning: gh/timeout unavailable; closed state cleanup skipped" >&2
fi

if [[ "${#STATE_REMOVE_KEYS[@]}" -gt 0 ]]; then
  state_keys_json="$(printf '%s\n' "${STATE_REMOVE_KEYS[@]}" | jq -R . | jq -s .)"
  STATE_JSON="$(jq --argjson keys "$state_keys_json" 'delpaths($keys | map([.]))' <<<"$STATE_JSON")"
  if [[ "$MODE" == "apply" ]]; then
    state_tmp="$(mktemp "$(dirname "$STATE_FILE")/.reviews.maintenance.XXXXXX")"
    printf '%s\n' "$STATE_JSON" >"$state_tmp"
    mv "$state_tmp" "$STATE_FILE"
    state_tmp=""
    chmod 600 "$STATE_FILE"
    for state_key in "${STATE_REMOVE_KEYS[@]}"; do
      report_action "closed state entry" "$state_key"
    done
  fi
fi

while IFS= read -r report_path; do
  [[ -n "$report_path" ]] || continue
  case "$report_path" in
    "$LOG_ROOT"/*/pr-*/*)
      PROTECTED_LOG_DIRS["$(dirname "$report_path")"]=1
      ;;
  esac
done < <(jq -r 'to_entries[] | .value.report // empty' <<<"$STATE_JSON")

if [[ "$QUEUE_VALID" -eq 1 && -d "$PROMPT_DIR" ]]; then
  while IFS= read -r -d '' prompt; do
    [[ -z "${PROTECTED_PROMPTS[$prompt]:-}" ]] || continue
    older_than_seconds "$prompt" "$((PROMPT_DAYS * 86400))" || continue
    safe_remove_path "prompt" "$prompt" "$PROMPT_DIR"
  done < <(find "$PROMPT_DIR" -maxdepth 1 -type f -name '*.md' -print0)
fi

if [[ "$QUEUE_VALID" -eq 1 && -d "$CHECK_ENV_ROOT" ]]; then
  while IFS= read -r -d '' check_env; do
    run_key="$(run_key_for_path "$check_env" "$CHECK_ENV_ROOT")"
    [[ -z "${PROTECTED_RUNS[$run_key]:-}" ]] || continue
    older_than_seconds "$check_env" "$((CHECK_ENV_DAYS * 86400))" || continue
    safe_remove_path "check environment" "$check_env" "$CHECK_ENV_ROOT"
  done < <(find "$CHECK_ENV_ROOT" -mindepth 2 -maxdepth 2 -type d -name 'pr-*' -print0)
fi

if [[ "$QUEUE_VALID" -eq 1 && -d "$LOG_ROOT" ]]; then
  while IFS= read -r -d '' log_dir; do
    run_key="$(run_key_for_path "$log_dir" "$LOG_ROOT")"
    [[ -z "${PROTECTED_RUNS[$run_key]:-}" ]] || continue
    [[ -z "${PROTECTED_LOG_DIRS[$log_dir]:-}" ]] || continue
    older_than_seconds "$log_dir" "$((LOG_DAYS * 86400))" || continue
    safe_remove_path "review log" "$log_dir" "$LOG_ROOT"
  done < <(find "$LOG_ROOT" -mindepth 2 -maxdepth 2 -type d -name 'pr-*' -print0)
fi

if [[ "$QUEUE_VALID" -eq 1 && -d "$WORKTREE_ROOT" ]]; then
  while IFS= read -r -d '' worktree; do
    run_key="$(run_key_for_path "$worktree" "$WORKTREE_ROOT")"
    [[ -z "${PROTECTED_RUNS[$run_key]:-}" ]] || continue
    run_is_actively_leased "$worktree" && continue
    older_than_seconds "$worktree" "$((WORKTREE_DAYS * 86400))" || continue
    relative="${worktree#"$WORKTREE_ROOT"/}"
    worktree_repo="${relative%%/*}"
    base_repo="$(review_bot_repo_dir "$REPO_ROOT" "$WORKSPACE" "$CONFIG" "$worktree_repo")"
    if [[ "$MODE" == "apply" ]]; then
      if ! git -C "$base_repo" worktree remove --force "$worktree" >/dev/null 2>&1; then
        printf 'review-bot: warning: could not safely remove worktree %s\n' "$worktree" >&2
        continue
      fi
    fi
    report_action "worktree" "$worktree"
  done < <(find "$WORKTREE_ROOT" -mindepth 2 -maxdepth 2 -type d -name 'pr-*' -print0)
fi

if [[ -d "$LEGACY_REPO_ROOT" ]]; then
  while IFS= read -r -d '' legacy_clone; do
    older_than_seconds "$legacy_clone" "$((LEGACY_CLONE_DAYS * 86400))" || continue
    safe_remove_path "legacy runtime clone" "$legacy_clone" "$LEGACY_REPO_ROOT"
  done < <(find "$LEGACY_REPO_ROOT" -mindepth 1 -maxdepth 1 -type d -print0)
fi

while IFS= read -r -d '' temp_file; do
  older_than_seconds "$temp_file" "$((TEMP_HOURS * 3600))" || continue
  safe_remove_path "temporary file" "$temp_file" "$RUNTIME_ROOT"
done < <(find "$RUNTIME_ROOT" -maxdepth 1 -type f \( -name '.queue.*' -o -name '.health.*' \) -print0)
while IFS= read -r -d '' temp_file; do
  older_than_seconds "$temp_file" "$((TEMP_HOURS * 3600))" || continue
  safe_remove_path "temporary file" "$temp_file" "$PROMPT_DIR"
done < <(find "$PROMPT_DIR" -maxdepth 1 -type f -name '.prompt.*' -print0)
while IFS= read -r -d '' temp_file; do
  older_than_seconds "$temp_file" "$((TEMP_HOURS * 3600))" || continue
  safe_remove_path "temporary file" "$temp_file" "$(dirname "$STATE_FILE")"
done < <(find "$(dirname "$STATE_FILE")" -maxdepth 1 -type f -name '.reviews.*' -print0)

if [[ "$MODE" == "dry-run" ]]; then
  echo "review-bot: dry-run complete; rerun with --apply to remove listed items"
else
  echo "review-bot: maintenance apply complete"
fi
