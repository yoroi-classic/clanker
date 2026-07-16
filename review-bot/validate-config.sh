#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.json}"

if ! command -v jq >/dev/null 2>&1; then
  echo "review-bot: missing required command: jq" >&2
  exit 2
fi

if [[ ! -f "$CONFIG" ]]; then
  echo "review-bot: configuration file not found: $CONFIG" >&2
  exit 2
fi

if ! jq -e '
  def positive_integer:
    type == "number" and . == floor and . > 0;
  def nonnegative_integer:
    type == "number" and . == floor and . >= 0;
  def string_array:
    type == "array" and all(.[]; type == "string");

  type == "object"
  and ((.owner // "yoroi-classic") | type == "string" and length > 0)
  and ((.reviewer // "") | type == "string")
  and ((.workspace // "repos") | type == "string" and length > 0)
  and ((.worktreeRoot // "review-bot/.runtime/worktrees") | type == "string" and length > 0)
  and ((.runtimeRoot // "review-bot/.runtime") | type == "string" and length > 0)
  and ((.logRoot // "review-bot/logs") | type == "string" and length > 0)
  and ((.stateFile // "review-bot/state/reviews.json") | type == "string" and length > 0)
  and ((.pollSeconds // 300) | positive_integer)
  and ((.discoveryTimeoutSeconds // 30) | positive_integer)
  and ((.discoveryMaxAttempts // 4) | positive_integer)
  and ((.discoveryBackoffBaseSeconds // 2) | positive_integer)
  and ((.discoveryBackoffMaxSeconds // 30) | positive_integer)
  and ((.discoveryBackoffMaxSeconds // 30) >= (.discoveryBackoffBaseSeconds // 2))
  and ((.healthStaleSeconds // 900) | positive_integer)
  and ((.watchLogMaxBytes // 5242880) | positive_integer)
  and ((.watchLogRetain // 3) | nonnegative_integer)
  and ((.checkTimeoutSeconds // 3600) | positive_integer)
  and ((.localCheckNetwork // "deny") | . == "deny" or . == "allow")
  and ((.localCheckCpuSeconds // 600) | positive_integer)
  and ((.localCheckMemoryBytes // 1073741824) | positive_integer)
  and ((.localCheckWorkspaceBytes // 2147483648) | positive_integer)
  and ((.localCheckScratchBytes // 268435456) | positive_integer)
  and ((.localCheckMaxProcesses // 128) | positive_integer)
  and ((.localCheckMaxOpenFiles // 256) | positive_integer)
  and ((.localCheckMaxOutputBytes // 10485760) | positive_integer)
  and ((.commentMode // "comment") | . == "comment" or . == "review")
  and ((.includeDrafts // false) | type == "boolean")
  and ((.skipSelfAuthored // true) | type == "boolean")
  and ((.worktreeRetain // 8) | nonnegative_integer)
  and ((.localChecks // []) | string_array)
  and (
    (.repos // {})
    | type == "object"
      and all(
        to_entries[];
        (.value | type == "object")
        and ((.value.path // "") | type == "string")
        and ((.value.workdir // ".") | type == "string" and length > 0)
        and ((.value.localChecks // []) | string_array)
      )
  )
' "$CONFIG" >/dev/null; then
  echo "review-bot: invalid configuration values or types in $CONFIG" >&2
  exit 2
fi

echo "review-bot: configuration valid: $CONFIG"
