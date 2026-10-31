top@{ withSystem, ... }:
{
  # gate: t_gosti_serve_migrate_state
  #
  # The deploy every live serve host goes through, run for real: a host boots
  # on the serve module as hosts ran it before the product rename (vendored
  # verbatim in ./fixtures/serve-module-before-rename.nix), serves, and is then
  # `switch-to-configuration`ed onto the current module. Asserts that the
  # switch keeps everything the fleet's trust rests on while every name moves:
  #
  #   * the same enrollment secret before and after: the signed-manifest keyId
  #     keeps its hash part and only its prefix changes, `vmh1-` to `gosti1-`
  #     (the controller's trust store must carry the new spelling),
  #   * the same bearer token accepted,
  #   * the daemon runs as `gosti-serve` (user and group), from
  #     /var/lib/gosti-serve, which now holds the files written before the
  #     switch, owned by the new user; the old directories are gone,
  #   * a consumer-declared extra migration (a libvirt-style image pool) whose
  #     target tmpfiles already created empty is moved too,
  #   * the old textfile snapshot is removed from node-exporter's directory,
  #   * no old unit remains.
  #
  # No mocks: the real modules, the real gosti binary, real systemd and the
  # real NixOS switch. (No backend is exercised: the migration touches only
  # names and directories.)
  perSystem =
    {
      pkgs,
      lib,
      self',
      ...
    }:
    let
      flake = top.config.flake;
      # MIGRATION TEST: the fixture is the pre-rename module, so it is reached
      # through its old attribute name and configured through its old paths.
      oldModule =
        (import ./fixtures/serve-module-before-rename.nix { inherit withSystem; })
        .flake.modules.nixos.vm-harness-serve;
      newModule = flake.modules.nixos.gosti-serve;
      # The gosti the fleet ran with that module (its source predates the
      # rename, so its entry point keeps the old path).
      gostiDeployed = self'.packages.gosti.overrideAttrs (_: {
        version = "0.1.2-6d050ba";
        src = pkgs.fetchFromGitHub {
          owner = "metacraft-labs";
          repo = "gosti";
          rev = "6d050ba03dbfc736a5a26e4459b7965398c16a68";
          hash = "sha256-UBQvUnHTBVo60AM1xUqVM1/UbCTlq1dfbrBIidvgEkk=";
        };
        buildPhase = ''
          runHook preBuild
          nim c --hints:off --opt:speed --nimcache:$TMPDIR/nimcache -o:gosti src/vm_harness/cli.nim
          runHook postBuild
        '';
      });
      port = 8873;
      token = "gosti-migrate-bearer-31cd";
      enroll = "gosti-migrate-enroll-secret-6b2e9f0c";
      textfileDir = "/var/lib/prometheus-node-exporter/textfile";

      secretsModule =
        { ... }:
        {
          system.activationScripts.gostiMigrateSecrets.text = ''
            mkdir -p /run/gosti-secrets
            printf '%s' '${token}' > /run/gosti-secrets/token
            printf '%s' '${enroll}' > /run/gosti-secrets/enroll
            chmod 0444 /run/gosti-secrets/token /run/gosti-secrets/enroll
          '';
          systemd.tmpfiles.rules = [ "d ${textfileDir} 0755 root root -" ];
        };
      serveSettings = {
        enable = true;
        listenAddress = "127.0.0.1";
        inherit port;
        backend = "incus";
        overlayInterface = null;
        authTokenFile = "/run/gosti-secrets/token";
        enrollSecretFile = "/run/gosti-secrets/enroll";
        hostId = "migrate-fixture";
        inventoryExporter = {
          enable = true;
          backends = [ "incus" ];
          interval = "1h";
        };
      };
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_gosti_serve_migrate_state = pkgs.testers.nixosTest {
          name = "t_gosti_serve_migrate_state";
          nodes.host =
            { ... }:
            {
              imports = [
                # Keyed so the specialisation can disable exactly this module.
                {
                  key = "gosti-serve-before-rename";
                  imports = [ oldModule ];
                  services.gosti-serve = serveSettings // {
                    package = gostiDeployed;
                  };
                }
                secretsModule
              ];
              # The deploy target: the same host with the current module in
              # place of the old one. The test switches onto it at runtime.
              specialisation.renamed.configuration = {
                disabledModules = [ { key = "gosti-serve-before-rename"; } ];
                imports = [ newModule ];
                services.gosti-serve = serveSettings // {
                  # MIGRATION TEST: a consumer-owned directory under its old name.
                  stateMigrations = lib.mkOptionDefault [
                    {
                      from = "/storage/vm-harness-serve";
                      to = "/storage/gosti-serve";
                      owner = "gosti-serve:gosti-serve";
                    }
                  ];
                };
                # tmpfiles creates the new pool dir first, as a consumer would.
                systemd.tmpfiles.rules = [ "d /storage/gosti-serve 0750 gosti-serve gosti-serve -" ];
              };
            };

          testScript = ''
            import re

            def manifest_key_id():
                out = host.succeed(
                    "curl -sf -H 'Authorization: Bearer ${token}' "
                    "http://127.0.0.1:${toString port}/v1/manifest"
                )
                m = re.search(r'"keyId"\s*:\s*"([^"]+)"', out)
                assert m, f"no keyId in /v1/manifest: {out!r}"
                return m.group(1)

            host.wait_for_unit("multi-user.target")

            # MIGRATION TEST: everything in this block names the pre-rename
            # state on purpose.
            with subtest("before: the pre-rename module serves"):
                host.wait_for_unit("gosti-serve.service")
                host.wait_until_succeeds(
                    "curl -sf -H 'Authorization: Bearer ${token}' "
                    "http://127.0.0.1:${toString port}/v1/info"
                )
                key_before = manifest_key_id()
                host.succeed("echo pre-switch > /var/lib/vm-harness-serve/sentinel")
                host.succeed(
                    "mkdir -p /storage/vm-harness-serve"
                    " && echo pool > /storage/vm-harness-serve/overlay.qcow2"
                )
                host.succeed("echo 'old 1' > ${textfileDir}/vmh-ephemeral.prom")
                assert "User=vm-harness-serve" in host.succeed("systemctl cat gosti-serve.service")

            with subtest("switch onto the current module"):
                host.succeed(
                    "/run/current-system/specialisation/renamed/bin/switch-to-configuration test >&2"
                )

            with subtest("after: the migration ran and the daemon serves under the new names"):
                host.succeed("systemctl is-active gosti-serve-migrate-state.service")
                host.wait_for_unit("gosti-serve.service")
                host.wait_until_succeeds(
                    "curl -sf -H 'Authorization: Bearer ${token}' "
                    "http://127.0.0.1:${toString port}/v1/info"
                )
                unit = host.succeed("systemctl cat gosti-serve.service")
                assert "User=gosti-serve" in unit and "Group=gosti-serve" in unit, unit
                pid = host.succeed("systemctl show -p MainPID --value gosti-serve.service").strip()
                host.succeed(
                    f"tr '\\0' '\\n' < /proc/{pid}/environ "
                    "| grep -qx STATE_DIRECTORY=/var/lib/gosti-serve"
                )

            with subtest("after: identity and state survived the move"):
                key_after = manifest_key_id()
                assert key_before.startswith("vmh1-") and key_after == "gosti1-" + key_before[len("vmh1-"):], (
                    f"the enrollment secret changed across the migration: {key_before} -> {key_after}"
                )
                host.fail(
                    "curl -sf -H 'Authorization: Bearer WRONG' "
                    "http://127.0.0.1:${toString port}/v1/info"
                )
                host.succeed("grep -qx pre-switch /var/lib/gosti-serve/sentinel")
                host.succeed("test ! -L /var/lib/gosti-serve")
                host.succeed("test \"$(stat -c %U:%G /var/lib/gosti-serve/sentinel)\" = gosti-serve:gosti-serve")
                host.succeed("grep -qx pool /storage/gosti-serve/overlay.qcow2")
                host.succeed("test \"$(stat -c %U /storage/gosti-serve/overlay.qcow2)\" = gosti-serve")
                for old in ("/var/lib/vm-harness-serve", "/var/lib/vm-harness-serve-inventory",
                            "/var/lib/vm-harness-serve-healthcheck", "/storage/vm-harness-serve",
                            "${textfileDir}/vmh-ephemeral.prom"):
                    host.succeed(f"test ! -e {old}")
                host.fail("getent passwd vm-harness-serve")
                host.fail("systemctl cat vm-harness-serve.service")

            with subtest("after: the migration is idempotent"):
                host.succeed("systemctl restart gosti-serve-migrate-state.service")
                host.succeed("systemctl restart gosti-serve.service")
                host.wait_until_succeeds(
                    "curl -sf -H 'Authorization: Bearer ${token}' "
                    "http://127.0.0.1:${toString port}/v1/info"
                )
                assert manifest_key_id() == key_after
                host.succeed("systemctl start gosti-serve-healthcheck.service")
          '';
        };
      };
    };
}
