#!/usr/bin/env bash
# Propose distro source updates; never merge or publish unreviewed packages.
set -Eeuo pipefail
: "${GH_TOKEN:?}" "${GITHUB_REPOSITORY:?}"
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
shopt -s nullglob
for file in discovered/*.txt; do
  name="$(basename "$file" .txt)"
  family="${name%%-*}"
  target="${name#*-}"
  version="$(<"$file")"
  branch="bot/update-$family-$target"
  git switch -C "$branch" origin/main
  python3 scripts/ci/update-versions.py "$family" "$target" "$version"
  if git diff --quiet -- release/versions.json; then
    echo "No change: $family/$target"
    continue
  fi
  # Avoid retriggering CI or overwriting a pending bot PR for an identical update.
  git fetch origin "refs/heads/$branch:refs/remotes/origin/$branch" 2>/dev/null || :
  if git show "origin/$branch:release/versions.json" 2>/dev/null |
     cmp -s - release/versions.json; then
    echo "Existing proposal is up to date: $branch"
    continue
  fi
  git add release/versions.json
  git commit -m "build: update native $family/$target source to $version"
  git push --force-with-lease origin "HEAD:refs/heads/$branch"
  if ! gh pr list --repo "$GITHUB_REPOSITORY" --head "$branch" --state open \
       --json number --jq '.[0].number // empty' | grep -q .; then
    gh pr create --repo "$GITHUB_REPOSITORY" --base main --head "$branch" \
      --draft --title "Update $family/$target Netavark source to $version" \
      --body "Discovered from the distribution's native source repository. Review upstream changes and patch applicability, then run the native build and networking regressions before merging. The downstream revision resets to xddd1 for a new source version."
  fi
  # GITHUB_TOKEN-created PRs do not trigger pull_request workflows.
  # workflow_dispatch is an explicit exception to GitHub's recursion prevention.
  gh workflow run ci.yml --repo "$GITHUB_REPOSITORY" --ref "$branch"
done
git switch main
