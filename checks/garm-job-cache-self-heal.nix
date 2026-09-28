top@{ ... }:
{
  # Gate `t_garm_job_cache_self_heal` — stranded queued pool jobs
  # (central GARM, high-mem-server, 2026-09-28; F2 in reprobuild-specs
  # Sovereign-CI-Fleet-And-GOSTI-Substrate.milestones.org).
  #
  # WHAT IS UNDER TEST
  #
  #   GARM's OWN basePoolManager.consumeQueuedJobs() against GARM's OWN
  #   `database/sql` store on a real SQLite file. The manager's in-memory job
  #   cache is set up to DISAGREE with the store, the way a lost or reordered
  #   watcher notification leaves it: store queued + unlocked, cache "locked
  #   by us" for more than 10 minutes. The patched tree must serve the job;
  #   stock GARM skips it on every pass. Mocks: provider + GitHub client only
  #   (no hypervisor or github.com in the sandbox); see the test file header.
  #
  # THE NEGATIVE CONTROL
  #
  #   The same test file runs against the tree we ship and against one that
  #   is identical except that `fix-job-cache-stale-lock.patch` is left out.
  #   The two defect tests must FAIL there, and the two controls (an ordinary
  #   job is served; a genuine recent lock is respected, i.e. no duplicate
  #   runners) must PASS on BOTH trees.
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

          patchUnderTest = ../packages/garm/patches/fix-job-cache-stale-lock.patch;

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
              "garm-job-cache-self-heal: fix-job-cache-stale-lock.patch is not in packages/garm/default.nix `patches`, so the negative control would be identical to the patched tree";
            pkgs.applyPatches {
              name = "garm-src-unpatched";
              inherit (garm) src;
              patches = controlPatches;
            };
        in
        {
          t_garm_job_cache_self_heal =
            pkgs.runCommand "t_garm_job_cache_self_heal"
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
                GATE_TEST_FILE = ./garm/job_cache_self_heal_test.go;

                # The tags packages/garm/default.nix builds the daemon with,
                # plus `testing`, which is what gates GARM's own test files.
                GATE_GO_TAGS = "testing osusergo netgo sqlite_omit_load_extension";

                meta.description = "GARM's own consumeQueuedJobs() serves a queued job whose cached lock went stale (with negative control)";
              }
              ''
                set -o pipefail
                bash ${./t_garm_job_cache_self_heal.sh} 2>&1 | tee gate.log
                mkdir -p "$out"
                cp gate.log "$out/result"
              '';
        }
      );
    };
}
