top@{ ... }:
{
  # gate: t_gosti_serve_identity
  #
  # Pure-eval + one tiny build. Pins the names a serve host is known by:
  #
  #   * `packages.gosti` installs exactly one command, `bin/gosti` (a real
  #     executable, not a symlink), plus `share/gosti/guest-recipes`;
  #     `lib.getExe` yields it.
  #   * on NixOS the units are `gosti-serve*`, carry no aliases, and run as the
  #     `gosti-serve` user and group from the `gosti-serve` state directory;
  #     `gosti-serve-migrate-state.service` is required by and ordered before
  #     every one of them; the unit runs `bin/gosti` and exports
  #     `GOSTI_EPHEMERAL_LABEL_DIR`.
  #   * on nix-darwin the job label is org.metacraft-labs.gosti-serve, the
  #     state dir is /private/var/lib/gosti-serve and the job exports
  #     `GOSTI_EPHEMERAL_LABEL_DIR`.
  #
  # The deploy that moves a live host onto these names is
  # t_gosti_serve_migrate_state. No mocks: real module evaluation and a real
  # package build.
  perSystem =
    {
      pkgs,
      lib,
      self',
      ...
    }:
    let
      flake = top.config.flake;
      settings = {
        enable = true;
        listenAddress = "10.10.10.1";
        backend = "incus";
        overlayInterface = null;
        authTokenFile = "/run/gosti-secrets/token";
        enrollSecretFile = "/run/gosti-secrets/enroll";
        inventoryExporter = {
          enable = true;
          backends = [ "incus" ];
        };
      };

      cfg =
        (lib.nixosSystem {
          system = pkgs.stdenv.hostPlatform.system;
          modules = [
            flake.modules.nixos.gosti-serve
            {
              boot.loader.grub.enable = false;
              fileSystems."/" = {
                device = "none";
                fsType = "tmpfs";
              };
              system.stateVersion = "24.05";
              services.gosti-serve = settings;
            }
          ];
        }).config;
      units = [
        "gosti-serve"
        "gosti-serve-inventory"
        "gosti-serve-healthcheck"
      ];
      svc = cfg.systemd.services;
      sc = svc.gosti-serve.serviceConfig;
      env = map toString (lib.toList (sc.Environment or [ ]));
      migrate = svc.gosti-serve-migrate-state;

      linuxChecks = [
        {
          ok = lib.all (u: (svc.${u}.aliases or [ ]) == [ ]) units;
          msg = "the gosti-serve units must carry no aliases";
        }
        {
          ok =
            sc.User == "gosti-serve"
            && sc.Group == "gosti-serve"
            && sc.StateDirectory == "gosti-serve"
            && cfg.users.users ? gosti-serve
            && cfg.users.groups ? gosti-serve;
          msg = "the daemon must run as gosti-serve:gosti-serve from the gosti-serve state dir";
        }
        {
          ok = lib.all (
            u: lib.elem "${u}.service" migrate.requiredBy && lib.elem "${u}.service" migrate.before
          ) units;
          msg = "gosti-serve-migrate-state must be required by and ordered before every gosti-serve unit";
        }
        {
          ok = lib.hasInfix "/bin/gosti " (toString sc.ExecStart);
          msg = "ExecStart does not run bin/gosti (got ${toString sc.ExecStart})";
        }
        {
          ok = lib.any (e: lib.hasPrefix "GOSTI_EPHEMERAL_LABEL_DIR=/var/lib/gosti-serve/" e) env;
          msg = "the unit must export GOSTI_EPHEMERAL_LABEL_DIR under /var/lib/gosti-serve";
        }
      ];

      darwinChecks = lib.optionals pkgs.stdenv.hostPlatform.isDarwin (
        let
          d =
            (top.inputs.nix-darwin.lib.darwinSystem {
              inherit (pkgs.stdenv.hostPlatform) system;
              modules = [
                flake.modules.darwin.gosti-serve
                {
                  networking.hostName = "gosti-identity-fixture";
                  system.stateVersion = 6;
                  services.gosti-serve = {
                    enable = true;
                    listenAddress = "127.0.0.1";
                    authTokenFile = "/run/agenix/gosti-serve/token";
                    backend = "tart-macos";
                  };
                }
              ];
            }).config;
          job = d.launchd.daemons.gosti-serve.serviceConfig;
        in
        [
          {
            ok = job.Label == "org.metacraft-labs.gosti-serve";
            msg = "darwin: the serve job label must be org.metacraft-labs.gosti-serve";
          }
          {
            ok = job.WorkingDirectory or d.services.gosti-serve.stateDir == "/private/var/lib/gosti-serve";
            msg = "darwin: the state dir must be /private/var/lib/gosti-serve";
          }
          {
            ok = job.EnvironmentVariables ? GOSTI_EPHEMERAL_LABEL_DIR;
            msg = "darwin: the job must export GOSTI_EPHEMERAL_LABEL_DIR";
          }
        ]
      );

      failures = map (c: c.msg) (
        lib.filter (c: !c.ok) (lib.optionals pkgs.stdenv.hostPlatform.isLinux linuxChecks ++ darwinChecks)
      );
      gosti = self'.packages.gosti;
    in
    {
      checks.t_gosti_serve_identity =
        assert lib.assertMsg (failures == [ ]) (
          "t_gosti_serve_identity:\n  " + lib.concatStringsSep "\n  " failures
        );
        assert lib.assertMsg (
          lib.getExe gosti == "${gosti}/bin/gosti"
        ) "lib.getExe packages.gosti must be bin/gosti";
        pkgs.runCommand "t_gosti_serve_identity" { } ''
          set -eu
          test -x ${gosti}/bin/gosti
          test ! -L ${gosti}/bin/gosti
          test "$(ls ${gosti}/bin)" = gosti
          test -d ${gosti}/share/gosti/guest-recipes
          echo "GATE PASS: gosti package layout + serve identity" >"$out"
        '';
    };
}
