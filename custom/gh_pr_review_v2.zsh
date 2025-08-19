# gh_pr_review_v2: list unresolved review threads and comments since last commit
# Requires: gh, jq
gh_pr_review_v2() {
  emulate -L zsh
  set -o pipefail

  local subcmd="" owner="" repo="" pr="" since="" include_resolved=0

  # ---- argument parsing (works in zsh & bash style) ----
  while [[ $# -gt 0 ]]; do
    case "$1" in
      threads|comments) subcmd="$1"; shift ;;
      --owner=*) owner="${1#*=}"; shift ;;
      --owner)   owner="$2"; shift 2 ;;
      --repo=*)  repo="${1#*=}"; shift ;;
      --repo)    repo="$2"; shift 2 ;;
      --pr=*|--pr-number=*|--number=*) pr="${1#*=}"; shift ;;
      --pr|--pr-number|--number) pr="$2"; shift 2 ;;
      --since=*) since="${1#*=}"; shift ;;
      --since)   since="$2"; shift 2 ;;
      --include-resolved) include_resolved=1; shift ;;
      -h|--help)
        cat <<'EOF'
Usage: gh_pr_review_v2 [threads|comments] [--owner X] [--repo Y] [--pr N]
                    [--since ISO8601] [--include-resolved]

  threads   List review threads (default: unresolved only; add --include-resolved)
  comments  List review comments updated since last commit (or --since)

Examples:
  gh_pr_review_v2 threads
  gh_pr_review_v2 comments --pr 123
  gh_pr_review_v2 threads --owner foo --repo bar --pr 69
EOF
        return 0;;
      *) print -u2 "Unknown arg: $1"; return 2;;
    esac
  done

  # ---- detect owner/repo if not provided ----
  if [[ -z "$owner" || -z "$repo" ]]; then
    if read -r owner repo < <(gh repo view --json owner,name -q '.owner.login+" "+.name' 2>/dev/null); then
      :
    else
      # fallback to parsing git remote
      local remote url path
      remote=$(git config --get branch."$(git rev-parse --abbrev-ref HEAD 2>/dev/null)".remote 2>/dev/null || echo origin)
      url=$(git remote get-url "$remote" 2>/dev/null || true)
      path="${url##*:}"; path="${path#https://github.com/}"; path="${path%.git}"
      owner="${owner:-${path%%/*}}"
      repo="${repo:-${path##*/}}"
    fi
  fi
  [[ -z "$owner" || -z "$repo" ]] && { print -u2 "Could not determine owner/repo"; return 1; }

  # ---- detect PR number if not provided ----
  if [[ -z "$pr" ]]; then
    pr=$(gh pr view --json number -q .number 2>/dev/null) || {
      print -u2 "No PR detected for current branch. Pass --pr <number>."; return 1;
    }
  fi

  # ---- subcommands ----
  case "${subcmd:-threads}" in
    threads)
      _ghpr_list_threads "$owner" "$repo" "$pr" "$include_resolved"
      ;;
    comments)
      _ghpr_list_comments_since "$owner" "$repo" "$pr" "$since"
      ;;
    *)
      print -u2 "Unknown subcommand: $subcmd"; return 2
      ;;
  esac
}

# List review threads (GraphQL) with pagination; default: unresolved only
_ghpr_list_threads_v2() {
  emulate -L zsh; set -o pipefail
  local owner="$1" repo="$2" pr="$3" include_resolved="$4"
  local cursor="" has_next="true"

  while [[ "$has_next" == "true" ]]; do
    local q='
      query($owner:String!,$repo:String!,$number:Int!,$cursor:String) {
        repository(owner:$owner, name:$repo) {
          pullRequest(number:$number) {
            reviewThreads(first:100, after:$cursor) {
              nodes {
                id
                isResolved
                isOutdated
                path
                line
                originalLine
                startLine
                originalStartLine
                comments(first:100) {
                  nodes {
                    databaseId
                    author { login }
                    body
                    createdAt
                    url
                  }
                }
              }
              pageInfo { hasNextPage endCursor }
            }
          }
        }
      }'

    local resp
    resp=$(gh api graphql -F owner="$owner" -F repo="$repo" -F number="$pr" -F cursor="${cursor:-null}" -f query="$q") || return 1

    # filter unresolved unless --include-resolved
    if (( include_resolved )); then
      echo "$resp" | jq -r '
        .data.repository.pullRequest.reviewThreads.nodes[]
        | "— " + (if .isResolved then "[resolved] " else "" end) + (.path // "general") + ":" + ((.line // .originalLine // .startLine // .originalStartLine // "N/A")|tostring)
        + "\n  threadId: \(.id)\n  outdated: \(.isOutdated)\n"
        + ( .comments.nodes[] | "  [\(.author.login)] \(.createdAt)\n    id=\(.databaseId)\n    \(.body|gsub("\r";"")|gsub("\n";"\n    "))\n    \(.url)\n" )
      '
    else
      echo "$resp" | jq -r '
        .data.repository.pullRequest.reviewThreads.nodes[]
        | select(.isResolved == false)
        | "— " + (.path // "general") + ":" + ((.line // .originalLine // .startLine // .originalStartLine // "N/A")|tostring)
        + "\n  threadId: \(.id)\n  outdated: \(.isOutdated)\n"
        + ( .comments.nodes[] | "  [\(.author.login)] \(.createdAt)\n    id=\(.databaseId)\n    \(.body|gsub("\r";"")|gsub("\n";"\n    "))\n    \(.url)\n" )
      '
    fi

    has_next=$(echo "$resp" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')
    cursor=$(echo "$resp"     | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor')
  done
}

# List review comments updated since last commit (REST)
_ghpr_list_comments_since_v2() {
  emulate -L zsh; set -o pipefail
  local owner="$1" repo="$2" pr="$3" since="$4"

  if [[ -z "$since" ]]; then
    # last PR commit date via REST (safe and predictable)
    since=$(gh api "/repos/$owner/$repo/pulls/$pr/commits" \
            | jq -r '.[-1].commit.committer.date') || return 1
  fi

  # Pull request REVIEW comments (not issue comments)
  gh api --paginate -H "Accept: application/vnd.github+json" \
    "/repos/$owner/$repo/pulls/$pr/comments?since=$since&per_page=100" \
  | jq -r '
      .[]? |
      "— \(.path // "general"):\(.line // .original_line // "N/A")  (\(.updated_at))"
      + "\n  id=\(.id) by \(.user.login)"
      + "\n  \(.body|gsub("\r";"")|gsub("\n";"\n  "))"
      + "\n  \(.html_url)\n"
    '
}
