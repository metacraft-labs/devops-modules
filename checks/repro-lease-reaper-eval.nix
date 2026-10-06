top@{ inputs, ... }:
{
  # Ephemeral-State-Leases L4 (§4.1) gate: t_repro_lease_reaper_eval.
  #
  # Pure-EVAL proof (no VM boot, no deploy) that the `mcl-reprobuild` module's
  # L4 systemd wiring evaluates and renders the expected units:
  #   * the NixOS class, with `enableSystemLeaseReaper = true`, produces a
  #     `repro-lease-reaper.service` whose ExecStart is
  #     `repro daemon serve --foreground --system … --state-root <dir>/state`
  #     — the system-scope wall-clock reaper;
  #   * the home-manager class, with `enableUserDaemon = true`, produces a
  #     `repro-daemon` systemd.user service running `repro daemon serve
  #     --foreground` — the user-scope lease registry + reaper.
  #
  # The check derivation is a trivial `runCommand`; the eval itself
  # (instantiating both module classes + reading their unit ExecStart) is the
  # gate. A wiring regression (dropped `--system`, missing `--state-root`,
  # renamed unit) makes an asserted substring absent and the eval/build FAIL.
  perSystem =
    {
      pkgs,
      lib,
      inputs',
      ...
    }:
    let
      flake = top.config.flake;
      reproPkg = inputs'.reprobuild.packages.reprobuild;

      # ---- Evaluate the NixOS class (system reaper) via lib.nixosSystem (the
      # same idiom the netbird-with-agenix eval gate uses). ----
      nixosEval = lib.nixosSystem {
        system = pkgs.stdenv.hostPlatform.system;
        modules = [
          flake.modules.nixos.mcl-reprobuild
          (
            { ... }:
            {
              boot.loader.grub.enable = false;
              fileSystems."/" = {
                device = "none";
                fsType = "tmpfs";
              };
              system.stateVersion = "24.05";
              programs.reprobuild = {
                enable = true;
                package = reproPkg;
                enableSystemLeaseReaper = true;
              };
            }
          )
        ];
      };
      # ExecStart may normalize to a string or a single-element list depending
      # on the (NixOS vs home-manager) unit type; coerce both to a flat string
      # so the assertions below are transport-agnostic.
      toExecStr = v: if builtins.isList v then lib.concatStringsSep " " (map toString v) else toString v;

      systemReaperExec = toExecStr nixosEval.config.systemd.services.repro-lease-reaper.serviceConfig.ExecStart;

      # ---- Evaluate the home-manager class (user daemon). home-manager is a
      # flake input; its `lib.homeManagerConfiguration` renders a standalone HM
      # config we can read the systemd.user unit off. Guarded so the
      # system-reaper proof still stands if the input is unavailable. ----
      hmLib = (inputs.home-manager or { }).lib or null;
      userDaemonExec =
        if hmLib != null && hmLib ? homeManagerConfiguration then
          toExecStr
            (hmLib.homeManagerConfiguration {
              inherit pkgs;
              modules = [
                flake.modules.homeManager.mcl-reprobuild
                (
                  { ... }:
                  {
                    home.username = "reprotest";
                    home.homeDirectory = "/home/reprotest";
                    home.stateVersion = "24.05";
                    programs.reprobuild = {
                      enable = true;
                      package = reproPkg;
                      enableUserDaemon = true;
                    };
                  }
                )
              ];
            }).config.systemd.user.services.repro-daemon.Service.ExecStart
        else
          "";
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_repro_lease_reaper_eval =
          pkgs.runCommand "t_repro_lease_reaper_eval"
            {
              systemReaper = systemReaperExec;
              userDaemon = userDaemonExec;
            }
            ''
              set -eu
              echo "system reaper ExecStart: $systemReaper"
              echo "user daemon  ExecStart: $userDaemon"

              # The system-scope reaper must run `repro daemon serve --system`
              # against an explicit `--state-root` (the durable system lease
              # store). These substrings are load-bearing: a wiring regression
              # drops one and this assertion fails.
              case "$systemReaper" in
                *"daemon serve"*) : ;;
                *) echo "system reaper missing 'daemon serve'"; exit 1 ;;
              esac
              case "$systemReaper" in
                *"--system"*) : ;;
                *) echo "system reaper missing --system"; exit 1 ;;
              esac
              case "$systemReaper" in
                *"--state-root"*) : ;;
                *) echo "system reaper missing --state-root"; exit 1 ;;
              esac

              # The user daemon (when home-manager is available) runs the
              # per-user `repro daemon serve`.
              if [ -n "$userDaemon" ]; then
                case "$userDaemon" in
                  *"daemon serve"*) : ;;
                  *) echo "user daemon missing 'daemon serve'"; exit 1 ;;
                esac
              fi

              touch "$out"
            '';
      };
    };
}
