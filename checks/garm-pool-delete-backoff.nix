# Gate `t_garm_pool_delete_backoff`: a pool instance whose provider delete
# keeps failing is retried on a doubling backoff that logs a warning per step
# and is not reported as a delete on every 5 s pass, and the orphan sweep
# releases each instance's lock when it is done with it (central GARM on
# high-mem-server, 2026-11-16..18: incus datasets pinned by locked mounts).
# Runs checks/garm/pool_delete_backoff_test.go against the shipped GARM tree
# (must pass) and against the same tree minus fix-pool-delete-backoff.patch
# (must fail). See checks/t_garm_pool_delete_backoff.sh.
{ ... }:
{
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
          patchUnderTest = ../packages/garm/patches/fix-pool-delete-backoff.patch;
          patchedSrc = pkgs.applyPatches {
            name = "garm-src-patched";
            inherit (garm) src;
            patches = garm.patches;
          };
          controlPatches = builtins.filter (p: p != patchUnderTest) garm.patches;
          unpatchedSrc =
            assert lib.assertMsg (builtins.length controlPatches == builtins.length garm.patches - 1)
              "garm-pool-delete-backoff: fix-pool-delete-backoff.patch is not in packages/garm/default.nix `patches`, so the negative control would be identical to the patched tree";
            pkgs.applyPatches {
              name = "garm-src-unpatched";
              inherit (garm) src;
              patches = controlPatches;
            };
        in
        {
          t_garm_pool_delete_backoff =
            pkgs.runCommand "t_garm_pool_delete_backoff"
              {
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.gnugrep
                  pkgs.go_1_26
                  pkgs.gcc
                ];
                GATE_PATCHED_SRC = patchedSrc;
                GATE_UNPATCHED_SRC = unpatchedSrc;
                GATE_TEST_FILE = ./garm/pool_delete_backoff_test.go;
                GATE_GO_TAGS = "testing osusergo netgo sqlite_omit_load_extension";
                meta.description = "A failing pool instance delete backs off quietly and warns, and the orphan sweep releases each lock (with negative control)";
              }
              ''
                set -o pipefail
                bash ${./t_garm_pool_delete_backoff.sh} 2>&1 | tee gate.log
                mkdir -p "$out"
                cp gate.log "$out/result"
              '';
        }
      );
    };
}
