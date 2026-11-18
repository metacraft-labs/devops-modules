# Gate `t_garm_scaleset_worker_update_race`: a scale-set worker must not lose
# an update committed between its initial load and its watcher subscription
# (m3, 2026-11-17: the restore of `enabled: true` landed 0.17 s before scale
# set 15's worker subscribed, and the worker stayed disabled for 28 h). Runs
# checks/garm/scaleset_worker_update_race_test.go against the shipped GARM
# tree (must pass) and against the same tree minus
# fix-scaleset-worker-start-race.patch (must fail). See
# checks/t_garm_scaleset_worker_update_race.sh.
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
          patchUnderTest = ../packages/garm/patches/fix-scaleset-worker-start-race.patch;
          patchedSrc = pkgs.applyPatches {
            name = "garm-src-patched";
            inherit (garm) src;
            patches = garm.patches;
          };
          controlPatches = builtins.filter (p: p != patchUnderTest) garm.patches;
          unpatchedSrc =
            assert lib.assertMsg (builtins.length controlPatches == builtins.length garm.patches - 1)
              "garm-scaleset-worker-update-race: fix-scaleset-worker-start-race.patch is not in packages/garm/default.nix `patches`, so the negative control would be identical to the patched tree";
            pkgs.applyPatches {
              name = "garm-src-unpatched";
              inherit (garm) src;
              patches = controlPatches;
            };
        in
        {
          t_garm_scaleset_worker_update_race =
            pkgs.runCommand "t_garm_scaleset_worker_update_race"
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
                GATE_TEST_FILE = ./garm/scaleset_worker_update_race_test.go;
                GATE_GO_TAGS = "testing osusergo netgo sqlite_omit_load_extension";
                meta.description = "A scale-set worker does not lose an update committed before it subscribed (with negative control)";
              }
              ''
                set -o pipefail
                bash ${./t_garm_scaleset_worker_update_race.sh} 2>&1 | tee gate.log
                mkdir -p "$out"
                cp gate.log "$out/result"
              '';
        }
      );
    };
}
