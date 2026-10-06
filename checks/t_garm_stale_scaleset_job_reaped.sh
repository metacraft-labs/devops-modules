#!/usr/bin/env bash
# Gate `t_garm_stale_scaleset_job_reaped` — milestone H3 of
# `docs/Host-Stability-Recovery.milestones.org` in metacraft-labs/infra.
#
#   "A scale-set job row stuck in `queued` whose GitHub run has completed is
#    cleared by GARM's own reconciler within its reconcile interval. A test
#    that only deletes the row by hand does NOT close this gate; the mechanism
#    must work."
#
# So this gate drives GARM's OWN basePoolManager.reconcileStaleJobs() against
# GARM's OWN sqlDatabase on a real SQLite file, twice:
#
#   PATCHED  — the tree this repo ships (packages/garm/default.nix `patches`).
#              All seven sub-tests must PASS.
#   UNPATCHED— byte-identical except that
#              patches/fix-stale-scaleset-job-reaper.patch is left out.
#              The scale-set sub-tests must FAIL, and the two sub-tests that
#              guard properties the patch must NOT change — the pre-existing
#              workflow-job reap and entity isolation — must still PASS.
#
# The second half is the NEGATIVE CONTROL. Without it "the row was reaped"
# could pass for reasons that have nothing to do with the patch.
#
# Nothing here asserts WALL-CLOCK. This gate is built on a host whose ZFS pool
# stalls for minutes at a time (a 1103-byte `cp` has been measured at 119.7 s),
# so elapsed time is not a property of the code under test. What is asserted is
# COUNTS (rows before/after, forge calls made) inside the Go tests, and CPU
# SECONDS here — a process parked in D state accrues no CPU, so a CPU ceiling
# is load-independent while still catching a reaper that starts doing real work
# per pass.
#
# Environment supplied by checks/garm-stale-scaleset-job-reaped.nix:
#   GATE_PATCHED_SRC    patched GARM source tree (read-only store path)
#   GATE_UNPATCHED_SRC  same tree minus the patch under test
#   GATE_TEST_FILE      checks/garm/stale_scaleset_job_test.go
#   GATE_GO_TAGS        build tags to compile with
#   GATE_CPU_CEILING    CPU-seconds ceiling for one full patched test run
set -euo pipefail

say() { printf '\n=== %s ===\n' "$*"; }
fail() {
  printf 'GATE FAIL: %s\n' "$*" >&2
  exit 1
}

work="$(mktemp -d)"
export GOCACHE="$work/gocache"
export GOPATH="$work/gopath"
export GOFLAGS=-mod=vendor
export GOTOOLCHAIN=local
export CGO_ENABLED=1
export HOME="$work"

# ---------------------------------------------------------------------------
# 0. STATIC CONTRACT — what "within the reconcile interval" means.
#
# The Go tests drive the real startLoopForFunction() loop, but at a compressed
# tick so the gate does not sleep for five minutes. The PRODUCTION schedule is
# therefore asserted here, against the source, so the compressed tick cannot
# quietly become the only thing that is ever checked.
# ---------------------------------------------------------------------------
say "0. schedule contract"
grep -q 'PoolStaleJobReconcileInterval = 5 \* time.Minute' \
  "$GATE_PATCHED_SRC/runner/common/pool.go" ||
  fail "PoolStaleJobReconcileInterval is no longer 5 minutes"
grep -q 'startLoopForFunction(r.reconcileStaleJobs, common.PoolStaleJobReconcileInterval, "stale_job_reconciler"' \
  "$GATE_PATCHED_SRC/runner/pool/pool.go" ||
  fail "reconcileStaleJobs is no longer wired into the pool manager's loop"
echo "ok: reconcileStaleJobs runs every common.PoolStaleJobReconcileInterval = 5m"

# ---------------------------------------------------------------------------
# 1. STATIC REGRESSION GUARDS — the two upstream gaps, asserted at the exact
#    lines they live at, so a future rebase that drops the patch is caught even
#    if the behavioural tests were somehow satisfied another way.
# ---------------------------------------------------------------------------
say "1. the two gaps are closed in the patched tree"
grep -q 'workflow_job_id > 0 OR scale_set_job_id' \
  "$GATE_PATCHED_SRC/database/sql/jobs.go" ||
  fail "gap 1: ListEntityJobsByStatus still excludes scale set jobs"
grep -q 'func (s \*sqlDatabase) DeleteJobByID' \
  "$GATE_PATCHED_SRC/database/sql/jobs.go" ||
  fail "gap 2: no DeleteJobByID — the reaper cannot address a scale set row"
grep -q 'r.store.DeleteJobByID(r.ctx, job.ID)' \
  "$GATE_PATCHED_SRC/runner/pool/pool.go" ||
  fail "gap 2: reconcileStaleJobs still deletes by WorkflowJobID"

say "1b. the unpatched tree really does still carry both gaps"
grep -q 'Where("workflow_job_id > 0")' \
  "$GATE_UNPATCHED_SRC/database/sql/jobs.go" ||
  fail "negative control is not a control: the unpatched tree has no workflow_job_id filter"
if grep -q 'DeleteJobByID' "$GATE_UNPATCHED_SRC/database/sql/jobs.go"; then
  fail "negative control is not a control: the unpatched tree already has DeleteJobByID"
fi
echo "ok: the two trees differ in exactly the way the gate assumes"

# ---------------------------------------------------------------------------
# 2. THE MECHANISM — patched tree, all sub-tests must pass.
# ---------------------------------------------------------------------------
say "2. patched tree: GARM's own reconciler clears the phantom"
patched="$work/patched"
cp -r "$GATE_PATCHED_SRC" "$patched"
chmod -R u+w "$patched"
cp "$GATE_TEST_FILE" "$patched/runner/pool/stale_scaleset_job_test.go"

cd "$patched"
set +e
go test -tags "$GATE_GO_TAGS" -count=1 -timeout 1800s -v \
  -run TestStaleScaleSetJobSuite ./runner/pool/ >"$work/patched.log" 2>&1
patched_rc=$?
set -e
grep -E '^(=== RUN|    --- |--- |ok|FAIL)' "$work/patched.log" || true

[ "$patched_rc" -eq 0 ] || fail "patched tree: the suite did not pass (rc=$patched_rc)"

for t in \
  TestStaleScaleSetJobIsACandidate \
  TestStaleScaleSetJobReapedInOnePass \
  TestGenuinelyQueuedScaleSetJobSurvives \
  TestReapingIsRowAccurate \
  TestAnotherEntitysJobIsNotACandidate \
  TestPoolJobStillReapedByWorkflowJobID \
  TestReapedByTheRealLoop; do
  grep -q -- "--- PASS: TestStaleScaleSetJobSuite/$t" "$work/patched.log" ||
    fail "patched tree: $t did not run or did not pass"
done
echo "ok: 7/7 sub-tests passed on the patched tree"

# CPU ceiling, measured on a STEADY-STATE re-run — the first run above pays
# for compiling the package graph, which is not a property of the reaper. One
# pass of the reaper is a SELECT, one forge call and a DELETE; the seven-test
# suite should cost a fraction of a CPU second of actual work on top of the
# link. CPU rather than wall-clock because a process parked in D state on a
# stalled pool accrues no CPU, so this ceiling is load-independent. It exists
# to catch a reaper that starts doing bulk work per pass, not to benchmark the
# box.
say "2b. CPU cost of a steady-state run"
TIMEFORMAT='%3U %3S'
set +e
cpu_line="$( { time go test -tags "$GATE_GO_TAGS" -count=1 -timeout 1800s \
  -run TestStaleScaleSetJobSuite ./runner/pool/ >"$work/patched2.log" 2>&1
  echo $? >"$work/patched2.rc"; } 2>&1 )"
set -e
[ "$(cat "$work/patched2.rc")" = "0" ] || {
  cat "$work/patched2.log"
  fail "patched tree: the steady-state re-run did not pass"
}
cpu_used_ms="$(awk -v l="$cpu_line" 'BEGIN { split(l, p, " "); printf "%d", (p[1] + p[2]) * 1000 }')"
echo "steady-state run CPU (user+sys): ${cpu_used_ms} ms (ceiling ${GATE_CPU_CEILING} s)"
[ "$cpu_used_ms" -gt 0 ] ||
  fail "CPU measurement returned 0 ms — the measurement itself is broken, not the code"
awk -v used="$cpu_used_ms" -v ceil="$GATE_CPU_CEILING" \
  'BEGIN { if (used > ceil * 1000) exit 1 }' ||
  fail "the suite burned ${cpu_used_ms} ms of CPU, over the ${GATE_CPU_CEILING}s ceiling"

# ---------------------------------------------------------------------------
# 3. THE NEGATIVE CONTROL — unpatched tree, the scale-set sub-tests must FAIL.
#
# TestReapedByTheRealLoop is deliberately excluded here: on the unpatched tree
# it blocks for ever on a reap that never happens, and the only thing that
# would end it is a wall-clock timeout, which this gate does not assert on.
# The six deterministic sub-tests settle the question.
# ---------------------------------------------------------------------------
say "3. negative control: the SAME tests against the unpatched tree"
unpatched="$work/unpatched"
cp -r "$GATE_UNPATCHED_SRC" "$unpatched"
chmod -R u+w "$unpatched"
cp "$GATE_TEST_FILE" "$unpatched/runner/pool/stale_scaleset_job_test.go"

cd "$unpatched"
set +e
go test -tags "$GATE_GO_TAGS" -count=1 -timeout 1800s -v \
  -run 'TestStaleScaleSetJobSuite/(TestStaleScaleSetJobIsACandidate|TestStaleScaleSetJobReapedInOnePass|TestGenuinelyQueuedScaleSetJobSurvives|TestReapingIsRowAccurate|TestAnotherEntitysJobIsNotACandidate|TestPoolJobStillReapedByWorkflowJobID)' \
  ./runner/pool/ >"$work/unpatched.log" 2>&1
unpatched_rc=$?
set -e
grep -E '^(    --- |--- |ok|FAIL)' "$work/unpatched.log" || true

[ "$unpatched_rc" -ne 0 ] ||
  fail "NEGATIVE CONTROL DID NOT REPRODUCE THE DEFECT: the unpatched tree passed. \
The assertions are vacuous — they would pass with or without the fix."

# It must fail for the RIGHT reason: the scale-set assertions, and only those.
for t in \
  TestStaleScaleSetJobIsACandidate \
  TestStaleScaleSetJobReapedInOnePass \
  TestGenuinelyQueuedScaleSetJobSurvives \
  TestReapingIsRowAccurate; do
  grep -q -- "--- FAIL: TestStaleScaleSetJobSuite/$t" "$work/unpatched.log" ||
    fail "negative control: $t was expected to FAIL unpatched but did not"
done

# ... and the two properties the patch must NOT change pass on BOTH trees. That
# is what proves the suite is not simply broken on the unpatched tree for a
# build reason: the ordinary workflow-job reap, and entity isolation (which
# guards against the relaxed filter's OR escaping its parentheses and letting
# one entity's reconciler condemn another entity's rows).
for t in \
  TestPoolJobStillReapedByWorkflowJobID \
  TestAnotherEntitysJobIsNotACandidate; do
  grep -q -- "--- PASS: TestStaleScaleSetJobSuite/$t" "$work/unpatched.log" ||
    fail "negative control: $t should pass on BOTH trees"
done

# The signature of the defect: the forge is never consulted at all, because the
# candidate list is empty.
grep -qE 'FAIL:[[:space:]]*GetWorkflowRunByID' "$work/unpatched.log" ||
  fail "negative control failed, but not with the expected signature (forge never called)"
echo "ok: unpatched tree leaves the row stuck and never calls the forge"

say "GATE PASS: t_garm_stale_scaleset_job_reaped"
