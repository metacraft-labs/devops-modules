# Gate `t_garm_deleting_capacity`: a GARM instance stuck on the deletion lane
# (pending_delete/deleting, e.g. an incus `zfs destroy` that stays "dataset is
# busy") must not consume its pool's MaxRunners, and the exemption must stay
# bounded at MaxRunners. Runs checks/garm/deleting_capacity_test.go against the
# shipped GARM tree (must pass) and against the same tree minus
# fix-deleting-instances-hold-capacity.patch (must fail). See
# checks/t_garm_deleting_capacity.sh.
top@{ ... }:
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
          patchUnderTest = ../packages/garm/patches/fix-deleting-instances-hold-capacity.patch;
          patchedSrc = pkgs.applyPatches {
            name = "garm-src-patched";
            inherit (garm) src;
            patches = garm.patches;
          };
          controlPatches = builtins.filter (p: p != patchUnderTest) garm.patches;
          unpatchedSrc =
            assert lib.assertMsg (builtins.length controlPatches == builtins.length garm.patches - 1)
              "garm-deleting-capacity: fix-deleting-instances-hold-capacity.patch is not in packages/garm/default.nix `patches`, so the negative control would be identical to the patched tree";
            pkgs.applyPatches {
              name = "garm-src-unpatched";
              inherit (garm) src;
              patches = controlPatches;
            };
        in
        {
          t_garm_deleting_capacity =
            pkgs.runCommand "t_garm_deleting_capacity"
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
                GATE_TEST_FILE = ./garm/deleting_capacity_test.go;
                GATE_GO_TAGS = "testing osusergo netgo sqlite_omit_load_extension";
                meta.description = "Instances stuck deleting do not consume a pool's MaxRunners, bounded at 2x (with negative control)";
              }
              ''
                set -o pipefail
                bash ${./t_garm_deleting_capacity.sh} 2>&1 | tee gate.log
                mkdir -p "$out"
                cp gate.log "$out/result"
              '';
        }
      );
    };
}
