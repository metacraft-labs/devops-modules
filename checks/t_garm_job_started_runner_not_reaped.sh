#!/usr/bin/env bash
# Gate `t_garm_job_started_runner_not_reaped` — GARM's timeout reaper must not
# try to retire a runner that GARM itself recorded picking up a job.
#
# Observation (central GARM, high-mem-server, 2026-11-25): two agent-harbor
# runners hours into a 1080-minute job were listed by GitHub as offline AND
# not busy for a moment. reapTimedOutRunners (timed out from UpdatedAt, which
# is not refreshed while a job runs) asked GitHub to remove them, and GitHub
# refused with 422 because the jobs were still assigned. The forge's busy
# flag, which fix-busy-runner-reap.patch consults, is what flickered; the
# instance's RunnerActive status, which GARM set on the job's in_progress
# event, did not.
#
# This gate drives GARM's OWN runnerCleanup() and
# cleanupOrphanedProviderRunners() against GARM's OWN store on a real SQLite
# file, twice:
#
#   PATCHED   — the tree this repo ships. All four sub-tests must PASS.
#   UNPATCHED — identical except that
#               patches/fix-reap-skips-job-started-runners.patch is left out.
#               The defect sub-test must FAIL; the three controls must PASS.
#
# Environment supplied by checks/garm-job-started-runner-not-reaped.nix:
#   GATE_PATCHED_SRC, GATE_UNPATCHED_SRC, GATE_TEST_FILE, GATE_GO_TAGS
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

suite=TestJobStartedRunnerReapSuite
defect_tests="TestJobStartedRunnerListedOfflineIdleIsNotReaped"
control_tests="TestIdleOfflineRunnerPastTimeoutIsReaped TestNeverJoinedRunnerPastTimeoutIsReaped TestJobStartedRunnerGoneFromForgeIsRetired"

run_suite() { # <src> <dest> <log>
  cp -r "$1" "$2"
  chmod -R u+w "$2"
  cp "$GATE_TEST_FILE" "$2/runner/pool/job_started_runner_reap_test.go"
  (cd "$2" && go test -tags "$GATE_GO_TAGS" -count=1 -timeout 1800s -v \
    -run "$suite" ./runner/pool/ >"$3" 2>&1)
}

say "0. static: the patched tree guards the reaper on RunnerActive, the control does not"
grep -q 'not reaping runner: it started a job' "$GATE_PATCHED_SRC/runner/pool/pool.go" ||
  fail "patched tree does not carry the RunnerActive guard"
if grep -q 'not reaping runner: it started a job' "$GATE_UNPATCHED_SRC/runner/pool/pool.go"; then
  fail "negative control is not a control: the unpatched tree already carries the guard"
fi
echo "ok"

say "1. patched tree"
set +e
run_suite "$GATE_PATCHED_SRC" "$work/patched" "$work/patched.log"
patched_rc=$?
set -e
grep -E '^(=== RUN|    --- |--- |ok|FAIL)' "$work/patched.log" || true
[ "$patched_rc" -eq 0 ] || fail "patched tree: the suite did not pass (rc=$patched_rc)"
for t in $defect_tests $control_tests; do
  grep -q -- "--- PASS: $suite/$t" "$work/patched.log" ||
    fail "patched tree: $t did not run or did not pass"
done
echo "ok: 4/4 sub-tests passed on the patched tree"

say "2. negative control: the same tests against the unpatched tree"
set +e
run_suite "$GATE_UNPATCHED_SRC" "$work/unpatched" "$work/unpatched.log"
unpatched_rc=$?
set -e
grep -E '^(    --- |--- |ok|FAIL)' "$work/unpatched.log" || true
[ "$unpatched_rc" -ne 0 ] ||
  fail "NEGATIVE CONTROL DID NOT REPRODUCE THE DEFECT: the unpatched tree passed"
for t in $defect_tests; do
  grep -q -- "--- FAIL: $suite/$t" "$work/unpatched.log" ||
    fail "negative control: $t was expected to FAIL unpatched but did not"
done
for t in $control_tests; do
  grep -q -- "--- PASS: $suite/$t" "$work/unpatched.log" ||
    fail "negative control: $t should pass on BOTH trees"
done
# The defect's signature: the unpatched tree asked the forge to remove a
# runner that is running a job (only the forge's 422 stopped it).
grep -q 'Expected "RemoveEntityRunner" to not have been called' "$work/unpatched.log" ||
  fail "negative control failed, but not with the removal-attempt signature"
echo "ok: the unpatched tree tries to remove the runner mid-job; the controls hold on both trees"

say "GATE PASS: t_garm_job_started_runner_not_reaped"
