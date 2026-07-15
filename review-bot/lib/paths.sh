#!/usr/bin/env bash

review_bot_repo_root() {
  local script_dir="$1"

  cd "$script_dir/.." && pwd -P
}

review_bot_abs_path() {
  local base="$1"
  local value="$2"
  local default_value="$3"
  local path
  local parent
  local leaf

  if [[ -z "$value" || "$value" == "null" ]]; then
    value="$default_value"
  fi

  case "$value" in
    /*)
      path="$value"
      ;;
    *)
      path="$base/$value"
      ;;
  esac

  if [[ -d "$path" ]]; then
    cd "$path" && pwd -P
    return
  fi

  parent="$(dirname "$path")"
  leaf="$(basename "$path")"
  if [[ -d "$parent" ]]; then
    printf '%s/%s\n' "$(cd "$parent" && pwd -P)" "$leaf"
  else
    printf '%s\n' "$path"
  fi
}

review_bot_config_path() {
  local config="$1"
  local base="$2"
  local jq_filter="$3"
  local default_value="$4"
  local value

  value="$(jq -r "$jq_filter // empty" "$config")"
  review_bot_abs_path "$base" "$value" "$default_value"
}

review_bot_config_value() {
  local config="$1"
  local jq_filter="$2"
  local default_value="$3"
  local value

  value="$(jq -r "$jq_filter // empty" "$config")"
  if [[ -z "$value" || "$value" == "null" ]]; then
    printf '%s\n' "$default_value"
  else
    printf '%s\n' "$value"
  fi
}

review_bot_owner() {
  local config="$1"

  if [[ -n "${REVIEW_BOT_OWNER:-}" ]]; then
    printf '%s\n' "$REVIEW_BOT_OWNER"
  else
    review_bot_config_value "$config" '.owner' 'yoroi-classic'
  fi
}

review_bot_env_path() {
  local base="$1"
  local env_value="$2"
  local config="$3"
  local jq_filter="$4"
  local default_value="$5"
  local value

  if [[ -n "$env_value" ]]; then
    review_bot_abs_path "$base" "$env_value" "$default_value"
    return
  fi

  value="$(jq -r "$jq_filter // empty" "$config")"
  review_bot_abs_path "$base" "$value" "$default_value"
}

review_bot_reviewer() {
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

  gh api user --jq '.login'
}
