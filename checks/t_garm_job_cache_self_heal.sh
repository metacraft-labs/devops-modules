#!/usr/bin/env bash
# Gate `t_garm_job_cache_self_heal` — stranded queued pool jobs.
#
# Incident (central GARM, high-mem-server, 2026-09-28): a queued job for the
# full agent-harbor Windows pool was retried every ~30 s until 11:57:56Z and
# then never again, although the DB row stayed queued and unlocked and both
# slots freed at 12:23Z. The pool manager's in-memory job cache said "locked
# by us"; the 10-minute retry's UnlockJob() is a silent no-op on an unlocked
# row, so nothing ever corrected the cache.
#
# This gate drives GARM's OWN consumeQueuedJobs() against GARM's OWN store on
# a real SQLite file, twice:
#
#   PATCHED   — the tree this repo ships. All four sub-tests must PASS.
#   UNPATCHED — identical except that patches/fix-job-cache-stale-lock.patch
#               is left out. The two defect sub-tests must FAIL; the two
#               controls must still PASS (so the control is not simply broken).
#
# Environment supplied by checks/garm-job-cache-self-heal.nix:
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

suite=TestJobCacheSelfHealSuite
defect_tests="TestStaleCachedLockIsHealed TestGhostJobIsDropped"
control_tests="TestFreshQueuedJobIsServed TestGenuineRecentLockIsRespected"

run_suite() { # <src> <dest> <log>
  cp -r "$1" "$2"
  chmod -R u+w "$2"
  cp "$GATE_TEST_FILE" "$2/runner/pool/job_cache_self_heal_test.go"
  (cd "$2" && go test -tags "$GATE_GO_TAGS" -count=1 -timeout 1800s -v \
    -run "$suite" ./runner/pool/ >"$3" 2>&1)
}

say "0. static: the patched tree writes through and heals, the control does not"
grep -q 'func (r \*basePoolManager) refreshCachedJob' "$GATE_PATCHED_SRC/runner/pool/util.go" ||
  fail "patched tree has no refreshCachedJob"
if grep -q 'refreshCachedJob' "$GATE_UNPATCHED_SRC/runner/pool/util.go"; then
  fail "negative control is not a control: the unpatched tree already has refreshCachedJob"
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
# The defect's signature: the stranded job never got a runner.
grep -q 'the stranded job must get a runner' "$work/unpatched.log" ||
  fail "negative control failed, but not with the stranded-job signature"
echo "ok: the unpatched tree strands the job; the controls hold on both trees"

say "GATE PASS: t_garm_job_cache_self_heal"
