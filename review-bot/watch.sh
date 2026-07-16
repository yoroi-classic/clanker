#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${REVIEW_BOT_CONFIG:-$SCRIPT_DIR/config.json}"
source "$SCRIPT_DIR/lib/paths.sh"
REPO_ROOT="$(review_bot_repo_root "$SCRIPT_DIR")"
MODE="${1:-watch}"
child_pid=""

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "review-bot: missing required command: $1" >&2
    exit 2
  fi
}

require flock
require jq

"$SCRIPT_DIR/validate-config.sh" "$CONFIG" >/dev/null

POLL_SECONDS="${REVIEW_BOT_POLL_SECONDS:-$(jq -r '.pollSeconds // 300' "$CONFIG")}"
RUNTIME_ROOT="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_RUNTIME_ROOT:-}" "$CONFIG" '.runtimeRoot' 'review-bot/.runtime')"
PROMPT_DIR="${REVIEW_BOT_PROMPT_DIR:-$RUNTIME_ROOT/prompts}"
QUEUE_FILE="${REVIEW_BOT_QUEUE_FILE:-$RUNTIME_ROOT/queue.jsonl}"
QUEUE_LOCK_FILE="${REVIEW_BOT_QUEUE_LOCK:-$RUNTIME_ROOT/queue.lock}"
HEALTH_FILE="${REVIEW_BOT_HEALTH_FILE:-$RUNTIME_ROOT/health.json}"
WATCH_LOG="${REVIEW_BOT_WATCH_LOG:-}"
WATCH_LOG_MAX_BYTES="${REVIEW_BOT_WATCH_LOG_MAX_BYTES:-$(jq -r '.watchLogMaxBytes // 5242880' "$CONFIG")}"
WATCH_LOG_RETAIN="${REVIEW_BOT_WATCH_LOG_RETAIN:-$(jq -r '.watchLogRetain // 3' "$CONFIG")}"
DISCOVERY_TIMEOUT_SECONDS="${REVIEW_BOT_DISCOVERY_TIMEOUT_SECONDS:-$(jq -r '.discoveryTimeoutSeconds // 30' "$CONFIG")}"
DISCOVERY_MAX_ATTEMPTS="${REVIEW_BOT_DISCOVERY_MAX_ATTEMPTS:-$(jq -r '.discoveryMaxAttempts // 4' "$CONFIG")}"
DISCOVERY_BACKOFF_BASE_SECONDS="${REVIEW_BOT_DISCOVERY_BACKOFF_BASE_SECONDS:-$(jq -r '.discoveryBackoffBaseSeconds // 2' "$CONFIG")}"
DISCOVERY_BACKOFF_MAX_SECONDS="${REVIEW_BOT_DISCOVERY_BACKOFF_MAX_SECONDS:-$(jq -r '.discoveryBackoffMaxSeconds // 30' "$CONFIG")}"
LIST_QUEUE_SCRIPT="${REVIEW_BOT_LIST_QUEUE_SCRIPT:-$SCRIPT_DIR/list-queue.sh}"
AGENT_PROMPT_SCRIPT="${REVIEW_BOT_AGENT_PROMPT_SCRIPT:-$SCRIPT_DIR/agent-prompt.sh}"

review_bot_require_positive_integer pollSeconds "$POLL_SECONDS"
review_bot_require_positive_integer discoveryTimeoutSeconds "$DISCOVERY_TIMEOUT_SECONDS"
review_bot_require_positive_integer discoveryMaxAttempts "$DISCOVERY_MAX_ATTEMPTS"
review_bot_require_positive_integer discoveryBackoffBaseSeconds "$DISCOVERY_BACKOFF_BASE_SECONDS"
review_bot_require_positive_integer discoveryBackoffMaxSeconds "$DISCOVERY_BACKOFF_MAX_SECONDS"
review_bot_require_positive_integer watchLogMaxBytes "$WATCH_LOG_MAX_BYTES"
review_bot_require_nonnegative_integer watchLogRetain "$WATCH_LOG_RETAIN"
if [[ "$DISCOVERY_BACKOFF_MAX_SECONDS" -lt "$DISCOVERY_BACKOFF_BASE_SECONDS" ]]; then
  echo "review-bot: discoveryBackoffMaxSeconds must be at least discoveryBackoffBaseSeconds" >&2
  exit 2
fi

case "$MODE" in
  watch|--watch)
    MODE="watch"
    ;;
  once|--once)
    MODE="once"
    ;;
  *)
    echo "usage: $0 [watch|once]" >&2
    exit 2
    ;;
esac

timestamp() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

log_message() {
  printf '%s review-bot: %s\n' "$(timestamp)" "$*"
}

stop_child() {
  if [[ -n "$child_pid" ]] && review_bot_pid_running "$child_pid"; then
    review_bot_terminate_tree "$child_pid"
    wait "$child_pid" >/dev/null 2>&1 || true
  fi
  child_pid=""
}

cleanup_orphan_temps_unlocked() {
  find "$RUNTIME_ROOT" -maxdepth 1 -type f \
    \( -name '.queue.*' -o -name '.health.*' \) -delete 2>/dev/null || true
  find "$PROMPT_DIR" -maxdepth 1 -type f -name '.prompt.*' -delete 2>/dev/null || true
  find "$(dirname "$HEALTH_FILE")" -maxdepth 1 -type f -name '.health.*' -delete 2>/dev/null || true
}

cleanup_orphan_temps() {
  mkdir -p "$RUNTIME_ROOT" "$PROMPT_DIR" "$(dirname "$HEALTH_FILE")" "$(dirname "$QUEUE_LOCK_FILE")"
  if [[ "${REVIEW_BOT_QUEUE_LOCK_HELD:-0}" == "1" ]]; then
    cleanup_orphan_temps_unlocked
    return
  fi

  (
    flock 9
    cleanup_orphan_temps_unlocked
  ) 9>"$QUEUE_LOCK_FILE"
}

shutdown() {
  log_message "watcher stopping"
  stop_child
  cleanup_orphan_temps
  exit 0
}

trap shutdown INT TERM

queue_count() {
  if [[ -f "$QUEUE_FILE" ]] && jq -e -s 'type == "array"' "$QUEUE_FILE" >/dev/null 2>&1; then
    jq -s 'length' "$QUEUE_FILE"
  else
    printf '0\n'
  fi
}

write_health() (
  set -euo pipefail

  local status="$1"
  local error_message="${2:-}"
  local previous='{}'
  local now_epoch
  local now_iso
  local last_success_at
  local last_success_epoch
  local previous_failures
  local failures
  local count
  local health_tmp=""

  cleanup_health_tmp() {
    [[ -z "$health_tmp" ]] || rm -f "$health_tmp"
  }
  trap cleanup_health_tmp EXIT INT TERM

  mkdir -p "$(dirname "$HEALTH_FILE")"
  if [[ -f "$HEALTH_FILE" ]]; then
    previous="$(jq -c 'if type == "object" then . else {} end' "$HEALTH_FILE" 2>/dev/null)" || previous='{}'
  fi

  now_epoch="$(date +%s)"
  now_iso="$(timestamp)"
  count="$(queue_count)"
  if [[ "$status" == "ok" ]]; then
    last_success_at="$now_iso"
    last_success_epoch="$now_epoch"
    failures=0
    error_message=""
  else
    last_success_at="$(jq -r '
      if (.last_success_at | type) == "string" then .last_success_at else empty end
    ' <<<"$previous")"
    last_success_epoch="$(jq -r '
      if (.last_success_epoch | type) == "number"
        and .last_success_epoch == (.last_success_epoch | floor)
        and .last_success_epoch >= 0
      then .last_success_epoch
      else 0
      end
    ' <<<"$previous")"
    previous_failures="$(jq -r '
      if (.consecutive_failures | type) == "number"
        and .consecutive_failures == (.consecutive_failures | floor)
        and .consecutive_failures >= 0
      then .consecutive_failures
      else 0
      end
    ' <<<"$previous")"
    failures="$((previous_failures + 1))"
  fi

  health_tmp="$(mktemp "$(dirname "$HEALTH_FILE")/.health.XXXXXX")"
  jq -n \
    --arg status "$status" \
    --arg last_attempt_at "$now_iso" \
    --argjson last_attempt_epoch "$now_epoch" \
    --arg last_success_at "$last_success_at" \
    --argjson last_success_epoch "$last_success_epoch" \
    --arg last_error "$error_message" \
    --argjson consecutive_failures "$failures" \
    --argjson queue_count "$count" \
    '{
      status: $status,
      last_attempt_at: $last_attempt_at,
      last_attempt_epoch: $last_attempt_epoch,
      last_success_at: (if $last_success_at == "" then null else $last_success_at end),
      last_success_epoch: (if $last_success_epoch == 0 then null else $last_success_epoch end),
      last_error: (if $last_error == "" then null else $last_error end),
      consecutive_failures: $consecutive_failures,
      queue_count: $queue_count
    }' >"$health_tmp"
  mv "$health_tmp" "$HEALTH_FILE"
  health_tmp=""
)

refresh_queue() (
  set -euo pipefail

  local raw_tmp=""
  local queue_tmp=""
  local prompt_tmp=""
  local count=0
  local repo
  local number
  local owner
  local head_sha
  local base_sha
  local short_sha
  local short_base_sha
  local prompt_file
  local item
  local had_queue=0
  local old_map='{}'
  local new_map
  local delta
  local change

  cleanup_refresh_temps() {
    [[ -z "$raw_tmp" ]] || rm -f "$raw_tmp"
    [[ -z "$queue_tmp" ]] || rm -f "$queue_tmp"
    [[ -z "$prompt_tmp" ]] || rm -f "$prompt_tmp"
  }
  trap cleanup_refresh_temps EXIT INT TERM

  mkdir -p "$RUNTIME_ROOT" "$PROMPT_DIR" "$(dirname "$QUEUE_FILE")"
  raw_tmp="$(mktemp "$RUNTIME_ROOT/.queue.raw.XXXXXX")"
  queue_tmp="$(mktemp "$RUNTIME_ROOT/.queue.XXXXXX")"

  "$LIST_QUEUE_SCRIPT" pending >"$raw_tmp"

  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    owner="$(jq -r '.owner' <<<"$item")"
    repo="$(jq -r '.repo' <<<"$item")"
    number="$(jq -r '.number' <<<"$item")"
    head_sha="$(jq -r '.head_sha' <<<"$item")"
    base_sha="$(jq -r '.base_sha' <<<"$item")"
    review_bot_validate_owner "$owner"
    review_bot_validate_repo "$repo"
    review_bot_validate_pr_number "$number"
    review_bot_validate_sha head "$head_sha"
    review_bot_validate_sha base "$base_sha"
    short_sha="${head_sha:0:12}"
    short_base_sha="${base_sha:0:12}"
    prompt_file="$PROMPT_DIR/$owner-$repo-$number-$short_base_sha-$short_sha.md"

    if [[ ! -f "$prompt_file" ]]; then
      prompt_tmp="$(mktemp "$PROMPT_DIR/.prompt.XXXXXX")"
      REVIEW_BOT_PROMPT_METADATA_JSON="$item" \
        "$AGENT_PROMPT_SCRIPT" "$repo" "$number" >"$prompt_tmp"
      mv "$prompt_tmp" "$prompt_file"
      prompt_tmp=""
    fi

    jq -c --arg prompt "$prompt_file" '. + {prompt:$prompt}' <<<"$item" >>"$queue_tmp"
    count="$((count + 1))"
  done <"$raw_tmp"

  if [[ -f "$QUEUE_FILE" ]]; then
    had_queue=1
    old_map="$(jq -s '
      map({
        key: ([.owner, .repo, (.number | tostring), .base_sha, .head_sha] | join("\u001f")),
        value: .
      }) | from_entries
    ' "$QUEUE_FILE")"
  fi
  new_map="$(jq -s '
    map({
      key: ([.owner, .repo, (.number | tostring), .base_sha, .head_sha] | join("\u001f")),
      value: .
    }) | from_entries
  ' "$queue_tmp")"
  delta="$(jq -n --argjson old "$old_map" --argjson new "$new_map" '
    {
      added: (($new | keys) - ($old | keys) | map($new[.])),
      removed: (($old | keys) - ($new | keys) | map($old[.]))
    }
  ')"

  mv "$queue_tmp" "$QUEUE_FILE"
  queue_tmp=""
  rm -f "$raw_tmp"
  raw_tmp=""

  while IFS= read -r change; do
    [[ -n "$change" ]] || continue
    log_message "queue added $(jq -r '"\(.owner)/\(.repo)#\(.number) at \(.head_sha): \(.prompt)"' <<<"$change")"
  done < <(jq -c '.added[]' <<<"$delta")
  while IFS= read -r change; do
    [[ -n "$change" ]] || continue
    log_message "queue removed $(jq -r '"\(.owner)/\(.repo)#\(.number) at \(.head_sha)"' <<<"$change")"
  done < <(jq -c '.removed[]' <<<"$delta")

  if [[ "$had_queue" -eq 0 ]] || jq -e '(.added | length) > 0 or (.removed | length) > 0' <<<"$delta" >/dev/null; then
    log_message "queue now has $count pending semantic review prompt(s)"
  fi
)

poll_once_unlocked() {
  local rc

  set +e
  refresh_queue
  rc="$?"
  set -e
  if [[ "$rc" -eq 0 ]]; then
    write_health ok
    return 0
  fi

  write_health error "queue refresh failed with exit $rc; last valid queue preserved"
  log_message "poll failed with exit $rc; last valid queue preserved" >&2
  return "$rc"
}

poll_once() {
  if [[ "${REVIEW_BOT_QUEUE_LOCK_HELD:-0}" == "1" ]]; then
    poll_once_unlocked
    return
  fi

  mkdir -p "$(dirname "$QUEUE_LOCK_FILE")"
  (
    flock 9
    poll_once_unlocked
  ) 9>"$QUEUE_LOCK_FILE"
}

run_poll() {
  local rc

  poll_once &
  child_pid="$!"
  set +e
  wait "$child_pid"
  rc="$?"
  set -e
  child_pid=""
  cleanup_orphan_temps
  return "$rc"
}

if [[ "$MODE" == "once" ]]; then
  set +e
  run_poll
  rc="$?"
  set -e
  exit "$rc"
fi

while true; do
  set +e
  run_poll
  set -e

  if [[ -n "$WATCH_LOG" ]]; then
    review_bot_rotate_log "$WATCH_LOG" "$WATCH_LOG_MAX_BYTES" "$WATCH_LOG_RETAIN"
  fi

  sleep "$POLL_SECONDS" &
  child_pid="$!"
  set +e
  wait "$child_pid"
  set -e
  child_pid=""
done
