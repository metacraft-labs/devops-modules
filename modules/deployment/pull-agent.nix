{ withSystem, ... }:
{
  flake.modules.nixos.deployment-pull-agent =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    let
      cfg = config.services.mcl-deploy-agent;
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

      allowedSigners = pkgs.writeText "mcl-deployment-agent-allowed-signers" (
        concatMapStringsSep "\n" (key: "${cfg.manifestPrincipal} ${key}") cfg.manifestPublicKeys + "\n"
      );

      args = [
        "--target ${escapeShellArg cfg.targetName}"
        "--allowed-signers ${escapeShellArg allowedSigners}"
        "--state-dir ${escapeShellArg cfg.stateDir}"
        "--event-log ${escapeShellArg cfg.eventLog}"
        "--max-attempts ${toString cfg.maxAttempts}"
        "--fetch-timeout-seconds ${toString cfg.fetchTimeoutSeconds}"
      ]
      ++ map (source: "--manifest ${escapeShellArg source}") cfg.manifestSources
      ++ map (dir: "--manifest-dir ${escapeShellArg dir}") cfg.manifestDirectories
      ++ lib.optionals cfg.dryRun [ "--dry-run" ]
      ++ lib.optionals (cfg.restoreCommand != "") [
        "--restore-command ${escapeShellArg cfg.restoreCommand}"
      ]
      ++ lib.optionals (cfg.switchCommand != "") [
        "--switch-command ${escapeShellArg cfg.switchCommand}"
      ]
      ++ lib.optionals (cfg.rollbackCommand != "") [
        "--rollback-command ${escapeShellArg cfg.rollbackCommand}"
      ]
      ++ lib.optionals (cfg.generationCommand != "") [
        "--generation-command ${escapeShellArg cfg.generationCommand}"
      ];

      agentCommand = concatMapStringsSep " " (x: x) ([ "${getExe cfg.package} deploy-agent" ] ++ args);
      prepareLocksDirectory = pkgs.writeTextFile {
        name = "mcl-deploy-agent-prepare-locks";
        executable = true;
        text = ''
          #!${pkgs.python3}/bin/python3
          import os
          import stat
          import sys


          def refuse(message):
              print(
                  "mcl-deploy-agent lock preparation refused: " + message,
                  file=sys.stderr,
              )
              raise SystemExit(1)


          if len(sys.argv) != 2:
              refuse("expected exactly one deployment state directory argument")

          state_path = sys.argv[1]
          directory_flags = (
              os.O_RDONLY
              | os.O_DIRECTORY
              | os.O_NOFOLLOW
              | os.O_CLOEXEC
          )

          try:
              state_fd = os.open(state_path, directory_flags)
          except OSError as error:
              refuse("cannot securely open state directory %s: %s" % (state_path, error))

          try:
              state_metadata = os.fstat(state_fd)
              if not stat.S_ISDIR(state_metadata.st_mode):
                  refuse("state path is not a directory: " + state_path)
              if state_metadata.st_uid != 0 or state_metadata.st_gid != 0:
                  refuse(
                      "state directory must be owned by root:root: " + state_path
                  )
              if stat.S_IMODE(state_metadata.st_mode) & 0o022:
                  refuse(
                      "state directory must not be writable by group or other: "
                      + state_path
                  )

              try:
                  locks_fd = os.open("locks", directory_flags, dir_fd=state_fd)
              except FileNotFoundError:
                  try:
                      os.mkdir("locks", 0o700, dir_fd=state_fd)
                  except FileExistsError:
                      # A root-only race is outside the threat model, but still
                      # bind and validate the winner instead of replacing it.
                      pass
                  except OSError as error:
                      refuse(
                          "cannot create locks directory in %s: %s"
                          % (state_path, error)
                      )
                  try:
                      locks_fd = os.open("locks", directory_flags, dir_fd=state_fd)
                  except OSError as error:
                      refuse(
                          "new locks path is not a safe directory in %s: %s"
                          % (state_path, error)
                      )
              except OSError as error:
                  try:
                      leaf = os.stat(
                          "locks",
                          dir_fd=state_fd,
                          follow_symlinks=False,
                      )
                      leaf_kind = (
                          "symlink"
                          if stat.S_ISLNK(leaf.st_mode)
                          else "non-directory"
                      )
                  except OSError:
                      leaf_kind = "unsafe or inaccessible object"
                  refuse(
                      "locks path in %s is a %s: %s"
                      % (state_path, leaf_kind, error)
                  )

              try:
                  metadata = os.fstat(locks_fd)
                  mode = stat.S_IMODE(metadata.st_mode)
                  if not stat.S_ISDIR(metadata.st_mode):
                      refuse("locks path is not a directory in " + state_path)
                  if metadata.st_uid != 0 or metadata.st_gid != 0:
                      refuse(
                          "locks directory must be owned by root:root in "
                          + state_path
                      )
                  if mode not in (0o700, 0o750, 0o755):
                      refuse(
                          "locks directory has unsupported mode %04o in %s"
                          % (mode, state_path)
                      )

                  # Only two known-safe legacy modes are migrated. fchmod acts
                  # on the already-bound descriptor and cannot follow a leaf
                  # symlink. The protected root-owned state directory prevents
                  # an unprivileged user from replacing its `locks` entry.
                  if mode != 0o700:
                      os.fchmod(locks_fd, 0o700)

                  verified = os.fstat(locks_fd)
                  named = os.stat(
                      "locks",
                      dir_fd=state_fd,
                      follow_symlinks=False,
                  )
                  if (
                      not stat.S_ISDIR(verified.st_mode)
                      or verified.st_uid != 0
                      or verified.st_gid != 0
                      or stat.S_IMODE(verified.st_mode) != 0o700
                      or named.st_dev != verified.st_dev
                      or named.st_ino != verified.st_ino
                  ):
                      refuse(
                          "locks directory failed post-migration verification in "
                          + state_path
                      )
              finally:
                  os.close(locks_fd)
          finally:
              os.close(state_fd)
        '';
      };
    in
    {
      options.services.mcl-deploy-agent = {
        enable = mkEnableOption "target-side pull agent for signed mcl deployment manifests";

        package = mkOption {
          type = types.package;
          default = defaultPackage;
          description = "Package providing the mcl-devops binary.";
        };

        targetName = mkOption {
          type = types.str;
          default = config.networking.hostName;
          description = "Expected manifest target name. The agent rejects every other target.";
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

        manifestSources = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Exact signed manifest files or HTTP(S) URLs polled by the agent.";
        };

        manifestDirectories = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Directories containing signed manifests for this target only.";
        };

        maxAttempts = mkOption {
          type = types.ints.positive;
          default = 3;
          description = "Maximum apply attempts for one deployment before marking it non-retryable.";
        };

        fetchTimeoutSeconds = mkOption {
          type = types.ints.positive;
          default = 30;
          description = "Timeout used when fetching HTTP(S) manifest sources.";
        };

        interval = mkOption {
          type = types.str;
          default = "15min";
          description = "systemd OnUnitActiveSec interval for polling desired state.";
        };

        jitter = mkOption {
          type = types.str;
          default = "5min";
          description = "systemd RandomizedDelaySec for polling.";
        };

        lockFile = mkOption {
          type = types.str;
          default = "/run/lock/mcl-deploy-agent-${cfg.targetName}.lock";
          description = "flock lock file that prevents concurrent apply attempts on this target.";
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
            message = "services.mcl-deploy-agent.manifestPublicKeys must not be empty.";
          }
          {
            assertion = cfg.manifestSources != [ ] || cfg.manifestDirectories != [ ];
            message = "services.mcl-deploy-agent needs at least one manifest source or directory.";
          }
        ];

        environment.systemPackages = [ cfg.package ];

        systemd.tmpfiles.rules = [
          "d ${cfg.stateDir} 0750 root root -"
          "d /var/log/mcl/deployments 0755 root root -"
        ]
        ++ map (dir: "d ${dir} 0750 root root -") cfg.manifestDirectories;

        systemd.services.mcl-deploy-agent = {
          description = "Pull and apply signed mcl desired-state manifests for ${cfg.targetName}";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          # Hardening: this service runs switch-to-configuration, and the closure it
          # activates contains a new version of this very unit (its mcl-devops store path
          # changes on every publish). Keep restartIfChanged false so a change to
          # this unit can't make switch-to-configuration restart it mid-switch; the
          # new definition takes effect on the next timer activation instead.
          # NOTE: this is defensive, not the fix for the historical deploy wedge.
          # That wedge was switch-to-configuration-ng blocking forever on a lost
          # systemd JobRemoved D-Bus signal on the classic dbus-daemon, fixed in the
          # consumer (infra) via services.dbus.implementation = "broker" plus a
          # TimeoutStartSec bound on this service.
          #
          # FU1 (DEPLOY-AGENT-SELFHEAL): restartIfChanged=false alone does NOT make
          # a switch that (re)starts this unit safe. When switch-to-configuration
          # runs from inside this unit's own cgroup and issues
          # `systemctl start/restart mcl-deploy-agent.service`, systemd terminates
          # the running invocation to service that job -- which kills the switch
          # process mid-activation, so its own restart job never completes and the
          # deploy wedges (verified on gpu-server-001/002). The fix lives in
          # `mcl-devops deploy-agent`/`deploy-apply`: switch-to-configuration is executed in
          # a detached `systemd-run` transient unit (its OWN cgroup), so systemd can
          # freely (re)start this unit without tearing the switch down, while the
          # agent still `--wait`s for and reports the switch exit code. Verified:
          # a detached switch that `systemctl restart`s the launching oneshot lets
          # the restart complete and the switch survive.
          restartIfChanged = false;
          serviceConfig = {
            Type = "oneshot";
            ExecStartPre = [
              "${prepareLocksDirectory} ${escapeShellArg cfg.stateDir}"
            ];
            ExecStart = "${pkgs.util-linux}/bin/flock -n ${escapeShellArg cfg.lockFile} ${agentCommand}";
            CacheDirectory = "mcl-deploy-agent";
            Environment = [
              "HOME=/var/cache/mcl-deploy-agent"
              "XDG_CACHE_HOME=/var/cache/mcl-deploy-agent"
            ];
            NoNewPrivileges = true;
            # The agent runs switch-to-configuration, whose activation scripts
            # legitimately update /root, /home, and /run/user.
            ProtectHome = false;
            PrivateTmp = true;
          };
        };

        systemd.timers.mcl-deploy-agent = {
          description = "Poll signed mcl desired-state manifests for ${cfg.targetName}";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnActiveSec = cfg.interval;
            OnUnitActiveSec = cfg.interval;
            RandomizedDelaySec = cfg.jitter;
            Persistent = true;
          };
        };
      };
    };
}
