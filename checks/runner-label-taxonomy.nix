{ ... }:
{
  # Runner-Fleet-Capability-Pools-And-Remote-Driving RC1 gate:
  # t_runner_label_taxonomy.
  #
  # Proves the company-agnostic manifest→label DERIVATION + `advertised ⊆
  # derived` LINTER (../modules/runner-label-taxonomy) — WITHOUT the infra repo.
  # It consumes `packages.runner-label-tool` (the CLI over derive.py) and,
  # against RA6 manifest FIXTURES (../modules/runner-label-taxonomy/tests):
  #
  #   1. DERIVATION: `derive` maps a known signed /v1/manifest envelope (hms:
  #      linux/x86-64-v3/gpu/nested/docker/rr-hw-counters/incus+libvirt) to the
  #      EXACT expected label set, and a bare arm64 macOS/tart manifest (m3) to
  #      its set — asserting the v3⊇v2 arch-level ladder, the podman=false →
  #      no-label rule, and the available-only hypervisor rule.
  #   2. LINTER PASS: a valid subset (governed labels ⊆ derived, plus policy
  #      labels dev-env-ready/org:*/ephemeral passing through) exits 0.
  #   3. LINTER FAIL: a host advertising labels its manifest does NOT prove
  #      (x86-64-v4 over a v3 host, hyperv it can't drive, podman it lacks)
  #      exits non-zero — a real veto, not a warning.
  #   4. FAIL-CLOSED: an unsupported manifestVersion yields NO labels (exit 2).
  #
  # This is the same tool RB2/RC2 run at JIT-registration time and infra CI runs
  # to lint advertised sets, so a derivation that drifts from the linter — or a
  # linter weakened to pass an over-advertised host — cannot land here.
  perSystem =
    { config, pkgs, ... }:
    let
      tool = "${config.packages.runner-label-tool}/bin/runner-label-tool";
      t = ../modules/runner-label-taxonomy/tests;
    in
    {
      checks.t_runner_label_taxonomy =
        pkgs.runCommand "t_runner_label_taxonomy"
          {
            nativeBuildInputs = [ pkgs.jq ];
          }
          ''
            set -euo pipefail
            fail() { echo "[t_runner_label_taxonomy][FAIL] $1" >&2; exit 1; }

            # ---- 1. DERIVATION maps each fixture to its EXACT expected set ----
            echo "[t_runner_label_taxonomy] derive: hms envelope"
            ${tool} derive --json -m ${t}/manifest-hms.json > hms.actual.json \
              || fail "derive errored on the hms manifest"
            jq -S . hms.actual.json > hms.actual.sorted
            jq -S . ${t}/expected-hms.json > hms.expected.sorted
            diff -u hms.expected.sorted hms.actual.sorted \
              || fail "hms derived label set != expected"

            echo "[t_runner_label_taxonomy] derive: m3 bare manifest (arm64/tart)"
            ${tool} derive --json -m ${t}/manifest-m3.json > m3.actual.json \
              || fail "derive errored on the m3 manifest"
            jq -S . m3.actual.json > m3.actual.sorted
            jq -S . ${t}/expected-m3.json > m3.expected.sorted
            diff -u m3.expected.sorted m3.actual.sorted \
              || fail "m3 derived label set != expected"

            # Spot-check the load-bearing mapping rules on the hms set.
            grep -q '"x86-64-v2"' hms.actual.json || fail "v3 host must also derive x86-64-v2 (arch-level ladder)"
            grep -q '"x86-64-v3"' hms.actual.json || fail "v3 host must derive x86-64-v3"
            if grep -q '"x86-64-v4"' hms.actual.json; then fail "v3 host must NOT derive x86-64-v4"; fi
            if grep -q '"podman"'   hms.actual.json; then fail "podman=false must NOT derive the podman label"; fi
            grep -q '"self-hosted"' hms.actual.json || fail "every serve-host runner must derive self-hosted"

            # ---- 2. LINTER PASSES a valid subset (policy labels pass through) ----
            echo "[t_runner_label_taxonomy] lint: valid subset PASSES"
            ${tool} lint -m ${t}/manifest-hms.json --advertised-file ${t}/advertised-hms-valid.json \
              || fail "linter rejected a valid subset (advertised ⊆ derived) + policy labels"

            # ---- 3. LINTER FAILS an over-advertised host ----------------------
            echo "[t_runner_label_taxonomy] lint: over-advertised host FAILS"
            if ${tool} lint -m ${t}/manifest-hms.json --advertised-file ${t}/advertised-hms-invalid.json; then
              fail "linter accepted a host advertising labels its manifest does not prove"
            fi
            # And it must name the specific offending labels, not fail generically.
            ${tool} lint -m ${t}/manifest-hms.json --advertised-file ${t}/advertised-hms-invalid.json 2>lint.err || true
            for bad in x86-64-v4 hyperv podman; do
              grep -q "$bad" lint.err || fail "linter did not report the offending label '$bad'"
            done
            # A single unproven label is enough to fail (defense against a lenient join).
            if ${tool} lint -m ${t}/manifest-hms.json --advertised gpu,tart; then
              fail "linter accepted 'tart' which the hms manifest does not prove"
            fi

            # ---- 4. FAIL-CLOSED on an unsupported manifest version ------------
            echo "[t_runner_label_taxonomy] derive: unsupported manifestVersion fails closed"
            jq '.identity.manifest.manifestVersion = "999"' ${t}/manifest-hms.json > bad-version.json
            if ${tool} derive -m bad-version.json; then
              fail "derive emitted labels for an unsupported manifestVersion (must fail closed)"
            fi

            echo "[t_runner_label_taxonomy][PASS] derivation exact; linter vetoes over-advertised, passes valid subset, fails closed on version skew"
            touch $out
          '';
    };
}
