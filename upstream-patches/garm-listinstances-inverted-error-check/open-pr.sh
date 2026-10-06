#!/usr/bin/env bash
#
# Open the upstream PR for the garm ListInstances inverted-error-check fix.
#
# Prerequisites:
#   - `gh` authenticated (`gh auth status`)
#   - A fork of cloudbase/garm on your GitHub account
#
# Usage:
#   FORK=<your-gh-user>/garm ./open-pr.sh
#
# It clones your fork into a scratch dir, applies fix.patch with `git am` on a
# branch cut from upstream's default branch, pushes to your fork, and opens the
# PR against cloudbase/garm with PR.md as the body. Review before running.

set -euo pipefail

UPSTREAM="cloudbase/garm"
FORK="${FORK:?set FORK to your fork, e.g. FORK=yourname/garm}"
BRANCH="${BRANCH:-fix-listinstances-inverted-error-check}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Determine upstream's default branch (main/master) without guessing.
BASE="$(gh repo view "$UPSTREAM" --json defaultBranchRef -q .defaultBranchRef.name)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

git clone "https://github.com/${FORK}.git" "$work"
cd "$work"
git remote add upstream "https://github.com/${UPSTREAM}.git"
git fetch upstream "$BASE"
git checkout -b "$BRANCH" "upstream/${BASE}"

# Apply the prepared patch (3-way in case upstream context drifted).
git am --3way "${HERE}/fix.patch"

# Build sanity (optional; needs a Go toolchain):
# go build ./... >/dev/null

git push -u origin "$BRANCH"

gh pr create \
  --repo "$UPSTREAM" \
  --base "$BASE" \
  --head "${FORK%%/*}:${BRANCH}" \
  --title "Fix inverted error check in external provider ListInstances" \
  --body-file "${HERE}/PR.md"
