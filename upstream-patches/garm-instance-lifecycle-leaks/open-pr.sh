#!/usr/bin/env bash
#
# Open the upstream PR for the garm instance-lifecycle leak fix.
#
# Prerequisites:
#   - `gh` authenticated (`gh auth status`)
#   - A fork of cloudbase/garm on your GitHub account
#
# Usage:
#   FORK=<your-gh-user>/garm ./open-pr.sh
#
# Clones your fork, applies fix.patch with `git am` on a branch cut from
# upstream's default branch, adds the accompanying test as a second commit,
# pushes, and opens the PR against cloudbase/garm with PR.md as the body.
# Review before running.
#
# The test is NOT carried inside fix.patch: ../../checks/garm/instance_lifecycle_test.go
# is the single source of truth, injected by the gate t_garm_instance_lifecycle
# into both a patched and an unpatched tree. This script copies it in, scrubbed
# of private infrastructure identifiers (see ../CLAUDE.md).

set -euo pipefail

UPSTREAM="cloudbase/garm"
FORK="${FORK:?set FORK to your fork, e.g. FORK=yourname/garm}"
BRANCH="${BRANCH:-fix-instance-lifecycle-leaks}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_SRC="${HERE}/../../checks/garm/instance_lifecycle_test.go"
[ -f "$TEST_SRC" ] || { echo "missing $TEST_SRC" >&2; exit 1; }

BASE="$(gh repo view "$UPSTREAM" --json defaultBranchRef -q .defaultBranchRef.name)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

git clone "https://github.com/${FORK}.git" "$work"
cd "$work"
git remote add upstream "https://github.com/${UPSTREAM}.git"
git fetch upstream "$BASE"
git checkout -b "$BRANCH" "upstream/${BASE}"

git am --3way "${HERE}/fix.patch"

# Strip the gate preamble (upstream has no checks/ dir) and private names.
sed -e '/^\/\/ Gate t_garm_instance_lifecycle/,/^\/\/ WHAT IS UNDER TEST$/{/^\/\/ WHAT IS UNDER TEST$/!d}' \
  -e '/^\/\/ THE PRODUCTION DEFECTS/,/^\/\/ WHY IT DISCRIMINATES$/{/^\/\/ WHY IT DISCRIMINATES$/!d}' \
  -e '/^\/\/ WHY IT DISCRIMINATES$/,/^package pool$/{/^package pool$/!d}' \
  -e 's|"metacraft-labs"|"example-org"|g' \
  -e 's|"hms-libvirt"|"test-provider"|g' \
  -e 's|garm-qglasrc9bvey|garm-dropped|g' \
  -e 's|100\.83\.174\.120:8873|192.0.2.10:8873|g' \
  "$TEST_SRC" >runner/pool/instance_lifecycle_test.go
gofmt -w runner/pool/instance_lifecycle_test.go

if grep -nEi 'high-mem-server|metacraft|hms-|100\.83\.|checks/t_garm|gpu-server' \
  runner/pool/instance_lifecycle_test.go; then
  echo "REFUSING TO OPEN THE PR: private identifiers survived the scrub." >&2
  exit 1
fi
git add runner/pool/instance_lifecycle_test.go
git commit -s -m "Test instance-lifecycle handling in the pool manager

Drives cleanupOrphanedGithubRunners() and retryFailedInstancesForOnePool()
against the real SQLite store with a mocked provider and forge: an instance
absent from ListInstances is routed through DeleteInstance, a failing delete
neither cancels its siblings nor is retried every tick, and create retries
are spaced out."

#   go test -tags testing ./runner/pool/ -run TestInstanceLifecycleSuite
git push -u origin "$BRANCH"
gh pr create --repo "$UPSTREAM" --base "$BASE" --head "${FORK%%/*}:${BRANCH}" \
  --title "Never forget an instance the provider may still hold; stop delete storms" \
  --body-file "${HERE}/PR.md"
