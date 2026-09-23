#!/usr/bin/env bash
#
# Open the upstream PR for the garm stale-scale-set-job reaper fix.
#
# Prerequisites:
#   - `gh` authenticated (`gh auth status`)
#   - A fork of cloudbase/garm on your GitHub account
#
# Usage:
#   FORK=<your-gh-user>/garm ./open-pr.sh
#
# It clones your fork into a scratch dir, applies fix.patch with `git am` on a
# branch cut from upstream's default branch, adds the accompanying test as a
# second commit, pushes to your fork, and opens the PR against cloudbase/garm
# with PR.md as the body. Review before running.
#
# NOTE ON THE TEST FILE. The test is NOT carried inside fix.patch. It lives at
# ../../checks/garm/stale_scaleset_job_test.go, which is the single source of
# truth: the gate `t_garm_stale_scaleset_job_reaped` injects that same file into
# BOTH a patched and an unpatched GARM tree, so the negative control runs the
# identical assertions. Duplicating it into fix.patch would guarantee drift
# between what we gate on and what we upstream. This script copies it in.

set -euo pipefail

UPSTREAM="cloudbase/garm"
FORK="${FORK:?set FORK to your fork, e.g. FORK=yourname/garm}"
BRANCH="${BRANCH:-fix-stale-scaleset-job-reaper}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_SRC="${HERE}/../../checks/garm/stale_scaleset_job_test.go"

[ -f "$TEST_SRC" ] || {
  echo "missing $TEST_SRC — the gate's test file is the source of truth for the upstream test" >&2
  exit 1
}

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
git am --3way "${HERE}/fix.patch"

# 2. the test. Two transformations on the way in.
#
#    (a) Strip the metacraft-labs-specific gate preamble from the doc comment —
#        upstream has no `checks/` directory to point at.
#    (b) SCRUB PRIVATE INFRASTRUCTURE IDENTIFIERS. This file is our gate's
#        source of truth and deliberately carries the real identifiers of the
#        incident it reproduces, which is right for a private milestone but
#        wrong to hand to an unrelated upstream project: the host name is a
#        named production server and `codetracer-ci` is a PRIVATE repository.
#        The numeric run IDs and scale-set UUIDs are opaque and are kept, so
#        the fixture still stands for something concrete. Same rule as PR.md
#        (see ../AGENTS.md: "written for a public upstream audience — no
#        private infra details"), and the same class of scrub as
#        `chore: scrub recon-grade private names from deployment fixtures/tests`.
sed -e '/^\/\/ Gate t_garm_stale_scaleset_job_reaped/,/^\/\/ WHAT IS UNDER TEST$/{/^\/\/ WHAT IS UNDER TEST$/!d}' \
  -e 's|^//\tRun the same file against the UNPATCHED tree (the negative control, see$|//\tRun the same file against an unpatched tree and every scale-set assertion|' \
  -e '/^\/\/\tchecks\/t_garm_stale_scaleset_job_reaped\.sh) and TestStaleScaleSetJob\*$/d' \
  -e 's|"metacraft-labs"|"example-org"|g' \
  -e 's|"codetracer-ci"|"example-repo"|g' \
  -e 's|the live phantom on high-mem-server exactly|the observed phantom exactly|' \
  -e 's|On high-mem-server every one of the 9 rows in the live|On the affected controller every one of the rows in the live|' \
  -e 's|^// high-mem-server at the time of writing (run |// a live controller at the time of writing (run |' \
  -e 's|(the live phantom hangs off org metacraft-labs)|(the observed phantom hung off an organization entity)|' \
  -e 's|^// function wired into it is asserted separately and statically by$|// function wired into it is asserted separately and statically against|' \
  -e '/^\/\/ checks\/t_garm_stale_scaleset_job_reaped\.sh against pool\.go and$/d' \
  -e 's|^// runner/common/pool\.go\.$|// pool.go and runner/common/pool.go.|' \
  "$TEST_SRC" >runner/pool/stale_scaleset_job_test.go
gofmt -w runner/pool/stale_scaleset_job_test.go

# The scrub above is a set of literal substitutions and will silently stop
# working if the source file is reworded. Fail loudly instead of publishing.
if grep -nEi 'high-mem-server|codetracer-ci|metacraft-labs|/var/lib/garm|zroot|checks/t_garm' \
  runner/pool/stale_scaleset_job_test.go; then
  echo >&2
  echo "REFUSING TO OPEN THE PR: private identifiers survived the scrub above." >&2
  echo "The source test file was reworded; update the sed rules to match." >&2
  exit 1
fi
git add runner/pool/stale_scaleset_job_test.go
git commit -m "Test that reconcileStaleJobs reaps a stale scale set job

Drives the real basePoolManager.reconcileStaleJobs() — directly and via
the real startLoopForFunction() loop — against the real database/sql
store on a real SQLite file, with only the forge mocked. Covers the
positive case, the safety case (a job whose run is still in_progress is
left alone), row accuracy across three rows that all carry
workflow_job_id = 0, and the unchanged workflow-job path.

Signed-off-by: Metacraft Labs <info@metacraft-labs.com>"

# Build + test sanity (needs a Go toolchain with cgo):
#   go build ./...
#   go test -tags testing ./runner/pool/ -run TestStaleScaleSetJobSuite

git push -u origin "$BRANCH"

gh pr create \
  --repo "$UPSTREAM" \
  --base "$BASE" \
  --head "${FORK%%/*}:${BRANCH}" \
  --title "Make reconcileStaleJobs able to see and reap scale set jobs" \
  --body-file "${HERE}/PR.md"
