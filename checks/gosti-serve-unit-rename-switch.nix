top@{ withSystem, ... }:
{
  # gate: t_gosti_serve_unit_rename_switch (GOSTI1b step 2, unit half)
  #
  # The deploy every live serve host goes through, run for real: a host boots on
  # the serve module as it was BEFORE the unit rename (vendored verbatim in
  # ./fixtures/vm-harness-serve-pre-unit-rename.nix), serves, and is then
  # `switch-to-configuration`ed onto the current module. Asserts that the
  # switch changes nothing the fleet's trust rests on:
  #
  #   * the same signed-manifest keyId before and after (enrollment identity),
  #   * the same bearer token accepted, the same LoadCredential paths, user and
  #     group,
  #   * the daemon's state dir is still /var/lib/vm-harness-serve (a file
  #     written before the switch is still there; /var/lib/gosti-serve is a
  #     symlink to it; the new process's STATE_DIRECTORY points at it),
  #   * exactly one daemon runs, as `gosti-serve.service`, and
  #     `vm-harness-serve.service` is an alias of it (same MainPID; `systemctl
  #     restart vm-harness-serve` restarts it),
  #   * the watchdog and inventory timers moved to `gosti-serve-*` and the old
  #     ones are gone.
  #
  # No mocks: the real modules, the real gosti binary, real systemd and the real
  # NixOS switch. (No backend is exercised: the rename touches only units.)
  perSystem =
    {
      pkgs,
      lib,
      ...
    }:
    let
      flake = top.config.flake;
      oldModule =
        (import ./fixtures/vm-harness-serve-pre-unit-rename.nix { inherit withSystem; })
        .flake.modules.nixos.vm-harness-serve;
      newModule = flake.modules.nixos.vm-harness-serve;
      port = 8873;
      token = "gosti-rename-bearer-31cd";
      enroll = "gosti-rename-enroll-secret-6b2e9f0c";

      secretsModule =
        { ... }:
        {
          system.activationScripts.gostiRenameSecrets.text = ''
            mkdir -p /run/vmh-secrets
            printf '%s' '${token}' > /run/vmh-secrets/token
            printf '%s' '${enroll}' > /run/vmh-secrets/enroll
            chmod 0400 /run/vmh-secrets/token /run/vmh-secrets/enroll
          '';
        };
      serveSettings = {
        enable = true;
        listenAddress = "127.0.0.1";
        inherit port;
        backend = "incus";
        overlayInterface = null;
        authTokenFile = "/run/vmh-secrets/token";
        enrollSecretFile = "/run/vmh-secrets/enroll";
        hostId = "rename-fixture";
        inventoryExporter = {
          enable = true;
          backends = [ "incus" ];
          interval = "1h";
        };
      };
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_gosti_serve_unit_rename_switch = pkgs.testers.nixosTest {
          name = "t_gosti_serve_unit_rename_switch";
          nodes.host =
            { ... }:
            {
              imports = [
                # Keyed so the specialisation can disable exactly this module.
                {
                  key = "gosti-serve-pre-unit-rename";
                  imports = [ oldModule ];
                }
                secretsModule
              ];
              services.gosti-serve = serveSettings;
              # The deploy target: the same host with the current module in
              # place of the old one. The test switches onto it at runtime.
              specialisation.renamed.configuration = {
                disabledModules = [ { key = "gosti-serve-pre-unit-rename"; } ];
                imports = [ newModule ];
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

            def main_pid(unit):
                return host.succeed(f"systemctl show -p MainPID --value {unit}").strip()

            host.wait_for_unit("multi-user.target")

            with subtest("before: the pre-rename module serves as vm-harness-serve.service"):
                host.wait_for_unit("vm-harness-serve.service")
                host.wait_for_file("/run/vm-harness-serve/port")
                host.fail("systemctl cat gosti-serve.service")
                key_before = manifest_key_id()
                host.succeed("echo pre-switch > /var/lib/vm-harness-serve/sentinel")
                unit_before = host.succeed("systemctl cat vm-harness-serve.service")

            with subtest("switch onto the current module"):
                host.succeed(
                    "/run/current-system/specialisation/renamed/bin/switch-to-configuration test >&2"
                )

            with subtest("after: one daemon, gosti-serve.service, aliased as vm-harness-serve.service"):
                host.wait_for_unit("gosti-serve.service")
                host.wait_until_succeeds(
                    "curl -sf -H 'Authorization: Bearer ${token}' "
                    "http://127.0.0.1:${toString port}/v1/info"
                )
                pid = main_pid("gosti-serve.service")
                assert pid != "0", "gosti-serve.service has no main process"
                assert main_pid("vm-harness-serve.service") == pid, (
                    "vm-harness-serve.service must be an alias of gosti-serve.service"
                )
                host.succeed("systemctl is-active vm-harness-serve.service")

            with subtest("after: identity, credentials and state are unchanged"):
                assert manifest_key_id() == key_before, "keyId changed across the unit rename"
                host.fail(
                    "curl -sf -H 'Authorization: Bearer WRONG' "
                    "http://127.0.0.1:${toString port}/v1/info"
                )
                unit = host.succeed("systemctl cat gosti-serve.service")
                for line in ("LoadCredential=token:/run/vmh-secrets/token",
                             "LoadCredential=enroll-secret:/run/vmh-secrets/enroll",
                             "User=vm-harness-serve", "Group=vm-harness-serve"):
                    assert line in unit_before, f"fixture lost {line!r}"
                    assert line in unit, f"renamed unit lost {line!r}"
                host.succeed("grep -qx pre-switch /var/lib/vm-harness-serve/sentinel")
                assert host.succeed("readlink -f /var/lib/gosti-serve").strip() == "/var/lib/vm-harness-serve"
                host.succeed(
                    f"tr '\\0' '\\n' < /proc/{pid}/environ "
                    "| grep -qx STATE_DIRECTORY=/var/lib/vm-harness-serve"
                )

            with subtest("after: watchdog + inventory moved to gosti-serve-*"):
                host.succeed("systemctl is-active gosti-serve-healthcheck.timer")
                host.succeed("systemctl is-active gosti-serve-inventory.timer")
                for old in ("vm-harness-serve-healthcheck.timer", "vm-harness-serve-inventory.timer"):
                    state = host.execute(f"systemctl is-active {old}")[1].strip()
                    assert state != "active", f"{old} is still active after the rename"
                host.succeed("systemctl start gosti-serve-healthcheck.service")

            with subtest("the legacy name still drives the unit"):
                before = main_pid("gosti-serve.service")
                host.succeed("systemctl restart vm-harness-serve.service")
                host.wait_for_unit("gosti-serve.service")
                assert main_pid("gosti-serve.service") != before, "restart via the alias did nothing"
                host.wait_until_succeeds(
                    "curl -sf -H 'Authorization: Bearer ${token}' "
                    "http://127.0.0.1:${toString port}/v1/info"
                )
                assert manifest_key_id() == key_before
          '';
        };
      };
    };
}
