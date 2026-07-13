#!/usr/bin/env bash

# Synchronize the community repository into this fork's master branch.
#
# The destination is always master, regardless of which branch invokes the
# script. The two remotes have deliberately different roles:
#   upstream  community repository used as the source of updates
#   origin    this repository's fork, whose master branch is published
#
# The script requires a clean working tree before switching branches. It never
# force-pushes or automatically resolves conflicts: merge conflicts remain for
# manual resolution, and a non-fast-forward push is safely rejected.
#
# Usage:
#   ./sync-upstream.sh
#   ./sync-upstream.sh <upstream-branch>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
SOURCE_REMOTE="upstream"
PUSH_REMOTE="origin"
TARGET_BRANCH="master"

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
  printf '%s\n' "Switch to local master, update it from origin/master, merge the selected"
  printf '%s\n' "community branch, and publish the result to origin/master."
  printf '\n'
  printf '%b\n' "${COLOR_DIM}Arguments:${COLOR_RESET}"
  printf '  %-22s %s\n' "upstream-branch" "Branch on upstream (default: upstream HEAD, then master)"
  printf '\n'
  printf '%b\n' "${COLOR_DIM}Environment:${COLOR_RESET}"
  printf '  %-22s %s\n' "NO_COLOR=1" "Disable colored output"
  printf '\n'
  printf '%s\n' "The destination is always origin/master and the script never force-pushes."
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

  # Prefer the community remote's configured default. Fresh or manually
  # configured clones may not have this symbolic ref, so master is the fallback.
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
  local starting_branch upstream_branch upstream_ref origin_ref merge_result

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

  # Anchor every Git operation to this checkout, regardless of the caller's cwd.
  cd "$REPO_ROOT"
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Repository not found at $REPO_ROOT"

  starting_branch="$(git branch --show-current)"
  [[ -n "$starting_branch" ]] || die "Detached HEAD is not supported; check out a branch first"

  # The script may switch away from the caller's branch. Reject staged, unstaged,
  # and untracked work first so checkout and merge cannot hide local changes.
  [[ -z "$(git status --porcelain)" ]] \
    || die "Working tree is not clean; commit or stash changes first"

  remote_exists "$SOURCE_REMOTE" || die "Remote '$SOURCE_REMOTE' does not exist"
  remote_exists "$PUSH_REMOTE" || die "Remote '$PUSH_REMOTE' does not exist"
  git show-ref --verify --quiet "refs/heads/$TARGET_BRANCH" \
    || die "Local branch '$TARGET_BRANCH' does not exist"

  upstream_branch="$(resolve_upstream_branch "$requested_branch")"
  upstream_ref="$SOURCE_REMOTE/$upstream_branch"
  origin_ref="$PUSH_REMOTE/$TARGET_BRANCH"

  info "Synchronizing community updates into master"
  print_summary_row "Started on" "$starting_branch"
  print_summary_row "Source" "$upstream_ref"
  print_summary_row "Destination" "$origin_ref"

  if [[ "$starting_branch" != "$TARGET_BRANCH" ]]; then
    step "Switching from $starting_branch to $TARGET_BRANCH"
    git switch "$TARGET_BRANCH"
  else
    info "Already on $TARGET_BRANCH"
  fi

  # Refresh both remote-tracking branches. Updating local master from origin first
  # preserves fork-only commits and prevents publishing from a stale local base.
  step "Fetching $origin_ref and $upstream_ref"
  git fetch "$PUSH_REMOTE" "$TARGET_BRANCH"
  git fetch "$SOURCE_REMOTE" "$upstream_branch"
  git rev-parse --verify "${origin_ref}^{commit}" >/dev/null 2>&1 \
    || die "Fetched branch '$origin_ref' does not resolve to a commit"
  git rev-parse --verify "${upstream_ref}^{commit}" >/dev/null 2>&1 \
    || die "Fetched branch '$upstream_ref' does not resolve to a commit"

  step "Updating local $TARGET_BRANCH from $origin_ref"
  # Only a fast-forward is accepted here. Diverged local and fork histories need
  # explicit human reconciliation rather than an unexpected automatic merge.
  git merge --ff-only "$origin_ref"

  if git merge-base --is-ancestor "$upstream_ref" HEAD; then
    merge_result="already included"
    info "$upstream_ref is already included; no community merge needed"
  else
    step "Merging $upstream_ref into $TARGET_BRANCH"
    # A failed merge intentionally leaves Git's normal conflict state intact.
    git merge --no-ff "$upstream_ref" -m "chore: sync $upstream_ref"
    merge_result="merge commit created"
  fi

  # Publish this exact master HEAD to origin/master. The explicit refspec avoids
  # user-specific push settings, and the absence of --force protects the remote.
  step "Pushing $TARGET_BRANCH to $origin_ref"
  git push --set-upstream "$PUSH_REMOTE" "HEAD:refs/heads/$TARGET_BRANCH"

  success "Community version synchronized to master"
  print_summary_row "Upstream" "$upstream_ref"
  print_summary_row "Merge" "$merge_result"
  print_summary_row "Published" "$origin_ref"
  print_summary_row "Current" "$TARGET_BRANCH"
}

main "$@"
