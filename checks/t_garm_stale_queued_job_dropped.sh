#!/usr/bin/env bash
# Gate `t_garm_stale_queued_job_dropped` — the pool manager must stop serving
# a queued job once it is older than GitHub's 24-hour queue limit.
#
# Observation (central GARM, high-mem-server, 2026-11-25): 165 queued pool
# jobs from runs that had ended up to eight weeks earlier were still retried
# on every pass, taking about half of all runner-create attempts. Upstream
# never deletes a queued job.
#
# This gate drives GARM's OWN consumeQueuedJobs() through GARM's own pool
# stress suite (real SQLite store), twice:
#
#   PATCHED   — the tree this repo ships. Both sub-tests must PASS.
#   UNPATCHED — identical except that patches/expire-stale-queued-jobs.patch
#               is left out. The defect sub-test must FAIL; the control must
#               PASS.
#
# Environment supplied by checks/garm-stale-queued-job-dropped.nix:
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

suite=TestPoolStressTestSuite
defect_tests="TestStaleQueuedJobIsDropped"
control_tests="TestQueuedJobUnderTheLimitIsKept"

run_suite() { # <src> <dest> <log>
  cp -r "$1" "$2"
  chmod -R u+w "$2"
  cp "$GATE_TEST_FILE" "$2/runner/pool/stale_queued_job_test.go"
  (cd "$2" && go test -tags "$GATE_GO_TAGS" -count=1 -timeout 1800s -v \
    -run "$suite/(TestStaleQueuedJobIsDropped|TestQueuedJobUnderTheLimitIsKept)" ./runner/pool/ >"$3" 2>&1)
}

say "0. static: the patched tree expires stale queued jobs, the control does not"
grep -q 'maxQueuedJobAge' "$GATE_PATCHED_SRC/runner/pool/pool.go" ||
  fail "patched tree does not carry the queued-job age limit"
if grep -q 'maxQueuedJobAge' "$GATE_UNPATCHED_SRC/runner/pool/pool.go"; then
  fail "negative control is not a control: the unpatched tree already carries the age limit"
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
echo "ok: 2/2 sub-tests passed on the patched tree"

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
# The defect's signature: the unpatched tree kept the 25-hour-old job.
grep -q 'a job queued for 25 hours is still in the store' "$work/unpatched.log" ||
  fail "negative control failed, but not with the stale-job signature"
echo "ok: the unpatched tree keeps the stale job; the control holds on both trees"

say "GATE PASS: t_garm_stale_queued_job_dropped"
