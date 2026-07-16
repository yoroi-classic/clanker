#!/usr/bin/env bash

review_bot_configure_github_get() {
  local config="$1"

  REVIEW_BOT_GH_TIMEOUT_SECONDS="${REVIEW_BOT_DISCOVERY_TIMEOUT_SECONDS:-$(jq -r '.discoveryTimeoutSeconds // 30' "$config")}"
  REVIEW_BOT_GH_MAX_ATTEMPTS="${REVIEW_BOT_DISCOVERY_MAX_ATTEMPTS:-$(jq -r '.discoveryMaxAttempts // 4' "$config")}"
  REVIEW_BOT_GH_BACKOFF_BASE_SECONDS="${REVIEW_BOT_DISCOVERY_BACKOFF_BASE_SECONDS:-$(jq -r '.discoveryBackoffBaseSeconds // 2' "$config")}"
  REVIEW_BOT_GH_BACKOFF_MAX_SECONDS="${REVIEW_BOT_DISCOVERY_BACKOFF_MAX_SECONDS:-$(jq -r '.discoveryBackoffMaxSeconds // 30' "$config")}"

  review_bot_require_positive_integer discoveryTimeoutSeconds "$REVIEW_BOT_GH_TIMEOUT_SECONDS"
  review_bot_require_positive_integer discoveryMaxAttempts "$REVIEW_BOT_GH_MAX_ATTEMPTS"
  review_bot_require_positive_integer discoveryBackoffBaseSeconds "$REVIEW_BOT_GH_BACKOFF_BASE_SECONDS"
  review_bot_require_positive_integer discoveryBackoffMaxSeconds "$REVIEW_BOT_GH_BACKOFF_MAX_SECONDS"
  if [[ "$REVIEW_BOT_GH_BACKOFF_MAX_SECONDS" -lt "$REVIEW_BOT_GH_BACKOFF_BASE_SECONDS" ]]; then
    echo "review-bot: discoveryBackoffMaxSeconds must be at least discoveryBackoffBaseSeconds" >&2
    return 2
  fi
}

review_bot_gh_get() {
  local attempt=1
  local delay="$REVIEW_BOT_GH_BACKOFF_BASE_SECONDS"
  local jitter
  local output
  local rc
  local wait_seconds

  while true; do
    set +e
    output="$(timeout --kill-after=5s "${REVIEW_BOT_GH_TIMEOUT_SECONDS}s" gh api "$@" -X GET)"
    rc="$?"
    set -e
    if [[ "$rc" -eq 0 ]]; then
      [[ -z "$output" ]] || printf '%s\n' "$output"
      return 0
    fi
    if [[ "$attempt" -ge "$REVIEW_BOT_GH_MAX_ATTEMPTS" ]]; then
      return "$rc"
    fi

    jitter="$((RANDOM % (delay / 2 + 1)))"
    wait_seconds="$((delay + jitter))"
    if [[ "$wait_seconds" -gt "$REVIEW_BOT_GH_BACKOFF_MAX_SECONDS" ]]; then
      wait_seconds="$REVIEW_BOT_GH_BACKOFF_MAX_SECONDS"
    fi
    printf 'review-bot: GitHub GET failed (attempt %s/%s, exit %s); retrying in %ss\n' \
      "$attempt" "$REVIEW_BOT_GH_MAX_ATTEMPTS" "$rc" "$wait_seconds" >&2
    sleep "$wait_seconds"
    attempt="$((attempt + 1))"
    delay="$((delay * 2))"
    if [[ "$delay" -gt "$REVIEW_BOT_GH_BACKOFF_MAX_SECONDS" ]]; then
      delay="$REVIEW_BOT_GH_BACKOFF_MAX_SECONDS"
    fi
  done
}

review_bot_resolve_reviewer_bounded() {
  local config="$1"
  local reviewer

  if [[ -n "${REVIEW_BOT_REVIEWER:-}" ]]; then
    printf '%s\n' "$REVIEW_BOT_REVIEWER"
    return
  fi

  reviewer="$(jq -r '.reviewer // .assignee // empty' "$config")"
  if [[ -n "$reviewer" && "$reviewer" != "null" ]]; then
    printf '%s\n' "$reviewer"
    return
  fi

  review_bot_gh_get user --jq '.login'
}
