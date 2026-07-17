#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${REVIEW_BOT_CONFIG:-$SCRIPT_DIR/config.json}"
source "$SCRIPT_DIR/lib/paths.sh"
source "$SCRIPT_DIR/lib/github.sh"
REPO_ROOT="$(review_bot_repo_root "$SCRIPT_DIR")"
MODE="${1:-watch}"
POLL_SECONDS="${REVIEW_BOT_POLL_SECONDS:-$(jq -r '.pollSeconds // 300' "$CONFIG")}"
RUNTIME_ROOT="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_RUNTIME_ROOT:-}" "$CONFIG" '.runtimeRoot' 'review-bot/.runtime')"
PROMPT_DIR="${REVIEW_BOT_PROMPT_DIR:-$RUNTIME_ROOT/prompts}"
QUEUE_FILE="${REVIEW_BOT_QUEUE_FILE:-$RUNTIME_ROOT/queue.jsonl}"
QUEUE_LOCK_FILE="${REVIEW_BOT_QUEUE_LOCK:-$RUNTIME_ROOT/queue.lock}"
HEALTH_FILE="${REVIEW_BOT_HEALTH_FILE:-$RUNTIME_ROOT/health.json}"
DISCOVERY_TIMEOUT_SECONDS="${REVIEW_BOT_DISCOVERY_TIMEOUT_SECONDS:-$(jq -r '.discoveryTimeoutSeconds // 30' "$CONFIG")}"
DISCOVERY_RETRIES="${REVIEW_BOT_DISCOVERY_RETRIES:-$(jq -r '.discoveryRetries // 3' "$CONFIG")}"
DISCOVERY_RETRY_BASE_SECONDS="${REVIEW_BOT_DISCOVERY_RETRY_BASE_SECONDS:-$(jq -r '.discoveryRetryBaseSeconds // 2' "$CONFIG")}"
DISCOVERY_RETRY_JITTER_SECONDS="${REVIEW_BOT_DISCOVERY_RETRY_JITTER_SECONDS:-$(jq -r '.discoveryRetryJitterSeconds // 1' "$CONFIG")}"
child_pid=""
active_temps=()

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "review-bot: missing required command: $1" >&2
    exit 2
  fi
}

require flock
require jq
require timeout

review_bot_validate_discovery_config \
  "$POLL_SECONDS" \
  "$DISCOVERY_TIMEOUT_SECONDS" \
  "$DISCOVERY_RETRIES" \
  "$DISCOVERY_RETRY_BASE_SECONDS" \
  "$DISCOVERY_RETRY_JITTER_SECONDS"

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

stop_child() {
  if [[ -n "$child_pid" ]] && review_bot_pid_running "$child_pid"; then
    review_bot_terminate_tree "$child_pid"
    wait "$child_pid" >/dev/null 2>&1 || true
  fi
}

cleanup_temps() {
  local path
  for path in "${active_temps[@]}"; do
    [[ -n "$path" ]] || continue
    rm -f "$path"
  done
  active_temps=()
}

shutdown() {
  printf '%s review-bot: watcher stopping\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  stop_child
  cleanup_temps
  exit 0
}

trap shutdown INT TERM
trap cleanup_temps EXIT

write_health() {
  local status="$1"
  local count="$2"
  local added="$3"
  local removed="$4"
  local error="$5"
  local previous_success=""
  local health_tmp

  mkdir -p "$(dirname "$HEALTH_FILE")"
  if [[ -f "$HEALTH_FILE" ]]; then
    previous_success="$(jq -r '.last_success // empty' "$HEALTH_FILE" 2>/dev/null || true)"
  fi
  if [[ "$status" == "healthy" ]]; then
    previous_success="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi

  health_tmp="$(mktemp "$(dirname "$HEALTH_FILE")/.health.XXXXXX")"
  active_temps+=("$health_tmp")
  jq -n \
    --arg status "$status" \
    --arg checked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg last_success "$previous_success" \
    --arg error "$error" \
    --argjson queue_count "$count" \
    --argjson added "$added" \
    --argjson removed "$removed" \
    '{
      status:$status,
      checked_at:$checked_at,
      last_success:(if $last_success == "" then null else $last_success end),
      queue_count:$queue_count,
      added:$added,
      removed:$removed,
      error:(if $error == "" then null else $error end)
    }' >"$health_tmp"
  mv "$health_tmp" "$HEALTH_FILE"
}

poll_once_unlocked() {
  local queue_tmp
  local raw_tmp
  local count=0
  local repo
  local number
  local owner
  local head_sha
  local base_sha
  local short_sha
  local short_base_sha
  local prompt_file
  local prompt_tmp
  local old_keys=""
  local new_keys=""
  local added=0
  local removed=0
  local current_count=0

  mkdir -p "$RUNTIME_ROOT" "$PROMPT_DIR" "$(dirname "$QUEUE_FILE")"
  raw_tmp="$(mktemp "$RUNTIME_ROOT/.queue.raw.XXXXXX")"
  queue_tmp="$(mktemp "$RUNTIME_ROOT/.queue.XXXXXX")"
  active_temps+=("$raw_tmp" "$queue_tmp")

  if ! "$SCRIPT_DIR/list-queue.sh" pending >"$raw_tmp"; then
    if [[ -f "$QUEUE_FILE" ]]; then
      current_count="$(wc -l <"$QUEUE_FILE")"
    fi
    write_health "stale" "$current_count" 0 0 "GitHub queue refresh failed"
    cleanup_temps
    return 1
  fi

  if [[ -f "$QUEUE_FILE" ]]; then
    old_keys="$(jq -r '"\(.owner)/\(.repo)#\(.number)@\(.base_sha):\(.head_sha)"' "$QUEUE_FILE" 2>/dev/null | sort || true)"
  fi

  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    owner="$(jq -r '.owner' <<<"$item")"
    repo="$(jq -r '.repo' <<<"$item")"
    number="$(jq -r '.number' <<<"$item")"
    head_sha="$(jq -r '.head_sha' <<<"$item")"
    base_sha="$(jq -r '.base_sha' <<<"$item")"
    short_sha="${head_sha:0:12}"
    short_base_sha="${base_sha:0:12}"
    prompt_file="$PROMPT_DIR/$owner-$repo-$number-$short_base_sha-$short_sha.md"

    if [[ ! -f "$prompt_file" ]]; then
      prompt_tmp="$(mktemp "$PROMPT_DIR/.prompt.XXXXXX")"
      active_temps+=("$prompt_tmp")
      "$SCRIPT_DIR/agent-prompt.sh" "$repo" "$number" >"$prompt_tmp"
      mv "$prompt_tmp" "$prompt_file"
      printf '%s review-bot: added prompt for %s/%s#%s at %s: %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$owner" "$repo" "$number" "$head_sha" "$prompt_file"
    fi

    jq -c --arg prompt "$prompt_file" '. + {prompt:$prompt}' <<<"$item" >>"$queue_tmp"
    count="$((count + 1))"
  done <"$raw_tmp"

  new_keys="$(jq -r '"\(.owner)/\(.repo)#\(.number)@\(.base_sha):\(.head_sha)"' "$queue_tmp" 2>/dev/null | sort || true)"
  added="$(comm -13 <(printf '%s\n' "$old_keys") <(printf '%s\n' "$new_keys") | sed '/^$/d' | wc -l)"
  removed="$(comm -23 <(printf '%s\n' "$old_keys") <(printf '%s\n' "$new_keys") | sed '/^$/d' | wc -l)"
  mv "$queue_tmp" "$QUEUE_FILE"
  rm -f "$raw_tmp"
  active_temps=()
  write_health "healthy" "$count" "$added" "$removed" ""
  active_temps=()

  if [[ "$added" -eq 0 && "$removed" -eq 0 ]]; then
    printf '%s review-bot: queue unchanged (%s pending)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$count"
  else
    printf '%s review-bot: queue changed: +%s -%s (%s pending)\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$added" "$removed" "$count"
  fi
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

if [[ "$MODE" == "once" ]]; then
  poll_once
  exit "$?"
fi

while true; do
  printf '%s review-bot: poll starting\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  poll_once &
  child_pid="$!"
  set +e
  wait "$child_pid"
  rc="$?"
  set -e
  if [[ "$rc" -ne 0 ]]; then
    printf '%s review-bot: poll finished with failures\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
  else
    printf '%s review-bot: poll finished\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
  child_pid=""

  sleep "$POLL_SECONDS" &
  child_pid="$!"
  set +e
  wait "$child_pid"
  rc="$?"
  set -e
  if [[ "$rc" -ne 0 ]]; then
    child_pid=""
    continue
  fi
  child_pid=""
done
