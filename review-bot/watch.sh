#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${REVIEW_BOT_CONFIG:-$SCRIPT_DIR/config.json}"
source "$SCRIPT_DIR/lib/paths.sh"
REPO_ROOT="$(review_bot_repo_root "$SCRIPT_DIR")"
MODE="${1:-watch}"
POLL_SECONDS="${REVIEW_BOT_POLL_SECONDS:-$(jq -r '.pollSeconds // 300' "$CONFIG")}"
RUNTIME_ROOT="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_RUNTIME_ROOT:-}" "$CONFIG" '.runtimeRoot' 'review-bot/.runtime')"
PROMPT_DIR="${REVIEW_BOT_PROMPT_DIR:-$RUNTIME_ROOT/prompts}"
QUEUE_FILE="${REVIEW_BOT_QUEUE_FILE:-$RUNTIME_ROOT/queue.jsonl}"
child_pid=""

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

shutdown() {
  printf '%s review-bot: watcher stopping\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  stop_child
  exit 0
}

trap shutdown INT TERM

poll_once() {
  local queue_tmp
  local raw_tmp
  local count=0
  local repo
  local number
  local owner
  local head_sha
  local short_sha
  local prompt_file
  local prompt_tmp

  mkdir -p "$RUNTIME_ROOT" "$PROMPT_DIR" "$(dirname "$QUEUE_FILE")"
  raw_tmp="$(mktemp "$RUNTIME_ROOT/.queue.raw.XXXXXX")"
  queue_tmp="$(mktemp "$RUNTIME_ROOT/.queue.XXXXXX")"

  if ! "$SCRIPT_DIR/list-queue.sh" pending >"$raw_tmp"; then
    rm -f "$raw_tmp" "$queue_tmp"
    return 1
  fi

  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    owner="$(jq -r '.owner' <<<"$item")"
    repo="$(jq -r '.repo' <<<"$item")"
    number="$(jq -r '.number' <<<"$item")"
    head_sha="$(jq -r '.head_sha' <<<"$item")"
    short_sha="${head_sha:0:12}"
    prompt_file="$PROMPT_DIR/$owner-$repo-$number-$short_sha.md"

    if [[ ! -f "$prompt_file" ]]; then
      prompt_tmp="$(mktemp "$PROMPT_DIR/.prompt.XXXXXX")"
      "$SCRIPT_DIR/agent-prompt.sh" "$repo" "$number" >"$prompt_tmp"
      mv "$prompt_tmp" "$prompt_file"
    fi

    jq --arg prompt "$prompt_file" '. + {prompt:$prompt}' <<<"$item" >>"$queue_tmp"
    printf '%s review-bot: prompt ready for %s/%s#%s at %s: %s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$owner" "$repo" "$number" "$head_sha" "$prompt_file"
    count="$((count + 1))"
  done <"$raw_tmp"

  mv "$queue_tmp" "$QUEUE_FILE"
  rm -f "$raw_tmp"

  if [[ "$count" -eq 0 ]]; then
    printf '%s review-bot: no pending semantic review prompts\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  else
    printf '%s review-bot: %s pending semantic review prompt(s)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$count"
  fi
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
