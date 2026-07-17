#!/usr/bin/env bash

review_bot_positive_integer() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

review_bot_validate_discovery_config() {
  local poll_seconds="$1"
  local timeout_seconds="$2"
  local retries="$3"
  local retry_base_seconds="$4"
  local retry_jitter_seconds="$5"

  review_bot_positive_integer "$poll_seconds" || {
    echo "review-bot: pollSeconds must be a positive integer, got: $poll_seconds" >&2
    return 2
  }
  review_bot_positive_integer "$timeout_seconds" || {
    echo "review-bot: discoveryTimeoutSeconds must be a positive integer, got: $timeout_seconds" >&2
    return 2
  }
  review_bot_positive_integer "$retries" || {
    echo "review-bot: discoveryRetries must be a positive integer, got: $retries" >&2
    return 2
  }
  review_bot_positive_integer "$retry_base_seconds" || {
    echo "review-bot: discoveryRetryBaseSeconds must be a positive integer, got: $retry_base_seconds" >&2
    return 2
  }
  [[ "$retry_jitter_seconds" =~ ^[0-9]+$ ]] || {
    echo "review-bot: discoveryRetryJitterSeconds must be a non-negative integer, got: $retry_jitter_seconds" >&2
    return 2
  }
}

review_bot_gh() {
  local attempt=1
  local rc=0
  local delay
  local jitter
  local timeout_seconds="${REVIEW_BOT_DISCOVERY_TIMEOUT_SECONDS:?}"
  local retries="${REVIEW_BOT_DISCOVERY_RETRIES:?}"
  local retry_base_seconds="${REVIEW_BOT_DISCOVERY_RETRY_BASE_SECONDS:?}"
  local retry_jitter_seconds="${REVIEW_BOT_DISCOVERY_RETRY_JITTER_SECONDS:?}"

  while (( attempt <= retries )); do
    set +e
    timeout --kill-after=5s "${timeout_seconds}s" gh "$@"
    rc="$?"
    set -e
    if [[ "$rc" -eq 0 ]]; then
      return 0
    fi
    if (( attempt == retries )); then
      break
    fi

    delay="$((retry_base_seconds * (1 << (attempt - 1))))"
    jitter=0
    if (( retry_jitter_seconds > 0 )); then
      jitter="$((RANDOM % (retry_jitter_seconds + 1)))"
    fi
    printf 'review-bot: GitHub request failed (attempt %s/%s, status %s); retrying in %ss\n' \
      "$attempt" "$retries" "$rc" "$((delay + jitter))" >&2
    sleep "$((delay + jitter))"
    attempt="$((attempt + 1))"
  done

  printf 'review-bot: GitHub request failed after %s attempt(s), status %s\n' "$retries" "$rc" >&2
  return "$rc"
}
