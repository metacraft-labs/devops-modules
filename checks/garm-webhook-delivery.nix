top@{ ... }:
{
  # Runner-Fleet-Capability-Pools-And-Remote-Driving campaign, milestone RC3.
  #
  # gate: t_garm_webhook_delivery
  #
  # Proves the RC3 public-webhook contract HERMETICALLY — no real GitHub, no real
  # Cloudflare — end to end through the general `garm-webhook-endpoint` module in
  # its DEFAULT `netbird-relay` mode (nginx TLS reverse proxy, GitHub-IP-pinned,
  # forwarding the RAW body). Two nodes:
  #
  #   garm    — the central GARM host: the faithful GARM `/webhooks` stand-in
  #             (checks/garm-webhook-upstream.py — HMAC contract copied from the
  #             pinned garm source, emits garm_webhook_received{valid,reason}) on
  #             127.0.0.1:9997, the garm-webhook-endpoint relay on :443 for
  #             `ci-webhook.test` (self-signed), and the garm-fleet-external-checks
  #             exporter (delivery-ledger + blackbox probe).
  #   github  — simulates GitHub: signs a workflow_job body with the shared
  #             secret and POSTs through the relay; also serves the GitHub API
  #             deliveries fixture the exporter reads.
  #
  # Asserted:
  #   (1) HMAC VALID -> accepted: a correctly-signed workflow_job POST from an
  #       allowed (GitHub-range) source is forwarded and GARM increments
  #       garm_webhook_received{valid="true"}.
  #   (2) HMAC TAMPERED -> rejected: a stale-signature body is 401'd and GARM
  #       increments garm_webhook_received{valid="false",reason="signature_invalid"}.
  #   (3) GitHub-IP pinning: a POST from a source OUTSIDE the pinned ranges is
  #       403'd by the relay and never reaches GARM.
  #   (4) delivery-health external check FIRES on a non-2xx delivery fixture:
  #       github_webhook_last_delivery_ok == 0 + deliveries_failed_total >= 1.
  #   (5) blackbox probe: probe_success == 1 for the live endpoint (it answers,
  #       even a 403), == 0 for a dead endpoint.
  #
  # (1)/(2)/(4)/(5) are exactly the samples the RE1b GarmWebhookHmacFailures /
  # GithubWebhookDeliveryFailing / GithubWebhookEndpointProbeDown alerts key on.
  perSystem =
    {
      pkgs,
      lib,
      self',
      ...
    }:
    let
      flake = top.config.flake;

      secret = "test-webhook-secret-rc3-0123456789abcdef";
      hostname = "ci-webhook.test";

      garmIp = "192.168.1.1";
      githubIp = "192.168.1.2";
      upstreamPort = 9997;
      fixturePort = 8080;

      py = pkgs.python3;

      upstreamScript = ./garm-webhook-upstream.py;
      fixtureScript = ./github-api-fixture.py;

      # The real VM activation creates a fresh test CA at runtime. A cached
      # build-time certificate expires independently of the fixture derivation.
      testCert = "/run/garm-webhook-fixture-tls";

      netModule =
        octet:
        { lib, ... }:
        {
          networking.useDHCP = false;
          networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
            {
              address = "192.168.1.${octet}";
              prefixLength = 24;
            }
          ];
          networking.hosts."${garmIp}" = [ hostname ];
        };
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_garm_webhook_delivery = pkgs.testers.nixosTest {
          name = "t_garm_webhook_delivery";

          nodes.garm =
            { config, pkgs, ... }:
            {
              imports = [
                flake.modules.nixos.garm-webhook-endpoint
                flake.modules.nixos.garm-fleet-external-checks
                (netModule "1")
              ];

              # The faithful GARM /webhooks stand-in.
              systemd.services.garm-webhook-upstream = {
                wantedBy = [ "multi-user.target" ];
                after = [ "network.target" ];
                serviceConfig = {
                  ExecStart = "${py}/bin/python3 ${upstreamScript}";
                  Environment = [
                    "WEBHOOK_SECRET=${secret}"
                    "LISTEN_HOST=127.0.0.1"
                    "LISTEN_PORT=${toString upstreamPort}"
                  ];
                  Restart = "always";
                };
              };

              services.garm-webhook-endpoint = {
                enable = true;
                mode = "netbird-relay";
                publicHostname = hostname;
                upstream = "http://127.0.0.1:${toString upstreamPort}";
                webhookPath = "/webhooks";
                # Pin to the github node ONLY (a /32) — everything else is 403'd.
                githubHookCidrs = [ "${githubIp}/32" ];
                tls.certFile = "${testCert}/cert.pem";
                tls.keyFile = "${testCert}/key.pem";
              };

              # Genuine per-VM TLS material shared by nginx and the strict
              # exporter probe; never reused from the Nix build cache.
              system.activationScripts.webhookFixtureTls.deps = [
                "users"
                "groups"
              ];
              system.activationScripts.webhookFixtureTls.text = ''
                install -d -m 0755 ${testCert} || exit 1
                (
                  umask 077
                  ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 -nodes \
                    -keyout ${testCert}/key.pem -out ${testCert}/cert.pem -days 3 \
                    -subj "/CN=${hostname}" -addext "subjectAltName=DNS:${hostname}"
                ) || exit 1
                chown ${config.services.nginx.user}:${config.services.nginx.group} ${testCert}/key.pem || exit 1
                chmod 0600 ${testCert}/key.pem || exit 1
                chmod 0644 ${testCert}/cert.pem || exit 1
              '';

              # Textfile dir for the exporter (DynamicUser + strict sandbox).
              systemd.tmpfiles.rules = [
                "d /var/lib/node-exporter/textfile 0777 root root -"
              ];
              # Trust the same real runtime test CA for the exporter's HTTPS probe.
              systemd.services.garm-fleet-external-checks.serviceConfig.Environment = [
                "SSL_CERT_FILE=${testCert}/cert.pem"
              ];
              system.activationScripts.gfcToken.text = ''
                mkdir -p /run/gfc
                printf 'dummy-token' > /run/gfc/token
                chmod 0444 /run/gfc/token
              '';

              services.garm-fleet-external-checks = {
                enable = true;
                package = self'.packages.garm-fleet-external-checks;
                apiBase = "http://${githubIp}:${toString fixturePort}";
                webhooks = [
                  {
                    org = "test-org";
                    hookId = 1;
                    tokenFile = "/run/gfc/token";
                  }
                ];
                probes = [
                  {
                    name = "live";
                    url = "https://${hostname}/webhooks";
                  }
                  {
                    name = "dead";
                    url = "http://127.0.0.1:1/webhooks";
                  }
                ];
              };

              environment.systemPackages = [
                pkgs.curl
                pkgs.python3
              ];
              networking.firewall.allowedTCPPorts = [ 443 ];
            };

          nodes.github =
            { pkgs, ... }:
            {
              imports = [ (netModule "2") ];
              environment.systemPackages = [
                pkgs.curl
                pkgs.python3
              ];
              # GitHub API deliveries fixture the exporter reads.
              systemd.services.github-api-fixture = {
                wantedBy = [ "multi-user.target" ];
                after = [ "network.target" ];
                serviceConfig = {
                  ExecStart = "${py}/bin/python3 ${fixtureScript}";
                  Environment = [
                    "FIXTURE_PORT=${toString fixturePort}"
                    "DELIVERY_STATUS=502"
                  ];
                  Restart = "always";
                };
              };
              networking.firewall.allowedTCPPorts = [ fixturePort ];
            };

          testScript =
            { nodes, ... }:
            ''
              start_all()

              garm.wait_for_unit("multi-user.target")
              garm.wait_for_unit("garm-webhook-upstream.service")
              garm.wait_for_unit("nginx.service")
              github.wait_for_unit("multi-user.target")
              github.wait_for_unit("github-api-fixture.service")

              garm.wait_for_open_port(${toString upstreamPort})
              garm.wait_for_open_port(443)
              github.wait_for_open_port(${toString fixturePort})

              SECRET = "${secret}"

              # Stage a canonical workflow_job body + a tampered variant on github.
              github.succeed(
                  "printf '%s' '{\"action\":\"queued\",\"workflow_job\":{\"id\":42,"
                  "\"labels\":[\"self-hosted\",\"linux\",\"x64\"]}}' > /tmp/body.json"
              )
              github.succeed(
                  "printf '%s' '{\"action\":\"queued\",\"workflow_job\":{\"id\":99,"
                  "\"labels\":[\"self-hosted\",\"linux\",\"x64\"]}}' > /tmp/tampered.json"
              )
              # Signature computed over body.json (GitHub's X-Hub-Signature-256).
              sig = github.succeed(
                  "python3 -c \"import hmac,hashlib;"
                  "print('sha256='+hmac.new(b'" + SECRET + "', open('/tmp/body.json','rb').read(), hashlib.sha256).hexdigest())\""
              ).strip()

              def counts():
                  out = garm.succeed("curl -sf http://127.0.0.1:${toString upstreamPort}/metrics")
                  c = {}
                  for line in out.splitlines():
                      if line.startswith("garm_webhook_received"):
                          # garm_webhook_received{valid="x",reason="y"} N
                          key, _, val = line.rpartition(" ")
                          c[key] = int(val)
                  return c

              with subtest("(1) HMAC valid -> forwarded + accepted (valid=true increments)"):
                  before = counts()
                  code = github.succeed(
                      f"curl -k -s -o /dev/null -w '%{{http_code}}' -X POST "
                      f"-H 'X-Hub-Signature-256: {sig}' -H 'X-GitHub-Event: workflow_job' "
                      f"--data-binary @/tmp/body.json https://${hostname}/webhooks"
                  ).strip()
                  assert code == "200", f"valid signed POST expected 200, got {code}"
                  after = counts()
                  key = 'garm_webhook_received{valid="true",reason=""}'
                  assert after.get(key, 0) == before.get(key, 0) + 1, (
                      f"garm_webhook_received valid=true did not increment: {before} -> {after}"
                  )

              with subtest("(2) HMAC tampered -> rejected (valid=false,signature_invalid)"):
                  before = counts()
                  # Same (now stale) signature, DIFFERENT body.
                  code = github.succeed(
                      f"curl -k -s -o /dev/null -w '%{{http_code}}' -X POST "
                      f"-H 'X-Hub-Signature-256: {sig}' -H 'X-GitHub-Event: workflow_job' "
                      f"--data-binary @/tmp/tampered.json https://${hostname}/webhooks"
                  ).strip()
                  assert code == "401", f"tampered POST expected 401, got {code}"
                  after = counts()
                  key = 'garm_webhook_received{valid="false",reason="signature_invalid"}'
                  assert after.get(key, 0) == before.get(key, 0) + 1, (
                      f"garm_webhook_received valid=false did not increment: {before} -> {after}"
                  )

              with subtest("(3) GitHub-IP pinning: a source outside the pinned range is 403'd"):
                  # The garm node's own IP (${garmIp}) is NOT in the pinned /32.
                  code = garm.succeed(
                      f"curl -k -s -o /dev/null -w '%{{http_code}}' -X POST "
                      f"-H 'X-Hub-Signature-256: {sig}' --data-binary @/dev/null "
                      f"https://${hostname}/webhooks"
                  ).strip()
                  assert code == "403", f"off-range POST expected 403, got {code}"

              with subtest("(4)+(5) external delivery-health + blackbox probe fire"):
                  garm.succeed("systemctl start garm-fleet-external-checks.service")
                  garm.wait_until_succeeds(
                      "test -s /var/lib/node-exporter/textfile/garm-fleet-external-checks.prom",
                      timeout=30,
                  )
                  prom = garm.succeed(
                      "cat /var/lib/node-exporter/textfile/garm-fleet-external-checks.prom"
                  )
                  print(prom)
                  # (4) delivery ledger: most-recent delivery was 502 -> ok=0, failures>=1.
                  assert 'github_webhook_last_delivery_ok{org="test-org",hook_id="1"} 0' in prom, prom
                  import re
                  m = re.search(r'github_webhook_deliveries_failed_total\{org="test-org",hook_id="1"\} (\d+)', prom)
                  assert m and int(m.group(1)) >= 1, f"expected >=1 failed deliveries:\n{prom}"
                  # (5) blackbox probe: live endpoint answers (probe_success 1), dead is 0.
                  assert 'probe_success{endpoint="https://${hostname}/webhooks",name="live"} 1' in prom, prom
                  assert 'probe_success{endpoint="http://127.0.0.1:1/webhooks",name="dead"} 0' in prom, prom

              with subtest("real runtime TLS validity and strict untrusted-CA refusal"):
                  garm.succeed("test $(stat -c %U:%G ${testCert}/key.pem) = ${nodes.garm.services.nginx.user}:${nodes.garm.services.nginx.group}")
                  garm.succeed("runuser -u ${nodes.garm.services.nginx.user} -- test -r ${testCert}/key.pem")
                  garm.succeed("${pkgs.openssl}/bin/openssl x509 -in ${testCert}/cert.pem -checkend 0 -noout")
                  garm.succeed("${pkgs.openssl}/bin/openssl x509 -in ${testCert}/cert.pem -checkhost ${hostname} -noout")
                  assert garm.succeed("stat -c %a ${testCert}/key.pem").strip() == "600"
                  assert garm.succeed("stat -c %a ${testCert}/cert.pem").strip() == "644"
                  # A different genuine CA must refuse this otherwise-live endpoint.
                  # Only this test-owned drop-in changes trust; all production probe
                  # code, hostname, TLS verification and metric assertions remain.
                  garm.succeed("install -d -m 0700 /run/garm-webhook-negative-tls")
                  garm.succeed("umask 077; ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout /run/garm-webhook-negative-tls/key.pem -out /run/garm-webhook-negative-tls/cert.pem -days 3 -subj /CN=untrusted-fixture-ca")
                  garm.succeed("chmod 0644 /run/garm-webhook-negative-tls/cert.pem && chmod 0755 /run/garm-webhook-negative-tls")
                  dropin = "/run/systemd/system/garm-fleet-external-checks.service.d/99-owned-tls-negative.conf"
                  garm.succeed(f"test ! -e {dropin} && mkdir -p /run/systemd/system/garm-fleet-external-checks.service.d")
                  original_unit = garm.succeed("systemctl cat garm-fleet-external-checks.service")
                  try:
                      garm.succeed(f"printf '[Service]\\nEnvironment=SSL_CERT_FILE=/run/garm-webhook-negative-tls/cert.pem\\n' > {dropin}")
                      garm.succeed("systemctl daemon-reload && systemctl restart garm-fleet-external-checks.service")
                      negative = garm.succeed("cat /var/lib/node-exporter/textfile/garm-fleet-external-checks.prom")
                      assert 'probe_success{endpoint="https://${hostname}/webhooks",name="live"} 0' in negative, negative
                      assert 'probe_http_status_code{endpoint="https://${hostname}/webhooks",name="live"} 0' in negative, negative
                  finally:
                      garm.succeed(f"rm {dropin} && systemctl daemon-reload")
                  assert garm.succeed("systemctl cat garm-fleet-external-checks.service") == original_unit
                  garm.succeed("systemctl restart garm-fleet-external-checks.service")
                  restored = garm.succeed("cat /var/lib/node-exporter/textfile/garm-fleet-external-checks.prom")
                  assert 'probe_success{endpoint="https://${hostname}/webhooks",name="live"} 1' in restored, restored
                  assert 'probe_success{endpoint="http://127.0.0.1:1/webhooks",name="dead"} 0' in restored, restored

              print("ALL RC3 WEBHOOK-DELIVERY ASSERTIONS PASSED")
            '';
        };
      };
    };
}
