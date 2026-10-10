#!/usr/bin/env bash
#
# Commits the diagram to the branch the workflow runs for and pushes it. On a pull request that is
# the pull request's branch, so the diagram lands in the change that altered the schema. Nothing is
# committed when the diagram is the one already there. What the composite action's "commit" step runs.
#
# Environment:
#   OUTPUT_PATH       the diagram's path in the repository
#   GH_TOKEN          a token that may push to the branch
#   COMMIT_MESSAGE
#   GITHUB_REPOSITORY, GITHUB_HEAD_REF, GITHUB_REF_NAME, GITHUB_OUTPUT
#                     set by GitHub; GITHUB_HEAD_REF names the branch of a pull request and is
#                     empty for every other event
set -euo pipefail

fail() {
  echo "::error::$1" >&2
  exit 1
}

branch="${GITHUB_HEAD_REF:-$GITHUB_REF_NAME}"

# For a pull request the checkout is a detached merge of the branch into its base; the diagram
# belongs on the branch itself, so that is checked out, with the diagram carried across.
if [ "$(git rev-parse --abbrev-ref HEAD)" != "$branch" ]; then
  diagram=$(mktemp)
  trap 'rm -f "$diagram"' EXIT
  cp "$OUTPUT_PATH" "$diagram"
  git checkout -q -- "$OUTPUT_PATH" 2>/dev/null || rm -f "$OUTPUT_PATH"
  git fetch -q --depth=1 origin "$branch" 2>/dev/null \
    || fail "Branch '$branch' is gone: the pull request was probably merged or closed before the diagram was ready."
  git checkout -q -B "$branch" FETCH_HEAD
  mkdir -p "$(dirname "$OUTPUT_PATH")"
  cp "$diagram" "$OUTPUT_PATH"
fi

git add "$OUTPUT_PATH"
if git diff --cached --quiet; then
  echo "The diagram is the one already in the repository, nothing to commit."
  echo "commit-sha=" >> "$GITHUB_OUTPUT"
  exit 0
fi

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git commit -q -m "$COMMIT_MESSAGE"
git push -q "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "HEAD:refs/heads/${branch}"

sha=$(git rev-parse HEAD)
echo "Committed the diagram to ${branch} as ${sha}."
echo "commit-sha=${sha}" >> "$GITHUB_OUTPUT"
