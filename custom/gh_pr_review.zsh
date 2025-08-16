#!/usr/bin/env zsh

# gh_pr_review.zsh – a Zsh helper for GitHub PR review workflows
#
# This function and supporting helpers simplify common review tasks
# by combining the power of the GitHub CLI (gh) with a bit of
# GraphQL.  It will automatically detect the current repository
# context, locate the pull request associated with your current
# branch, and expose sub‑commands to fetch unresolved review
# threads or comments since the last commit.  You can override
# detection with explicit flags for owner, repository and pull
# number.  Under the hood it makes only authenticated API calls
# with `gh api` and pipes JSON through `jq` for filtering.
#
# Usage:
#   # list unresolved review threads for the current branch
#   gh_pr_review threads
#
#   # list review comments updated since the last commit on the
#   # current branch
#   gh_pr_review comments
#
#   # override repository detection
#   gh_pr_review threads --owner octocat --repo hello-world --pr 42
#
#   # show a help message
#   gh_pr_review help
#
# Notes:
#   • Requires GitHub CLI (gh) to be installed and logged in.
#   • Requires `jq` for JSON processing.
#   • Handles pagination of review threads when more than 100 exist.
#   • Uses GraphQL for review thread metadata and REST for
#     per‑comment retrieval when filtering by time.

function _gh_pr_review_usage() {
  cat <<'USAGE'
Usage: gh_pr_review <command> [options]

Commands:
  threads   List unresolved review threads on a pull request.
  comments  List review comments updated since the latest commit.
  help      Show this usage information.

Options (applicable to both sub‑commands):
  --owner <owner>     GitHub repository owner (defaults to current repository owner).
  --repo <repo>       GitHub repository name (defaults to current repository name).
  --pr <number>       Pull request number (defaults to PR associated with current branch).
  --include-resolved  When listing threads, include resolved threads as well.
  --since <timestamp> Override the default commit timestamp when listing comments.

Examples:
  # List unresolved review threads for current PR
  gh_pr_review threads

  # Include resolved threads as well
  gh_pr_review threads --include-resolved

  # List review comments updated since a specific date
  gh_pr_review comments --since 2025-01-01T00:00:00Z

USAGE
}

# Internal helper: Determine repository owner and name using gh
function _gh_detect_repo() {
  local repo_json
  repo_json=$(gh repo view --json owner,name 2>/dev/null)
  if [[ -n $repo_json ]]; then
    echo "$repo_json" | jq -r '.owner.login + "|" + .name'
  fi
}

# Internal helper: Determine PR number from current branch
function _gh_detect_pr() {
  local branch pr_json pr_number
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  if [[ -z $branch ]]; then
    return
  fi
  # Use gh to view PR associated with branch; quietly ignore errors
  pr_json=$(gh pr view "$branch" --json number 2>/dev/null)
  if [[ -n $pr_json ]]; then
    pr_number=$(echo "$pr_json" | jq -r '.number')
    [[ $pr_number != "null" ]] && echo "$pr_number"
  fi
}

# Internal helper: Parse generic options common to sub‑commands
function _gh_pr_review_parse_options() {
  # Accepts an associative array name by reference
  local -n __opts=$1
  shift
  # Initialize defaults
  __opts[owner]=""
  __opts[repo]=""
  __opts[pr]=""
  __opts[include_resolved]=0
  __opts[since]=""

  # Use zparseopts for simple long options
  local -a args
  args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --owner)
        __opts[owner]="$2"; shift 2;;
      --repo)
        __opts[repo]="$2"; shift 2;;
      --pr)
        __opts[pr]="$2"; shift 2;;
      --include-resolved)
        __opts[include_resolved]=1; shift;;
      --since)
        __opts[since]="$2"; shift 2;;
      --help|-h)
        _gh_pr_review_usage; return 1;;
      --*)
        echo "Unknown option: $1" >&2; return 1;;
      *)
        args+=("$1"); shift;;
    esac
  done
  # Pass back remaining non‑option args
  __opts[args]="$args"
}

# Subcommand: threads
# List unresolved (or optionally all) review threads with summary info
function _gh_pr_review_threads() {
  local -A opts
  _gh_pr_review_parse_options opts "$@" || return 1
  # Determine repo details if missing
  if [[ -z ${opts[owner]} || -z ${opts[repo]} ]]; then
    local detected
    detected=$(_gh_detect_repo)
    if [[ -z $detected ]]; then
      echo "Unable to detect repository; please specify --owner and --repo." >&2
      return 1
    fi
    opts[owner]="${detected%%|*}"
    opts[repo]="${detected##*|}"
  fi
  # Determine PR number if missing
  if [[ -z ${opts[pr]} ]]; then
    opts[pr]=$(_gh_detect_pr)
    if [[ -z ${opts[pr]} ]]; then
      echo "Unable to detect pull request; please specify --pr." >&2
      return 1
    fi
  fi

  local owner=${opts[owner]} repo=${opts[repo]} pr=${opts[pr]}
  local include_resolved=${opts[include_resolved]}

  # GraphQL query template. We request reviewThreads with pagination; each call
  # fetches up to 100 threads. We'll fill in variables via gh api.
  local graphql_query
  graphql_query='query($owner: String!, $repo: String!, $number: Int!, $cursor: String) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $number) {
        reviewThreads(first: 100, after: $cursor) {
          nodes {
            id
            isResolved
            isOutdated
            path
            line
            startLine
            diffSide
            comments(first: 100) {
              nodes {
                databaseId
                body
                author { login }
                createdAt
                updatedAt
              }
            }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }'

  echo "Fetching review threads for $owner/$repo PR#$pr..." >&2
  local cursor="null"
  local has_next="true"
  local tmp_json
  while [[ $has_next == "true" ]]; do
    if [[ $cursor == "null" ]]; then
      # first page – omit cursor variable
      tmp_json=$(gh api graphql -f owner="$owner" -f repo="$repo" -F number="$pr" -f query="$graphql_query" 2>/dev/null)
    else
      tmp_json=$(gh api graphql -f owner="$owner" -f repo="$repo" -F number="$pr" -F cursor="$cursor" -f query="$graphql_query" 2>/dev/null)
    fi
    if [[ -z $tmp_json ]]; then
      echo "Failed to fetch review threads from GitHub." >&2
      return 1
    fi
    # Process threads
    echo "$tmp_json" | jq -r --argjson include_resolved "$include_resolved" '
      .data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false or ($include_resolved == 1)) |
      "---\nThread ID: \(.id)\nResolved: \(.isResolved)\nOutdated: \(.isOutdated)\nPath: \(.path // "(general comment)")\nLine: \(.line // "N/A")\nStartLine: \(.startLine // "N/A")\nComments: \(.comments.nodes | length)" as $header | $header,
      ("  " + (.comments.nodes[] | "Author: \(.author.login) | Created: \(.createdAt) | Body: \(.body | gsub("\n"; " "))) )
    '
    # Determine if more pages exist
    has_next=$(echo "$tmp_json" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')
    if [[ $has_next == "true" ]]; then
      cursor=$(echo "$tmp_json" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor')
    fi
  done
}

# Subcommand: comments
# List review comments updated since the latest commit on the PR (or a provided timestamp)
function _gh_pr_review_comments() {
  local -A opts
  _gh_pr_review_parse_options opts "$@" || return 1
  # Determine repo details
  if [[ -z ${opts[owner]} || -z ${opts[repo]} ]]; then
    local detected
    detected=$(_gh_detect_repo)
    if [[ -z $detected ]]; then
      echo "Unable to detect repository; please specify --owner and --repo." >&2
      return 1
    fi
    opts[owner]="${detected%%|*}"
    opts[repo]="${detected##*|}"
  fi
  # Determine PR number
  if [[ -z ${opts[pr]} ]]; then
    opts[pr]=$(_gh_detect_pr)
    if [[ -z ${opts[pr]} ]]; then
      echo "Unable to detect pull request; please specify --pr." >&2
      return 1
    fi
  fi
  local owner=${opts[owner]} repo=${opts[repo]} pr=${opts[pr]}
  local since_ts=${opts[since]}
  # Determine timestamp: either from --since or from last commit on PR
  if [[ -z $since_ts ]]; then
    # Use gh pr view to get last commit date
    local commit_json
    commit_json=$(gh pr view "$pr" --json commits 2>/dev/null)
    if [[ -z $commit_json ]]; then
      echo "Failed to fetch commits; cannot determine last commit timestamp." >&2
      return 1
    fi
    since_ts=$(echo "$commit_json" | jq -r '.commits[-1].commit.committedDate')
    if [[ -z $since_ts || $since_ts == "null" ]]; then
      echo "Could not determine last commit date from PR." >&2
      return 1
    fi
  fi
  echo "Fetching review comments on $owner/$repo PR#$pr since $since_ts..." >&2
  # Use REST API to list review comments; filter by updated time and display summary
  # Use Accept header to get default JSON
  local comments_json
  comments_json=$(gh api "/repos/$owner/$repo/pulls/$pr/comments" --paginate --jq "map(select(.updated_at > \"$since_ts\"))")
  if [[ -z $comments_json || $comments_json == "null" ]]; then
    echo "No review comments found since $since_ts." >&2
    return 0
  fi
  echo "$comments_json" | jq -r '
    .[] |
    "---\nComment ID: \(.id)\nUpdated: \(.updated_at)\nPath: \(.path // "(general)")\nLine: \(.line // "N/A")\nUser: \(.user.login)\nBody: \(.body | gsub("\n"; " "))"
  '
}

function gh_pr_review() {
  local cmd="$1"
  shift || true
  case "$cmd" in
    threads)
      _gh_pr_review_threads "$@";;
    comments)
      _gh_pr_review_comments "$@";;
    help|-h|--help|"")
      _gh_pr_review_usage;;
    *)
      echo "Unknown command: $cmd" >&2
      _gh_pr_review_usage
      return 1;;
  esac
}

# Only export the main function if we're being sourced (not executed)
if [[ ${(%):-%N} != "$0" ]]; then
  # Prepend to functions and mark for autoload if using zsh modules
  functions[gh_pr_review]="$(functions gh_pr_review)"
fi