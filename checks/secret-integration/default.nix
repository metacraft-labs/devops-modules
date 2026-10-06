# Integration test for `mcl-devops secret` — verifies edit, re-encrypt, and
# re-encrypt-all against a minimal nixosConfiguration that imports the
# mcl secrets module.
#
# Run:  nix run .#checks.x86_64-linux.secret-integration
{
  lib,
  inputs,
  self,
  ...
}:
let
  # Build a minimal nixosConfiguration importing the mcl secrets modules.
  # `secretsModule` supplies the per-machine `mcl.secrets` definition so each
  # test machine can vary its services (including a deliberately broken one).
  mkMachine =
    secretsModule:
    inputs.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        self.modules.nixos.mcl-host-info
        self.modules.nixos.mcl-secrets
        secretsModule
        {
          _module.args.dirs.modules = self + "/modules";
          mcl.host-info = {
            type = "server";
            isDebugVM = false;
            configPath = "./checks/test-machine";
            sshKey = builtins.readFile ./test-keys/.ssh/id_ed25519.pub;
          };
          mcl.secrets.extraKeys = [ (builtins.readFile ./test-keys/.ssh/extra_id_ed25519.pub) ];
          age.identityPaths = [ ./test-keys/.ssh/id_ed25519 ];
          boot.loader.grub.enable = false;
          fileSystems."/".device = "none";
          fileSystems."/".fsType = "tmpfs";
          system.stateVersion = "25.11";
        }
      ];
    };
in
{
  # ---------------------------------------------------------------------------
  # 1.  Define nixosConfigurations to test the mcl.secrets and `mcl-devops secret`
  #     command. Besides the primary machine, we add:
  #       - `broken-machine`: its `mcl.secrets.services` throws on evaluation,
  #         exercising the per-machine `tryEval` error path in `list` (the
  #         whole-fleet eval must not abort just because one machine fails).
  #       - `test-secret-machine-vm`: a valid machine whose name ends in
  #         `-vm`, exercising the VM filtering in `list` (hidden by default,
  #         shown with `--include-vms`).
  # ---------------------------------------------------------------------------
  flake.nixosConfigurations.test-secret-machine = mkMachine {
    mcl.secrets.services.test-svc = {
      encryptedSecretDir = self + "/checks/test-machine/secrets";
      secrets.password = { };
      secrets.api-key = { };
    };
    mcl.secrets.services.other-svc = {
      encryptedSecretDir = self + "/checks/test-machine/secrets";
      secrets.token = { };
    };
  };

  # A machine-shaped fixture whose secrets fail to evaluate. `mcl-devops secret list`
  # forces `attrNames services.<name>.secrets`, so a throwing `secrets` attrset
  # triggers the `builtins.tryEval` guard and yields an `__error__` marker
  # instead of aborting the whole-fleet evaluation.
  #
  # This is intentionally not a full nixosSystem. Routing the throw through the
  # real module would pull it into `age.secrets` (which maps over
  # `services.<name>.secrets`) and therefore into `system.build.toplevel`, so
  # the machine could not be evaluated at all — the command-specific test must
  # remain the only path that forces the secret error.
  #
  # Because it stands in for a nixosSystem, the fixture has to offer the same
  # surface that consumers of a `nixosConfigurations` entry read. That is not
  # just `config`: tooling that walks the flake's outputs (`nix flake show`,
  # `nix flake check`) reads `pkgs.stdenv.system` to decide which system a
  # machine belongs to. A fixture without `pkgs` makes those commands fail on
  # the flake as a whole, so `pkgs` is part of the fixture's contract and is
  # also what supplies its placeholder toplevel below.
  flake.nixosConfigurations.broken-machine =
    let
      pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
    in
    {
      inherit pkgs;

      config = {
        system.build.toplevel = pkgs.runCommand "nixos-system-broken-machine-secret-fixture" { } ''
          mkdir -p "$out"
        '';

        mcl.secrets.services.broken-svc.secrets = throw "intentional eval failure for broken-machine";
      };
    };

  # A valid machine whose name ends in `-vm`; `list` hides it unless
  # `--include-vms` is passed.
  flake.nixosConfigurations.test-secret-machine-vm = mkMachine {
    mcl.secrets.services.vm-svc = {
      encryptedSecretDir = self + "/checks/test-machine/secrets";
      secrets.vm-secret = { };
    };
  };

  # ---------------------------------------------------------------------------
  # 2.  A runnable test script that exercises `mcl-devops secret` subcommands.
  # ---------------------------------------------------------------------------
  perSystem =
    {
      self',
      pkgs,
      ...
    }:
    let
      inherit (pkgs.stdenv.hostPlatform) isLinux;
    in
    {
      checks = lib.optionalAttrs isLinux {
        secret-integration = pkgs.writeShellApplication {
          name = "test-mcl-secret";
          runtimeInputs = [
            self'.packages.mcl-devops
            pkgs.age
            pkgs.openssh
            pkgs.nix
            pkgs.jq
          ];
          text = "bash ${
            pkgs.replaceVars ./test-mcl-secret.sh {
              TEST_KEYS_DIR = "${./test-keys}";
            }
          }";
        };
      };
    };
}
