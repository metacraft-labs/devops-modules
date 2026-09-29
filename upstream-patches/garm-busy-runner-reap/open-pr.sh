#!/usr/bin/env bash
#
# Open the upstream PR for the garm busy-runner reap fix.
#
# Prerequisites:
#   - `gh` authenticated (`gh auth status`)
#   - A fork of cloudbase/garm on your GitHub account
#
# Usage:
#   FORK=<your-gh-user>/garm ./open-pr.sh
#
# Clones your fork into a scratch dir, applies fix.patch (fix + tests in
# runner/pool/busy_runner_reap_test.go, one commit) with `git am` on a branch
# cut from upstream's default branch, pushes it to your fork, and opens the PR
# against cloudbase/garm with PR.md as the body. Review before running.
#
# fix.patch was generated against upstream main c58e7375 (2026-09-29). The
# local Nix patch (packages/garm/patches/fix-busy-runner-reap.patch) is the
# same change on our older pin, cut on top of our other local patches (it
# differs only in context).

set -euo pipefail

UPSTREAM="cloudbase/garm"
FORK="${FORK:?set FORK to your fork, e.g. FORK=yourname/garm}"
BRANCH="${BRANCH:-fix-busy-runner-reap}"
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
#   go test -tags testing ./runner/pool/ -run TestBusyRunnerReapSuite

git push -u origin "$BRANCH"

gh pr create \
  --repo "$UPSTREAM" \
  --base "$BASE" \
  --head "${FORK%%/*}:${BRANCH}" \
  --title "Never reap a runner the forge reports busy" \
  --body-file "${HERE}/PR.md"
