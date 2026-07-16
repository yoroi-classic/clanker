#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "quality: missing required command: $1" >&2
    exit 2
  fi
}

require bash
require git
require jq
require shellcheck

mapfile -t SHELL_FILES < <(git -C "$ROOT" ls-files '*.sh')
mapfile -t JSON_FILES < <(git -C "$ROOT" ls-files '*.json')

if [[ "${#SHELL_FILES[@]}" -eq 0 ]]; then
  echo "quality: no tracked shell files found" >&2
  exit 1
fi

if [[ "${#JSON_FILES[@]}" -eq 0 ]]; then
  echo "quality: no tracked JSON files found" >&2
  exit 1
fi

printf 'quality: checking Bash syntax (%s files)\n' "${#SHELL_FILES[@]}"
(
  cd "$ROOT"
  bash -n "${SHELL_FILES[@]}"
)

printf 'quality: running ShellCheck (%s files)\n' "${#SHELL_FILES[@]}"
(
  cd "$ROOT"
  # SC1091: bot scripts resolve their shared library from SCRIPT_DIR.
  # SC2016: single-quoted printf/jq strings intentionally contain Markdown
  # backticks or jq expressions, not shell expansions.
  shellcheck --severity=warning --exclude=SC1091,SC2016 "${SHELL_FILES[@]}"
)

printf 'quality: validating JSON (%s files)\n' "${#JSON_FILES[@]}"
(
  cd "$ROOT"
  jq empty "${JSON_FILES[@]}"
)

printf 'quality: running review-bot smoke tests\n'
"$ROOT/review-bot/tests/smoke-test.sh"

printf 'quality: running coding-bot smoke tests\n'
"$ROOT/coding-bot/tests/smoke-test.sh"

printf 'quality: ok\n'
