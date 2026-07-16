#!/usr/bin/env bash

review_bot_validate_owner() {
  local owner="$1"

  [[ "$owner" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]] || {
    printf 'review-bot: invalid GitHub owner: %s\n' "$owner" >&2
    return 2
  }
}

review_bot_validate_repo() {
  local repo="$1"

  [[ "$repo" =~ ^[A-Za-z0-9._-]{1,100}$ ]] || {
    printf 'review-bot: invalid GitHub repository name: %s\n' "$repo" >&2
    return 2
  }
  [[ "$repo" != "." && "$repo" != ".." ]] || {
    printf 'review-bot: invalid GitHub repository name: %s\n' "$repo" >&2
    return 2
  }
}

review_bot_validate_pr_number() {
  local number="$1"

  [[ "$number" =~ ^[1-9][0-9]*$ ]] || {
    printf 'review-bot: invalid pull request number: %s\n' "$number" >&2
    return 2
  }
}

review_bot_validate_sha() {
  local label="$1"
  local sha="$2"

  [[ "$sha" =~ ^[0-9a-fA-F]{40}$ ]] || {
    printf 'review-bot: invalid %s SHA: %s\n' "$label" "$sha" >&2
    return 2
  }
}

review_bot_safe_workdir() {
  local worktree="$1"
  local configured="$2"
  local resolved
  local worktree_root

  [[ "$configured" != /* ]] || {
    printf 'review-bot: configured workdir must be relative: %s\n' "$configured" >&2
    return 2
  }

  worktree_root="$(cd "$worktree" && pwd -P)"
  resolved="$(cd "$worktree_root" && cd "$configured" 2>/dev/null && pwd -P)" || {
    printf 'review-bot: configured workdir does not exist: %s\n' "$configured" >&2
    return 2
  }
  case "$resolved" in
    "$worktree_root"|"$worktree_root"/*)
      printf '%s\n' "$resolved"
      ;;
    *)
      printf 'review-bot: configured workdir escapes the review worktree: %s\n' "$configured" >&2
      return 2
      ;;
  esac
}

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

review_bot_repo_dir() {
  local repo_root="$1"
  local workspace="$2"
  local config="$3"
  local repo="$4"
  local configured_path

  configured_path="$(jq -r --arg repo "$repo" '.repos[$repo].path // empty' "$config")"
  if [[ -n "$configured_path" ]]; then
    review_bot_abs_path "$repo_root" "$configured_path" "$workspace/$repo"
  else
    printf '%s/%s\n' "$workspace" "$repo"
  fi
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

review_bot_require_positive_integer() {
  local label="$1"
  local value="$2"

  [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
    printf 'review-bot: %s must be a positive integer, got: %s\n' "$label" "$value" >&2
    return 2
  }
}

review_bot_require_nonnegative_integer() {
  local label="$1"
  local value="$2"

  [[ "$value" =~ ^[0-9]+$ ]] || {
    printf 'review-bot: %s must be a nonnegative integer, got: %s\n' "$label" "$value" >&2
    return 2
  }
}

review_bot_health_file_is_valid() {
  local health_file="$1"

  jq -e '
    def nonnegative_integer:
      type == "number"
      and . == floor
      and . >= 0
      and . <= 9007199254740991;
    type == "object"
    and (.status == "ok" or .status == "error")
    and (.last_attempt_at | type == "string")
    and (.last_attempt_epoch | nonnegative_integer)
    and (.last_success_at == null or (.last_success_at | type == "string"))
    and (.last_success_epoch == null or (.last_success_epoch | nonnegative_integer))
    and (.last_error == null or (.last_error | type == "string"))
    and (.consecutive_failures | nonnegative_integer)
    and (.queue_count | nonnegative_integer)
  ' "$health_file" >/dev/null 2>&1
}

review_bot_file_size() {
  local path="$1"
  local size

  if command -v stat >/dev/null 2>&1; then
    if size="$(stat -c '%s' "$path" 2>/dev/null)"; then
      printf '%s\n' "$size"
      return
    fi
    if size="$(stat -f '%z' "$path" 2>/dev/null)"; then
      printf '%s\n' "$size"
      return
    fi
  fi

  wc -c <"$path" | tr -d '[:space:]'
}

review_bot_rotate_log() {
  local log_file="$1"
  local max_bytes="$2"
  local retain="$3"
  local size
  local index

  [[ -f "$log_file" ]] || return 0
  size="$(review_bot_file_size "$log_file")"
  [[ "$size" -ge "$max_bytes" ]] || return 0

  if [[ "$retain" -gt 0 ]]; then
    rm -f "$log_file.$retain"
    for ((index = retain - 1; index >= 1; index--)); do
      if [[ -f "$log_file.$index" ]]; then
        mv "$log_file.$index" "$log_file.$((index + 1))"
      fi
    done
    cp "$log_file" "$log_file.1"
    chmod 600 "$log_file.1"
  fi

  : >"$log_file"
  chmod 600 "$log_file"
}

review_bot_pid_running() {
  local pid="${1:-}"

  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1
}

review_bot_watch_command_matches() {
  local command="$1"
  local watch_script="$2"

  case "$command" in
    "$watch_script" | "bash $watch_script" | "/bin/bash $watch_script")
      return 0
      ;;
  esac

  return 1
}

review_bot_pid_is_watch() {
  local pid="${1:-}"
  local watch_script="$2"
  local command

  review_bot_pid_running "$pid" || return 1
  command="$(ps -p "$pid" -o args= 2>/dev/null | sed -E 's/^[[:space:]]+//')"
  review_bot_watch_command_matches "$command" "$watch_script"
}

review_bot_find_watch_pid() {
  local watch_script="$1"

  command -v ps >/dev/null 2>&1 || return 1
  ps -eo pid=,args= 2>/dev/null | awk -v script="$watch_script" '
    {
      pid = $1
      sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", $0)
      if ($0 == script || $0 == "bash " script || $0 == "/bin/bash " script) {
        print pid
        exit
      }
    }
  '
}

review_bot_terminate_tree() {
  local root_pid="${1:-}"
  local child

  review_bot_pid_running "$root_pid" || return 0
  if command -v pgrep >/dev/null 2>&1; then
    while IFS= read -r child; do
      [[ -n "$child" ]] || continue
      review_bot_terminate_tree "$child"
    done < <(pgrep -P "$root_pid" 2>/dev/null || true)
  fi

  kill "$root_pid" >/dev/null 2>&1 || true
}
