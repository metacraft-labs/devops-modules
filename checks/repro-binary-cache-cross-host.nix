top@{ ... }:
{
  # Windows-Runner-Binary-Cache-Deploy M2 gate: t_cross_host_publish_substitute.
  #
  # A genuine TWO-NODE (cross-host, real TCP, NOT loopback) proof that the
  # reprobuild binary cache works over the network:
  #
  #   * node `server` runs the M1 `services.mcl-repro-binary-cache` systemd unit
  #     (the REAL packaged daemon from the reprobuild flake — no stub) bound on
  #     0.0.0.0:7878 with the firewall opened.
  #   * node `client` runs `repro-binary-cache-crosshost` (the M2 driver shipped
  #     in the same reprobuild package) pointed at `http://server:7878` — the
  #     server node's hostname, a distinct routable endpoint on the VM network,
  #     never 127.0.0.1.
  #
  # The driver PUBLISHES a synthetic 5-member deployment closure
  # (hex0 → stage0-posix → mescc-tools → mes → tcc) to the remote server, then
  # SUBSTITUTES the whole closure back from a FRESH empty local store, and
  # asserts inside its own process:
  #
  #   * the closure plan has all 5 members;
  #   * every member's payload was fetched over the wire (bytesFetched > 0) and
  #     NONE were served from the local cache (skipped == false) — so at least
  #     one (in fact every) payload genuinely crossed the network;
  #   * each member re-extracts BYTE-IDENTICAL to the originally-published
  #     on-disk prefix tree.
  #
  # The driver exits 0 only if all of that holds; the test script asserts exit 0
  # and independently confirms the network path (a fresh /manifests/<hex> miss
  # from the client reaches the server over TCP, and the OK line reports a
  # non-zero total_bytes_fetched).
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
        t_cross_host_publish_substitute = pkgs.testers.nixosTest {
          name = "t_cross_host_publish_substitute";

          nodes.server =
            { ... }:
            {
              imports = [ flake.modules.nixos.mcl-repro-binary-cache ];
              services.mcl-repro-binary-cache = {
                enable = true;
                package = reproBinaryCache;
                listenAddress = "0.0.0.0";
                port = 7878;
                # The client reaches the daemon across the VM network, so the
                # port must be open on the server's firewall (the loopback M1
                # gate never needed this).
                openFirewall = true;
              };
            };

          nodes.client =
            { ... }:
            {
              environment.systemPackages = [
                # Ships build/bin/repro-binary-cache-crosshost (the M2 driver)
                # plus the libzstd the client links against for decompress.
                reproBinaryCache
                pkgs.curl
                pkgs.zstd
              ];
            };

          testScript = ''
            start_all()

            server.wait_for_unit("multi-user.target")
            client.wait_for_unit("multi-user.target")

            with subtest("the remote binary-cache daemon is up and reachable over TCP"):
                server.wait_for_unit("mcl-repro-binary-cache.service")
                server.wait_for_open_port(7878)
                # Cross-host reachability: the client hits the SERVER hostname,
                # not loopback. /healthz proves real routing before we publish.
                client.wait_until_succeeds(
                    "curl -sf -o /dev/null http://server:7878/healthz", timeout=60
                )
                healthz = client.succeed("curl -s http://server:7878/healthz").strip()
                assert healthz == "ok", f"cross-host healthz body={healthz!r}"

            with subtest("a fresh manifest lookup MISSES over the network (real server, empty for this key)"):
                # 64 hex zeros is a key we never publish; a 404 from the remote
                # confirms the client is talking to the actual daemon, not a
                # local stub or cache.
                status = client.succeed(
                    "curl -s -o /dev/null -w '%{http_code}' "
                    "http://server:7878/manifests/"
                    + ("0" * 64)
                ).strip()
                assert status == "404", f"expected 404 for unpublished key, got {status!r}"

            with subtest("client publishes a 5-member closure to the remote server and substitutes it back byte-identical"):
                # The driver does the whole cross-host publish→substitute and
                # asserts byte-identity + wire-crossing internally; it exits 0
                # only if every payload came from the remote (bytesFetched>0,
                # not skipped) and re-extracted identically.
                out = client.succeed(
                    "REPRO_BINARY_CACHE_URL=http://server:7878 "
                    "repro-binary-cache-crosshost 2>&1"
                )
                print(out)
                assert "OK cross-host publish" in out, out
                assert "members=5" in out, out
                # total_bytes_fetched must be strictly positive — the closure
                # crossed the wire on the way back, it was not a local hit.
                import re
                m = re.search(r"total_bytes_fetched=(\d+)", out)
                assert m, f"driver did not report total_bytes_fetched: {out!r}"
                assert int(m.group(1)) > 0, f"total_bytes_fetched was 0: {out!r}"

            with subtest("after the closure was published, the root manifest is now a HIT on the remote"):
                # Extract the root entry-key hex the driver printed and confirm
                # the SERVER now serves it (200) over the network — corroborates
                # that the publish landed on the remote host, not locally.
                mroot = re.search(r"root=([0-9a-f]{64})", out)
                assert mroot, f"driver did not report root=<64hex>: {out!r}"
                root_hex = mroot.group(1)
                status = client.succeed(
                    "curl -s -o /dev/null -w '%{http_code}' "
                    f"http://server:7878/manifests/{root_hex}"
                ).strip()
                assert status == "200", f"root manifest not a hit on server: {status!r}"
          '';
        };
      };
    };
}
