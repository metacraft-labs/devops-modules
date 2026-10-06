top@{ ... }:
{
  # H3 (metacraft-labs/infra, docs/Host-Stability-Recovery.milestones.org) —
  # gate `t_garm_stale_scaleset_job_reaped`.
  #
  # WHAT IS UNDER TEST
  #
  #   GARM's OWN stale-job reconciler, `basePoolManager.reconcileStaleJobs()`,
  #   running against GARM's OWN `database/sql` store on a real SQLite file.
  #   Nothing about the reaper is re-implemented and the job rows are created
  #   through `store.CreateOrUpdateJob()` — the same call the scale set
  #   listener's `recordOrUpdateJob()` makes. The only mocked boundary is the
  #   forge itself (`GetWorkflowRunByID` / `GetWorkflowJobByID`), because a
  #   hermetic build sandbox cannot reach github.com.
  #
  #   The milestone is explicit that "a test that only deletes the row by hand
  #   does NOT close this gate; the mechanism must work". So the reaper is
  #   invoked both directly and through the real `startLoopForFunction()` loop
  #   that runner startup wires it into, and the production five-minute
  #   schedule is asserted separately and statically against the source.
  #
  # THE NEGATIVE CONTROL
  #
  #   The same test file is run against two trees built from the SAME upstream
  #   source: the one this repo ships, and one identical except that
  #   `packages/garm/patches/fix-stale-scaleset-job-reaper.patch` is left out.
  #   The scale-set assertions must FAIL on the unpatched tree — and fail with
  #   the defect's signature, the forge never being consulted at all — while
  #   the two assertions that guard properties the patch must NOT change (the
  #   pre-existing workflow-job reap, and entity isolation) pass on BOTH, which
  #   is what proves the unpatched run is not simply broken for a build reason.
  #
  # NOT WALL-CLOCK
  #
  #   This gate is built on a host whose ZFS pool stalls for minutes at a time,
  #   so no elapsed-time figure here would be a property of the code. The Go
  #   tests assert on counts (rows before/after, forge calls made); the shell
  #   asserts a CPU-second ceiling, which a process parked in D state cannot
  #   trip.
  perSystem =
    {
      pkgs,
      lib,
      self',
      ...
    }:
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (
        let
          garm = self'.packages.garm;

          patchUnderTest = ../packages/garm/patches/fix-stale-scaleset-job-reaper.patch;

          # The tree we ship: upstream + every patch in packages/garm.
          patchedSrc = pkgs.applyPatches {
            name = "garm-src-patched";
            inherit (garm) src;
            patches = garm.patches;
          };

          # The control: the same tree with ONLY the patch under test removed.
          # If that list ever stops containing the patch, `builtins.filter`
          # silently yields the same tree and the control stops controlling —
          # so assert the removal actually removed something.
          controlPatches = builtins.filter (p: p != patchUnderTest) garm.patches;
          unpatchedSrc =
            assert lib.assertMsg (builtins.length controlPatches == builtins.length garm.patches - 1)
              "garm-stale-scaleset-job-reaped: fix-stale-scaleset-job-reaper.patch is not in packages/garm/default.nix `patches`, so the negative control would be identical to the patched tree";
            pkgs.applyPatches {
              name = "garm-src-unpatched";
              inherit (garm) src;
              patches = controlPatches;
            };
        in
        {
          t_garm_stale_scaleset_job_reaped =
            pkgs.runCommand "t_garm_stale_scaleset_job_reaped"
              {
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.gawk
                  pkgs.gnugrep
                  pkgs.go_1_26
                  pkgs.gcc
                ];

                GATE_PATCHED_SRC = patchedSrc;
                GATE_UNPATCHED_SRC = unpatchedSrc;
                GATE_TEST_FILE = ./garm/stale_scaleset_job_test.go;

                # The tags packages/garm/default.nix builds the daemon with,
                # plus `testing`, which is what gates GARM's own test files.
                GATE_GO_TAGS = "testing osusergo netgo sqlite_omit_load_extension";

                # Measured on a steady-state re-run (the compile is paid for by
                # the first run). Generous on purpose: this is a regression
                # guard against a reaper that starts doing bulk work per pass,
                # not a benchmark.
                GATE_CPU_CEILING = "120";

                meta.description = "H3 gate: GARM's own reconciler reaps a stale scale-set job (with negative control)";
              }
              ''
                set -o pipefail
                bash ${./t_garm_stale_scaleset_job_reaped.sh} 2>&1 | tee gate.log
                mkdir -p "$out"
                cp gate.log "$out/result"
              '';
        }
      );
    };
}
