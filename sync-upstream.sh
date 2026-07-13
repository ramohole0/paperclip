#!/usr/bin/env bash

# Fetch the latest upstream branch and merge it into the current branch.
#
# Usage:
#   ./sync-upstream.sh
#   ./sync-upstream.sh <upstream-branch>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

REMOTE="upstream"
UPSTREAM_BRANCH="${1:-}"
CURRENT_BRANCH="$(git branch --show-current)"

if [[ $# -gt 1 ]]; then
  printf 'Usage: %s [upstream-branch]\n' "${0##*/}" >&2
  exit 2
fi

if [[ -z "$CURRENT_BRANCH" ]]; then
  printf 'Error: detached HEAD is not supported. Check out a branch first.\n' >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  printf 'Error: the working tree is not clean. Commit or stash changes first.\n' >&2
  exit 1
fi

if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
  printf 'Error: remote "%s" does not exist.\n' "$REMOTE" >&2
  exit 1
fi

if [[ -z "$UPSTREAM_BRANCH" ]]; then
  UPSTREAM_HEAD="$(git symbolic-ref --quiet --short "refs/remotes/$REMOTE/HEAD" 2>/dev/null || true)"
  UPSTREAM_BRANCH="${UPSTREAM_HEAD#${REMOTE}/}"
  if [[ -z "$UPSTREAM_BRANCH" || "$UPSTREAM_BRANCH" == "$UPSTREAM_HEAD" ]]; then
    UPSTREAM_BRANCH="master"
  fi
fi

printf 'Fetching %s/%s...\n' "$REMOTE" "$UPSTREAM_BRANCH"
git fetch "$REMOTE" "$UPSTREAM_BRANCH"

UPSTREAM_REF="$REMOTE/$UPSTREAM_BRANCH"
if git merge-base --is-ancestor "$UPSTREAM_REF" HEAD; then
  printf 'Already up to date with %s.\n' "$UPSTREAM_REF"
  exit 0
fi

printf 'Merging %s into %s...\n' "$UPSTREAM_REF" "$CURRENT_BRANCH"
git merge --no-ff "$UPSTREAM_REF" -m "chore: sync $UPSTREAM_REF"
printf 'Successfully synced %s into %s.\n' "$UPSTREAM_REF" "$CURRENT_BRANCH"
