#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${REVIEW_BOT_CONFIG:-$SCRIPT_DIR/config.json}"
source "$SCRIPT_DIR/lib/paths.sh"
source "$SCRIPT_DIR/lib/github.sh"
REPO_ROOT="$(review_bot_repo_root "$SCRIPT_DIR")"
DOCTOR_REPO_ROOT="${REVIEW_BOT_DOCTOR_REPO_ROOT:-$REPO_ROOT}"
failures=0
warnings=0

pass() {
  printf 'PASS %s: %s\n' "$1" "$2"
}

warn() {
  printf 'WARN %s: %s\n' "$1" "$2"
  warnings="$((warnings + 1))"
}

fail() {
  printf 'FAIL %s: %s\n' "$1" "$2"
  failures="$((failures + 1))"
}

required_tools=(awk base64 bash bwrap date du find flock gh git jq ps realpath timeout)
missing_tools=()
for tool in "${required_tools[@]}"; do
  command -v "$tool" >/dev/null 2>&1 || missing_tools+=("$tool")
done
if [[ "${#missing_tools[@]}" -eq 0 ]]; then
  pass tools "all required commands are available"
else
  fail tools "missing ${missing_tools[*]}"
fi

if "$SCRIPT_DIR/validate-config.sh" "$CONFIG" >/dev/null 2>&1; then
  pass config "$CONFIG"
else
  fail config "invalid configuration: $CONFIG"
  printf 'review-bot doctor: %s failure(s), %s warning(s)\n' "$failures" "$warnings"
  exit 1
fi

WORKSPACE="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_WORKSPACE:-}" "$CONFIG" '.workspace' 'repos')"
WORKTREE_ROOT="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_WORKTREE_ROOT:-}" "$CONFIG" '.worktreeRoot' 'review-bot/.runtime/worktrees')"
RUNTIME_ROOT="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_RUNTIME_ROOT:-}" "$CONFIG" '.runtimeRoot' 'review-bot/.runtime')"
LOG_ROOT="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_LOG_ROOT:-}" "$CONFIG" '.logRoot' 'review-bot/logs')"
STATE_FILE="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_STATE_FILE:-}" "$CONFIG" '.stateFile' 'review-bot/state/reviews.json')"
PID_FILE="${REVIEW_BOT_PID_FILE:-$RUNTIME_ROOT/watch.pid}"
HEALTH_FILE="${REVIEW_BOT_HEALTH_FILE:-$RUNTIME_ROOT/health.json}"
WATCH_SCRIPT="${REVIEW_BOT_WATCH_SCRIPT:-$SCRIPT_DIR/watch.sh}"
WATCH_SCRIPT_PATH="$(cd "$(dirname "$WATCH_SCRIPT")" && pwd)/$(basename "$WATCH_SCRIPT")"
HEALTH_STALE_SECONDS="${REVIEW_BOT_HEALTH_STALE_SECONDS:-$(jq -r '.healthStaleSeconds // 900' "$CONFIG")}"
review_bot_require_positive_integer healthStaleSeconds "$HEALTH_STALE_SECONDS"
review_bot_configure_github_get "$CONFIG"

check_directory() {
  local label="$1"
  local path="$2"
  local existing="$path"

  while [[ ! -e "$existing" && "$existing" != "/" ]]; do
    existing="$(dirname "$existing")"
  done
  if [[ ! -d "$existing" ]]; then
    fail "$label" "no existing directory parent for $path"
  elif [[ ! -r "$existing" || ! -w "$existing" || ! -x "$existing" ]]; then
    fail "$label" "path is not accessible/read-write: $existing"
  else
    pass "$label" "$path"
  fi
}

if [[ -d "$WORKSPACE" ]]; then
  pass workspace "$WORKSPACE"
else
  fail workspace "missing $WORKSPACE"
fi
check_directory runtime "$RUNTIME_ROOT"
check_directory worktrees "$WORKTREE_ROOT"
check_directory logs "$LOG_ROOT"
check_directory state-path "$(dirname "$STATE_FILE")"

if [[ ! -f "$STATE_FILE" ]]; then
  warn state "not created yet: $STATE_FILE"
elif jq -e '
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
  pass state "valid JSON object with $(jq 'length' "$STATE_FILE") record(s)"
else
  fail state "invalid record structure in $STATE_FILE"
fi

missing_reports=0
if [[ -f "$STATE_FILE" ]] && jq -e 'type == "object"' "$STATE_FILE" >/dev/null 2>&1; then
  while IFS= read -r report_path; do
    [[ -z "$report_path" || -f "$report_path" ]] || missing_reports="$((missing_reports + 1))"
  done < <(jq -r 'to_entries[] | .value.report // empty' "$STATE_FILE")
  if [[ "$missing_reports" -eq 0 ]]; then
    pass state-reports "all referenced reports exist"
  else
    warn state-reports "$missing_reports referenced report(s) are missing"
  fi
fi

if command -v gh >/dev/null 2>&1 &&
  timeout --kill-after=5s "${REVIEW_BOT_GH_TIMEOUT_SECONDS}s" gh auth status >/dev/null 2>&1; then
  pass github-auth "GitHub CLI is authenticated"
  if reviewer="$(review_bot_resolve_reviewer_bounded "$CONFIG" 2>/dev/null)" && [[ -n "$reviewer" ]]; then
    pass reviewer "$reviewer"
  else
    fail reviewer "could not resolve configured/authenticated reviewer"
  fi
  if rate="$(review_bot_gh_get rate_limit --jq '.resources.core | "remaining=\(.remaining) limit=\(.limit) reset=\(.reset)"' 2>/dev/null)"; then
    pass rate-limit "$rate"
  else
    fail rate-limit "could not read GitHub core rate limit"
  fi
else
  fail github-auth "GitHub CLI is not authenticated"
fi

watcher_pid=""
if [[ -f "$PID_FILE" ]] && review_bot_pid_is_watch "$(<"$PID_FILE")" "$WATCH_SCRIPT_PATH"; then
  watcher_pid="$(<"$PID_FILE")"
else
  watcher_pid="$(review_bot_find_watch_pid "$WATCH_SCRIPT_PATH" || true)"
  if [[ -n "$watcher_pid" ]]; then
    mkdir -p "$(dirname "$PID_FILE")"
    printf '%s\n' "$watcher_pid" >"$PID_FILE"
  elif [[ -f "$PID_FILE" ]]; then
    rm -f "$PID_FILE"
  fi
fi

if [[ -n "$watcher_pid" ]]; then
  if [[ ! -f "$HEALTH_FILE" ]]; then
    fail watcher "pid $watcher_pid is running without a completed health record"
  elif review_bot_health_file_is_valid "$HEALTH_FILE"; then
    watcher_health="$(jq -r '"status=\(.status) failures=\(.consecutive_failures // 0) queue=\(.queue_count // 0)"' "$HEALTH_FILE")"
    last_success_epoch="$(jq -r '.last_success_epoch // 0' "$HEALTH_FILE")"
    if [[ "$(jq -r '.status' "$HEALTH_FILE")" == "error" ]]; then
      fail watcher "pid $watcher_pid $watcher_health"
    elif [[ "$last_success_epoch" -eq 0 ]] ||
      [[ "$(( $(date +%s) - last_success_epoch ))" -gt "$HEALTH_STALE_SECONDS" ]]; then
      fail watcher "pid $watcher_pid stale $watcher_health"
    else
      pass watcher "pid $watcher_pid $watcher_health"
    fi
  else
    fail watcher "invalid health file: $HEALTH_FILE"
  fi
else
  warn watcher "not running"
fi

if ! submodule_output="$(git -C "$DOCTOR_REPO_ROOT" submodule status --recursive 2>/dev/null)"; then
  fail submodules "could not inspect recursive submodules under $DOCTOR_REPO_ROOT"
else
  if grep -q '^-' <<<"$submodule_output"; then
    fail submodules "one or more recursive submodules are not initialized"
  else
    pass submodules "recursive submodules are initialized"
  fi
  if grep -q '^+' <<<"$submodule_output"; then
    warn submodule-pins "one or more checkouts differ from pinned SHAs"
  else
    pass submodule-pins "checked-out SHAs match the superproject"
  fi
fi

for size_path in "$RUNTIME_ROOT" "$WORKTREE_ROOT" "$LOG_ROOT" "$(dirname "$STATE_FILE")"; do
  if [[ -e "$size_path" ]]; then
    size="$(du -sh "$size_path" 2>/dev/null | awk '{print $1}')"
    printf 'INFO size: %s %s\n' "$size" "$size_path"
  else
    printf 'INFO size: 0 %s\n' "$size_path"
  fi
done

printf 'review-bot doctor: %s failure(s), %s warning(s)\n' "$failures" "$warnings"
[[ "$failures" -eq 0 ]]
