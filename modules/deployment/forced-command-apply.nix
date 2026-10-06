{ withSystem, ... }:
{
  flake.modules.nixos.deployment-forced-command-apply =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    let
      cfg = config.services.mcl-deployment-ssh-apply;
      defaultPackage = withSystem pkgs.stdenv.hostPlatform.system (
        { config, ... }: config.packages.mcl-devops
      );
      inherit (lib)
        concatMapStringsSep
        escapeShellArg
        getExe
        mkEnableOption
        mkIf
        mkOption
        types
        ;

      allowedSigners = pkgs.writeText "mcl-deployment-allowed-signers" (
        concatMapStringsSep "\n" (key: "${cfg.manifestPrincipal} ${key}") cfg.manifestPublicKeys + "\n"
      );

      rootApply = pkgs.writeShellScript "mcl-deployment-root-apply" ''
        set -euo pipefail
        exec ${getExe cfg.package} deploy-apply \
          --manifest - \
          --target ${escapeShellArg cfg.targetName} \
          --allowed-signers ${escapeShellArg allowedSigners} \
          --state-dir ${escapeShellArg cfg.stateDir} \
          --event-log ${escapeShellArg cfg.eventLog} \
          --reject-ssh-original-command${lib.optionalString cfg.dryRun " \\\n          --dry-run"}${
            lib.optionalString (
              cfg.restoreCommand != ""
            ) " \\\n          --restore-command ${escapeShellArg cfg.restoreCommand}"
          }${
            lib.optionalString (
              cfg.switchCommand != ""
            ) " \\\n          --switch-command ${escapeShellArg cfg.switchCommand}"
          }${
            lib.optionalString (
              cfg.rollbackCommand != ""
            ) " \\\n          --rollback-command ${escapeShellArg cfg.rollbackCommand}"
          }${
            lib.optionalString (
              cfg.generationCommand != ""
            ) " \\\n          --generation-command ${escapeShellArg cfg.generationCommand}"
          }
      '';

      forcedCommand = pkgs.writeShellScript "mcl-deployment-forced-command" ''
        set -euo pipefail
        if [ -n "''${SSH_ORIGINAL_COMMAND:-}" ]; then
          echo "mcl deployment key accepts signed manifests on stdin only" >&2
          exit 126
        fi
        exec /run/wrappers/bin/sudo -n ${escapeShellArg rootApply}
      '';

      forcedKey =
        key:
        "command=\"${forcedCommand}\",restrict,no-agent-forwarding,no-X11-forwarding,no-port-forwarding,no-pty ${key}";
    in
    {
      options.services.mcl-deployment-ssh-apply = {
        enable = mkEnableOption "hardened SSH apply wrapper for signed mcl deployment manifests";

        package = mkOption {
          type = types.package;
          default = defaultPackage;
          description = "Package providing the mcl-devops binary.";
        };

        user = mkOption {
          type = types.str;
          default = "deploy";
          description = "Restricted SSH user used for deployment apply.";
        };

        group = mkOption {
          type = types.str;
          default = "deploy";
          description = "Primary group for the restricted deploy user.";
        };

        targetName = mkOption {
          type = types.str;
          default = config.networking.hostName;
          description = "Expected manifest target name.";
        };

        stateDir = mkOption {
          type = types.str;
          default = "/var/lib/mcl/deployments";
          description = "Target-local durable deployment state directory.";
        };

        eventLog = mkOption {
          type = types.str;
          default = "/var/log/mcl/deployments/${cfg.targetName}.jsonl";
          description = "Target-side deployment event JSONL log path.";
        };

        manifestPrincipal = mkOption {
          type = types.str;
          default = "mcl-deployment";
          description = "OpenSSH allowed-signers principal for deployment manifest signatures.";
        };

        manifestPublicKeys = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "OpenSSH public keys trusted to sign deployment manifests.";
        };

        authorizedKeys = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "SSH public keys allowed to invoke the forced apply command.";
        };

        dryRun = mkOption {
          type = types.bool;
          default = false;
          description = "Verify manifests and write state/events without restore or switch.";
        };

        restoreCommand = mkOption {
          type = types.str;
          default = "";
          description = "Optional root command override for closure restore tests. Empty uses the production Nix restore path.";
        };

        switchCommand = mkOption {
          type = types.str;
          default = "";
          description = "Optional root command override for switch tests. Empty uses the desired system switch-to-configuration.";
        };

        rollbackCommand = mkOption {
          type = types.str;
          default = "";
          description = "Optional root command override for rollback tests. Empty uses the previous generation switch-to-configuration.";
        };

        generationCommand = mkOption {
          type = types.str;
          default = "";
          description = "Optional root command override that prints the current generation. Empty uses /run/current-system.";
        };
      };

      config = mkIf cfg.enable {
        assertions = [
          {
            assertion = cfg.manifestPublicKeys != [ ];
            message = "services.mcl-deployment-ssh-apply.manifestPublicKeys must not be empty.";
          }
          {
            assertion = cfg.authorizedKeys != [ ];
            message = "services.mcl-deployment-ssh-apply.authorizedKeys must not be empty.";
          }
        ];

        users.groups.${cfg.group} = { };
        users.users.${cfg.user} = {
          isSystemUser = true;
          group = cfg.group;
          home = "/var/lib/${cfg.user}";
          createHome = true;
          shell = pkgs.bashInteractive;
          openssh.authorizedKeys.keys = map forcedKey cfg.authorizedKeys;
        };

        environment.systemPackages = [ cfg.package ];

        systemd.tmpfiles.rules = [
          "d ${cfg.stateDir} 0750 root root -"
          "d /var/log/mcl/deployments 0755 root root -"
        ];

        security.sudo.extraRules = [
          {
            users = [ cfg.user ];
            commands = [
              {
                command = "${rootApply}";
                options = [ "NOPASSWD" ];
              }
            ];
          }
        ];
      };
    };
}
