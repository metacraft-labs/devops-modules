#!/usr/bin/env bash
#
# Open the upstream PRs for "allow macOS pools".
#
# THIS IS TWO PRs, IN ORDER, AND THE ORDER IS NOT OPTIONAL. The `OSType`
# constants live in cloudbase/garm-provider-common, which has Windows, Linux
# and Unknown only. fix.patch (against cloudbase/garm) references
# `params.MacOS`, so it does not compile until provider-common has been merged,
# tagged, and vendored into garm. See PR.md.
#
#   step 1  provider-common-fix.patch -> cloudbase/garm-provider-common
#   step 2  (upstream merges + tags it, and bumps garm's go.mod + vendor/)
#   step 3  fix.patch + the test      -> cloudbase/garm
#
# Prerequisites:
#   - `gh` authenticated (`gh auth status`)
#   - A fork of the repo you are opening against, on your GitHub account
#
# Usage:
#   STEP=common FORK=<your-gh-user>/garm-provider-common ./open-pr.sh
#   STEP=garm   FORK=<your-gh-user>/garm               ./open-pr.sh
#
# It clones your fork into a scratch dir, applies the patch with `git am` on a
# branch cut from upstream's default branch, pushes, and opens the PR with
# PR.md as the body. Review before running.
#
# NOTE ON THE TEST FILE. The test is NOT carried inside fix.patch. It lives at
# ../../checks/garm/macos_pool_ostype_test.go, which is the single source of
# truth: the gate `t_garm_macos_pools_supported` compiles that same file into
# BOTH a patched and an unpatched GARM tree, so the negative control runs the
# identical assertions. Duplicating it into fix.patch would guarantee drift
# between what we gate on and what we upstream. This script copies it in for
# the `garm` step.

set -euo pipefail

STEP="${STEP:?set STEP to 'common' (garm-provider-common) or 'garm'}"
FORK="${FORK:?set FORK to your fork, e.g. FORK=yourname/garm}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_SRC="${HERE}/../../checks/garm/macos_pool_ostype_test.go"

case "$STEP" in
  common)
    UPSTREAM="cloudbase/garm-provider-common"
    PATCH="${HERE}/provider-common-fix.patch"
    BRANCH="${BRANCH:-add-macos-ostype-constant}"
    TITLE="Add a MacOS OSType constant"
    ;;
  garm)
    UPSTREAM="cloudbase/garm"
    PATCH="${HERE}/fix.patch"
    BRANCH="${BRANCH:-allow-macos-pools}"
    TITLE="Allow macOS pools, matching what scale sets already accept"
    [ -f "$TEST_SRC" ] || {
      echo "missing $TEST_SRC — the gate's test file is the source of truth for the upstream test" >&2
      exit 1
    }
    ;;
  *)
    echo "STEP must be 'common' or 'garm' (got '$STEP')" >&2
    exit 1
    ;;
esac

# Determine upstream's default branch (main/master) without guessing.
BASE="$(gh repo view "$UPSTREAM" --json defaultBranchRef -q .defaultBranchRef.name)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

git clone "https://github.com/${FORK}.git" "$work"
cd "$work"
git remote add upstream "https://github.com/${UPSTREAM}.git"
git fetch upstream "$BASE"
git checkout -b "$BRANCH" "upstream/${BASE}"

# 1. the fix.
git am --3way "$PATCH"

# 2. the test — `garm` step only; garm-provider-common has no Runner to test.
if [ "$STEP" = garm ]; then
  # Strip the metacraft-labs-specific gate preamble from the doc comment:
  # upstream has no `checks/` directory to point at. The rest of the header —
  # what is under test, why it is an internal test, why nothing is mocked — is
  # exactly as useful upstream and is kept verbatim.
  sed -e '/^\/\/ Gate t_garm_macos_pools_supported/,/^\/\/ WHAT IS UNDER TEST$/{/^\/\/ WHAT IS UNDER TEST$/!d}' \
    "$TEST_SRC" >runner/macos_pool_ostype_test.go
  gofmt -w runner/macos_pool_ostype_test.go

  # The scrub above is a literal substitution and will silently stop working if
  # the source file is reworded. Fail loudly instead of publishing. (This test
  # deliberately carries no host names, org names or private repo names — this
  # guard exists so that stays true.)
  if grep -nEi 'high-mem-server|metacraft|infra/checks|reprobuild-specs|m3-tart' \
    runner/macos_pool_ostype_test.go; then
    echo >&2
    echo "REFUSING TO OPEN THE PR: private identifiers survived the scrub above." >&2
    echo "The source test file was reworded; update the sed rule to match." >&2
    exit 1
  fi
  git add runner/macos_pool_ostype_test.go
  git commit -m "Test that the pool path accepts os_type=macos

Drives the real Runner.appendTagsToCreatePoolParams() — the function
that returns the 400 — rather than IsSupportedOSType alone, so the test
keeps meaning something if the caller changes. Covers the macOS case,
that linux and windows are unaffected, that an unknown OS type and an
unsupported architecture are still rejected, and that the provider check
at the end of the function is still reached.

Signed-off-by: Metacraft Labs <info@metacraft-labs.com>"
fi

# Build + test sanity (needs a Go toolchain with cgo):
#   go build ./...
#   go test -tags testing ./runner/ -run 'TestMacOS|TestLinuxAndWindows|TestUnknown|TestUnsupported'

git push -u origin "$BRANCH"

gh pr create \
  --repo "$UPSTREAM" \
  --base "$BASE" \
  --head "${FORK%%/*}:${BRANCH}" \
  --title "$TITLE" \
  --body-file "${HERE}/PR.md"
