top@{ ... }:
{
  # Gate `t_garm_job_started_runner_not_reaped` — GARM's timeout reaper must
  # not try to retire a runner that GARM itself recorded picking up a job
  # (central GARM, high-mem-server, 2026-11-25: GitHub listed two runners
  # mid-job as offline and not busy, the reaper asked to remove them, and
  # GitHub refused with 422).
  #
  # WHAT IS UNDER TEST
  #
  #   GARM's OWN basePoolManager.runnerCleanup() and
  #   cleanupOrphanedProviderRunners(), against GARM's OWN `database/sql`
  #   store on a real SQLite file. Mocks: forge client + provider only (no
  #   github.com or hypervisor in the sandbox); see the test file header.
  #
  # THE NEGATIVE CONTROL
  #
  #   The same test file runs against the tree we ship and against one that
  #   is identical except that `fix-reap-skips-job-started-runners.patch` is
  #   left out. The defect test must FAIL there, and the three controls (an
  #   idle timed-out runner and a never-joined runner are still reaped; a
  #   runner that started a job and that the forge no longer has is still
  #   retired) must PASS on BOTH trees.
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

          patchUnderTest = ../packages/garm/patches/fix-reap-skips-job-started-runners.patch;

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
              "garm-job-started-runner-not-reaped: fix-reap-skips-job-started-runners.patch is not in packages/garm/default.nix `patches`, so the negative control would be identical to the patched tree";
            pkgs.applyPatches {
              name = "garm-src-unpatched";
              inherit (garm) src;
              patches = controlPatches;
            };
        in
        {
          t_garm_job_started_runner_not_reaped =
            pkgs.runCommand "t_garm_job_started_runner_not_reaped"
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
                GATE_TEST_FILE = ./garm/job_started_runner_reap_test.go;

                # The tags packages/garm/default.nix builds the daemon with,
                # plus `testing`, which is what gates GARM's own test files.
                GATE_GO_TAGS = "testing osusergo netgo sqlite_omit_load_extension";

                meta.description = "GARM's timeout reaper never retires a runner that started a job (with negative control)";
              }
              ''
                set -o pipefail
                bash ${./t_garm_job_started_runner_not_reaped.sh} 2>&1 | tee gate.log
                mkdir -p "$out"
                cp gate.log "$out/result"
              '';
        }
      );
    };
}
