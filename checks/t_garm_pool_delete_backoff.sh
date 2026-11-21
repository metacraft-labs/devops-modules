#!/usr/bin/env bash
# Gate `t_garm_pool_delete_backoff`: see checks/garm-pool-delete-backoff.nix
# and packages/garm/default.nix (fix-pool-delete-backoff.patch).
#
# Environment supplied by checks/garm-pool-delete-backoff.nix:
#   GATE_PATCHED_SRC    patched GARM source tree (read-only store path)
#   GATE_UNPATCHED_SRC  same tree minus fix-pool-delete-backoff.patch
#   GATE_TEST_FILE      checks/garm/pool_delete_backoff_test.go
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

TESTS=(
  TestPoolDeletePendingInBackoffLogsNoAttempt
  TestPoolDeleteFailureWarnsAndDoubles
  TestPoolSweepReleasesEachInstanceLock
)
RUN="^($(
  IFS='|'
  echo "${TESTS[*]}"
))\$"

say "0. static: the delete backoff doubles and its clock is injectable"
grep -q 'func NewInstanceDeleteBackoffWithClock' "$GATE_PATCHED_SRC/locking/local_backoff_locker.go" ||
  fail "the patched tree has no NewInstanceDeleteBackoffWithClock"
if grep -q 'NewInstanceDeleteBackoffWithClock' "$GATE_UNPATCHED_SRC/locking/local_backoff_locker.go"; then
  fail "negative control is not a control: the unpatched tree already has the fix"
fi
echo "ok"

run_test() { # <tree> <log>
  cp "$GATE_TEST_FILE" "$1/runner/pool/pool_delete_backoff_test.go"
  (cd "$1" && go test -tags "$GATE_GO_TAGS" -count=1 -race -timeout 10m -v \
    ./runner/pool/ -run "$RUN" >"$2" 2>&1)
}

say "1. patched tree: backoff schedule (locking) and the pool delete loop"
cp -r "$GATE_PATCHED_SRC" "$work/patched"
chmod -R u+w "$work/patched"
(cd "$work/patched" && go test -tags "$GATE_GO_TAGS" -count=1 -race -v \
  ./locking/ -run '^TestBackoffTestSuite$' >"$work/locking.log" 2>&1) || {
  tail -60 "$work/locking.log"
  fail "patched tree: locking tests failed"
}
grep -q -- '--- PASS: TestBackoffTestSuite/TestDoublingScheduleAndReset' "$work/locking.log" ||
  fail "patched tree: TestDoublingScheduleAndReset did not run or did not pass"
set +e
run_test "$work/patched" "$work/patched.log"
rc=$?
set -e
grep -E '^(    --- |--- |ok|FAIL)' "$work/patched.log" || true
if [ "$rc" -ne 0 ]; then
  grep -v '^time=' "$work/patched.log" | tail -60
  fail "patched tree: the tests did not pass (rc=$rc)"
fi
for t in "${TESTS[@]}"; do
  grep -q -- "--- PASS: $t" "$work/patched.log" || fail "patched tree: $t did not run or did not pass"
done

say "2. negative control: the SAME tests against the tree without the patch"
cp -r "$GATE_UNPATCHED_SRC" "$work/unpatched"
chmod -R u+w "$work/unpatched"
set +e
run_test "$work/unpatched" "$work/unpatched.log"
rc=$?
set -e
grep -E '^(    --- |--- |ok|FAIL)|Messages:' "$work/unpatched.log" || true
[ "$rc" -ne 0 ] || fail "NEGATIVE CONTROL PASSED: the assertions are vacuous"
for t in "${TESTS[@]}"; do
  grep -q -- "--- FAIL: $t" "$work/unpatched.log" ||
    fail "negative control: $t was expected to FAIL unpatched but did not"
done
grep -q 'logged "removing instance from pool" at info level' "$work/unpatched.log" ||
  fail "negative control failed, but not because a skipped pass logged a delete"
grep -q 'a failed delete must log exactly one backoff warning' "$work/unpatched.log" ||
  fail "negative control failed, but not because the backoff warning is missing"
grep -q 'kept earlier instances locked while it worked on later ones' "$work/unpatched.log" ||
  fail "negative control failed, but not because the sweep held earlier locks"

say "GATE PASS: t_garm_pool_delete_backoff"
