{ ... }:
{
  perSystem =
    { pkgs, lib, ... }:
    {
      # The flake-checks build job roots the flake's own source (and the locked
      # inputs already in the store) before its first per-output build, so a
      # GC between two builds in a batch cannot delete it. The test runs the
      # workflow's own steps with the real `nix` CLI against a throwaway local
      # store and collects it with the real GC, including a negative control.
      # Linux only: it needs a `local?root=` store inside the build sandbox.
      checks = lib.optionalAttrs pkgs.stdenv.isLinux {
        reusable-flake-checks-source-root =
          pkgs.runCommand "reusable-flake-checks-source-root"
            {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.coreutils
                pkgs.findutils
                pkgs.gawk
                pkgs.git
                pkgs.nix
                (pkgs.python3.withPackages (ps: [ ps.pyyaml ]))
              ];
            }
            ''
              BASH_BIN=${pkgs.bash}/bin/bash python3 ${../scripts/tests/test_flake_source_root.py} \
                ${../.github/workflows/reusable-flake-checks-ci-matrix.yml}
              touch "$out"
            '';
      };
    };
}
