#!/usr/bin/env bash
# Gate `t_garm_busy_runner_not_reaped` — GARM must never retire a runner the
# forge reports busy.
#
# Observation (central GARM, high-mem-server, 2026-09-27..29): 17 runners
# that GitHub reported offline-but-busy were handed to DeleteRunner by
# reapTimedOutRunners (timed out from UpdatedAt, which is not refreshed while
# a job runs). Only GitHub's 422 saved them, and every refusal aborted the
# reap pass and skipped the entity's orphan sweep. cleanupOrphanedProviderRunners
# destroys an active instance missing from a single runner listing without
# asking the forge at all.
#
# This gate drives GARM's OWN runnerCleanup() and
# cleanupOrphanedProviderRunners() against GARM's OWN store on a real SQLite
# file, twice:
#
#   PATCHED   — the tree this repo ships. All five sub-tests must PASS.
#   UNPATCHED — identical except that patches/fix-busy-runner-reap.patch is
#               left out. The three defect sub-tests must FAIL; the two
#               controls must still PASS (so the control is not simply broken).
#
# Environment supplied by checks/garm-busy-runner-not-reaped.nix:
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

suite=TestBusyRunnerReapSuite
defect_tests="TestBusyRunnerPastBootstrapTimeoutIsNotReaped TestRefusedReapDoesNotSkipOrphanSweep TestActiveRunnerMissingFromOneListingIsNotDestroyed"
control_tests="TestIdleOfflineRunnerPastTimeoutIsReaped TestActiveRunnerGoneFromForgeIsRetired"

run_suite() { # <src> <dest> <log>
  cp -r "$1" "$2"
  chmod -R u+w "$2"
  cp "$GATE_TEST_FILE" "$2/runner/pool/busy_runner_reap_test.go"
  (cd "$2" && go test -tags "$GATE_GO_TAGS" -count=1 -timeout 1800s -v \
    -run "$suite" ./runner/pool/ >"$3" 2>&1)
}

say "0. static: the patched tree reads the forge's busy flag, the control does not"
grep -q 'Busy:   val.GetBusy()' "$GATE_PATCHED_SRC/runner/pool/util.go" ||
  fail "patched tree does not carry the REST listing's busy flag"
grep -q 'Busy:   runner.Busy' "$GATE_PATCHED_SRC/runner/pool/util.go" ||
  fail "patched tree does not carry the scale set listing's busy flag"
if grep -q 'GetBusy()' "$GATE_UNPATCHED_SRC/runner/pool/util.go"; then
  fail "negative control is not a control: the unpatched tree already reads the busy flag"
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
echo "ok: 5/5 sub-tests passed on the patched tree"

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
# The defect's signature: the unpatched tree asked the forge to remove a busy
# runner (only the forge's 422 stopped it).
grep -q 'Expected "RemoveEntityRunner" to not have been called' "$work/unpatched.log" ||
  fail "negative control failed, but not with the busy-runner-removal signature"
echo "ok: the unpatched tree tries to remove the busy runner; the controls hold on both trees"

say "GATE PASS: t_garm_busy_runner_not_reaped"
