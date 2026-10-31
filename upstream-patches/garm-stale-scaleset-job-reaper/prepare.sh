#!/usr/bin/env bash
#
# prepare hook for submit-prepared-pr: runs in the PR tree after fix.patch is
# applied. It adds the test as a second commit, taken from the gate's source of
# truth (stale_scaleset_job_test.go in this bundle, declared in bundle.toml
# `inputs`), with two transformations on the way in:
#
#   (a) strip the gate preamble from the doc comment (upstream has no
#       `checks/` directory to point at);
#   (b) scrub private infrastructure identifiers. The source file deliberately
#       carries the real identifiers of the incident it reproduces (a named
#       production server, a private repository), which is right for our gate
#       and wrong for an upstream project. The numeric run IDs and scale-set
#       UUIDs are opaque and are kept.
#
# The substitutions are literal and silently stop matching if the source is
# reworded; bundle.toml [review] forbid turns that into a loud failure.
#
# The test commit carries the same author and Signed-off-by as the fix commit.
set -euo pipefail

TEST_SRC="${BUNDLE_DIR:?run me through submit-prepared-pr}/stale_scaleset_job_test.go"
DST=runner/pool/stale_scaleset_job_test.go
command -v gofmt >/dev/null || { echo "prepare.sh needs gofmt on PATH (e.g. nix shell nixpkgs#go)" >&2; exit 1; }

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
  "$TEST_SRC" >"$DST"
gofmt -w "$DST"

AUTHOR="$(git log -1 --format='%an <%ae>')"
git add "$DST"
git commit -q --author="$AUTHOR" -m "Test that reconcileStaleJobs reaps a stale scale set job

Drives the real basePoolManager.reconcileStaleJobs() — directly and via
the real startLoopForFunction() loop — against the real database/sql
store on a real SQLite file, with only the forge mocked. Covers the
positive case, the safety case (a job whose run is still in_progress is
left alone), row accuracy across three rows that all carry
workflow_job_id = 0, and the unchanged workflow-job path.

Signed-off-by: $AUTHOR"
echo "added $DST as a second commit"
