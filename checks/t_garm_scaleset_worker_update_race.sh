#!/usr/bin/env bash
# Gate `t_garm_scaleset_worker_update_race`: see
# checks/garm-scaleset-worker-update-race.nix and packages/garm/default.nix
# (fix-scaleset-worker-start-race.patch).
#
# Environment supplied by checks/garm-scaleset-worker-update-race.nix:
#   GATE_PATCHED_SRC    patched GARM source tree (read-only store path)
#   GATE_UNPATCHED_SRC  same tree minus fix-scaleset-worker-start-race.patch
#   GATE_TEST_FILE      checks/garm/scaleset_worker_update_race_test.go
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

TEST=TestWorkerStartSeesUpdateCommittedBeforeSubscribe

say "0. static: the worker re-reads its scale set after subscribing"
grep -q 'w.refreshScaleSetLocked()' "$GATE_PATCHED_SRC/workers/scaleset/scaleset.go" ||
  fail "Worker.Start() no longer re-reads the scale set after RegisterConsumer"
if grep -q 'refreshScaleSetLocked' "$GATE_UNPATCHED_SRC/workers/scaleset/scaleset.go"; then
  fail "negative control is not a control: the unpatched tree already has the fix"
fi
echo "ok"

run_test() { # <tree> <log>
  cp "$GATE_TEST_FILE" "$1/workers/scaleset/scaleset_worker_update_race_test.go"
  (cd "$1" && go test -tags "$GATE_GO_TAGS" -count=1 -race -timeout 10m -v \
    ./workers/scaleset/ -run "^$TEST\$" >"$2" 2>&1)
}

say "1. patched tree: an update committed before the worker subscribed is not lost"
cp -r "$GATE_PATCHED_SRC" "$work/patched"
chmod -R u+w "$work/patched"
set +e
run_test "$work/patched" "$work/patched.log"
rc=$?
set -e
grep -E '^(    --- |--- |ok|FAIL)' "$work/patched.log" || true
if [ "$rc" -ne 0 ]; then
  tail -60 "$work/patched.log"
  fail "patched tree: the test did not pass (rc=$rc)"
fi
grep -q -- "--- PASS: $TEST" "$work/patched.log" ||
  fail "patched tree: $TEST did not run or did not pass"

say "2. negative control: the SAME test against the tree without the patch"
cp -r "$GATE_UNPATCHED_SRC" "$work/unpatched"
chmod -R u+w "$work/unpatched"
set +e
run_test "$work/unpatched" "$work/unpatched.log"
rc=$?
set -e
grep -E '^(    --- |--- |ok|FAIL)|Messages:' "$work/unpatched.log" || true
[ "$rc" -ne 0 ] || fail "NEGATIVE CONTROL PASSED: the assertion is vacuous"
grep -q -- "--- FAIL: $TEST" "$work/unpatched.log" ||
  fail "negative control: $TEST was expected to FAIL unpatched but did not"
grep -q 'worker kept a stale copy of the scale set' "$work/unpatched.log" ||
  fail "negative control failed, but not with the stale-copy signature"
grep -q 'the worker never opened a message session' "$work/unpatched.log" ||
  fail "negative control failed, but the listener still opened a session"

say "GATE PASS: t_garm_scaleset_worker_update_race"
