{ withSystem, ... }:
{
  flake.modules.nixos.deployment-reconciler-timer =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    let
      cfg = config.services.mcl-deployment-reconciler;
      defaultPackage = withSystem pkgs.stdenv.hostPlatform.system (
        { config, ... }: config.packages.mcl-devops
      );
      inherit (lib)
        concatMapStringsSep
        escapeShellArg
        getExe
        mapAttrsToList
        mkEnableOption
        mkIf
        mkOption
        types
        ;

      args = [
        "--state-dir ${escapeShellArg cfg.stateDir}"
        "--event-log ${escapeShellArg cfg.eventLog}"
        "--ssh-user ${escapeShellArg cfg.sshUser}"
      ]
      ++ map (target: "--target ${escapeShellArg target}") cfg.targets
      ++ mapAttrsToList (
        target: host: "--target-host ${escapeShellArg "${target}=${host}"}"
      ) cfg.targetHosts
      ++ map (option: "--ssh-option ${escapeShellArg option}") cfg.sshOptions
      ++ lib.optionals (cfg.identityFile != "") [ "--identity-file ${escapeShellArg cfg.identityFile}" ]
      ++ lib.optionals cfg.dryRun [ "--dry-run" ];

      reconcileCommand = concatMapStringsSep " " (x: x) (
        [ "${getExe cfg.package} deploy-reconcile" ] ++ args
      );
    in
    {
      options.services.mcl-deployment-reconciler = {
        enable = mkEnableOption "systemd timer for mcl desired-state reconciliation retries";

        package = mkOption {
          type = types.package;
          default = defaultPackage;
          description = "Package providing the mcl-devops binary.";
        };

        stateDir = mkOption {
          type = types.str;
          default = "/var/lib/mcl/deployments";
          description = "Durable reconciler state directory.";
        };

        eventLog = mkOption {
          type = types.str;
          default = "/var/log/mcl/deployments/reconciler.jsonl";
          description = "Deployment event JSONL file written by retry runs.";
        };

        interval = mkOption {
          type = types.str;
          default = "15min";
          description = "systemd OnUnitActiveSec interval for retry runs.";
        };

        jitter = mkOption {
          type = types.str;
          default = "5min";
          description = "systemd RandomizedDelaySec for retry runs.";
        };

        lockFile = mkOption {
          type = types.str;
          default = "/run/lock/mcl-deployment-reconciler.lock";
          description = "flock lock file that prevents concurrent retry runs.";
        };

        targets = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Optional target selector for retry runs.";
        };

        targetHosts = mkOption {
          type = types.attrsOf types.str;
          default = { };
          description = "Target-to-SSH-host mapping for retry runs.";
        };

        sshUser = mkOption {
          type = types.str;
          default = "deploy";
          description = "SSH user used by the reconciler.";
        };

        sshOptions = mkOption {
          type = types.listOf types.str;
          default = [
            "BatchMode=yes"
            "ConnectTimeout=15"
          ];
          description = "Extra ssh -o options passed to mcl-devops deploy-reconcile.";
        };

        identityFile = mkOption {
          type = types.str;
          default = "";
          description = "Optional SSH identity file.";
        };

        dryRun = mkOption {
          type = types.bool;
          default = false;
          description = "Run retry reconciliation in dry-run mode.";
        };
      };

      config = mkIf cfg.enable {
        systemd.tmpfiles.rules = [
          "d ${cfg.stateDir} 0750 root root -"
          "d /var/log/mcl/deployments 0755 root root -"
        ];

        systemd.services.mcl-deployment-reconciler = {
          description = "Reconcile pending mcl desired-state deployments";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          # Hardening, same rationale as mcl-deploy-agent: this runs
          # switch-to-configuration and the activated closure contains a new version
          # of this unit, so keep restartIfChanged false to avoid restarting it
          # mid-switch. Defensive only -- the historical deploy wedge was a lost
          # dbus JobRemoved signal blocking switch-to-configuration-ng, fixed in the
          # consumer via dbus-broker plus a TimeoutStartSec bound, not here.
          restartIfChanged = false;
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.util-linux}/bin/flock -n ${escapeShellArg cfg.lockFile} ${reconcileCommand}";
            NoNewPrivileges = true;
            ProtectHome = true;
            PrivateTmp = true;
          };
        };

        systemd.timers.mcl-deployment-reconciler = {
          description = "Retry pending mcl desired-state deployments";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnUnitActiveSec = cfg.interval;
            OnBootSec = cfg.interval;
            RandomizedDelaySec = cfg.jitter;
            Persistent = true;
          };
        };
      };
    };
}
