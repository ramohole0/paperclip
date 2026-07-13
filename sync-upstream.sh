#!/usr/bin/env bash

# Synchronize the current branch with the community repository, then publish it.
#
# The two remotes have deliberately different roles:
#   upstream  community repository used as the source of updates
#   origin    this repository's fork, used as the push destination
#
# The script requires a clean working tree so a merge cannot hide local work. It
# never force-pushes or automatically resolves conflicts: merge conflicts remain
# available for manual resolution, and a non-fast-forward push is safely rejected.
#
# Usage:
#   ./sync-upstream.sh
#   ./sync-upstream.sh <upstream-branch>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
SOURCE_REMOTE="upstream"
PUSH_REMOTE="origin"

if [[ -t 1 && "${NO_COLOR:-}" == "" ]]; then
  COLOR_RESET=$'\033[0m'
  COLOR_BOLD=$'\033[1m'
  COLOR_DIM=$'\033[2m'
  COLOR_BLUE=$'\033[34m'
  COLOR_GREEN=$'\033[32m'
  COLOR_RED=$'\033[31m'
  COLOR_CYAN=$'\033[36m'
else
  COLOR_RESET=""
  COLOR_BOLD=""
  COLOR_DIM=""
  COLOR_BLUE=""
  COLOR_GREEN=""
  COLOR_RED=""
  COLOR_CYAN=""
fi

SYNC_LABEL="${COLOR_BOLD}${COLOR_CYAN}Paperclip${COLOR_RESET}${COLOR_DIM} sync${COLOR_RESET}"

print_status() {
  local color="$1"
  local label="$2"
  shift 2
  printf '%b %b%-7s%b %s\n' "$SYNC_LABEL" "$color" "$label" "$COLOR_RESET" "$*"
}

info() {
  print_status "$COLOR_BLUE" "info" "$*"
}

step() {
  print_status "$COLOR_CYAN" "run" "$*"
}

success() {
  print_status "$COLOR_GREEN" "ok" "$*"
}

die() {
  print_status "$COLOR_RED" "error" "$*" >&2
  exit 1
}

print_summary_row() {
  local label="$1"
  local value="$2"
  printf '  %b%-12s%b %s\n' "$COLOR_DIM" "$label" "$COLOR_RESET" "$value"
}

usage() {
  printf '%b\n' "${COLOR_BOLD}Paperclip upstream synchronization${COLOR_RESET}"
  printf '\n'
  printf '%b\n' "${COLOR_DIM}Usage:${COLOR_RESET} ./sync-upstream.sh [upstream-branch]"
  printf '\n'
  printf '%s\n' "Fetch and merge the selected upstream branch into the current branch,"
  printf '%s\n' "then push the current branch to the same branch name on origin."
  printf '\n'
  printf '%b\n' "${COLOR_DIM}Arguments:${COLOR_RESET}"
  printf '  %-22s %s\n' "upstream-branch" "Branch on upstream (default: upstream HEAD, then master)"
  printf '\n'
  printf '%b\n' "${COLOR_DIM}Environment:${COLOR_RESET}"
  printf '  %-22s %s\n' "NO_COLOR=1" "Disable colored output"
  printf '\n'
  printf '%s\n' "The push configures origin/<current-branch> as the tracking branch and never force-pushes."
}

remote_exists() {
  git remote get-url "$1" >/dev/null 2>&1
}

resolve_upstream_branch() {
  local requested_branch="$1"
  local upstream_head

  if [[ -n "$requested_branch" ]]; then
    printf '%s\n' "$requested_branch"
    return
  fi

  # Prefer the remote's configured default. Fresh or manually configured clones
  # may not have this symbolic ref, so retain master as a compatibility fallback.
  upstream_head="$(git symbolic-ref --quiet --short "refs/remotes/$SOURCE_REMOTE/HEAD" 2>/dev/null || true)"
  upstream_head="${upstream_head#${SOURCE_REMOTE}/}"
  if [[ -n "$upstream_head" ]]; then
    printf '%s\n' "$upstream_head"
  else
    printf '%s\n' "master"
  fi
}

main() {
  local requested_branch=""
  local current_branch upstream_branch upstream_ref push_destination merge_result

  if [[ $# -gt 1 ]]; then
    usage >&2
    exit 2
  fi

  case "${1:-}" in
    -h|--help|help)
      usage
      exit 0
      ;;
    -*)
      usage >&2
      exit 2
      ;;
    *) requested_branch="${1:-}" ;;
  esac

  # Anchor all Git operations to this checkout, regardless of the caller's cwd.
  cd "$REPO_ROOT"
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Repository not found at $REPO_ROOT"

  current_branch="$(git branch --show-current)"
  [[ -n "$current_branch" ]] || die "Detached HEAD is not supported; check out a branch first"

  # Fetching is harmless, but merging is not. Fail before any network or history
  # operation when staged, unstaged, or untracked work could be mixed into it.
  [[ -z "$(git status --porcelain)" ]] \
    || die "Working tree is not clean; commit or stash changes first"

  remote_exists "$SOURCE_REMOTE" || die "Remote '$SOURCE_REMOTE' does not exist"
  remote_exists "$PUSH_REMOTE" || die "Remote '$PUSH_REMOTE' does not exist"

  upstream_branch="$(resolve_upstream_branch "$requested_branch")"
  upstream_ref="$SOURCE_REMOTE/$upstream_branch"
  push_destination="$PUSH_REMOTE/$current_branch"

  info "Synchronizing community updates"
  print_summary_row "Source" "$upstream_ref"
  print_summary_row "Branch" "$current_branch"
  print_summary_row "Publish" "$push_destination"

  step "Fetching $upstream_ref"
  git fetch "$SOURCE_REMOTE" "$upstream_branch"
  git rev-parse --verify "${upstream_ref}^{commit}" >/dev/null 2>&1 \
    || die "Fetched branch '$upstream_ref' does not resolve to a commit"

  if git merge-base --is-ancestor "$upstream_ref" HEAD; then
    merge_result="already included"
    info "$upstream_ref is already included; no merge needed"
  else
    step "Merging $upstream_ref into $current_branch"
    # A failed merge intentionally leaves Git's normal conflict state intact.
    git merge --no-ff "$upstream_ref" -m "chore: sync $upstream_ref"
    merge_result="merge commit created"
  fi

  # Continue here even when no merge was needed: the local synchronization may
  # still be unpublished. The explicit refspec avoids relying on user push config,
  # publishes this exact HEAD under the same branch name, and never force-pushes.
  step "Pushing $current_branch to $push_destination"
  git push --set-upstream "$PUSH_REMOTE" "HEAD:refs/heads/$current_branch"

  success "Community version synchronized and published"
  print_summary_row "Upstream" "$upstream_ref"
  print_summary_row "Merge" "$merge_result"
  print_summary_row "Published" "$push_destination"
  print_summary_row "Tracking" "$push_destination"
}

main "$@"
