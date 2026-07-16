#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'quality-check: missing required command: %s\n' "$1" >&2
    exit 2
  fi
}

require bash
require bwrap
require find
require jq
require shellcheck

mapfile -d '' SHELL_FILES < <(
  find coding-bot review-bot scripts \
    -type f \
    -name '*.sh' \
    -not -path '*/.runtime/*' \
    -print0 |
    sort -z
)

if [[ "${#SHELL_FILES[@]}" -eq 0 ]]; then
  echo "quality-check: no shell files found" >&2
  exit 1
fi

printf 'quality-check: Bash syntax (%s files)\n' "${#SHELL_FILES[@]}"
bash -n "${SHELL_FILES[@]}"

printf 'quality-check: ShellCheck (%s files)\n' "${#SHELL_FILES[@]}"
shellcheck --severity=warning "${SHELL_FILES[@]}"

printf 'quality-check: JSON configuration\n'
./review-bot/validate-config.sh review-bot/config.json

printf 'quality-check: configuration validation tests\n'
./review-bot/tests/config-test.sh

printf 'quality-check: review-bot smoke test\n'
./review-bot/tests/smoke-test.sh

printf 'quality-check: coding-bot smoke test\n'
./coding-bot/tests/smoke-test.sh

echo "quality-check: ok"
