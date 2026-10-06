# Gate `t_garm_instance_lifecycle`: GARM must never forget an instance its
# provider may still hold, and one failing provider delete must not cancel its
# siblings or be retried every 5s. Runs checks/garm/instance_lifecycle_test.go
# against the shipped GARM tree (must pass) and against the same tree minus
# fix-instance-lifecycle-leaks.patch (the four defect tests must fail).
# See checks/t_garm_instance_lifecycle.sh.
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
          patchUnderTest = ../packages/garm/patches/fix-instance-lifecycle-leaks.patch;
          patchedSrc = pkgs.applyPatches {
            name = "garm-src-patched";
            inherit (garm) src;
            patches = garm.patches;
          };
          controlPatches = builtins.filter (p: p != patchUnderTest) garm.patches;
          unpatchedSrc =
            assert lib.assertMsg (builtins.length controlPatches == builtins.length garm.patches - 1)
              "garm-instance-lifecycle: fix-instance-lifecycle-leaks.patch is not in packages/garm/default.nix `patches`, so the negative control would be identical to the patched tree";
            pkgs.applyPatches {
              name = "garm-src-unpatched";
              inherit (garm) src;
              patches = controlPatches;
            };
        in
        {
          t_garm_instance_lifecycle =
            pkgs.runCommand "t_garm_instance_lifecycle"
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
                GATE_TEST_FILE = ./garm/instance_lifecycle_test.go;
                GATE_GO_TAGS = "testing osusergo netgo sqlite_omit_load_extension";
                meta.description = "GARM never forgets a provider instance; failing deletes neither cancel siblings nor storm (with negative control)";
              }
              ''
                set -o pipefail
                bash ${./t_garm_instance_lifecycle.sh} 2>&1 | tee gate.log
                mkdir -p "$out"
                cp gate.log "$out/result"
              '';
        }
      );
    };
}
