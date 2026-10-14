top@{ ... }:
{
  # gate: t_gosti_serve_survives_incus_blip
  #
  # Reproduces the gpu-server-001 outage of 2026-10-14 and its gpu-server-002
  # predecessor: incus.service failed ONCE and came back by itself seconds
  # later, but the serve daemon and the garm-incus-storage-network oneshot had
  # already failed their start jobs with "Dependency failed", and nothing ever
  # retried them. Serve stayed dead for hours. The watchdog meant to recover
  # that case did nothing: it looked for Result=dependency, which systemd does
  # not record for a failed start JOB.
  #
  # Three properties, each driven on a real systemd + incus + serve host:
  #
  #   (A) A failed incus start no longer takes serve or the convergence oneshot
  #       down with it: both depend on incus with Wants=, so serve starts
  #       anyway, and the oneshot keeps retrying (Restart=on-failure, no start
  #       limit) until incus is back.
  #   (B) The watchdog recovers a serve unit whose start failed on ANY
  #       dependency (a deliberately failing helper unit stands in for one),
  #       even though the unit's Result= still says `success`.
  #   (C) A state-file write the watchdog cannot make is logged and survived,
  #       not fatal under `set -e`.
  #
  # Each property is checked against its negative: the precondition that made
  # the old code fail is asserted first (the dependency failure really
  # happened, Result= really is not `dependency`, the write really fails).
  #
  # No mocks: real modules, the real gosti binary, real incus and systemd.
  # The two fault injections are runtime systemd drop-ins (a pre-start that
  # fails once), the smallest way to make a real unit fail exactly once.
  perSystem =
    { pkgs, lib, ... }:
    let
      flake = top.config.flake;
      token = "gosti-blip-bearer-5e1a";
      port = 8873;
      failOnce =
        marker:
        pkgs.writeShellScript "fail-once-${marker}" ''
          if [ ! -e /run/${marker} ]; then
            touch /run/${marker}
            echo "fault injection: failing once (${marker})" >&2
            exit 1
          fi
        '';
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_gosti_serve_survives_incus_blip = pkgs.testers.nixosTest {
          name = "t_gosti_serve_survives_incus_blip";
          nodes.host =
            { ... }:
            {
              imports = [
                flake.modules.nixos.vm-harness-serve
                flake.modules.nixos.garm-incus-runner-host
              ];
              networking.nftables.enable = true;
              virtualisation.incus.enable = true;
              virtualisation.diskSize = 8192;
              virtualisation.memorySize = 3072;
              services.garm-incus-runner-host = {
                enable = true;
                bridgeSubnet = "10.158.160.0/24";
                image.enable = false;
              };
              system.activationScripts.gostiBlipToken.text = ''
                mkdir -p /run/vmh-secrets
                printf '%s' '${token}' > /run/vmh-secrets/token
                chmod 0400 /run/vmh-secrets/token
              '';
              services.gosti-serve = {
                enable = true;
                listenAddress = "127.0.0.1";
                inherit port;
                backend = "incus";
                overlayInterface = null;
                authTokenFile = "/run/vmh-secrets/token";
              };
              # A stand-in dependency for (B), declared but not wired: the test
              # attaches it to gosti-serve with a runtime drop-in.
              systemd.services.blip-dependency = {
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                  ExecStartPre = "${failOnce "blip-dependency-failed"}";
                  ExecStart = "${pkgs.coreutils}/bin/true";
                };
              };
            };

          testScript = ''
            def listening():
                return host.execute(
                    "curl -s -o /dev/null -w '%{http_code}' --max-time 3 "
                    "http://127.0.0.1:${toString port}/v1/info"
                )[1].strip() in ("200", "401")

            host.wait_for_unit("multi-user.target")
            host.wait_for_unit("incus.service")
            host.wait_for_unit("gosti-serve.service")
            host.wait_for_unit("garm-incus-storage-network.service")

            with subtest("(A) an incus start that fails once does not strand serve or the oneshot"):
                host.succeed("systemctl stop gosti-serve.service garm-incus-storage-network.service incus.service incus.socket")
                host.succeed(
                    "mkdir -p /run/systemd/system/incus.service.d && "
                    "printf '[Service]\\nExecStartPre=${failOnce "incus-failed-once"}\\nRestart=on-failure\\nRestartSec=3\\n' "
                    "> /run/systemd/system/incus.service.d/blip.conf && systemctl daemon-reload"
                )
                # What the deploy agent does: start the units back up. incus's
                # start fails once (the blip), then systemd restarts it.
                host.execute("systemctl start --no-block incus.service gosti-serve.service garm-incus-storage-network.service")
                host.wait_until_succeeds("test -e /run/incus-failed-once", timeout=30)
                host.wait_until_succeeds("journalctl -u incus.service -o cat | grep -q 'fault injection: failing once'", timeout=30)
                host.wait_for_unit("gosti-serve.service", timeout=60)
                host.wait_until_succeeds("curl -s -o /dev/null --max-time 3 http://127.0.0.1:${toString port}/v1/info", timeout=60)
                assert listening(), "serve is not answering after the incus blip"
                host.wait_for_unit("incus.service", timeout=60)
                host.wait_until_succeeds(
                    "systemctl show -p ActiveState --value garm-incus-storage-network.service | grep -qx active",
                    timeout=180,
                )
                out = host.succeed("journalctl -u gosti-serve.service -o cat")
                assert "Dependency failed" not in out, out
                host.succeed("rm -rf /run/systemd/system/incus.service.d && systemctl daemon-reload")

            with subtest("(B) the watchdog restarts a serve whose start failed on a dependency"):
                host.succeed("systemctl stop gosti-serve.service")
                assert host.succeed("systemctl show -p Result --value gosti-serve.service").strip() == "success"
                host.succeed(
                    "mkdir -p /run/systemd/system/gosti-serve.service.d && "
                    "printf '[Unit]\\nRequires=blip-dependency.service\\nAfter=blip-dependency.service\\n' "
                    "> /run/systemd/system/gosti-serve.service.d/blip.conf && systemctl daemon-reload"
                )
                host.fail("systemctl start gosti-serve.service")
                host.succeed("journalctl -u gosti-serve.service -o cat | grep -q '^Dependency failed for '")
                # The old watchdog keyed on this, and it is still `success`.
                res = host.succeed("systemctl show -p Result --value gosti-serve.service").strip()
                assert res != "dependency", f"precondition: Result is {res!r}"
                assert host.succeed("systemctl is-active gosti-serve.service || true").strip() != "active"
                # The watchdog run that used to say "leaving it to systemd".
                host.succeed("systemctl start gosti-serve-healthcheck.service")
                host.succeed("journalctl -u gosti-serve-healthcheck.service -o cat | grep -q 'failed on a DEPENDENCY — retrying start'")
                host.wait_for_unit("gosti-serve.service", timeout=60)
                host.wait_until_succeeds("curl -s -o /dev/null --max-time 3 http://127.0.0.1:${toString port}/v1/info", timeout=60)
                host.succeed("rm -rf /run/systemd/system/gosti-serve.service.d && systemctl daemon-reload")

            with subtest("(B') a deliberate stop is still left alone"):
                host.succeed("systemctl stop gosti-serve.service")
                host.succeed("systemctl start gosti-serve-healthcheck.service")
                host.succeed("journalctl -u gosti-serve-healthcheck.service -o cat | grep -q 'leaving it to systemd'")
                assert host.succeed("systemctl is-active gosti-serve.service || true").strip() != "active"
                host.succeed("systemctl start gosti-serve.service")
                host.wait_for_unit("gosti-serve.service")

            with subtest("(C) an unwritable state file does not kill the watchdog"):
                host.succeed("systemctl stop gosti-serve.service")
                host.succeed("rm -rf /var/lib/vm-harness-serve-healthcheck/consecutive-failures && mkdir /var/lib/vm-harness-serve-healthcheck/consecutive-failures")
                host.succeed("systemctl start gosti-serve-healthcheck.service")
                host.succeed("journalctl -u gosti-serve-healthcheck.service -o cat | grep -q 'WARN: could not write'")
                assert host.succeed("systemctl show -p Result --value gosti-serve-healthcheck.service").strip() == "success"
                host.succeed("rmdir /var/lib/vm-harness-serve-healthcheck/consecutive-failures")
                host.succeed("systemctl start gosti-serve.service")
          '';
        };
      };
    };
}
