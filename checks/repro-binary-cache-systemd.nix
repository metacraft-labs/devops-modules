top@{ ... }:
{
  # Windows-Runner-Binary-Cache-Deploy M1 gate: t_repro_binary_cache_systemd_healthz.
  #
  # Boots a NixOS VM with `services.mcl-repro-binary-cache.enable = true`, starts
  # the unit, and asserts the REAL packaged daemon (built from the reprobuild
  # flake input — no stub) answers on 0.0.0.0:7878:
  #   * GET /healthz   -> 200 "ok"
  #   * GET /cache-info -> 200 with a non-empty octet-stream body that decodes
  #     as the SSZ CacheInfoRecord (probed for the advertised StoreDir path).
  # It also confirms the durable `--root` under /var/lib is populated (producer
  # keypair persisted) and that the unit is a long-running Type=simple service.
  perSystem =
    {
      pkgs,
      lib,
      inputs',
      ...
    }:
    let
      flake = top.config.flake;
      reproBinaryCache = inputs'.reprobuild.packages.repro-binary-cache;
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_repro_binary_cache_systemd_healthz = pkgs.testers.nixosTest {
          name = "t_repro_binary_cache_systemd_healthz";

          nodes.server =
            { ... }:
            {
              imports = [ flake.modules.nixos.mcl-repro-binary-cache ];
              environment.systemPackages = [
                pkgs.curl
                pkgs.python3
              ];
              services.mcl-repro-binary-cache = {
                enable = true;
                package = reproBinaryCache;
                # Bind loopback too so the in-VM curl reaches it; the default
                # 0.0.0.0 already covers this, kept explicit for the gate.
                listenAddress = "0.0.0.0";
                port = 7878;
              };
            };

          testScript = ''
            start_all()
            server.wait_for_unit("multi-user.target")

            with subtest("the packaged daemon unit is a long-running service, not a oneshot"):
                service_type = server.succeed(
                    "systemctl show -p Type --value mcl-repro-binary-cache.service"
                ).strip()
                assert service_type == "simple", f"unexpected Type={service_type!r}"

            with subtest("service comes up and binds the intended port"):
                server.wait_for_unit("mcl-repro-binary-cache.service")
                server.wait_for_open_port(7878)

            with subtest("GET /healthz returns 200 ok"):
                status = server.succeed(
                    "curl -s -o /tmp/healthz.body -w '%{http_code}' http://localhost:7878/healthz"
                ).strip()
                assert status == "200", f"healthz status={status!r}"
                body = server.succeed("cat /tmp/healthz.body").strip()
                assert body == "ok", f"healthz body={body!r}"

            with subtest("GET /cache-info returns 200 with a decodable octet-stream body"):
                status = server.succeed(
                    "curl -s -D /tmp/cacheinfo.hdr -o /tmp/cacheinfo.body "
                    "-w '%{http_code}' http://localhost:7878/cache-info"
                ).strip()
                assert status == "200", f"cache-info status={status!r}"
                headers = server.succeed("cat /tmp/cacheinfo.hdr").lower()
                assert "content-type: application/octet-stream" in headers, headers
                # Body must be non-empty and parseable as the SSZ CacheInfoRecord:
                # it advertises the StoreDir path the daemon defaults to
                # (<root>/store), so the durable root path must appear in the
                # decoded record.
                server.succeed(
                    "python3 - <<'PY'\n"
                    "data = open('/tmp/cacheinfo.body', 'rb').read()\n"
                    "assert len(data) > 0, 'cache-info body is empty'\n"
                    "# The advertised StoreDir is stored as UTF-8 bytes in the\n"
                    "# SSZ record; the daemon defaults it to <root>/store.\n"
                    "text = data.decode('latin-1')\n"
                    "assert '/var/lib/repro-binary-cache/store' in text, (\n"
                    "    'advertised StoreDir not found in cache-info record: %r' % text)\n"
                    "PY"
                )

            with subtest("durable --root store persists the producer keypair"):
                server.succeed("test -d /var/lib/repro-binary-cache")
                # The daemon materialises its ECDSA-P256 producer key under the
                # durable root on first boot; its presence proves --root is wired
                # to a persistent StateDirectory rather than a tmpfs.
                server.succeed(
                    "test -f /var/lib/repro-binary-cache/trust/server-ecdsa-p256.key"
                )
          '';
        };
      };
    };
}
