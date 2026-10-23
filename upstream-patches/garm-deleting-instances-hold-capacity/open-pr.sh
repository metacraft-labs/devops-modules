#!/usr/bin/env bash
#
# Open the upstream PR for the "instances stuck in deletion fill a pool" fix.
#
# Prerequisites:
#   - `gh` authenticated (`gh auth status`)
#   - A fork of cloudbase/garm on your GitHub account
#
# Usage:
#   FORK=<your-gh-user>/garm ./open-pr.sh
#
# Clones your fork into a scratch dir, applies fix.patch (fix + tests, one
# commit) with `git am` on a branch cut from upstream's default branch, pushes
# it to your fork, and opens the PR against cloudbase/garm with PR.md as the
# body. Review before running.
#
# fix.patch was generated against upstream main aa830b59 (2026-10-23). The
# local Nix patch (packages/garm/patches/fix-deleting-instances-hold-capacity.patch)
# is the same change on our older pin, cut on top of our other local patches.
# Differences: upstream already excludes `deleted` scale set runners from
# runnerCount() and counts deleting runners against the scale-down delta
# before its loop; this version keeps `deleted` out of every count and computes
# the delta from live runners only. It also adds the runner/pool test.

set -euo pipefail

UPSTREAM="cloudbase/garm"
FORK="${FORK:?set FORK to your fork, e.g. FORK=yourname/garm}"
BRANCH="${BRANCH:-fix-deleting-instances-hold-capacity}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BASE="$(gh repo view "$UPSTREAM" --json defaultBranchRef -q .defaultBranchRef.name)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

git clone "https://github.com/${FORK}.git" "$work"
cd "$work"
git remote add upstream "https://github.com/${UPSTREAM}.git"
git fetch upstream "$BASE"
git checkout -b "$BRANCH" "upstream/${BASE}"

git am --3way "${HERE}/fix.patch"

# Build + test sanity (needs a Go toolchain with cgo):
#   go build ./...
#   go test ./internal/capacity/ ./database/sql/ ./workers/scaleset/
#   go test -tags testing ./runner/pool/ -run 'TestPoolStressTestSuite/TestStuckDeletesDoNotConsumePoolCapacity'

git push -u origin "$BRANCH"

gh pr create \
  --repo "$UPSTREAM" \
  --base "$BASE" \
  --head "${FORK%%/*}:${BRANCH}" \
  --title "Don't let instances stuck in deletion fill a pool" \
  --body-file "${HERE}/PR.md"
