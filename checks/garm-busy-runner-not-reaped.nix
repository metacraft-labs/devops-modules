top@{ ... }:
{
  # Gate `t_garm_busy_runner_not_reaped` — GARM must never retire a runner
  # the forge reports busy (central GARM, high-mem-server, 2026-09-27..29; F13
  # in reprobuild-specs Sovereign-CI-Fleet-And-GOSTI-Substrate.milestones.org).
  #
  # WHAT IS UNDER TEST
  #
  #   GARM's OWN basePoolManager.runnerCleanup() (list the forge's runners,
  #   reap timed-out runners, sweep orphans) and
  #   cleanupOrphanedProviderRunners(), against GARM's OWN `database/sql`
  #   store on a real SQLite file. The forge reports a runner offline but
  #   BUSY past the bootstrap timeout; the patched tree must not ask the
  #   forge to remove it, must not let one refused removal skip the orphan
  #   sweep, and must not destroy an active instance on the strength of one
  #   runner listing. Mocks: forge client + provider only (no github.com or
  #   hypervisor in the sandbox); see the test file header.
  #
  # THE NEGATIVE CONTROL
  #
  #   The same test file runs against the tree we ship and against one that
  #   is identical except that `fix-busy-runner-reap.patch` is left out. The
  #   three defect tests must FAIL there, and the two controls (an idle
  #   timed-out runner is still reaped; an active runner the forge no longer
  #   has is still retired) must PASS on BOTH trees.
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

          patchUnderTest = ../packages/garm/patches/fix-busy-runner-reap.patch;

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
              "garm-busy-runner-not-reaped: fix-busy-runner-reap.patch is not in packages/garm/default.nix `patches`, so the negative control would be identical to the patched tree";
            pkgs.applyPatches {
              name = "garm-src-unpatched";
              inherit (garm) src;
              patches = controlPatches;
            };
        in
        {
          t_garm_busy_runner_not_reaped =
            pkgs.runCommand "t_garm_busy_runner_not_reaped"
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
                GATE_TEST_FILE = ./garm/busy_runner_reap_test.go;

                # The tags packages/garm/default.nix builds the daemon with,
                # plus `testing`, which is what gates GARM's own test files.
                GATE_GO_TAGS = "testing osusergo netgo sqlite_omit_load_extension";

                meta.description = "GARM's own runner cleanup never retires a runner the forge reports busy (with negative control)";
              }
              ''
                set -o pipefail
                bash ${./t_garm_busy_runner_not_reaped.sh} 2>&1 | tee gate.log
                mkdir -p "$out"
                cp gate.log "$out/result"
              '';
        }
      );
    };
}
