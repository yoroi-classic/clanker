#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${WORKSPACE_STATUS_ROOT:-$SCRIPT_ROOT}"
ROOT="$(cd "$ROOT" && pwd -P)"
FORMAT="table"
CONFIG_STREAM=""

cleanup() {
  [[ -z "$CONFIG_STREAM" ]] || rm -f "$CONFIG_STREAM"
}
trap cleanup EXIT

usage() {
  cat >&2 <<'USAGE'
usage: ./workspace-status.sh [--json]

Reports the state of every repository configured in .gitmodules without
fetching remotes. Default-branch comparison is shown when origin/HEAD exists
locally.

Set WORKSPACE_STATUS_ROOT to inspect another clanker checkout.
USAGE
}

case "${1:-}" in
  "")
    ;;
  --json)
    FORMAT="json"
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
esac

if [[ ! -f "$ROOT/.gitmodules" ]]; then
  echo "workspace-status: .gitmodules was not found under $ROOT" >&2
  exit 1
fi

CONFIG_STREAM="$(mktemp "${TMPDIR:-/tmp}/clanker-workspace-status.XXXXXX")"
set +e
git -C "$ROOT" config -z -f .gitmodules --get-regexp '^submodule\..*\.path$' \
  >"$CONFIG_STREAM"
config_rc="$?"
set -e
if [[ "$config_rc" -ne 0 && "$config_rc" -ne 1 ]]; then
  echo "workspace-status: could not parse submodule paths from $ROOT/.gitmodules" >&2
  exit 1
fi

ROWS=()
SUPERPROJECT_BRANCH="$(git -C "$ROOT" symbolic-ref --quiet --short HEAD || true)"

while IFS= read -r -d '' entry; do
  key="${entry%%$'\n'*}"
  path="${entry#*$'\n'}"
  name="${key#submodule.}"
  name="${name%.path}"
  repository_path="$(realpath -m "$ROOT/$path")"
  case "$repository_path" in
    "$ROOT"/*)
      ;;
    *)
      printf 'workspace-status: submodule path escapes workspace: %s\n' "$path" >&2
      exit 1
      ;;
  esac
  pinned="$(git -C "$ROOT" ls-tree HEAD -- "$path" | awk 'NR == 1 {print $3}')"
  configured_branch="$(git -C "$ROOT" config -f .gitmodules --get "submodule.$name.branch" || true)"
  checked="-"
  branch="missing"
  dirty="-"
  ahead="-"
  behind="-"
  recursive_missing="1"
  agents="no"
  default_branch="-"
  comparison_branch=""
  branch_mismatch="unknown"
  pin_mismatch="unknown"
  repository_root=""

  if [[ -f "$repository_path/AGENTS.md" ]]; then
    agents="yes"
  fi

  repository_root="$(git -C "$repository_path" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ "$repository_root" == "$repository_path" ]]; then
    checked="$(git -C "$repository_path" rev-parse HEAD)"
    branch="$(git -C "$repository_path" symbolic-ref --quiet --short HEAD || printf 'detached')"
    if [[ -n "$(git -C "$repository_path" status --porcelain --untracked-files=normal)" ]]; then
      dirty="yes"
    else
      dirty="no"
    fi

    upstream="$(
      git -C "$repository_path" rev-parse \
        --verify \
        --abbrev-ref \
        --symbolic-full-name \
        '@{upstream}' 2>/dev/null ||
        true
    )"
    if [[ -n "$upstream" ]]; then
      read -r ahead behind < <(
        git -C "$repository_path" rev-list --left-right --count "HEAD...$upstream"
      )
    fi

    recursive_missing="$(
      git -C "$repository_path" submodule status --recursive 2>/dev/null |
        awk '/^-/{count++} END{print count + 0}'
    )"
    default_branch="$(
      git -C "$repository_path" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null |
        sed 's#^origin/##' ||
        true
    )"
    if [[ -z "$default_branch" ]]; then
      default_branch="-"
    fi

    comparison_branch="$configured_branch"
    if [[ "$comparison_branch" == "." ]]; then
      comparison_branch="$SUPERPROJECT_BRANCH"
    fi
    if [[ -n "$comparison_branch" && "$default_branch" != "-" ]]; then
      if [[ "$comparison_branch" == "$default_branch" ]]; then
        branch_mismatch="no"
      else
        branch_mismatch="yes"
      fi
    fi

    if [[ "$checked" == "$pinned" ]]; then
      pin_mismatch="no"
    else
      pin_mismatch="yes"
    fi
  fi

  if [[ -z "$configured_branch" ]]; then
    configured_branch="-"
  fi

  ROWS+=("$(
    jq -cn \
      --arg repository "$path" \
      --arg pinned "$pinned" \
      --arg checked "$checked" \
      --arg branch "$branch" \
      --arg dirty "$dirty" \
      --arg ahead "$ahead" \
      --arg behind "$behind" \
      --arg recursive_missing "$recursive_missing" \
      --arg agents "$agents" \
      --arg configured_branch "$configured_branch" \
      --arg default_branch "$default_branch" \
      --arg branch_mismatch "$branch_mismatch" \
      --arg pin_mismatch "$pin_mismatch" \
      '{
        repository: $repository,
        pinned: $pinned,
        checked: $checked,
        branch: $branch,
        dirty: $dirty,
        ahead: $ahead,
        behind: $behind,
        recursive_missing: $recursive_missing,
        agents: $agents,
        configured_branch: $configured_branch,
        default_branch: $default_branch,
        branch_mismatch: $branch_mismatch,
        pin_mismatch: $pin_mismatch
      }'
  )")
done <"$CONFIG_STREAM"

if [[ "$FORMAT" == "json" ]]; then
  printf '%s\n' "${ROWS[@]}" | jq -s 'sort_by(.repository)'
  exit 0
fi

printf 'repository\tpinned\tchecked\tbranch\tdirty\tahead\tbehind\trecursive-missing\tAGENTS\tconfigured\tdefault\tbranch-mismatch\tpin-mismatch\n'
printf '%s\n' "${ROWS[@]}" |
  jq -sr 'sort_by(.repository)[] | [
    .repository,
    (.pinned[0:12]),
    (if .checked == "-" then "-" else .checked[0:12] end),
    .branch,
    .dirty,
    .ahead,
    .behind,
    .recursive_missing,
    .agents,
    .configured_branch,
    .default_branch,
    .branch_mismatch,
    .pin_mismatch
  ] | @tsv'
