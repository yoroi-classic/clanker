#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$ROOT/coding-bot/lib/queue.sh"
ORG="${CODING_BOT_ORG:-yoroi-classic}"
TARGET_WORKERS="${CODING_BOT_WORKERS:-}"
CURRENT_WORKERS="${CODING_BOT_CURRENT_WORKERS:-unknown}"
RUNTIME_ROOT="${CODING_BOT_RUNTIME_ROOT:-$ROOT/coding-bot/.runtime}"
UPDATE_REF="${CODING_BOT_UPDATE_REF:-origin/main}"

mkdir -p "$RUNTIME_ROOT"

print_file() {
  local path="$1"
  if [[ -f "$path" ]]; then
    printf '\n## %s\n\n' "${path#"$ROOT/"}"
    cat "$path"
    printf '\n'
  fi
}

print_self_update_status() {
  printf '\n## Clanker Self-Update\n\n'

  if [[ "${CODING_BOT_SKIP_UPDATE_CHECK:-0}" == "1" ]]; then
    printf 'Self-update check skipped by `CODING_BOT_SKIP_UPDATE_CHECK=1`.\n'
    return 0
  fi

  local marker="$RUNTIME_ROOT/clanker-update-needed"
  local update_ref="$UPDATE_REF"
  local update_remote update_branch remote_ref
  if [[ "$update_ref" == */* ]]; then
    update_remote="${update_ref%%/*}"
    update_branch="${update_ref#*/}"
  else
    update_remote="origin"
    update_branch="$update_ref"
    update_ref="$update_remote/$update_branch"
  fi
  remote_ref="refs/remotes/$update_ref"

  if ! git -C "$ROOT" config --get "remote.$update_remote.url" >/dev/null; then
    rm -f "$marker"
    printf 'Remote `%s` is not configured; skipping self-update check.\n' "$update_remote"
    return 0
  fi

  if ! git -C "$ROOT" fetch --quiet "$update_remote" "refs/heads/$update_branch:$remote_ref"; then
    printf 'Could not fetch `%s`; check manually before relying on local bot instructions.\n' "$update_ref"
    return 0
  fi

  local local_sha upstream_sha merge_base
  local_sha="$(git -C "$ROOT" rev-parse HEAD)"
  upstream_sha="$(git -C "$ROOT" rev-parse "$remote_ref")"
  merge_base="$(git -C "$ROOT" merge-base HEAD "$remote_ref")"

  if [[ "$local_sha" == "$upstream_sha" ]]; then
    rm -f "$marker"
    printf 'This clanker checkout is current with `%s`.\n' "$update_ref"
  elif [[ "$local_sha" == "$merge_base" ]]; then
    {
      printf 'git pull --ff-only\n'
      printf './coding-bot/bin/start.sh\n'
    } >"$marker"
    printf 'This clanker checkout is behind `%s`.\n' "$update_ref"
    printf 'Next turn first action: run `git pull --ff-only`, then rerun `./coding-bot/bin/start.sh`.\n'
    printf 'Marker written to `%s`.\n' "${marker#"$ROOT/"}"
  elif [[ "$upstream_sha" == "$merge_base" ]]; then
    rm -f "$marker"
    printf 'This clanker checkout is ahead of `%s`; push or finish local work before updating.\n' "$update_ref"
  else
    {
      printf 'git status --short --branch\n'
      printf 'git fetch --all --prune\n'
      printf 'git log --oneline --left-right HEAD...%s\n' "$remote_ref"
    } >"$marker"
    printf 'This clanker checkout has diverged from `%s`; resolve manually before taking new work.\n' "$update_ref"
    printf 'Marker written to `%s`.\n' "${marker#"$ROOT/"}"
  fi
}

cat <<'HEADER'
# Yoroi Classic Coding Bot Bootstrap

Use this as the starting context for a coding-agent session. Refresh live state
before changing code, and keep assigned work moving before taking new work.
HEADER

print_self_update_status

printf '\n## Workspace Status\n\n'
git -C "$ROOT" status --short --branch || true

printf '\n## Runtime Workspace\n\n'
printf 'Coding-bot scratch files should stay under `%s`.\n' "${RUNTIME_ROOT#"$ROOT/"}"
printf 'Generated prompts, review bodies, queues, and scratch files there may be deleted by the bot.\n'

print_file "$ROOT/coding-bot/SKILL.md"
print_file "$ROOT/standards/session.md"
print_file "$ROOT/standards/review.md"
print_file "$ROOT/coding-bot/runbooks/queue.md"
print_file "$ROOT/coding-bot/runbooks/multi-agent.md"

if [[ -n "$TARGET_WORKERS" ]]; then
  printf '\n## Worker Scaling Plan\n\n'
  "$ROOT/coding-bot/bin/worker-plan.sh" --no-queue "$TARGET_WORKERS" "$CURRENT_WORKERS"
fi

ASSIGNED_QUERY="org:$ORG is:issue is:open assignee:@me"
PRS_QUERY="org:$ORG is:pr is:open author:@me"

coding_bot_queue_begin
coding_bot_print_assigned_issues "Live Assigned Issues" "$ASSIGNED_QUERY"
coding_bot_print_authored_prs "Live Authored Pull Requests" "$PRS_QUERY"
coding_bot_print_queue_metrics

cat <<'FOOTER'

## First Actions

1. Classify authored PRs as merge-ready, needs-fix, or blocked on review.
2. Fix actionable review comments and failing checks before new work.
3. Pick the next assigned issue only when existing PRs are clear or blocked.
4. Keep temporary clones and caches out of the repository and clean them up.
FOOTER
