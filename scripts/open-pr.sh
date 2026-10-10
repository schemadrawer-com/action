#!/usr/bin/env bash
#
# Commits the diagram on a branch of its own and opens a pull request for it - unless the diagram
# is the one already in the repository. What the composite action's "pr" step runs.
#
# Environment:
#   OUTPUT_PATH     the diagram's path in the repository
#   GH_TOKEN        a token that may push the branch and open the pull request
#   BASE_BRANCH     the branch the pull request targets (default: the current one)
#   PR_BRANCH       the branch created for it (default: schemadrawer/update-<run id>-<run attempt>)
#   PR_TITLE, PR_BODY, COMMIT_MESSAGE
#   RUN_ID, RUN_ATTEMPT, GITHUB_REPOSITORY, GITHUB_OUTPUT
set -euo pipefail

base_branch="${BASE_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"
pr_branch="${PR_BRANCH:-schemadrawer/update-${RUN_ID}-${RUN_ATTEMPT}}"

git config user.name 'github-actions[bot]'
git config user.email 'github-actions[bot]@users.noreply.github.com'

git checkout -b "$pr_branch"
git add "$OUTPUT_PATH"

if git diff --cached --quiet; then
  echo "Result is identical to what's already in the repo, nothing to commit."
  exit 0
fi

git commit -m "$COMMIT_MESSAGE"
git push --force-with-lease origin "$pr_branch"

pr_url=$(gh pr create \
  --base "$base_branch" \
  --head "$pr_branch" \
  --title "$PR_TITLE" \
  --body "$PR_BODY" \
  --repo "$GITHUB_REPOSITORY")

echo "pull-request-url=$pr_url" >> "$GITHUB_OUTPUT"
