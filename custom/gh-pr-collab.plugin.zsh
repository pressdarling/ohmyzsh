#!/usr/bin/env zsh
# gh-pr-collab.plugin.zsh
# Enhanced GitHub PR collaboration plugin for oh-my-zsh
# Author: Claude & Brady
# Version: 1.0.0

# Colours for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Get current repository owner and name
__gh_get_repo_info() {
    local repo_info
    if repo_info=$(gh repo view --json owner,name 2>/dev/null); then
        echo "$repo_info" | jq -r '"\(.owner.login)/\(.name)"'
    else
        return 1
    fi
}

# Get current branch's PR number
__gh_get_current_pr() {
    local pr_number
    if pr_number=$(gh pr view --json number 2>/dev/null | jq -r '.number'); then
        echo "$pr_number"
    else
        return 1
    fi
}

# Parse command line arguments
__gh_parse_args() {
    local -A opts
    local positional=()
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --owner|-o)
                opts[owner]="$2"
                shift 2
                ;;
            --repo|-r)
                opts[repo]="$2"
                shift 2
                ;;
            --pr|--pr-number|-p)
                opts[pr]="$2"
                shift 2
                ;;
            --help|-h)
                opts[help]=1
                shift
                ;;
            *)
                positional+=("$1")
                shift
                ;;
        esac
    done
    
    # Output as JSON-like format for easy parsing
    for key in ${(k)opts}; do
        echo "${key}=${opts[$key]}"
    done
    
    if [[ ${#positional[@]} -gt 0 ]]; then
        echo "positional=${positional[@]}"
    fi
}

# Main function: Get unresolved review comments
gh-pr-unresolved() {
    local owner repo pr_number
    local show_help=0
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --owner|-o)
                owner="$2"
                shift 2
                ;;
            --repo|-r)
                repo="$2"
                shift 2
                ;;
            --pr|--pr-number|-p)
                pr_number="$2"
                shift 2
                ;;
            --help|-h)
                show_help=1
                shift
                ;;
            *)
                if [[ -z "$pr_number" && "$1" =~ ^[0-9]+$ ]]; then
                    pr_number="$1"
                fi
                shift
                ;;
        esac
    done
    
    if [[ $show_help -eq 1 ]]; then
        echo "${BOLD}Usage:${NC} gh-pr-unresolved [options] [PR_NUMBER]"
        echo ""
        echo "${BOLD}Options:${NC}"
        echo "  -o, --owner OWNER       Repository owner"
        echo "  -r, --repo REPO         Repository name"
        echo "  -p, --pr PR_NUMBER      Pull request number"
        echo "  -h, --help              Show this help message"
        echo ""
        echo "${BOLD}Examples:${NC}"
        echo "  gh-pr-unresolved                    # Current branch PR"
        echo "  gh-pr-unresolved 123                 # PR #123 in current repo"
        echo "  gh-pr-unresolved -o facebook -r react -p 456"
        return 0
    fi
    
    # Auto-detect repository if not provided
    if [[ -z "$owner" || -z "$repo" ]]; then
        local repo_info
        if repo_info=$(__gh_get_repo_info); then
            if [[ -z "$owner" ]]; then
                owner="${repo_info%%/*}"
            fi
            if [[ -z "$repo" ]]; then
                repo="${repo_info##*/}"
            fi
        else
            echo "${RED}Error: Could not detect repository. Please provide --owner and --repo${NC}" >&2
            return 1
        fi
    fi
    
    # Auto-detect PR number if not provided
    if [[ -z "$pr_number" ]]; then
        if pr_number=$(__gh_get_current_pr); then
            echo "${CYAN}Using PR #${pr_number} from current branch${NC}" >&2
        else
            echo "${RED}Error: Could not detect PR number. Please provide --pr or ensure you're on a PR branch${NC}" >&2
            return 1
        fi
    fi
    
    echo "${BLUE}Fetching unresolved review threads for ${owner}/${repo}#${pr_number}...${NC}" >&2
    
    # GraphQL query to get unresolved review threads
    local query='
    query($owner: String!, $repo: String!, $pr: Int!) {
        repository(owner: $owner, name: $repo) {
            pullRequest(number: $pr) {
                title
                url
                state
                reviewDecision
                reviews(last: 10) {
                    nodes {
                        state
                        author {
                            login
                        }
                        createdAt
                    }
                }
                reviewThreads(first: 100) {
                    totalCount
                    edges {
                        node {
                            isResolved
                            isOutdated
                            isCollapsed
                            path
                            line
                            startLine
                            comments(first: 100) {
                                totalCount
                                nodes {
                                    author {
                                        login
                                    }
                                    body
                                    createdAt
                                    url
                                    diffHunk
                                    path
                                    position
                                    outdated
                                }
                            }
                        }
                    }
                }
            }
        }
    }'
    
    local result
    result=$(gh api graphql -f owner="$owner" -f repo="$repo" -F pr="$pr_number" -f query="$query" 2>/dev/null)
    
    if [[ $? -ne 0 ]]; then
        echo "${RED}Error: Failed to fetch PR data${NC}" >&2
        return 1
    fi
    
    # Process and display results
    echo "$result" | jq -r '
        .data.repository.pullRequest as $pr |
        "\n\u001b[1m📋 Pull Request: \u001b[0m" + $pr.title,
        "\u001b[34m🔗 URL: \u001b[0m" + $pr.url,
        "\u001b[34m📊 State: \u001b[0m" + $pr.state,
        "\u001b[34m✅ Review Decision: \u001b[0m" + ($pr.reviewDecision // "NONE"),
        "",
        "\u001b[1m🔍 Review Threads Summary:\u001b[0m",
        "   Total threads: " + ($pr.reviewThreads.totalCount | tostring),
        "   Unresolved: " + ([$pr.reviewThreads.edges[].node | select(.isResolved == false)] | length | tostring),
        "   Resolved: " + ([$pr.reviewThreads.edges[].node | select(.isResolved == true)] | length | tostring),
        "",
        "\u001b[1m⚠️  Unresolved Review Threads:\u001b[0m",
        (
            $pr.reviewThreads.edges[] |
            select(.node.isResolved == false) |
            .node as $thread |
            "\n\u001b[33m📁 File: " + $thread.path + "\u001b[0m",
            (if $thread.startLine then
                "   📍 Lines: " + ($thread.startLine | tostring) + "-" + ($thread.line | tostring)
            else
                "   📍 Line: " + ($thread.line | tostring)
            end),
            "   " + (if $thread.isOutdated then "⚠️  OUTDATED" else "✅ Current" end),
            "   💬 Comments (" + ($thread.comments.totalCount | tostring) + "):",
            (
                $thread.comments.nodes[] |
                "      \u001b[36m@" + .author.login + "\u001b[0m (" + (.createdAt | split("T")[0]) + "):",
                "      " + (.body | split("\n") | join("\n      ")),
                "      \u001b[34m" + .url + "\u001b[0m",
                ""
            )
        ),
        "\n\u001b[32m✨ Done!\u001b[0m"
    '
}

# Get comments since last commit
gh-pr-comments-since-commit() {
    local owner repo pr_number
    local show_help=0
    
    # Parse arguments (similar to above)
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --owner|-o)
                owner="$2"
                shift 2
                ;;
            --repo|-r)
                repo="$2"
                shift 2
                ;;
            --pr|--pr-number|-p)
                pr_number="$2"
                shift 2
                ;;
            --help|-h)
                show_help=1
                shift
                ;;
            *)
                if [[ -z "$pr_number" && "$1" =~ ^[0-9]+$ ]]; then
                    pr_number="$1"
                fi
                shift
                ;;
        esac
    done
    
    if [[ $show_help -eq 1 ]]; then
        echo "${BOLD}Usage:${NC} gh-pr-comments-since-commit [options] [PR_NUMBER]"
        echo ""
        echo "${BOLD}Options:${NC}"
        echo "  -o, --owner OWNER       Repository owner"
        echo "  -r, --repo REPO         Repository name"
        echo "  -p, --pr PR_NUMBER      Pull request number"
        echo "  -h, --help              Show this help message"
        return 0
    fi
    
    # Auto-detect repository if not provided
    if [[ -z "$owner" || -z "$repo" ]]; then
        local repo_info
        if repo_info=$(__gh_get_repo_info); then
            if [[ -z "$owner" ]]; then
                owner="${repo_info%%/*}"
            fi
            if [[ -z "$repo" ]]; then
                repo="${repo_info##*/}"
            fi
        else
            echo "${RED}Error: Could not detect repository${NC}" >&2
            return 1
        fi
    fi
    
    # Auto-detect PR number if not provided
    if [[ -z "$pr_number" ]]; then
        if pr_number=$(__gh_get_current_pr); then
            echo "${CYAN}Using PR #${pr_number} from current branch${NC}" >&2
        else
            echo "${RED}Error: Could not detect PR number${NC}" >&2
            return 1
        fi
    fi
    
    echo "${BLUE}Fetching comments since last commit for ${owner}/${repo}#${pr_number}...${NC}" >&2
    
    # Get the last commit timestamp
    local last_commit_time
    last_commit_time=$(gh pr view "$pr_number" -R "${owner}/${repo}" --json commits \
        | jq -r '.commits[-1].commit.committedDate' 2>/dev/null)
    
    if [[ -z "$last_commit_time" ]]; then
        echo "${RED}Error: Could not fetch last commit time${NC}" >&2
        return 1
    fi
    
    echo "${CYAN}Last commit: ${last_commit_time}${NC}" >&2
    
    # Fetch all comments and filter by timestamp
    local query='
    query($owner: String!, $repo: String!, $pr: Int!) {
        repository(owner: $owner, name: $repo) {
            pullRequest(number: $pr) {
                title
                url
                comments(last: 100) {
                    nodes {
                        author {
                            login
                        }
                        body
                        createdAt
                        url
                    }
                }
                reviewThreads(first: 100) {
                    edges {
                        node {
                            comments(first: 100) {
                                nodes {
                                    author {
                                        login
                                    }
                                    body
                                    createdAt
                                    url
                                    path
                                }
                            }
                        }
                    }
                }
            }
        }
    }'
    
    local result
    result=$(gh api graphql -f owner="$owner" -f repo="$repo" -F pr="$pr_number" -f query="$query")
    
    if [[ $? -ne 0 ]]; then
        echo "${RED}Error: Failed to fetch PR comments${NC}" >&2
        return 1
    fi
    
    # Process and display comments since last commit
    echo "$result" | jq -r --arg last_commit "$last_commit_time" '
        .data.repository.pullRequest as $pr |
        
        # Collect all comments
        (
            [$pr.comments.nodes[] | select(.createdAt > $last_commit)] +
            [$pr.reviewThreads.edges[].node.comments.nodes[] | select(.createdAt > $last_commit)]
        ) as $new_comments |
        
        "\n\u001b[1m💬 Comments Since Last Commit\u001b[0m",
        "Last commit: " + $last_commit,
        "New comments: " + ($new_comments | length | tostring),
        "",
        (
            $new_comments |
            sort_by(.createdAt) |
            .[] |
            "\u001b[33m" + (.createdAt | split("T")[0]) + " " + (.createdAt | split("T")[1] | split(".")[0]) + "\u001b[0m",
            "\u001b[36m@" + .author.login + "\u001b[0m" + (if .path then " on " + .path else "" end),
            .body,
            "\u001b[34m" + .url + "\u001b[0m",
            ""
        )
    '
}

# Interactive PR review browser
gh-pr-review-interactive() {
    local owner repo pr_number
    
    # Parse arguments (similar pattern as above functions)
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --owner|-o)
                owner="$2"
                shift 2
                ;;
            --repo|-r)
                repo="$2"
                shift 2
                ;;
            --pr|--pr-number|-p)
                pr_number="$2"
                shift 2
                ;;
            *)
                if [[ -z "$pr_number" && "$1" =~ ^[0-9]+$ ]]; then
                    pr_number="$1"
                fi
                shift
                ;;
        esac
    done
    
    # Auto-detect if needed
    if [[ -z "$owner" || -z "$repo" ]]; then
        local repo_info
        if repo_info=$(__gh_get_repo_info); then
            if [[ -z "$owner" ]]; then
                owner="${repo_info%%/*}"
            fi
            if [[ -z "$repo" ]]; then
                repo="${repo_info##*/}"
            fi
        fi
    fi
    
    if [[ -z "$pr_number" ]]; then
        pr_number=$(__gh_get_current_pr)
    fi
    
    if [[ -z "$owner" || -z "$repo" || -z "$pr_number" ]]; then
        echo "${RED}Error: Could not determine repository or PR number${NC}" >&2
        return 1
    fi
    
    while true; do
        clear
        echo "${BOLD}${CYAN}GitHub PR Review Dashboard${NC}"
        echo "${BLUE}Repository: ${owner}/${repo}${NC}"
        echo "${BLUE}PR #${pr_number}${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "${BOLD}Options:${NC}"
        echo "  ${GREEN}1${NC}) View unresolved review threads"
        echo "  ${GREEN}2${NC}) View comments since last commit"
        echo "  ${GREEN}3${NC}) View all review comments"
        echo "  ${GREEN}4${NC}) View PR details"
        echo "  ${GREEN}5${NC}) Open PR in browser"
        echo "  ${GREEN}6${NC}) Approve PR"
        echo "  ${GREEN}7${NC}) Request changes"
        echo "  ${GREEN}8${NC}) Add comment"
        echo "  ${GREEN}9${NC}) Change PR number"
        echo "  ${GREEN}0${NC}) Change repository"
        echo "  ${RED}q${NC}) Quit"
        echo ""
        echo -n "Select option: "
        
        read -k1 choice
        echo ""
        
        case "$choice" in
            1)
                echo ""
                gh-pr-unresolved -o "$owner" -r "$repo" -p "$pr_number"
                echo ""
                echo "Press any key to continue..."
                read -k1
                ;;
            2)
                echo ""
                gh-pr-comments-since-commit -o "$owner" -r "$repo" -p "$pr_number"
                echo ""
                echo "Press any key to continue..."
                read -k1
                ;;
            3)
                echo ""
                gh pr view "$pr_number" -R "${owner}/${repo}" --comments
                echo ""
                echo "Press any key to continue..."
                read -k1
                ;;
            4)
                echo ""
                gh pr view "$pr_number" -R "${owner}/${repo}"
                echo ""
                echo "Press any key to continue..."
                read -k1
                ;;
            5)
                gh pr view "$pr_number" -R "${owner}/${repo}" --web
                ;;
            6)
                echo ""
                echo -n "Add approval comment (optional): "
                read comment
                if [[ -n "$comment" ]]; then
                    gh pr review "$pr_number" -R "${owner}/${repo}" --approve -b "$comment"
                else
                    gh pr review "$pr_number" -R "${owner}/${repo}" --approve
                fi
                echo "Press any key to continue..."
                read -k1
                ;;
            7)
                echo ""
                echo -n "Request changes comment: "
                read comment
                gh pr review "$pr_number" -R "${owner}/${repo}" --request-changes -b "$comment"
                echo "Press any key to continue..."
                read -k1
                ;;
            8)
                echo ""
                echo -n "Add comment: "
                read comment
                gh pr review "$pr_number" -R "${owner}/${repo}" --comment -b "$comment"
                echo "Press any key to continue..."
                read -k1
                ;;
            9)
                echo ""
                echo -n "Enter new PR number: "
                read pr_number
                ;;
            0)
                echo ""
                echo -n "Enter owner/repo (e.g., facebook/react): "
                read repo_input
                owner="${repo_input%%/*}"
                repo="${repo_input##*/}"
                echo -n "Enter PR number: "
                read pr_number
                ;;
            q|Q)
                echo "${GREEN}Goodbye!${NC}"
                return 0
                ;;
            *)
                echo "${RED}Invalid option${NC}"
                sleep 1
                ;;
        esac
    done
}

# Aliases for convenience
alias ghpru='gh-pr-unresolved'
alias ghprc='gh-pr-comments-since-commit'
alias ghpri='gh-pr-review-interactive'
alias ghpr='gh pr view --comments'

# Completion functions
_gh_pr_unresolved() {
    _arguments \
        '(-o --owner)'{-o,--owner}'[Repository owner]:owner:' \
        '(-r --repo)'{-r,--repo}'[Repository name]:repo:' \
        '(-p --pr --pr-number)'{-p,--pr,--pr-number}'[Pull request number]:pr:' \
        '(-h --help)'{-h,--help}'[Show help]' \
        '1:pr number:'
}

_gh_pr_comments_since_commit() {
    _arguments \
        '(-o --owner)'{-o,--owner}'[Repository owner]:owner:' \
        '(-r --repo)'{-r,--repo}'[Repository name]:repo:' \
        '(-p --pr --pr-number)'{-p,--pr,--pr-number}'[Pull request number]:pr:' \
        '(-h --help)'{-h,--help}'[Show help]' \
        '1:pr number:'
}

# Register completions
compdef _gh_pr_unresolved gh-pr-unresolved
compdef _gh_pr_comments_since_commit gh-pr-comments-since-commit

# Print loaded message
echo "${GREEN}✓${NC} gh-pr-collab plugin loaded. Use ${CYAN}gh-pr-unresolved --help${NC} to get started."
