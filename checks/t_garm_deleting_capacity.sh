#!/usr/bin/env bash
# Gate `t_garm_deleting_capacity`: see checks/garm-deleting-capacity.nix and
# packages/garm/default.nix (fix-deleting-instances-hold-capacity.patch).
#
# Environment supplied by checks/garm-deleting-capacity.nix:
#   GATE_PATCHED_SRC    patched GARM source tree (read-only store path)
#   GATE_UNPATCHED_SRC  same tree minus fix-deleting-instances-hold-capacity.patch
#   GATE_TEST_FILE      checks/garm/deleting_capacity_test.go
#   GATE_GO_TAGS        build tags to compile with
set -euo pipefail

say() { printf '\n=== %s ===\n' "$*"; }
fail() {
  printf 'GATE FAIL: %s\n' "$*" >&2
  exit 1
}

work="$(mktemp -d)"
export GOCACHE="$work/gocache" GOPATH="$work/gopath" GOFLAGS=-mod=vendor
export GOTOOLCHAIN=local CGO_ENABLED=1 HOME="$work"

TEST=TestStuckDeletesDoNotConsumePoolCapacity

say "0. static: every MaxRunners gate uses the capacity accounting"
p="$GATE_PATCHED_SRC"
grep -q 'capacity.Occupied(poolInstances, pool.MaxRunners)' "$p/runner/pool/pool.go" ||
  fail "addRunnerToPool still counts deleting instances against MaxRunners"
grep -q 'capacity.Occupied(existingInstances, pool.MaxRunners)' "$p/runner/pool/pool.go" ||
  fail "ensureIdleRunnersForOnePool still counts deleting instances against MaxRunners"
grep -q 'capacity.OccupiedStatuses(statuses, pool.MaxRunners)' "$p/database/sql/instances.go" ||
  fail "the database's CreateInstance check still counts deleting instances"
grep -q 'return capacity.Occupied(w.runnerList(), w.scaleSet.MaxRunners)' "$p/workers/scaleset/scaleset.go" ||
  fail "the scale-set runnerCount still counts deleting runners"
grep -q 'delta := w.liveRunnerCount() - w.targetRunners()' "$p/workers/scaleset/scaleset.go" ||
  fail "scale-set scale-down no longer acts on live runners only"
if grep -q 'capacity' "$GATE_UNPATCHED_SRC/runner/pool/pool.go"; then
  fail "negative control is not a control: the unpatched tree already has the fix"
fi
echo "ok"

say "1. capacity accounting unit tests (patched tree)"
cp -r "$p" "$work/patched"
chmod -R u+w "$work/patched"
(cd "$work/patched" && go test -tags "$GATE_GO_TAGS" -count=1 ./internal/capacity/) ||
  fail "internal/capacity tests failed"

run_suite() { # <tree> <log>
  cp "$GATE_TEST_FILE" "$1/runner/pool/deleting_capacity_test.go"
  # The package comes BEFORE -testify.m: go test stops parsing its own flags
  # at the first one it does not know.
  (cd "$1" && go test -tags "$GATE_GO_TAGS" -count=1 -timeout 1200s -v \
    ./runner/pool/ -run TestPoolStressTestSuite -testify.m "$TEST" >"$2" 2>&1)
}

say "2. patched tree: stuck deletes do not consume pool capacity (real sqlite store)"
set +e
run_suite "$work/patched" "$work/patched.log"
rc=$?
set -e
grep -E '^(    --- |--- |ok|FAIL)' "$work/patched.log" || true
if [ "$rc" -ne 0 ]; then
  tail -40 "$work/patched.log"
  fail "patched tree: the test did not pass (rc=$rc)"
fi
grep -q -- "--- PASS: TestPoolStressTestSuite/$TEST" "$work/patched.log" ||
  fail "patched tree: $TEST did not run or did not pass"

say "3. negative control: the SAME test against the tree without the patch"
cp -r "$GATE_UNPATCHED_SRC" "$work/unpatched"
chmod -R u+w "$work/unpatched"
set +e
run_suite "$work/unpatched" "$work/unpatched.log"
rc=$?
set -e
grep -E '^(    --- |--- |ok|FAIL)' "$work/unpatched.log" || true
[ "$rc" -ne 0 ] || fail "NEGATIVE CONTROL PASSED: the assertion is vacuous"
grep -q -- "--- FAIL: TestPoolStressTestSuite/$TEST" "$work/unpatched.log" ||
  fail "negative control: $TEST was expected to FAIL unpatched but did not"
grep -q 'stuck deletes must not block min-idle replenishment' "$work/unpatched.log" ||
  fail "negative control failed, but not with the capacity-starvation signature"

say "GATE PASS: t_garm_deleting_capacity"
