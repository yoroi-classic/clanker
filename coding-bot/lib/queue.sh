#!/usr/bin/env bash

CODING_BOT_QUEUE_READY=0
CODING_BOT_QUEUE_HTTP_CALLS=0
CODING_BOT_QUEUE_SEARCH_PAGES=0
CODING_BOT_QUEUE_AUTHORED_PRS=0
CODING_BOT_QUEUE_PR_DETAIL_CALLS=0
CODING_BOT_SEARCH_JSON=""
CODING_BOT_SEARCH_ERROR=""
CODING_BOT_PAGINATED_ARRAY_JSON=""

coding_bot_queue_begin() {
  CODING_BOT_QUEUE_READY=0
  CODING_BOT_QUEUE_HTTP_CALLS=0
  CODING_BOT_QUEUE_SEARCH_PAGES=0
  CODING_BOT_QUEUE_AUTHORED_PRS=0
  CODING_BOT_QUEUE_PR_DETAIL_CALLS=0
  CODING_BOT_SEARCH_ERROR=""

  if ! command -v gh >/dev/null 2>&1; then
    return 0
  fi

  if ! gh auth status >/dev/null 2>&1; then
    return 0
  fi

  CODING_BOT_QUEUE_READY=1
}

coding_bot_queue_unavailable_message() {
  if ! command -v gh >/dev/null 2>&1; then
    printf 'GitHub CLI is unavailable; refresh the queue manually.\n'
  else
    printf 'GitHub CLI is not authenticated; refresh the queue manually.\n'
  fi
}

coding_bot_fetch_search() {
  local query_text="$1"
  local page_count
  local raw_pages
  local returned_count
  local total_count

  CODING_BOT_SEARCH_JSON=""
  CODING_BOT_SEARCH_ERROR=""
  CODING_BOT_PAGINATED_ARRAY_JSON=""
  CODING_BOT_QUEUE_HTTP_CALLS="$((CODING_BOT_QUEUE_HTTP_CALLS + 1))"
  if ! raw_pages="$(gh api --paginate -X GET search/issues \
    -f q="$query_text" \
    -f per_page=100 \
    --jq '{total_count, incomplete_results, items}')"; then
    CODING_BOT_SEARCH_ERROR="GitHub Search request failed"
    return 1
  fi

  if ! CODING_BOT_SEARCH_JSON="$(jq -sce '
    map(
      select(
        type == "object"
        and (.total_count | type == "number" and . == floor and . >= 0 and . <= 9007199254740991)
        and (.incomplete_results | type == "boolean")
        and (.items | type == "array")
        and all(
          .items[];
          type == "object"
          and (.repository_url | type == "string" and test("^https://api\\.github\\.com/repos/[A-Za-z0-9-]+/[A-Za-z0-9._-]+$"))
          and (.number | type == "number" and . == floor and . >= 1 and . <= 9007199254740991)
          and (.title | type == "string")
          and (.html_url | type == "string")
        )
      )
    ) as $valid
    | if ($valid | length) == length and length > 0
      then .
      else error("invalid GitHub Search response")
      end
  ' <<<"$raw_pages" 2>/dev/null)"; then
    CODING_BOT_SEARCH_ERROR="GitHub Search returned an invalid response"
    return 1
  fi

  if ! page_count="$(jq -er 'length' <<<"$CODING_BOT_SEARCH_JSON")"; then
    return 1
  fi

  CODING_BOT_QUEUE_SEARCH_PAGES="$((CODING_BOT_QUEUE_SEARCH_PAGES + page_count))"
  CODING_BOT_QUEUE_HTTP_CALLS="$((CODING_BOT_QUEUE_HTTP_CALLS + page_count - 1))"

  total_count="$(jq -r '.[0].total_count' <<<"$CODING_BOT_SEARCH_JSON")"
  returned_count="$(jq '[.[].items[]] | length' <<<"$CODING_BOT_SEARCH_JSON")"
  if ! jq -e --argjson total "$total_count" 'all(.[]; .total_count == $total)' \
    <<<"$CODING_BOT_SEARCH_JSON" >/dev/null; then
    CODING_BOT_SEARCH_ERROR="GitHub Search page totals were inconsistent"
    return 1
  fi
  if jq -e 'any(.[]; .incomplete_results)' <<<"$CODING_BOT_SEARCH_JSON" >/dev/null; then
    CODING_BOT_SEARCH_ERROR="GitHub Search reported incomplete results; retry or partition the query before acting"
    return 1
  fi
  if [[ "$returned_count" -lt "$total_count" ]]; then
    CODING_BOT_SEARCH_ERROR="GitHub Search is incomplete ($returned_count of $total_count results); partition the query before acting"
    return 1
  elif [[ "$returned_count" -gt "$total_count" ]]; then
    CODING_BOT_SEARCH_ERROR="GitHub Search returned an inconsistent result count ($returned_count of $total_count)"
    return 1
  fi
}

coding_bot_fetch_pr_array() {
  local endpoint="$1"
  local raw_items
  local item_count
  local page_count

  CODING_BOT_PAGINATED_ARRAY_JSON=""
  if ! raw_items="$(gh api --paginate -X GET "$endpoint" -f per_page=100 --jq '.[]' 2>/dev/null)"; then
    item_count="$(jq -sce 'length' <<<"$raw_items" 2>/dev/null || printf '0')"
    page_count="$(((item_count + 99) / 100))"
    if [[ "$page_count" -eq 0 ]]; then
      page_count=1
    fi
    CODING_BOT_QUEUE_PR_DETAIL_CALLS="$((CODING_BOT_QUEUE_PR_DETAIL_CALLS + page_count))"
    CODING_BOT_QUEUE_HTTP_CALLS="$((CODING_BOT_QUEUE_HTTP_CALLS + page_count))"
    return 1
  fi
  if ! CODING_BOT_PAGINATED_ARRAY_JSON="$(jq -sce '.' <<<"$raw_items" 2>/dev/null)" ||
    ! item_count="$(jq -er 'length' <<<"$CODING_BOT_PAGINATED_ARRAY_JSON" 2>/dev/null)"; then
    item_count="$(jq -sce 'length' <<<"$raw_items" 2>/dev/null || printf '0')"
    page_count="$(((item_count + 99) / 100))"
    if [[ "$page_count" -eq 0 ]]; then
      page_count=1
    fi
    CODING_BOT_QUEUE_PR_DETAIL_CALLS="$((CODING_BOT_QUEUE_PR_DETAIL_CALLS + page_count))"
    CODING_BOT_QUEUE_HTTP_CALLS="$((CODING_BOT_QUEUE_HTTP_CALLS + page_count))"
    return 1
  fi
  page_count="$(((item_count + 99) / 100))"
  if [[ "$page_count" -eq 0 ]]; then
    page_count=1
  fi
  CODING_BOT_QUEUE_PR_DETAIL_CALLS="$((CODING_BOT_QUEUE_PR_DETAIL_CALLS + page_count))"
  CODING_BOT_QUEUE_HTTP_CALLS="$((CODING_BOT_QUEUE_HTTP_CALLS + page_count))"
}

coding_bot_print_assigned_issues() {
  local title="$1"
  local query_text="$2"
  local rows

  printf '\n## %s\n\n' "$title"
  if [[ "$CODING_BOT_QUEUE_READY" != "1" ]]; then
    coding_bot_queue_unavailable_message
    return 0
  fi

  if ! coding_bot_fetch_search "$query_text"; then
    printf 'Failed to fetch assigned issues: %s.\n' "$CODING_BOT_SEARCH_ERROR"
    return 0
  fi

  rows="$(jq -cr '
    .[].items[]
    | {
        repo: (.repository_url | sub("^https://api.github.com/repos/"; "")),
        number,
        title,
        url: .html_url
      }
  ' <<<"$CODING_BOT_SEARCH_JSON")"

  if [[ -z "$rows" ]]; then
    printf 'No matching issues found.\n'
    return 0
  fi

  while IFS= read -r row; do
    jq -r '"- \(.repo)#\(.number): \(.title) \(.url)"' <<<"$row"
  done <<<"$rows"
}

coding_bot_print_authored_prs() {
  local title="$1"
  local query_text="$2"
  local rows
  local row
  local repo
  local number
  local pr_title
  local url
  local pr_json
  local checks_json
  local reviews_json
  local review_comments_json
  local issue_comments_json
  local head_sha
  local head_short
  local draft
  local reviewers
  local checks
  local reviews
  local review_alerts
  local check_count
  local check_total

  printf '\n## %s\n\n' "$title"
  if [[ "$CODING_BOT_QUEUE_READY" != "1" ]]; then
    coding_bot_queue_unavailable_message
    return 0
  fi

  if ! coding_bot_fetch_search "$query_text"; then
    printf 'Failed to fetch authored pull requests: %s.\n' "$CODING_BOT_SEARCH_ERROR"
    return 0
  fi

  rows="$(jq -cr '
    .[].items[]
    | {
        repo: (.repository_url | sub("^https://api.github.com/repos/"; "")),
        number,
        title,
        url: .html_url
      }
  ' <<<"$CODING_BOT_SEARCH_JSON")"

  if [[ -z "$rows" ]]; then
    printf 'No matching pull requests found.\n'
    return 0
  fi

  while IFS= read -r row; do
    repo="$(jq -r '.repo' <<<"$row")"
    number="$(jq -r '.number' <<<"$row")"
    pr_title="$(jq -r '.title' <<<"$row")"
    url="$(jq -r '.url' <<<"$row")"
    CODING_BOT_QUEUE_AUTHORED_PRS="$((CODING_BOT_QUEUE_AUTHORED_PRS + 1))"
    CODING_BOT_QUEUE_PR_DETAIL_CALLS="$((CODING_BOT_QUEUE_PR_DETAIL_CALLS + 1))"
    CODING_BOT_QUEUE_HTTP_CALLS="$((CODING_BOT_QUEUE_HTTP_CALLS + 1))"

    if ! pr_json="$(gh api "repos/$repo/pulls/$number" 2>/dev/null)" ||
      ! jq -e '
        type == "object"
        and (.head.sha | type == "string" and length >= 7)
        and (.draft | type == "boolean")
        and (.requested_reviewers | type == "array")
        and all(.requested_reviewers[]; .login | type == "string")
      ' <<<"$pr_json" >/dev/null 2>&1; then
      printf -- '- %s#%s: %s [details=unavailable] %s\n' "$repo" "$number" "$pr_title" "$url"
      continue
    fi

    head_sha="$(jq -r '.head.sha' <<<"$pr_json")"
    head_short="${head_sha:0:7}"
    draft="$(jq -r '.draft' <<<"$pr_json")"
    reviewers="$(jq -r '
      [.requested_reviewers[].login]
      | if length == 0 then "none" else join(",") end
    ' <<<"$pr_json")"

    CODING_BOT_QUEUE_PR_DETAIL_CALLS="$((CODING_BOT_QUEUE_PR_DETAIL_CALLS + 1))"
    CODING_BOT_QUEUE_HTTP_CALLS="$((CODING_BOT_QUEUE_HTTP_CALLS + 1))"
    if checks_json="$(gh api -X GET "repos/$repo/commits/$head_sha/check-runs" -f per_page=100 2>/dev/null)" &&
      jq -e '
        type == "object"
        and (.total_count | type == "number" and . == floor and . >= 0 and . <= 9007199254740991)
        and (.check_runs | type == "array")
        and all(.check_runs[]; (.status | type == "string") and (.conclusion == null or (.conclusion | type == "string")))
      ' <<<"$checks_json" >/dev/null 2>&1; then
      check_count="$(jq '.check_runs | length' <<<"$checks_json")"
      check_total="$(jq '.total_count' <<<"$checks_json")"
      if [[ "$check_count" -lt "$check_total" ]]; then
        checks="checks=incomplete($check_count/$check_total)"
      elif [[ "$check_count" -gt "$check_total" ]]; then
        checks="checks=unknown"
      elif ! checks="$(jq -er '
          (.check_runs | map(.conclusion // .status)) as $states
          | "checks="
            + (([$states[] | select(. == "failure" or . == "cancelled" or . == "timed_out" or . == "action_required")] | length) | tostring)
            + " fail/"
            + (([$states[] | select(. == "queued" or . == "in_progress" or . == "waiting" or . == "requested" or . == "pending")] | length) | tostring)
            + " pending/"
            + (($states | length) | tostring)
            + " total"
        ' <<<"$checks_json")"; then
        checks="checks=unknown"
      fi
    else
      checks="checks=unknown"
    fi

    if coding_bot_fetch_pr_array "repos/$repo/pulls/$number/reviews" &&
      reviews_json="$CODING_BOT_PAGINATED_ARRAY_JSON" &&
      jq -e '
        type == "array"
        and all(.[]; (.state | type == "string") and (.user.login | type == "string"))
      ' <<<"$reviews_json" >/dev/null 2>&1 &&
      reviews="$(jq -er '
          [.[] | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED") | "\(.user.login):\(.state)"]
          | unique
          | if length == 0 then "reviews=none" else "reviews=" + join(",") end
        ' <<<"$reviews_json")"; then
      :
    else
      reviews="reviews=unknown"
    fi

    if [[ "$reviews" != "reviews=unknown" ]] &&
      coding_bot_fetch_pr_array "repos/$repo/pulls/$number/comments" &&
      review_comments_json="$CODING_BOT_PAGINATED_ARRAY_JSON" &&
      coding_bot_fetch_pr_array "repos/$repo/issues/$number/comments" &&
      issue_comments_json="$CODING_BOT_PAGINATED_ARRAY_JSON" &&
      jq -e '
        type == "array"
        and all(.[];
          (.body | type == "string")
          and (.user.login | type == "string")
          and (.html_url | type == "string")
          and (.commit_id | type == "string")
        )
      ' <<<"$review_comments_json" >/dev/null 2>&1 &&
      jq -e '
        type == "array"
        and all(.[];
          (.body | type == "string")
          and (.user.login | type == "string")
          and (.html_url | type == "string")
        )
      ' <<<"$issue_comments_json" >/dev/null 2>&1 &&
      review_alerts="$(printf '%s\n%s\n%s\n' "$reviews_json" "$review_comments_json" "$issue_comments_json" | jq -ser --arg head "$head_sha" '
        def body_text: (.body // "") | gsub("^[[:space:]]+|[[:space:]]+$"; "");
        def actionable:
          .state == "CHANGES_REQUESTED"
          or (body_text | test("(?i)(^|[^a-z0-9])p[0-3]([^a-z0-9]|$)|blocking finding|finding remains|blocks? (a )?clean merge|unresolved finding|one new issue"));
        def explicit_resolution:
          (body_text | test("(?i)^(no (blocking )?issues( found for [0-9a-f]{7,40})?|((the finding is resolved[.]?[[:space:]]+)?(nothing outstanding|no outstanding findings?)))[.!]?$"));
        .[0] as $reviews
        | .[1] as $inline
        | .[2] as $discussion
        | ([
            $reviews[]
            | select((.state == "COMMENTED" or .state == "CHANGES_REQUESTED") and (body_text | length) > 0)
            | . + {
                target: (if .commit_id == $head then "current" else "stale" end),
                url: (.html_url // "")
              }
          ] + [
            $inline[]
            | select((body_text | length) > 0)
            | . + {
                state: "COMMENTED",
                target: (if .commit_id == $head then "current" else "stale" end),
                url: .html_url
              }
          ] + [
            $discussion[]
            | select((body_text | length) > 0)
            | . + {state: "COMMENTED", target: "discussion", url: .html_url}
          ]) as $notes
        | ($head[0:7]) as $head_short
        | def resolves($finding):
            any($notes[];
              explicit_resolution
              and (
                (.target == "current")
                or (
                  .target == "discussion"
                  and (body_text | test("(?i)(^|[^0-9a-f])" + $head_short + "[0-9a-f]{0,33}([^0-9a-f]|$)"))
                )
              )
              and (
                ((.user.login | ascii_downcase) == ($finding.user.login | ascii_downcase))
                or ((.user.login | ascii_downcase) == "crypto2099")
              )
            );
          [$notes[] | select(.target == "current" and actionable and (resolves(.) | not))] as $current
        | [$notes[] | select(.target == "stale" and actionable and (resolves(.) | not))] as $stale
        | [$notes[] | select(.target == "discussion" and actionable)] as $discussion
        | (($current + $stale + $discussion | first | .url) // ($notes | first | .url) // "none") as $link
        | "review-alerts="
          + (($current | length) | tostring)
          + " current/"
          + (($stale | length) | tostring)
          + " stale/"
          + (($discussion | length) | tostring)
          + " discussion, notes="
          + (($notes | length) | tostring)
          + ", link="
          + $link
      ' 2>/dev/null)"; then
      :
    else
      review_alerts="review-alerts=unknown"
    fi

    printf -- '- %s#%s: %s [head=%s, draft=%s, requested=%s, %s, %s, %s] %s\n' \
      "$repo" "$number" "$pr_title" "$head_short" "$draft" "$reviewers" "$reviews" "$review_alerts" "$checks" "$url"
  done <<<"$rows"
}

coding_bot_print_queue_metrics() {
  if [[ "$CODING_BOT_QUEUE_READY" != "1" ]]; then
    return 0
  fi

  printf '\nQueue REST fan-out: %s HTTP request(s): %s paginated search page(s) and %s PR detail/check/review request(s) for %s authored PR(s).\n' \
    "$CODING_BOT_QUEUE_HTTP_CALLS" \
    "$CODING_BOT_QUEUE_SEARCH_PAGES" \
    "$CODING_BOT_QUEUE_PR_DETAIL_CALLS" \
    "$CODING_BOT_QUEUE_AUTHORED_PRS"
  printf 'Search results use REST pagination at 100 items per page; successful PR expansion costs at least five additional requests per PR.\n'
}
