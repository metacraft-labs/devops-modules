{ ... }:
{
  perSystem =
    { pkgs, lib, ... }:
    let
      # The darwin runners' `shell: bash` is /bin/bash, GNU bash 3.2.57. The
      # first version of the root step used `mapfile` and failed there with
      # exit 127, while this check (run under a current bash) passed. Build
      # the same release so the step is executed by the shell that runs it.
      # The flags only let 2007 C build with a current GCC.
      bash32 = pkgs.stdenv.mkDerivation {
        pname = "bash";
        version = "3.2.57";
        src = pkgs.fetchurl {
          url = "mirror://gnu/bash/bash-3.2.57.tar.gz";
          hash = "sha256-P6na+F6/NQaPCQzlEoPd7rPHXrW8cLGkp8sFhov+BqQ=";
        };
        nativeBuildInputs = [ pkgs.bison ];
        hardeningDisable = [ "format" ];
        env.NIX_CFLAGS_COMPILE = lib.concatStringsSep " " [
          "-std=gnu89"
          "-Wno-error"
          "-Wno-implicit-function-declaration"
          "-Wno-implicit-int"
          "-Wno-int-conversion"
          "-Wno-incompatible-pointer-types"
        ];
        configureFlags = [
          "--without-bash-malloc"
          "--disable-nls"
        ];
        enableParallelBuilding = false;
      };

      # (shell, its major version, Nix). Nix 2.35 stopped copying the flake
      # source in `nix flake metadata`, which broke the first version of the
      # step on the Linux runners while this check, on an older Nix, passed.
      combinations = [
        {
          bash = "${bash32}/bin/bash";
          major = "3";
          nix = pkgs.nix;
        }
        {
          bash = "${bash32}/bin/bash";
          major = "3";
          nix = pkgs.nixVersions.latest;
        }
        {
          bash = "${pkgs.bash}/bin/bash";
          major = lib.versions.major pkgs.bash.version;
          nix = pkgs.nixVersions.latest;
        }
      ];
    in
    {
      # The flake-checks build job roots the flake's own source (and the locked
      # inputs already in the store) before its first per-output build, so a
      # GC between two builds in a batch cannot delete it. The test runs the
      # workflow's own steps as a runner does, with the real `nix` CLI against
      # a throwaway local store, collects it with the real GC, and includes
      # negative controls for the GC, the shell and the bash-3.2 lint.
      # Linux only: it needs a `local?root=` store inside the build sandbox.
      checks = lib.optionalAttrs pkgs.stdenv.isLinux {
        reusable-flake-checks-source-root =
          pkgs.runCommand "reusable-flake-checks-source-root"
            {
              nativeBuildInputs = [
                pkgs.coreutils
                pkgs.findutils
                pkgs.gawk
                pkgs.git
                pkgs.gnugrep
                (pkgs.python3.withPackages (ps: [ ps.pyyaml ]))
              ];
            }
            ''
              ${lib.concatMapStrings (c: ''
                echo "== bash ${c.major} (${c.bash}), nix ${c.nix.version}"
                PATH="${c.nix}/bin:$PATH" BASH_BIN="${c.bash}" EXPECT_BASH_MAJOR="${c.major}" \
                  python3 ${../scripts/tests/test_flake_source_root.py} \
                  ${../.github/workflows/reusable-flake-checks-ci-matrix.yml}
              '') combinations}
              touch "$out"
            '';
      };
    };
}
