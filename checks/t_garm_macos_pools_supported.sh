#!/usr/bin/env bash
# Gate `t_garm_macos_pools_supported` — milestone MA11 of
# `Runner-Fleet-M3-ARM-Wave.milestones.org` (reprobuild-specs).
#
# THE REGRESSION THIS HALF OF THE GATE EXISTS TO END. The fleet is migrating
# from scale sets to capability POOLS. Stock cloudbase/garm accepts
# `os_type=macos` on a scale set and refuses it on a pool:
#
#   runner/types.go   supportedOSType = { params.Linux: {}, params.Windows: {} }
#   runner/runner.go  appendTagsToCreatePoolParams() rejects anything else
#
# and `appendTagsToCreatePoolParams` is the ONLY caller of IsSupportedOSType in
# the entire tree, so the allow-list governs pool creation and nothing else.
# Live consequence, high-mem-server 2026-09-16: the central GARM's reconcile
# created `metacraft-labs-linux-arm64`, then died on the macOS pool with
#   CreateOrgPool … {"details":"error fetching pool params: invalid OS type macos"}
# and restart-looped past 65 attempts, so every pool declared behind it was
# never attempted either.
#
# WHAT THIS HALF PROVES (hermetic; no host, no network, no deploy):
#
#   (1) THE PATCH IS PRESENT AND APPLIES. `packages/garm/patches/
#       allow-macos-pools.patch` is in the package's `patches` list — asserted
#       in the Nix expression, which refuses to build the control otherwise —
#       and BOTH input derivations are real garm builds, so their existence is
#       proof that the patch applies and that the patched tree still compiles.
#       The patched tree's allow-list admits macos; the control's does not.
#
#   (2) THE POOL PATH ACCEPTS macOS — and still rejects everything it should.
#       The SAME Go test file ran against both trees. It drives the real
#       `Runner.appendTagsToCreatePoolParams()`, the function that produced the
#       live 400, not a re-derived predicate. On the control the two macOS
#       assertions MUST fail and the four invariants MUST pass; the latter is
#       what proves the control is failing for the right reason rather than
#       because the file did not build.
#
# The OTHER two layers MA11 asks for — the reconcile surviving one failing pool,
# and the manifest-verify preflight being bounded — are asserted by the INFRA
# half of this gate, `infra/checks/t_garm_macos_pools_supported.sh`, because
# that is where the concrete controller configuration lives. This script SKIPs
# them BY NAME rather than going quiet about them.
#
# Environment supplied by checks/garm-macos-pools-supported.nix:
#   GATE_PATCHED_DIR  dir with gate.log + types.go + provider-common-params.go
#                     from a build of the tree this repo ships
#   GATE_CONTROL_DIR  the same, from a build with ONLY the patch under test
#                     left out
set -euo pipefail

gate="t_garm_macos_pools_supported"
skips=0
skip_notes=()

say() { printf '\n=== %s ===\n' "$*"; }
fail() {
  printf 'GATE FAIL: %s\n' "$*" >&2
  exit 1
}
skip() {
  printf 'GATE SKIP: %s\n' "$*" >&2
  skip_notes+=("$*")
  skips=$((skips + 1))
}

macos_tests=(
  TestMacOSPoolOSTypeAccepted
  TestMacOSIsSupportedOSType
)
invariant_tests=(
  TestLinuxAndWindowsPoolsStillAccepted
  TestUnknownOSTypeStillRejected
  TestUnsupportedArchStillRejected
  TestUnknownProviderStillRejected
)

patched_log="$GATE_PATCHED_DIR/gate.log"
control_log="$GATE_CONTROL_DIR/gate.log"

# ---------------------------------------------------------------------------
# 1. THE PATCH APPLIED, AND THE TWO TREES DIFFER IN EXACTLY THE WAY ASSUMED.
#
# Asserted against the SOURCE that was actually compiled, so a future rebase
# that silently drops the patch is caught even if the behavioural results were
# somehow satisfied another way.
# ---------------------------------------------------------------------------
say "1. the allow-list differs between the two compiled trees"
grep -q 'params.MacOS:' "$GATE_PATCHED_DIR/types.go" ||
  fail "patched tree: runner/types.go's supportedOSType does not admit macOS — allow-macos-pools.patch did not take effect"
grep -qE '^[[:space:]]*MacOS[[:space:]]+OSType = "macos"' \
  "$GATE_PATCHED_DIR/provider-common-params.go" ||
  fail "patched tree: the vendored garm-provider-common has no MacOS OSType constant. allow-macos-pools.patch depends on allow-macos-runner-install-templates.patch providing it, and on that patch coming FIRST in packages/garm/default.nix's list."
echo "ok: patched tree admits macOS on the pool path"

if grep -q 'params.MacOS:' "$GATE_CONTROL_DIR/types.go"; then
  fail "negative control is not a control: the unpatched tree already admits macOS"
fi
grep -q 'params.Windows: {},' "$GATE_CONTROL_DIR/types.go" ||
  fail "negative control is not a control: the unpatched tree has no recognisable supportedOSType map"
echo "ok: the two trees differ in exactly the way the gate assumes"

# ---------------------------------------------------------------------------
# 2a. THE MECHANISM — patched tree, every sub-test must pass.
# ---------------------------------------------------------------------------
say "2a. patched tree: the real pool-param gate accepts macOS"
grep -E '^(--- |ok|FAIL)' "$patched_log" || true
for t in "${macos_tests[@]}" "${invariant_tests[@]}"; do
  grep -q -- "--- PASS: $t" "$patched_log" ||
    fail "patched tree: $t did not run or did not pass (see $patched_log)"
done
if grep -q -- '--- FAIL:' "$patched_log"; then
  fail "patched tree: at least one sub-test FAILED (see $patched_log)"
fi
echo "ok: $(( ${#macos_tests[@]} + ${#invariant_tests[@]} )) sub-tests passed on the patched tree"

# ---------------------------------------------------------------------------
# 2b. THE NEGATIVE CONTROL — the SAME file, the unpatched tree.
# ---------------------------------------------------------------------------
say "2b. negative control: the same assertions against the unpatched tree"
grep -E '^(--- |ok|FAIL)' "$control_log" || true

grep -q -- '--- FAIL:' "$control_log" ||
  fail "NEGATIVE CONTROL DID NOT REPRODUCE THE DEFECT: the unpatched tree passed everything. \
The assertions are vacuous — they would pass with or without the patch."

for t in "${macos_tests[@]}"; do
  grep -q -- "--- FAIL: $t" "$control_log" ||
    fail "negative control: $t was expected to FAIL unpatched but did not"
done
# The four invariants must pass on BOTH trees. That is what proves the control
# run is failing because the pool path refuses macOS, and not because the test
# file failed to build or the fixture params are invalid.
for t in "${invariant_tests[@]}"; do
  grep -q -- "--- PASS: $t" "$control_log" ||
    fail "negative control: $t should pass on BOTH trees — the control is broken, not controlling"
done
# The signature of the defect, in the upstream error's own words.
grep -q 'invalid OS type macos' "$control_log" ||
  fail "negative control failed, but not with the expected signature ('invalid OS type macos')"
echo "ok: unpatched tree refuses a macOS pool with the exact live error"

# ---------------------------------------------------------------------------
# 3+4. The layers this half cannot see. Named, never silent.
# ---------------------------------------------------------------------------
say "3+4. the layers asserted by the infra half"
skip "reconcile-survives-one-failing-pool: asserted by infra/checks/t_garm_macos_pools_supported.sh, which drives high-mem-server's REAL rendered garm-reconcile script against a stubbed garm-cli. It needs a concrete controller configuration, which this repo (a module library) does not have."
skip "manifest-verify-preflight-is-bounded: asserted by infra/checks/t_garm_macos_pools_supported.sh. The preflight unit is declared in infra/machines/server/high-mem-server/central-garm.nix, not here."

echo
if [ "$skips" -gt 0 ]; then
  echo "$gate: $skips SKIP(S), each named above:"
  for n in "${skip_notes[@]}"; do echo "  - $n"; done
fi
say "GATE PASS (nixos-modules half): $gate"
