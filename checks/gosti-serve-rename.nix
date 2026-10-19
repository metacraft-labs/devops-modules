top@{ ... }:
{
  # gate: t_gosti_serve_rename (GOSTI1b steps 1, 2 and 4)
  #
  # Pure-eval + one tiny build. Proves the vm-harness → gosti rename on the
  # consumer side changes NOTHING a live serve host's identity rests on:
  #
  #   * step 1 — `packages.gosti` installs `bin/gosti` (executable) and
  #     `bin/vm-harness` as a symlink to it; `packages.vm-harness` is the same
  #     derivation; `lib.getExe` yields `bin/gosti`.
  #   * step 2 — `services.gosti-serve` is the canonical option path and the
  #     legacy `services.vm-harness-serve` still works (with a deprecation
  #     warning). The SAME settings under either path render byte-identical
  #     units: `gosti-serve.service` (aliased `vm-harness-serve.service`), its
  #     inventory/healthcheck units and timers on NixOS, and the launchd
  #     daemons on nix-darwin (label org.metacraft-labs.gosti-serve). User,
  #     group, state directory and credential names keep their
  #     `vm-harness-serve` values (they carry the enrollment keyId and the
  #     agenix secret ownership). The switch itself is
  #     t_gosti_serve_unit_rename_switch.
  #   * step 4 + 6 — the units export `GOSTI_EPHEMERAL_LABEL_DIR`; since step 6
  #     the legacy `VMH_EPHEMERAL_LABEL_DIR` is no longer exported (every
  #     deployed gosti and the default package read GOSTI_* first).
  #
  # No mocks: real module evaluation and a real package build.
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
        authTokenFile = "/run/vmh-secrets/token";
        enrollSecretFile = "/run/vmh-secrets/enroll";
        inventoryExporter = {
          enable = true;
          backends = [ "incus" ];
        };
      };

      nixosWith =
        path:
        (lib.nixosSystem {
          system = pkgs.stdenv.hostPlatform.system;
          modules = [
            flake.modules.nixos.vm-harness-serve
            (
              { ... }:
              {
                boot.loader.grub.enable = false;
                fileSystems."/" = {
                  device = "none";
                  fsType = "tmpfs";
                };
                system.stateVersion = "24.05";
              }
              // lib.setAttrByPath path settings
            )
          ];
        }).config;

      oldCfg = nixosWith [
        "services"
        "vm-harness-serve"
      ];
      newCfg = nixosWith [
        "services"
        "gosti-serve"
      ];
      unitNames = [
        "gosti-serve.service"
        "gosti-serve-inventory.service"
        "gosti-serve-inventory.timer"
        "gosti-serve-healthcheck.service"
        "gosti-serve-healthcheck.timer"
      ];
      unitText = cfg: name: builtins.unsafeDiscardStringContext cfg.systemd.units.${name}.unit.outPath;
      sc = newCfg.systemd.services.gosti-serve.serviceConfig;
      env = lib.toList (sc.Environment or [ ]);
      envOf =
        prefix: lib.findFirst (e: lib.hasPrefix "${prefix}EPHEMERAL_LABEL_DIR=" e) null (map toString env);
      valueOf = e: if e == null then null else lib.last (lib.splitString "=" e);

      darwinWith =
        path:
        (top.inputs.nix-darwin.lib.darwinSystem {
          inherit (pkgs.stdenv.hostPlatform) system;
          modules = [
            flake.modules.darwin.vm-harness-serve
            (
              { ... }:
              {
                networking.hostName = "gosti-rename-fixture";
                system.stateVersion = 6;
              }
              // lib.setAttrByPath path {
                enable = true;
                listenAddress = "127.0.0.1";
                authTokenFile = "/run/agenix/vm-harness-serve/token";
                backend = "tart-macos";
              }
            )
          ];
        }).config;
      darwinJobs =
        cfg:
        builtins.toJSON (
          lib.mapAttrs (_: d: d.serviceConfig) (
            lib.filterAttrs (n: _: lib.hasPrefix "gosti-serve" n) cfg.launchd.daemons
          )
        );

      warnsAbout = cfg: lib.any (w: lib.hasInfix "gosti-serve" w) cfg.warnings;

      linuxChecks = [
        {
          ok = lib.all (n: unitText oldCfg n == unitText newCfg n) unitNames;
          msg = "the legacy and canonical option paths render different units: ${
            lib.concatStringsSep ", " (lib.filter (n: unitText oldCfg n != unitText newCfg n) unitNames)
          }";
        }
        {
          ok = warnsAbout oldCfg && !(warnsAbout newCfg);
          msg = "the legacy option path must warn (and only it)";
        }
        {
          ok =
            sc.User == "vm-harness-serve"
            && sc.Group == "vm-harness-serve"
            && sc.StateDirectory == "vm-harness-serve:gosti-serve"
            && newCfg.users.users ? vm-harness-serve;
          msg = "user/group/state dir must keep their vm-harness-serve names (live identity); /var/lib/gosti-serve is only a symlink";
        }
        {
          ok =
            newCfg.systemd.services.gosti-serve.aliases == [ "vm-harness-serve.service" ]
            && !(newCfg.systemd.services ? vm-harness-serve);
          msg = "gosti-serve.service must carry exactly the vm-harness-serve.service alias, and no separate vm-harness-serve unit may exist";
        }
        {
          ok = lib.hasInfix "/bin/gosti " (toString sc.ExecStart);
          msg = "ExecStart does not run bin/gosti (got ${toString sc.ExecStart})";
        }
        {
          ok = envOf "GOSTI_" != null && envOf "VMH_" == null;
          msg = "the unit must export GOSTI_EPHEMERAL_LABEL_DIR and no longer VMH_EPHEMERAL_LABEL_DIR (GOSTI1b step 6)";
        }
      ];

      darwinChecks = lib.optionals pkgs.stdenv.hostPlatform.isDarwin (
        let
          oldD = darwinWith [
            "services"
            "vm-harness-serve"
          ];
          newD = darwinWith [
            "services"
            "gosti-serve"
          ];
          envVars = newD.launchd.daemons.gosti-serve.serviceConfig.EnvironmentVariables;
        in
        [
          {
            ok = darwinJobs oldD == darwinJobs newD;
            msg = "darwin: the legacy and canonical option paths render different launchd jobs";
          }
          {
            ok = newD.launchd.daemons.gosti-serve.serviceConfig.Label == "org.metacraft-labs.gosti-serve";
            msg = "darwin: the serve job label must be org.metacraft-labs.gosti-serve";
          }
          {
            ok = envVars ? GOSTI_EPHEMERAL_LABEL_DIR && !(envVars ? VMH_EPHEMERAL_LABEL_DIR);
            msg = "darwin: export GOSTI_EPHEMERAL_LABEL_DIR only (GOSTI1b step 6)";
          }
        ]
      );

      failures = map (c: c.msg) (
        lib.filter (c: !c.ok) (lib.optionals pkgs.stdenv.hostPlatform.isLinux linuxChecks ++ darwinChecks)
      );
      gosti = self'.packages.gosti;
    in
    {
      checks.t_gosti_serve_rename =
        assert lib.assertMsg (failures == [ ]) (
          "t_gosti_serve_rename:\n  " + lib.concatStringsSep "\n  " failures
        );
        assert lib.assertMsg (
          self'.packages.vm-harness.outPath == gosti.outPath
        ) "packages.vm-harness must alias packages.gosti";
        assert lib.assertMsg (
          lib.getExe gosti == "${gosti}/bin/gosti"
        ) "lib.getExe packages.gosti must be bin/gosti";
        pkgs.runCommand "t_gosti_serve_rename" { } ''
          set -eu
          test -x ${gosti}/bin/gosti
          test ! -L ${gosti}/bin/gosti
          test -L ${gosti}/bin/vm-harness
          test "$(readlink ${gosti}/bin/vm-harness)" = gosti
          test -d ${gosti}/share/vm-harness/guest-recipes
          echo "GATE PASS: gosti package layout + option rename + dual env export" >"$out"
        '';
    };
}
