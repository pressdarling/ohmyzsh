#!/usr/bin/env zsh

# gh-pr-review.plugin.zsh
# Enhanced GitHub PR Review Plugin for oh-my-zsh
# Optimised for cross-agent collaboration with comprehensive review management
# Author: Brady (with AI assistance)
# Version: 2.0.0

# Ensure gh CLI is installed
if ! command -v gh &>/dev/null; then
    echo "Warning: GitHub CLI (gh) is not installed. Install it from https://cli.github.com"
    return 1
fi

# Ensure jq is installed for JSON parsing
if ! command -v jq &>/dev/null; then
    echo "Warning: jq is not installed. Install it for enhanced functionality: brew install jq"
fi

# Main function: Get unresolved PR reviews and recent comments
gh-pr-review() {
    local owner=""
    local repo=""
    local pr_number=""
    local show_resolved=false
    local since_last_commit=false
    local interactive=false
    local verbose=false
    local format="pretty"
    
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
            --pr|-p|--pr-number)
                pr_number="$2"
                shift 2
                ;;
            --all|-a)
                show_resolved=true
                shift
                ;;
            --since-commit|-s)
                since_last_commit=true
                shift
                ;;
            --interactive|-i)
                interactive=true
                shift
                ;;
            --verbose|-v)
                verbose=true
                shift
                ;;
            --json)
                format="json"
                shift
                ;;
            --help|-h)
                _gh_pr_review_help
                return 0
                ;;
            *)
                echo "Unknown option: $1"
                _gh_pr_review_help
                return 1
                ;;
        esac
    done
    
    # Auto-detect repository and PR if not provided
    if [[ -z "$owner" || -z "$repo" ]]; then
        local repo_info
        repo_info=$(gh repo view --json owner,name 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            owner=$(echo "$repo_info" | jq -r '.owner.login')
            repo=$(echo "$repo_info" | jq -r '.name')
            [[ "$verbose" == true ]] && echo "✓ Detected repository: $owner/$repo"
        else
            echo "Error: Could not detect repository. Use --owner and --repo or run from within a git repository."
            return 1
        fi
    fi
    
    # Auto-detect PR number from current branch if not provided
    if [[ -z "$pr_number" ]]; then
        local pr_info
        pr_info=$(gh pr view --json number,state 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            pr_number=$(echo "$pr_info" | jq -r '.number')
            local pr_state=$(echo "$pr_info" | jq -r '.state')
            [[ "$verbose" == true ]] && echo "✓ Detected PR #$pr_number (${pr_state})"
        else
            # Try to find PR for current branch
            local branch_name=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
            if [[ -n "$branch_name" ]]; then
                pr_info=$(gh pr list --head "$branch_name" --json number,state --jq '.[0]' 2>/dev/null)
                if [[ -n "$pr_info" && "$pr_info" != "null" ]]; then
                    pr_number=$(echo "$pr_info" | jq -r '.number')
                    [[ "$verbose" == true ]] && echo "✓ Found PR #$pr_number for branch: $branch_name"
                else
                    echo "Error: No PR found for current branch. Use --pr-number or create a PR first."
                    return 1
                fi
            else
                echo "Error: Could not detect PR number. Use --pr-number or run from a branch with an open PR."
                return 1
            fi
        fi
    fi
    
    # Show PR summary
    echo "═══════════════════════════════════════════════════════════════════"
    echo "📋 PR Review Status for $owner/$repo #$pr_number"
    echo "═══════════════════════════════════════════════════════════════════"
    
    # Get PR details
    local pr_details=$(gh pr view "$pr_number" --repo "$owner/$repo" --json title,author,state,reviewDecision,url)
    echo "📌 $(echo "$pr_details" | jq -r '.title')"
    echo "👤 Author: $(echo "$pr_details" | jq -r '.author.login')"
    echo "📊 State: $(echo "$pr_details" | jq -r '.state')"
    echo "✅ Review Decision: $(echo "$pr_details" | jq -r '.reviewDecision // "PENDING"')"
    echo "🔗 $(echo "$pr_details" | jq -r '.url')"
    echo ""
    
    # Get unresolved review threads using GraphQL
    echo "───────────────────────────────────────────────────────────────────"
    echo "💬 Review Threads"
    echo "───────────────────────────────────────────────────────────────────"
    
    local graphql_query='
    query FetchReviewThreads($owner: String!, $repo: String!, $pr: Int!) {
        repository(owner: $owner, name: $repo) {
            pullRequest(number: $pr) {
                reviewThreads(first: 100) {
                    totalCount
                    nodes {
                        id
                        isResolved
                        isOutdated
                        isCollapsed
                        path
                        line
                        startLine
                        comments(first: 50) {
                            totalCount
                            nodes {
                                id
                                author {
                                    login
                                }
                                body
                                createdAt
                                updatedAt
                                url
                                replyTo {
                                    id
                                }
                            }
                        }
                    }
                }
            }
        }
    }'
    
    local threads_data=$(gh api graphql -f owner="$owner" -f repo="$repo" -F pr="$pr_number" -f query="$graphql_query")
    
    if [[ "$format" == "json" ]]; then
        echo "$threads_data" | jq '.data.repository.pullRequest.reviewThreads'
        return 0
    fi
    
    local total_threads=$(echo "$threads_data" | jq '.data.repository.pullRequest.reviewThreads.totalCount')
    local unresolved_count=$(echo "$threads_data" | jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)] | length')
    local resolved_count=$(echo "$threads_data" | jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == true)] | length')
    
    echo "📊 Total: $total_threads threads (✅ $resolved_count resolved, ❌ $unresolved_count unresolved)"
    echo ""
    
    # Display unresolved threads
    if [[ $unresolved_count -gt 0 ]]; then
        echo "❌ Unresolved Threads:"
        echo "$threads_data" | jq -r '
            .data.repository.pullRequest.reviewThreads.nodes[]
            | select(.isResolved == false)
            | "  📁 \(.path // "General")\(.line | if . then ":\(.)" else "" end)
  👤 Started by: \(.comments.nodes[0].author.login)
  💭 \"\(.comments.nodes[0].body | split("\n")[0] | if length > 80 then .[0:77] + "..." else . end)\"
  💬 \(.comments.totalCount) comment(s) | \(if .isOutdated then "⚠️  OUTDATED" else "✓ Current" end)
  🔗 \(.comments.nodes[0].url)
"'
    fi
    
    # Display resolved threads if requested
    if [[ "$show_resolved" == true && $resolved_count -gt 0 ]]; then
        echo ""
        echo "✅ Resolved Threads:"
        echo "$threads_data" | jq -r '
            .data.repository.pullRequest.reviewThreads.nodes[]
            | select(.isResolved == true)
            | "  📁 \(.path // "General")\(.line | if . then ":\(.)" else "" end)
  👤 Started by: \(.comments.nodes[0].author.login)
  💬 \(.comments.totalCount) comment(s)
"'
    fi
    
    # Get comments since last commit if requested
    if [[ "$since_last_commit" == true ]]; then
        echo ""
        echo "───────────────────────────────────────────────────────────────────"
        echo "🔄 Comments Since Last Commit"
        echo "───────────────────────────────────────────────────────────────────"
        
        # Get last commit timestamp
        local last_commit_info=$(gh pr view "$pr_number" --repo "$owner/$repo" --json commits --jq '.commits[-1]')
        local last_commit_date=$(echo "$last_commit_info" | jq -r '.committedDate')
        local last_commit_sha=$(echo "$last_commit_info" | jq -r '.oid[0:7]')
        
        echo "📍 Last commit: $last_commit_sha at $last_commit_date"
        echo ""
        
        # Filter comments after last commit
        echo "$threads_data" | jq -r --arg since "$last_commit_date" '
            .data.repository.pullRequest.reviewThreads.nodes[].comments.nodes[]
            | select(.createdAt > $since)
            | "  👤 \(.author.login) at \(.createdAt | split("T")[0])
  💭 \"\(.body | split("\n")[0] | if length > 80 then .[0:77] + "..." else . end)\"
  🔗 \(.url)
"'
    fi
    
    # Interactive mode
    if [[ "$interactive" == true ]]; then
        echo ""
        echo "───────────────────────────────────────────────────────────────────"
        echo "🎯 Interactive Actions"
        echo "───────────────────────────────────────────────────────────────────"
        echo "1) Open PR in browser"
        echo "2) Checkout PR locally"
        echo "3) View full PR diff"
        echo "4) Add a review comment"
        echo "5) Approve PR"
        echo "6) Request changes"
        echo "7) View CI status"
        echo "8) Refresh"
        echo "0) Exit"
        echo ""
        
        local choice
        read "choice?Select an action (0-8): "
        
        case "$choice" in
            1)
                gh pr view "$pr_number" --repo "$owner/$repo" --web
                ;;
            2)
                gh pr checkout "$pr_number" --repo "$owner/$repo"
                ;;
            3)
                gh pr diff "$pr_number" --repo "$owner/$repo"
                ;;
            4)
                echo "Enter your comment (press Ctrl+D when done):"
                local comment=$(cat)
                gh pr comment "$pr_number" --repo "$owner/$repo" --body "$comment"
                ;;
            5)
                gh pr review "$pr_number" --repo "$owner/$repo" --approve
                ;;
            6)
                echo "Enter your review comment:"
                read -r review_comment
                gh pr review "$pr_number" --repo "$owner/$repo" --request-changes --body "$review_comment"
                ;;
            7)
                gh pr checks "$pr_number" --repo "$owner/$repo"
                ;;
            8)
                gh-pr-review "$@"
                ;;
            0)
                echo "Exiting..."
                ;;
            *)
                echo "Invalid choice"
                ;;
        esac
    fi
}

# Helper function to display help
_gh_pr_review_help() {
    cat << EOF
GitHub PR Review Plugin - Enhanced PR review management for cross-agent collaboration

Usage: gh-pr-review [OPTIONS]

Options:
    --owner, -o <owner>      Repository owner (auto-detected if not provided)
    --repo, -r <repo>        Repository name (auto-detected if not provided)
    --pr, -p <number>        PR number (auto-detected from current branch if not provided)
    --all, -a                Show all threads including resolved ones
    --since-commit, -s       Show only comments since the last commit
    --interactive, -i        Enable interactive mode with additional actions
    --verbose, -v            Show verbose output with detection details
    --json                   Output raw JSON data
    --help, -h               Show this help message

Examples:
    # Auto-detect everything from current branch
    gh-pr-review

    # Specify PR explicitly
    gh-pr-review --pr 123

    # Full specification
    gh-pr-review --owner facebook --repo react --pr 28000

    # Show all threads and enable interactive mode
    gh-pr-review --all --interactive

    # Show comments since last commit
    gh-pr-review --since-commit

    # Get JSON output for scripting
    gh-pr-review --json | jq '.nodes[] | select(.isResolved == false)'

Features:
    ✓ Auto-detects repository and PR from current context
    ✓ Shows unresolved review threads with GraphQL API
    ✓ Filters comments by last commit timestamp
    ✓ Interactive mode for common PR actions
    ✓ Full JSON output for scripting
    ✓ Supports cross-repository operations

Requirements:
    - GitHub CLI (gh) authenticated
    - jq for JSON parsing (optional but recommended)
    - Git repository context (for auto-detection)

EOF
}

# Alias for convenience
alias gpr='gh-pr-review'
alias gpri='gh-pr-review --interactive'
alias gpra='gh-pr-review --all'
alias gprs='gh-pr-review --since-commit'

# Quick function to list all PRs with unresolved comments
gh-pr-unresolved-list() {
    local owner="$1"
    local repo="$2"
    
    if [[ -z "$owner" || -z "$repo" ]]; then
        local repo_info=$(gh repo view --json owner,name 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            owner=$(echo "$repo_info" | jq -r '.owner.login')
            repo=$(echo "$repo_info" | jq -r '.name')
        else
            echo "Usage: gh-pr-unresolved-list [owner] [repo]"
            return 1
        fi
    fi
    
    echo "Scanning open PRs in $owner/$repo for unresolved comments..."
    echo ""
    
    # Get all open PRs
    local prs=$(gh pr list --repo "$owner/$repo" --state open --json number,title,author --limit 100)
    
    echo "$prs" | jq -r '.[] | .number' | while read -r pr_num; do
        local pr_title=$(echo "$prs" | jq -r ".[] | select(.number == $pr_num) | .title")
        local pr_author=$(echo "$prs" | jq -r ".[] | select(.number == $pr_num) | .author.login")
        
        # Check for unresolved threads
        local unresolved=$(gh api graphql -f owner="$owner" -f repo="$repo" -F pr="$pr_num" -f query='
            query($owner: String!, $repo: String!, $pr: Int!) {
                repository(owner: $owner, name: $repo) {
                    pullRequest(number: $pr) {
                        reviewThreads(first: 100) {
                            nodes {
                                isResolved
                            }
                        }
                    }
                }
            }' 2>/dev/null | jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)] | length')
        
        if [[ "$unresolved" -gt 0 ]]; then
            echo "PR #$pr_num: $pr_title"
            echo "  Author: $pr_author"
            echo "  ❌ Unresolved threads: $unresolved"
            echo ""
        fi
    done
}

# Export functions for use in scripts
export -f gh-pr-review
export -f gh-pr-unresolved-list

# Success message on load
echo "✓ GitHub PR Review Plugin loaded. Use 'gh-pr-review --help' for usage."
