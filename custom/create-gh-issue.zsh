#!/usr/bin/env zsh

# ==============================================================================
#
# create-gh-issue.sh
#
# Description:
#   A Zsh script to create a GitHub issue in the current repository from a
#   Markdown file.
#
# Usage:
#   ./create-gh-issue.sh [options] <markdown_file>
#
# Options:
#   -l, --label <label>      (Optional) A comma-separated list of labels to add.
#   -a, --assignee <user>    (Optional) A GitHub username to assign to the issue.
#                            Use "@me" to self-assign.
#   -h, --help               Display this help message and exit.
#
# Example:
#   ./create-gh-issue.sh -l "bug,documentation" -a "@me" path/to/your/review.md
#
# ==============================================================================

# --- Helper: Display usage information ---
usage() {
  echo "Usage: $(basename "$0") [options] <markdown_file>"
  echo ""
  echo "Creates a GitHub issue from a Markdown file."
  echo ""
  echo "Options:"
  echo "  -l, --label <label>      (Optional) A comma-separated list of labels."
  echo "  -a, --assignee <user>    (Optional) A GitHub username to assign (use '@me' for self)."
  echo "  -h, --help               Display this help message and exit."
  echo ""
  echo "Example:"
  echo "  $(basename "$0") -l 'bug,needs-review' -a 'monalisa' docs/my-issue.md"
}

# --- Main function to create the issue ---
create_issue_from_file() {
  local file_path=""
  local labels=""
  local assignee=""
  local title=""

  # --- Parse command-line arguments ---
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -l|--label)
        if [[ -n "$2" ]]; then
          labels="$2"
          shift 2
        else
          echo "Error: --label requires a non-empty option argument." >&2
          return 1
        fi
        ;;
      -a|--assignee)
        if [[ -n "$2" ]]; then
          assignee="$2"
          shift 2
        else
          echo "Error: --assignee requires a non-empty option argument." >&2
          return 1
        fi
        ;;
      -h|--help)
        usage
        return 0
        ;;
      -*)
        echo "Error: Unknown option: $1" >&2
        usage
        return 1
        ;;
      *)
        # Assume the last argument is the file path
        if [[ -z "$file_path" ]]; then
            file_path="$1"
            shift
        else
            echo "Error: Multiple file paths provided. Only one is allowed." >&2
            usage
            return 1
        fi
        ;;
    esac
  done

  # --- Validate inputs ---
  if [[ -z "$file_path" ]]; then
    echo "Error: Markdown file path is required." >&2
    usage
    return 1
  fi

  if [[ ! -f "$file_path" ]]; then
    echo "Error: File not found at '$file_path'" >&2
    return 1
  fi

  # --- Determine the issue title ---
  # Use the filename (without extension) as the default title.
  # e.g., "path/to/my-awesome-feature.md" becomes "my-awesome-feature"
  title=$(basename "$file_path" .md | sed 's/-/ /g' | sed 's/_/ /g')
  # Capitalize the first letter
  title="$(tr '[:lower:]' '[:upper:]' <<< ${title:0:1})${title:1}"


  # --- Build the gh command ---
  local gh_command="gh issue create"

  # Add title
  gh_command+=" --title \"$title\""

  # Add body from file
  gh_command+=" --body-file \"$file_path\""

  # Add labels if provided
  if [[ -n "$labels" ]]; then
    gh_command+=" --label \"$labels\""
  fi

  # Add assignee if provided
  if [[ -n "$assignee" ]]; then
    gh_command+=" --assignee \"$assignee\""
  fi

  # --- Execute the command ---
  echo "Running command:"
  echo "$gh_command"
  echo "---"

  # Execute the command
  eval "$gh_command"
}

# # --- Run the main function with all script arguments ---
# create_issue_from_file "$@"
