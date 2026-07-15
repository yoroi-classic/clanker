#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 2 ]]; then
  echo "usage: $0 <repo> <pr-number>" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${REVIEW_BOT_CONFIG:-$SCRIPT_DIR/config.json}"
source "$SCRIPT_DIR/lib/paths.sh"
REPO_ROOT="$(review_bot_repo_root "$SCRIPT_DIR")"
REPO="$1"
PR_NUMBER="$2"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "review-bot: missing required command: $1" >&2
    exit 2
  fi
}

require gh
require jq

OWNER="$(review_bot_owner "$CONFIG")"
REVIEWER="$(review_bot_reviewer "$CONFIG")"
WORKSPACE="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_WORKSPACE:-}" "$CONFIG" '.workspace' 'review-bot/.runtime/repos')"
WORKTREE_ROOT="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_WORKTREE_ROOT:-}" "$CONFIG" '.worktreeRoot' 'review-bot/.runtime/worktrees')"
LOG_ROOT="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_LOG_ROOT:-}" "$CONFIG" '.logRoot' 'review-bot/logs')"
STATE_FILE="$(review_bot_env_path "$REPO_ROOT" "${REVIEW_BOT_STATE_FILE:-}" "$CONFIG" '.stateFile' 'review-bot/state/reviews.json')"

META="$(gh pr view "$PR_NUMBER" -R "$OWNER/$REPO" \
  --json number,title,url,headRefOid,headRefName,baseRefName,isDraft,author)"
PULL="$(gh api "/repos/$OWNER/$REPO/pulls/$PR_NUMBER")"

TITLE="$(jq -r '.title' <<<"$META")"
URL="$(jq -r '.url' <<<"$META")"
HEAD_SHA="$(jq -r '.headRefOid' <<<"$META")"
HEAD_REF="$(jq -r '.headRefName' <<<"$META")"
BASE_REF="$(jq -r '.baseRefName' <<<"$META")"
IS_DRAFT="$(jq -r '.isDraft' <<<"$META")"
AUTHOR="$(jq -r '.author.login' <<<"$META")"
BASE_SHA="$(jq -r '.base.sha' <<<"$PULL")"
REQUESTED_REVIEWERS="$(jq -r '[.requested_reviewers[]?.login] | join(", ")' <<<"$PULL")"
KEY="$OWNER/$REPO#$PR_NUMBER"

mapfile -t LOCAL_CHECKS < <(
  jq -r --arg repo "$REPO" '
    if .repos[$repo].localChecks then
      .repos[$repo].localChecks[]
    else
      .localChecks[]?
    end
  ' "$CONFIG"
)

cat <<PROMPT
You are a long-running Cubic-style code review agent.

Task: perform a real semantic review of \`$KEY\`, not just a build/test pass.

Context:
- Organization: \`$OWNER\`
- Repository: \`$REPO\`
- PR: \`#$PR_NUMBER\`
- URL: $URL
- Title: $TITLE
- Author: \`$AUTHOR\`
- Requested reviewers: \`$REQUESTED_REVIEWERS\`
- Configured reviewer: \`$REVIEWER\`
- Draft: \`$IS_DRAFT\`
- Base: \`$BASE_REF\` at \`$BASE_SHA\`
- Head: \`$HEAD_REF\` at \`$HEAD_SHA\`
- Clanker checkout: \`$REPO_ROOT\`
- Managed repo workspace: \`$WORKSPACE\`
- Check worktrees: \`$WORKTREE_ROOT\`
- Logs: \`$LOG_ROOT\`
- State file: \`$STATE_FILE\`

Hard requirements:
- Review only if \`$REVIEWER\` is explicitly requested as a reviewer.
- Do not review self-authored PRs unless the orchestrator explicitly says so.
- Do not approve from green checks alone.
- Use GitHub CI/checks as the build/test signal; do not duplicate CI locally unless targeted reproduction is needed.
- Run the local harness for review-specific evidence, then inspect the actual code diff and changed files.
- For clean results, approve only after semantic review finds no actionable issue.
- For findings, post a review/comment with narrow, actionable file/line references.
- If unsure whether something is a real issue, keep investigating rather than posting noise.
- Do not revert unrelated local changes. Other agents may be working in this checkout.

First commands:
\`\`\`sh
cd "$REPO_ROOT"
REVIEW_BOT_POST=0 REVIEW_BOT_FORCE=1 REVIEW_BOT_RECORD_DRY_RUN=0 ./review-bot/review-one.sh "$REPO" "$PR_NUMBER"
\`\`\`

After the harness runs, identify the generated worktree and evidence report:
\`\`\`sh
find "$WORKTREE_ROOT/$REPO" -maxdepth 1 -type d -name 'pr-$PR_NUMBER-*' -print
find "$LOG_ROOT/$REPO" -maxdepth 1 -type d -name 'pr-$PR_NUMBER-*' -print
\`\`\`

Required review procedure:
1. Inspect PR metadata and changed-file summary:
   \`\`\`sh
   gh pr view "$PR_NUMBER" -R "$OWNER/$REPO" --json title,body,author,baseRefName,headRefName,files,commits,reviews,statusCheckRollup
   gh pr diff "$PR_NUMBER" -R "$OWNER/$REPO" --stat
   gh pr diff "$PR_NUMBER" -R "$OWNER/$REPO"
   \`\`\`
2. Read the generated evidence report, CI rollup, and failed local review logs, if any.
3. Inspect relevant changed files in the worktree, not only the diff.
4. For dependency bumps, inspect lockfile/package changes and assess behavior/security impact beyond CI.
5. For wallet/blockchain code, be pedantic around:
   - private keys, mnemonics, passphrases, signing, derivation, address handling
   - transaction construction, fees, UTxO handling, token amounts, Lovelace precision
   - network IDs, protocol parameters, serialization determinism
   - storage, logging, telemetry, clipboard, URL surfaces
   - extension permissions, CSP, injected HTML, dynamic code execution
6. Decide:
   - If actionable issues exist, write a concise review body with findings first and post it without approval.
   - If no actionable issues exist, approve with a body that includes \`No issues found for $HEAD_SHA.\`

Posting commands:
- Findings, no approval:
  \`\`\`sh
  gh pr review "$PR_NUMBER" -R "$OWNER/$REPO" --comment --body-file /path/to/review.md
  \`\`\`
- Clean semantic review, approve:
  \`\`\`sh
  gh api -X POST "/repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews" \\
    -f event=APPROVE \\
    -F body=@/path/to/review.md \\
    --jq '.html_url // empty'
  \`\`\`

After posting, record the semantic review state so the watcher does not
re-queue the same head/base:
\`\`\`sh
./review-bot/record-review.sh "$REPO" "$PR_NUMBER" findings REVIEW_OR_COMMENT_URL "$HEAD_SHA" "$BASE_SHA" /path/to/review.md
./review-bot/record-review.sh "$REPO" "$PR_NUMBER" clean REVIEW_OR_COMMENT_URL "$HEAD_SHA" "$BASE_SHA" /path/to/review.md
\`\`\`
Use exactly one of those commands, matching the posted decision.

Finish by reporting to the orchestrator:
- PR reviewed
- head SHA reviewed
- GitHub CI/check status
- local review-specific checks run and their result
- semantic findings or explicit no-issues decision
- GitHub review/comment URL

Local review-specific checks configured for this repo:
$(if [[ "${#LOCAL_CHECKS[@]}" -eq 0 ]]; then printf -- '- none\n'; else printf -- '- `%s`\n' "${LOCAL_CHECKS[@]}"; fi)
PROMPT
