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
              dmd
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
