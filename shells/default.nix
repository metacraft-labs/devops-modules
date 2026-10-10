{ inputs, ... }:
{
  imports = [
    (import ../checks/pre-commit.nix {
      inherit inputs;
    }).flake.modules.flake.git-hooks
  ];

  perSystem =
    {
      pkgs,
      inputs',
      config,
      ...
    }:
    {
      devShells.default =
        let
          repl = pkgs.writeShellApplication {
            name = "repl";
            text = ''
              nix repl --file "$REPO_ROOT/repl.nix";
            '';
          };

          podman-as-docker = pkgs.writeShellScriptBin "docker" ''
            exec podman "$@"
          '';
        in
        pkgs.mkShell {
          packages =
            with pkgs;
            [
              inputs'.agenix.packages.agenix
              inputs'.nixos-anywhere.packages.nixos-anywhere
              # gcloud + the Workspace admin helpers (packages/default.nix); consumer
              # infra repos add the same bundle to their own dev shells.
              config.packages.workspace-admin-tools
              figlet
              just
              jq
              nix-eval-jobs
              nixos-rebuild
              nix-output-monitor
              openssl
              zlib
              pkg-config
              repl
              rage
              dub
              dub-to-nix
              ldc
              inputs'.nixpkgs-unstable.legacyPackages.act
              podman-as-docker

              # Terraform/OpenTofu tooling
              opentofu
              inputs'.terranix.packages.terranix
              cf-terraforming
              tflint
            ]
            ++ pkgs.lib.optionals (pkgs.stdenv.system == "x86_64-linux") [
              # nixpkgs' dmd 2.110.0 does not build against the gcc 15 that is
              # now the default stdenv compiler: phobos compiles zlib through
              # ImportC, and gcc 15's stddef.h uses `nullptr`, which DMD 2.110's
              # C importer does not know ("undefined identifier `nullptr`").
              # cache.nixos.org has no dmd 2.110.0, so this is broken upstream
              # rather than local. ldc and dub above come from nixpkgs on
              # purpose -- dlang.nix's are far older (ldc 1.30 vs 1.41) and
              # cannot parse argparse 2.x, which breaks `dub test`.
              inputs'.dlang-nix.packages.dmd
            ]
            ++ config.pre-commit.settings.enabledPackages
            ++ [ config.pre-commit.settings.package ];

          # The guarded, Reprobuild-aware installer every consumer uses; see
          # `mcl.gitHooks.installationScript` in checks/pre-commit.nix.
          shellHook = ''
            export REPO_ROOT="$PWD"
            export PATH="$REPO_ROOT/packages/mcl-devops/build:$PATH"
            figlet -t "Metacraft Nixos Modules"
          ''
          + config.mcl.gitHooks.installationScript;
        };
    };
}
