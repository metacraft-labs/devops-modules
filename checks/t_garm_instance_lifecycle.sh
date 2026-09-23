#!/usr/bin/env bash
# Gate `t_garm_instance_lifecycle` — see checks/garm-instance-lifecycle.nix and
# the header of checks/garm/instance_lifecycle_test.go for the defects.
#
# Environment supplied by checks/garm-instance-lifecycle.nix:
#   GATE_PATCHED_SRC    patched GARM source tree (read-only store path)
#   GATE_UNPATCHED_SRC  same tree minus fix-instance-lifecycle-leaks.patch
#   GATE_TEST_FILE      checks/garm/instance_lifecycle_test.go
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
  TestDroppedInstanceIsDeletedViaProvider
  TestFailedDeleteDoesNotCancelSiblings
  TestFailedCleanupDeleteBacksOff
  TestCreateRetryIsBackedOff
)

say "0. static: the upstream defects are gone from the patched tree"
pool="$GATE_PATCHED_SRC/runner/pool/pool.go"
grep -q 'Marking instance pending_delete so the provider can reclaim it' "$pool" ||
  fail "cleanupOrphanedGithubRunners no longer routes provider-absent instances to pending_delete"
if grep -q 'deleteInstanceFromProvider(errCtx, instance)' "$pool"; then
  fail "retry cleanup deletes still share a cancellable errgroup context"
fi
grep -q 'func createRetryBackoff' "$pool" || fail "create retries are not backed off"
grep -q 'InstanceAbsentFromProviderCount.WithLabelValues' "$pool" &&
  grep -q '"absent_from_provider_total"' "$GATE_PATCHED_SRC/metrics/instance.go" &&
  grep -q 'InstanceAbsentFromProviderCount,' "$GATE_PATCHED_SRC/metrics/metrics.go" ||
  fail "garm_runner_absent_from_provider_total is not defined, registered and incremented (alerting depends on it)"
grep -q 'PoolConsilitationInterval = 5 \* time.Second' "$GATE_PATCHED_SRC/runner/common/pool.go" ||
  fail "consolidation interval changed; re-derive the backoff rationale"
grep -q 'deleteInstanceFromProvider(errCtx, instance)' "$GATE_UNPATCHED_SRC/runner/pool/pool.go" ||
  fail "negative control is not a control: the unpatched tree lacks the errgroup defect"
echo "ok"

run_suite() { # <src> <dest> <log>
  cp -r "$1" "$2"
  chmod -R u+w "$2"
  cp "$GATE_TEST_FILE" "$2/runner/pool/instance_lifecycle_test.go"
  (cd "$2" && go test -tags "$GATE_GO_TAGS" -count=1 -timeout 1200s -v \
    -run TestInstanceLifecycleSuite ./runner/pool/ >"$3" 2>&1)
}

say "1. patched tree: every property holds"
set +e
run_suite "$GATE_PATCHED_SRC" "$work/patched" "$work/patched.log"
rc=$?
set -e
grep -E '^(    --- |--- |ok|FAIL)' "$work/patched.log" || true
[ "$rc" -eq 0 ] || fail "patched tree: the suite did not pass (rc=$rc)"
for t in "${TESTS[@]}"; do
  grep -q -- "--- PASS: TestInstanceLifecycleSuite/$t" "$work/patched.log" ||
    fail "patched tree: $t did not run or did not pass"
done

say "2. negative control: the SAME tests against the unpatched tree"
set +e
run_suite "$GATE_UNPATCHED_SRC" "$work/unpatched" "$work/unpatched.log"
rc=$?
set -e
grep -E '^(    --- |--- |ok|FAIL)' "$work/unpatched.log" || true
[ "$rc" -ne 0 ] || fail "NEGATIVE CONTROL PASSED: the assertions are vacuous"
for t in "${TESTS[@]}"; do
  grep -q -- "--- FAIL: TestInstanceLifecycleSuite/$t" "$work/unpatched.log" ||
    fail "negative control: $t was expected to FAIL unpatched but did not"
done
grep -q 'the DB record was deleted outright' "$work/unpatched.log" ||
  fail "negative control failed, but not with the leak signature"

say "GATE PASS: t_garm_instance_lifecycle"
