top@{ ... }:
{
  # Windows-Runner-Binary-Cache-Deploy M7 prereq (c) gate:
  # t_repro_deploy_agent_https_converges.
  #
  # A genuine TWO-NODE proof that the production nixos-modules wiring serves the
  # reprobuild binary cache over REAL HTTPS with a publish ALLOWLIST enforced,
  # and that the reprobuild deploy agent PULLS a signed desired-state manifest
  # over REAL TLS, verifies its ECDSA-P256 signature against the allowed-signers
  # set, and converges — while a manifest signed by a NON-allowlisted key is
  # rejected. Nothing is stubbed: real OpenSSL TLS on both the cache daemon and
  # the manifest host, real ECDSA-P256 signature verification in the agent.
  #
  #   * node `server` runs the M7-extended `services.mcl-repro-binary-cache`
  #     over HTTPS (self-signed ECDSA-P256 cert via LoadCredential) with an
  #     `--allowed-signers` allowlist, PLUS an nginx TLS vhost serving the
  #     signed RDMF manifest fixture at https://server/latest.rdm.
  #   * node `agent` runs `services.mcl-repro-deploy-agent` targeting
  #     `deploy-target-001`, pointed at the HTTPS manifest source, trusting the
  #     server's self-signed CA (REPRO_BINARY_CACHE_CA_FILE) and the manifest
  #     signer's ECDSA-P256 pubkey.
  #
  # The manifest + allowed-signers fixtures are REAL: minted once with a tiny
  # Nim helper against reprobuild's own `repro_deploy_agent` +
  # `repro_peer_cache/auth` libraries (see :fixture-provenance: in the check
  # body), so the signature the agent verifies is a genuine ECDSA-P256 signature
  # over the genuine RDMF envelope, and the trusted anchor is the matching
  # 130-char-hex uncompressed public key.
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
      # Binary-Caches.md §"Client CLI Surface (`repro cache`)": the standalone
      # `repro-binary-cache-client` package was retired; its toolset is now the
      # `repro cache <subcommand>` group shipped by the full `reprobuild`
      # package (`bin/repro`).
      repro = inputs'.reprobuild.packages.reprobuild;

      # --- Fixture provenance -------------------------------------------------
      # Minted with:
      #   $ cat > sign.nim <<'NIM'
      #   import std/[os, parseopt]
      #   import repro_deploy_agent
      #   import repro_peer_cache/auth as peerAuth
      #   proc pubHex(pub: PublicKeyBytes): string =
      #     const H = "0123456789abcdef"
      #     for b in pub: result.add H[int(b shr 4) and 0xf]; result.add H[int(b) and 0xf]
      #   # ...generateKeypair(); DeployManifest(target,sequence,deploymentId,
      #   #    profileText="",buildActions=@[]); signManifest(kp,m);
      #   #    writeFile(anchor, pubHex(kp.publicKey)); writeFile(manifest, encodeManifest(m))
      #   NIM
      #   $ nim c -r sign.nim (in `nix develop` of reprobuild dev @ ed97ef56)
      # for target=deploy-target-001 sequence=1. `untrusted.rdm` is signed by a
      # SECOND keypair whose pubkey is NOT in `trustedAnchorHex` — a
      # cryptographically-valid signature the allowlist must still reject.
      #
      # RE-MINTED when the envelope magic became `RDMF` (it was `RDM1`, whose
      # trailing digit read as a version and then contradicted a v2 envelope
      # that still began with those bytes). Same content as before — target,
      # sequence, deploymentIds, empty profileText, no build actions — so every
      # assertion below still means what it meant; only the magic differs. The
      # re-mint used infra's `render-deploy-manifest.py`, which is the other
      # implementation of this format, and each envelope was then verified with
      # the real `repro deploy-agent`: trusted → exit 0 / aoConverged,
      # untrusted → exit 2 / aoRejected, with the monotonic floor seeded at
      # u64 max so the trust gate is what is being observed and not the apply.
      trustedAnchorHex = "048bc8d2f7ff0824b8aa2f0b3bebef478c97a122121a3a98d85274d58c1faa7881764fb7d02aea0ff3baf0c2eec3741ad4865dc1795da2768f3884e037a53fa28e";
      trustedManifestB64 = "UkRNRgEAAAARAAAAZGVwbG95LXRhcmdldC0wMDEBAAAAAAAAAAgAAABkZXBsb3ktMQAAAAAAAAAABIvI0vf/CCS4qi8LO+vvR4yXoSISGjqY2FJ01YwfqniBdk+30CrqD/O68MLuw3Qa1IZdwXldonaPOITgN6U/oo4nv4/clnraQz4LLnK6y1TrZRkChcKFhyNx+YzJtreCGQugPjeGrY/Q54FPWvjhd/k0wUMteYrtNCzW5aazRGAS";
      untrustedManifestB64 = "UkRNRgEAAAARAAAAZGVwbG95LXRhcmdldC0wMDEBAAAAAAAAAAoAAABkZXBsb3ktYmFkAAAAAAAAAAAEL/7EVR3dklcGnxK9KHIghcO/yOEiTB/N9d1PkmftEfU0RBA7Yof9I0ulbaTnKfD7OmYtyeyonrWdmLZf8vWGs/Iq2S1MHACAkTZyHhuByJj6BRLS07Z1/zxziMqbecf453pyjRrkIeq5BPp0Na4Mj/GZ65LYbNBqcPoM+ziTi/8=";

      # Real RDMF manifest bytes on disk (base64-decoded at build time).
      manifestFixtures =
        pkgs.runCommand "repro-deploy-agent-manifest-fixtures" { nativeBuildInputs = [ pkgs.coreutils ]; }
          ''
            mkdir -p "$out"
            printf '%s' '${trustedManifestB64}' | base64 -d > "$out/latest.rdm"
            printf '%s' '${untrustedManifestB64}' | base64 -d > "$out/untrusted.rdm"
            printf '%s\n' '${trustedAnchorHex}' > "$out/allowed-signers"
          '';

      # Deterministic self-signed ECDSA-P256 cert/key, SANs covering how each
      # client reaches the server (hostname `server`, loopback, IP). Used both
      # for the cache HTTPS listener and the nginx manifest vhost, and as the CA
      # the agent + curl pin.
      tlsCerts = pkgs.runCommand "repro-deploy-agent-tls" { nativeBuildInputs = [ pkgs.openssl ]; } ''
        mkdir -p "$out"
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
          -keyout "$out/key.pem" -out "$out/cert.pem" -days 3650 -nodes \
          -subj "/CN=server" \
          -addext "subjectAltName=DNS:server,DNS:localhost,IP:127.0.0.1" 2>/dev/null
        chmod 0644 "$out/key.pem" "$out/cert.pem"
      '';
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_repro_deploy_agent_https_converges = pkgs.testers.nixosTest {
          name = "t_repro_deploy_agent_https_converges";

          nodes.server =
            { config, ... }:
            {
              imports = [ flake.modules.nixos.mcl-repro-binary-cache ];
              environment.systemPackages = [
                pkgs.curl
                repro
              ];

              # M7-extended cache module: HTTPS (self-signed cert) + publish
              # allowlist. Only the trusted anchor may publish.
              services.mcl-repro-binary-cache = {
                enable = true;
                package = reproBinaryCache;
                listenAddress = "0.0.0.0";
                port = 7878;
                openFirewall = true;
                tlsCertFile = "${tlsCerts}/cert.pem";
                tlsKeyFile = "${tlsCerts}/key.pem";
                allowedSignersFile = "${manifestFixtures}/allowed-signers";
              };

              # Serve the signed RDMF manifest over HTTPS (a separate vhost — the
              # cache daemon only serves /manifests/<hex> + /payloads/<hex>).
              services.nginx = {
                enable = true;
                virtualHosts."server" = {
                  onlySSL = true;
                  sslCertificate = "${tlsCerts}/cert.pem";
                  sslCertificateKey = "${tlsCerts}/key.pem";
                  root = "${manifestFixtures}";
                };
              };
              networking.firewall.allowedTCPPorts = [ 443 ];
            };

          nodes.agent =
            { ... }:
            {
              imports = [ flake.modules.nixos.mcl-repro-deploy-agent ];
              environment.systemPackages = [
                pkgs.curl
                repro
              ];

              # The production reprobuild deploy-agent unit, opt-in, targeting
              # deploy-target-001, pulling the signed manifest over HTTPS and
              # trusting the server's self-signed CA + the manifest signer.
              services.mcl-repro-deploy-agent = {
                enable = true;
                package = repro;
                targetName = "deploy-target-001";
                manifestSources = [ "https://server/latest.rdm" ];
                allowedSigners = [ trustedAnchorHex ];
                caFile = "${tlsCerts}/cert.pem";
                # Don't fire on boot before the server is up — the test triggers
                # ticks explicitly.
                runOnBoot = false;
              };
            };

          testScript = ''
            start_all()

            server.wait_for_unit("multi-user.target")
            agent.wait_for_unit("multi-user.target")

            server.wait_for_unit("mcl-repro-binary-cache.service")
            server.wait_for_open_port(7878)
            server.wait_for_unit("nginx.service")
            server.wait_for_open_port(443)

            ca = "${tlsCerts}/cert.pem"

            with subtest("the cache daemon speaks REAL TLS on :7878 (verified against the CA)"):
                # With the CA pinned, /healthz over HTTPS returns "ok".
                healthz = server.succeed(
                    f"curl -sS --cacert {ca} https://localhost:7878/healthz"
                ).strip()
                assert healthz == "ok", f"https healthz body={healthz!r}"

            with subtest("the TLS is genuine — verification FAILS without the CA, and plaintext is refused"):
                # No --cacert: the self-signed cert is untrusted -> curl fails
                # (exit non-zero). Proves a real cert is presented + verified.
                rc = server.execute(
                    "curl -sS -o /dev/null https://localhost:7878/healthz"
                )[0]
                assert rc != 0, "https without CA unexpectedly succeeded (TLS not real?)"
                # Plaintext HTTP against the TLS port must NOT yield a valid
                # HTTP status line (the port genuinely negotiates TLS).
                plain = server.execute(
                    "curl -sS -o /dev/null -w '%{http_code}' http://localhost:7878/healthz"
                )
                assert plain[0] != 0 or plain[1].strip() in ("", "000"), (
                    f"plaintext against the TLS port unexpectedly worked: {plain!r}"
                )

            with subtest("cross-host: the agent reaches the cache over TLS with the pinned CA"):
                agent.wait_until_succeeds(
                    f"curl -sS --cacert {ca} https://server:7878/healthz", timeout=60
                )
                h = agent.succeed(f"curl -sS --cacert {ca} https://server:7878/healthz").strip()
                assert h == "ok", f"cross-host https healthz={h!r}"

            with subtest("publish AUTHZ is enforced: a non-allowlisted producer is rejected HTTP 403"):
                # Generate a FRESH (random) producer keypair on the agent — this
                # producer is NOT in the server's allowlist. Derive a content
                # key for a synthetic prefix and try to publish it to the HTTPS
                # cache. The publish is a REAL ECDSA-P256-signed manifest over
                # REAL TLS; the daemon verifies the signature (valid) but the
                # producer pubkey is not allowlisted, so it returns HTTP 403 and
                # stores nothing.
                agent.succeed("mkdir -p /tmp/pfx/bin && printf 'PAYLOAD' > /tmp/pfx/bin/tool.txt")
                env = (
                    f"REPRO_BINARY_CACHE_URL=https://server:7878 "
                    f"REPRO_BINARY_CACHE_CA_FILE={ca} "
                    f"REPRO_BINARY_CACHE_KEY_PATH=/tmp/prod.key "
                    f"REPRO_BINARY_CACHE_CERT_PATH=/tmp/prod.pub "
                )
                # gen-key prints the producer pubkey hex (proves a real key).
                pub = agent.succeed(
                    f"env {env} repro cache gen-key"
                ).strip()
                assert len(pub) == 130, f"unexpected producer pubkey: {pub!r}"
                assert pub != "${trustedAnchorHex}", "fresh producer key collided with the trusted anchor"
                key = agent.succeed(
                    "env "
                    "repro cache derive-key "
                    "--package-name=unauthorized --package-version=1 "
                    "--platform-cpu=x86_64 --platform-os=linux "
                    "--toolchain-name=none --toolchain-version=0"
                ).strip()
                out = agent.execute(
                    f"env {env} repro cache publish {key} /tmp/pfx "
                    "--package-name=unauthorized --package-version=1 "
                    "--platform-cpu=x86_64 --platform-os=linux "
                    "--toolchain-name=none --toolchain-version=0 2>&1"
                )
                print("unauthorized publish output:\n" + out[1])
                # The publish must be refused — non-zero exit AND a 403 signal.
                assert out[0] != 0, f"unauthorized publish unexpectedly succeeded: {out!r}"
                assert "403" in out[1], f"publish rejection was not an HTTP 403: {out[1]!r}"
                # And nothing was stored: the manifest key must 404 on the server.
                st = server.succeed(
                    f"curl -sS --cacert {ca} -o /dev/null -w '%{{http_code}}' "
                    f"https://localhost:7878/manifests/{key}"
                ).strip()
                assert st == "404", f"rejected publish left a manifest behind: {st!r}"

            with subtest("the deploy-agent unit exists, is a oneshot+timer, and is wired to the HTTPS source"):
                service_type = agent.succeed(
                    "systemctl show -p Type --value mcl-repro-deploy-agent.service"
                ).strip()
                assert service_type == "oneshot", f"unexpected Type={service_type!r}"
                agent.succeed("systemctl cat mcl-repro-deploy-agent.timer >/dev/null")
                execstart = agent.succeed(
                    "systemctl show -p ExecStart --value mcl-repro-deploy-agent.service"
                )
                assert "deploy-agent" in execstart, execstart
                assert "https://server/latest.rdm" in execstart, execstart
                assert "deploy-target-001" in execstart, execstart

            with subtest("REAL signed-manifest fetch over HTTPS: the agent accepts the trusted manifest"):
                # Trigger one tick. The agent fetches the RDMF manifest over TLS
                # from https://server/latest.rdm (verifying the server cert
                # against REPRO_BINARY_CACHE_CA_FILE), decodes it, and verifies
                # its ECDSA-P256 signature against the allowed-signers set. The
                # signer IS allowlisted, so the manifest is accepted and the
                # monotonic floor advances to sequence 1 (the durable
                # last-applied-sequence file appears).
                agent.execute("systemctl start mcl-repro-deploy-agent.service")
                jrnl = agent.succeed(
                    "journalctl -u mcl-repro-deploy-agent.service --no-pager | tail -60"
                )
                print("deploy-agent journal (trusted):\n" + jrnl)
                # Non-fatal fetch is the crux; the outcome line reports the kind.
                # A verification failure would print 'rejected'/'verification';
                # a TLS failure would print a certificate/handshake error. Assert
                # neither appears and that a real fetch+decode happened.
                low = jrnl.lower()
                assert "verification_failed" not in low and "rejected" not in low, (
                    "trusted manifest was rejected — signature/allowlist gate misfired:\n" + jrnl
                )
                assert "certificate" not in low and "handshake" not in low and "requires -d:ssl" not in low, (
                    "TLS fetch of the trusted manifest failed:\n" + jrnl
                )
                # The durable monotonic floor for this target advanced to 1,
                # which only happens AFTER a successful apply of the fetched,
                # verified, sequence-1 manifest.
                agent.wait_until_succeeds(
                    "test -f /var/lib/repro-deploy-agent/deploy-agent/deploy-target-001.seq",
                    timeout=30,
                )
                floor = agent.succeed(
                    "cat /var/lib/repro-deploy-agent/deploy-agent/deploy-target-001.seq"
                ).strip()
                assert floor == "1", f"last-applied floor did not advance to 1: {floor!r}"

            with subtest("REAL signature gate: a manifest signed by a NON-allowlisted key is REJECTED"):
                # Point the SAME agent binary at the untrusted-signer manifest
                # (same target/sequence, cryptographically-valid signature by a
                # key that is NOT in the allowed-signers set). It must be
                # rejected (exit 2), the apply hook must NOT run, and the floor
                # must NOT change.
                out = agent.execute(
                    "env REPRO_BINARY_CACHE_CA_FILE=" + ca + " "
                    "repro deploy-agent "
                    "--target deploy-target-001 "
                    "--manifest https://server/untrusted.rdm "
                    "--allowed-signers ${manifestFixtures}/allowed-signers "
                    "--state-dir /tmp/agent-untrusted-state 2>&1"
                )
                print("untrusted deploy-agent output:\n" + out[1])
                assert out[0] == 2, f"untrusted manifest not rejected with exit 2: rc={out[0]} out={out[1]!r}"
                assert "aoRejected" in out[1] or "rejected" in out[1].lower() \
                    or "verification_failed" in out[1], \
                    f"rejection reason not surfaced: {out[1]!r}"
                # No floor file created for the untrusted attempt.
                assert agent.execute(
                    "test -f /tmp/agent-untrusted-state/deploy-agent/deploy-target-001.seq"
                )[0] != 0, "untrusted manifest wrongly advanced a floor"
          '';
        };
      };
    };
}
