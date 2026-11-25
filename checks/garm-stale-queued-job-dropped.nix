top@{ ... }:
{
  # Gate `t_garm_stale_queued_job_dropped` — the pool manager must stop
  # serving a queued job once it is older than GitHub's 24-hour queue limit
  # (central GARM, high-mem-server, 2026-11-25: 165 queued jobs from runs that
  # had long ended were retried on every pass).
  #
  # WHAT IS UNDER TEST
  #
  #   GARM's OWN consumeQueuedJobs(), through GARM's own pool stress suite
  #   against its `database/sql` store on a real SQLite file. See the test
  #   file header for the mocks and the one stand-in (the job's age).
  #
  # THE NEGATIVE CONTROL
  #
  #   The same test file runs against the tree we ship and against one that
  #   is identical except that `expire-stale-queued-jobs.patch` is left out.
  #   The defect test must FAIL there, and the control (a job queued for 23
  #   hours stays queued) must PASS on BOTH trees.
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

          patchUnderTest = ../packages/garm/patches/expire-stale-queued-jobs.patch;

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
              "garm-stale-queued-job-dropped: expire-stale-queued-jobs.patch is not in packages/garm/default.nix `patches`, so the negative control would be identical to the patched tree";
            pkgs.applyPatches {
              name = "garm-src-unpatched";
              inherit (garm) src;
              patches = controlPatches;
            };
        in
        {
          t_garm_stale_queued_job_dropped =
            pkgs.runCommand "t_garm_stale_queued_job_dropped"
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
                GATE_TEST_FILE = ./garm/stale_queued_job_test.go;

                # The tags packages/garm/default.nix builds the daemon with,
                # plus `testing`, which is what gates GARM's own test files.
                GATE_GO_TAGS = "testing osusergo netgo sqlite_omit_load_extension";

                meta.description = "GARM drops queued jobs older than GitHub's 24-hour queue limit (with negative control)";
              }
              ''
                set -o pipefail
                bash ${./t_garm_stale_queued_job_dropped.sh} 2>&1 | tee gate.log
                mkdir -p "$out"
                cp gate.log "$out/result"
              '';
        }
      );
    };
}
