top@{ ... }:
{
  # S3-Artifact-Store gate: t_s3_artifact_store_acl_and_creds.
  #
  # Boots a two-node NixOS network:
  #   * `server`  runs `mcl.s3-artifact-store` (Garage behind the nginx VPN
  #     ACL). Its allowed CIDR is the subnet of `allowed`.
  #   * `allowed` sits in the ACL-permitted subnet.
  #   * `denied`  sits OUTSIDE the ACL-permitted subnet.
  #
  # It asserts the SAME defence-in-depth the Attic cache enforces:
  #   1. Layer-1 VPN gate: nginx returns 403 to `denied` (wrong source net)
  #      BEFORE any credential is evaluated, and reaches Garage from
  #      `allowed`.
  #   2. Layer-2 credentials: an anonymous / invalid-credential request is
  #      rejected (Garage returns 403 AccessDenied), while a valid
  #      bucket-scoped key minted on-host by `mcl-garage-issue-key` performs a
  #      put/get round-trip through the nginx-proxied endpoint.
  #   3. Lifecycle: the managed bucket has the S3 expiry rule configured
  #      (mirrors the artifact retention-days).
  #
  # Runs entirely against plain HTTP inside the VM network (ACME/TLS is a prod
  # concern), by overriding the vhost's forceSSL/enableACME in the test while
  # keeping the module's real ACL + proxy locations intact.
  perSystem =
    {
      pkgs,
      lib,
      ...
    }:
    let
      flake = top.config.flake;

      # Deterministic Garage env for the hermetic test (never used in prod).
      # 32-byte hex rpc secret + an admin token.
      testEnvFile = pkgs.writeText "garage-test.env" ''
        GARAGE_RPC_SECRET=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
        GARAGE_ADMIN_TOKEN=test-admin-token
      '';

      # All three nodes share the default test VLAN (192.168.1.0/24). NixOS
      # assigns IPs ALPHABETICALLY by node name: allowed=.1, denied=.2,
      # server=.3. The ACL allows ONLY the `allowed` node's /32, so `denied`
      # (same subnet, same link) is rejected purely by the nginx source ACL —
      # a precise test of layer 1 that does not depend on multi-VLAN routing.
      serverIp = "192.168.1.3";
      allowedIp = "192.168.1.1";
      allowedCidr = "${allowedIp}/32";
      bucket = "ci-artifacts";
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_s3_artifact_store_acl_and_creds = pkgs.testers.nixosTest {
          name = "t_s3_artifact_store_acl_and_creds";

          nodes.server =
            { ... }:
            {
              imports = [ flake.modules.nixos.mcl-s3-artifact-store ];
              networking.firewall.allowedTCPPorts = [
                80
                443
              ];
              environment.systemPackages = [
                pkgs.awscli2
                pkgs.jq
                pkgs.acl # getfacl/setfacl for the traverse-ACL repro + assertion
              ];
              # Reproduce the REAL prod failure mode that the OLD `/srv` dataDir
              # MISSED.
              #
              # On high-mem-server the dataDir (`/storage/s3-artifact-store/data`)
              # lives under `/storage`, which is mode 0770 `root:metacraft` — NOT
              # world-traversable. The static `garage` system user is not in the
              # `metacraft` group and has no ACL entry, so it cannot TRAVERSE
              # `/storage` to reach its own data dir and garage dies with
              # `Unable to create Garage data directory: … Permission denied
              # (os error 13)` — regardless of the systemd sandbox (confirmed live
              # with `ProtectSystem=no`: still EACCES; the sandbox was never the
              # blocker). The infra layer fixes it with a POSIX-ACL traverse grant
              # `a+ /storage … u:garage:x`, exactly like the download-cache/garm
              # services already do for their users. The OLD test used
              # `dataDir=/srv/s3-store/data` under a world-traversable `/srv`
              # (0755), so garage could always reach it and the test passed while
              # prod failed.
              #
              # To reproduce hermetically: put the dataDir under a NON-traversable
              # `/teststore` (0770 root:root — garage is not in root's group), and
              # apply the SAME traverse-ACL fix the infra layer applies in prod.
              # A toggle (`storeTraverseAcl`, flipped by the non-vacuity probe)
              # controls whether the ACL is granted, so removing the fix
              # reproduces the exact prod EACCES.
              mcl.s3-artifact-store = {
                enable = true;
                domain = "s3.test.local";
                environmentFile = testEnvFile;
                nodeCapacity = "1G";
                dataDir = "/teststore/s3-artifact-store/data";
                metadataDir = "/var/lib/garage/meta";
                networkAcl.allow = [ allowedCidr ]; # only the `allowed` node /32
                buckets = [
                  {
                    name = bucket;
                    lifecycleExpiryDays = 1;
                  }
                ];
              };

              # Stand in for the prod `/storage` parent: a NON-world-traversable
              # 0770 root:root dir, PLUS the infra-layer traverse-ACL fix under
              # test. Created before the module's `garage-storage-dirs` pre-start
              # oneshot. `garage` cannot traverse the 0770 dir by unix bits alone;
              # only the `setfacl -m u:garage:x` grant (the exact analog of the
              # infra `a+ /storage … u:garage:x` tmpfiles rule) lets it through.
              # The `MCL_TEST_GRANT_GARAGE_ACL` toggle below is flipped OFF by the
              # non-vacuity probe to reproduce the prod EACCES boot failure.
              systemd.services.test-storage-parent = {
                description = "Create the non-traversable /teststore parent (prod /storage analog) + traverse ACL";
                wantedBy = [ "multi-user.target" ];
                after = [ "local-fs.target" ];
                before = [ "garage-storage-dirs.service" ];
                requiredBy = [ "garage-storage-dirs.service" ];
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                };
                path = [
                  pkgs.coreutils
                  pkgs.acl
                ];
                script = ''
                  set -euo pipefail
                  mkdir -p /teststore
                  chown root:root /teststore
                  chmod 0770 /teststore
                  # THE FIX under test: grant garage execute-only (traverse) on the
                  # 0770 parent. Toggle default = grant; the probe unsets it.
                  if [ "''${MCL_TEST_GRANT_GARAGE_ACL:-1}" = "1" ]; then
                    setfacl -m u:garage:x /teststore
                  fi
                '';
                environment.MCL_TEST_GRANT_GARAGE_ACL = "1";
              };
              # The module supplies the vhost + ACL but (like attic-cache-host)
              # does NOT own `services.nginx.enable` — that is the shared nginx
              # config's job in prod. Enable it here so the ACL is served.
              services.nginx.enable = true;
              # ACME/TLS cannot be provisioned hermetically; test the ACL +
              # proxy at plain HTTP while keeping the module's real locations.
              services.nginx.virtualHosts."s3.test.local" = {
                forceSSL = lib.mkForce false;
                enableACME = lib.mkForce false;
                acmeRoot = lib.mkForce null;
              };
              security.acme.certs = lib.mkForce { };
              security.acme.acceptTerms = true;
              security.acme.defaults.email = "test@test.local";
            };

          # Allowed consumer (.2, in the /32 ACL). Resolves the vhost name to
          # the server so SigV4's Host matches nginx's server_name.
          nodes.allowed =
            { ... }:
            {
              environment.systemPackages = [
                pkgs.curl
                pkgs.awscli2
              ];
              networking.extraHosts = "${serverIp} s3.test.local";
            };

          # Denied consumer (.3, NOT in the ACL). Same subnet + link as
          # `allowed`; rejected purely by the nginx source ACL.
          nodes.denied =
            { ... }:
            {
              environment.systemPackages = [ pkgs.curl ];
              networking.extraHosts = "${serverIp} s3.test.local";
            };

          testScript = ''
            import json

            start_all()
            server.wait_for_unit("multi-user.target")

            with subtest("non-traversable parent + strict-sandbox: garage.service STARTS when its dataDir is under a 0770 parent it can only traverse via ACL"):
                # The regression this guards (the REAL prod failure mode): the
                # dataDir sits under a NON-world-traversable 0770 root:root parent
                # (`/teststore`, the prod `/storage` analog). `garage` is not in
                # root's group, so without an ACL it cannot traverse the parent to
                # reach its own data dir and dies with `Unable to create Garage
                # data directory: … Permission denied (os error 13)` — regardless
                # of the sandbox. Assert the traverse-ACL was granted, the parent
                # is genuinely 0770 (else the repro is vacuous), the pre-start dir
                # oneshot ran, both dirs exist owned by `garage`, and garage is
                # genuinely ACTIVE. Also assert the sandbox stays STRICT (the fix
                # is a filesystem ACL, NOT a sandbox downgrade).
                server.wait_for_unit("test-storage-parent.service")
                server.wait_for_unit("garage-storage-dirs.service")
                # The parent must really be non-world-traversable (0770), else a
                # world-traversable dir would let garage through and the repro
                # would be vacuous (the /srv trap the old test fell into).
                server.succeed("test \"$(stat -c '%a' /teststore)\" = 770")
                # The traverse ACL for garage must be present (the fix under test).
                server.succeed("getfacl -p /teststore | grep -qx 'user:garage:--x'")
                server.wait_for_unit("garage.service")
                server.require_unit_state("garage.service", "active")
                server.succeed("test -d /teststore/s3-artifact-store/data")
                server.succeed("test -d /var/lib/garage/meta")
                server.succeed("test \"$(stat -c '%U' /teststore/s3-artifact-store/data)\" = garage")
                server.succeed("test \"$(stat -c '%U' /var/lib/garage/meta)\" = garage")
                # The sandbox must remain STRICT — the fix must not weaken it.
                server.succeed(
                    "systemctl show garage.service -p ProtectSystem | grep -qx 'ProtectSystem=strict'"
                )

            server.wait_for_open_port(3900)
            # The bootstrap unit applies the single-node layout, creates the
            # bucket, and sets the lifecycle rule.
            server.wait_for_unit("s3-artifact-store-bootstrap.service")
            server.wait_for_unit("nginx.service")
            server.wait_for_open_port(80)
            allowed.wait_for_unit("multi-user.target")
            denied.wait_for_unit("multi-user.target")

            with subtest("layer-1 ACL: a source OUTSIDE the allowed net is denied by nginx (403) before credentials"):
                # `denied` (.3) shares the subnet+link with `allowed` (.2) but
                # is outside the /32 ACL, so nginx must reject it with 403.
                status = denied.succeed(
                    "curl -s --max-time 20 -o /dev/null -w '%{http_code}' http://s3.test.local/"
                ).strip()
                assert status == "403", f"expected 403 from denied net, got {status!r}"

            with subtest("layer-1 ACL: an allowed source reaches Garage through nginx"):
                # nginx proxies the request to Garage, which answers an
                # unauthenticated request with an S3 error body (NOT an nginx
                # deny page) — proving the request was proxied, not blocked.
                out = allowed.succeed("curl -s http://s3.test.local/ ; true")
                assert "AccessDenied" in out or "<?xml" in out or "Error" in out, (
                    f"expected an S3 error body from Garage, got: {out!r}"
                )

            with subtest("layer-2 credentials: an anonymous/invalid request is denied (403)"):
                # Through the allowed net (so it is NOT an ACL 403), an
                # unauthenticated bucket write is rejected by Garage.
                status = allowed.succeed(
                    "curl -s -o /dev/null -w '%{http_code}' -X PUT "
                    "--data-binary 'x' http://s3.test.local/ci-artifacts/anon.txt"
                ).strip()
                assert status == "403", f"anonymous write should be 403, got {status!r}"

            with subtest("layer-2 credentials: mint a bucket-scoped CI key on-host and round-trip put/get"):
                keyjson = server.succeed("mcl-garage-issue-key ci-test write ci-artifacts")
                key = json.loads(keyjson.strip().splitlines()[-1])
                key_id = key["keyId"]
                secret = key["secretKey"]
                assert key_id.startswith("GK"), f"unexpected key id {key_id!r}"

                aws = (
                    f"AWS_ACCESS_KEY_ID={key_id} AWS_SECRET_ACCESS_KEY={secret} "
                    "AWS_EC2_METADATA_DISABLED=true "
                    "aws --endpoint-url http://s3.test.local --region garage s3"
                )
                # Round-trip through the nginx-proxied endpoint from the allowed
                # net using the scoped credential.
                allowed.succeed("echo hello-artifact > /tmp/probe.txt")
                allowed.succeed(f"{aws} cp /tmp/probe.txt s3://ci-artifacts/probe.txt")
                allowed.succeed(f"{aws} cp s3://ci-artifacts/probe.txt /tmp/got.txt")
                got = allowed.succeed("cat /tmp/got.txt").strip()
                assert got == "hello-artifact", f"round-trip mismatch: {got!r}"

            with subtest("lifecycle: the bucket has the S3 expiry rule configured"):
                lc = server.succeed(
                    f"AWS_ACCESS_KEY_ID={key_id} AWS_SECRET_ACCESS_KEY={secret} "
                    "AWS_EC2_METADATA_DISABLED=true "
                    "aws --endpoint-url http://127.0.0.1:3900 --region garage "
                    "s3api get-bucket-lifecycle-configuration --bucket ci-artifacts"
                )
                data = json.loads(lc)
                rules = data.get("Rules", [])
                assert any(
                    r.get("Expiration", {}).get("Days") == 1 for r in rules
                ), f"expected a 1-day expiry rule, got {rules!r}"
          '';
        };
      };
    };
}
