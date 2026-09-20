top@{ ... }:
{
  # Runner-Fleet-Capability-Pools-And-Remote-Driving campaign, milestone RC5.
  #
  # gate: t_pools_cutover_complete
  #
  # The END of the pools migration, asserted HERMETICALLY for the parts that CAN
  # be (the 48h live no-regression soak is the operator's post-cutover
  # validation — see docs/runbooks/Central-GARM-Cutover.runbook.md §RC5 and the
  # infra runbook). Three things this gate proves, all without a live fleet or
  # real GitHub:
  #
  #  (A) OVER-PROVISION rule + alert (the thundering-herd signal). promtool
  #      replays the RC5 `garm-fleet-overprovision` group from the SHIPPED
  #      alert-rule library: silent at ratio ~1 (one ephemeral runner per job),
  #      fires when a provider creates many runners for few served jobs, and
  #      stays silent on a high ratio below the served floor (a warm min-idle
  #      floor during a quiet period is not a herd). This is the same promtool
  #      contract as t_fleet_alerting, run here against the exact rendered rules.
  #
  #  (B) ALIAS-CLASS resolution (the class-by-class, no-flag-day bridge). A pool
  #      declaring `aliasClasses = [ "eph-linux-x64" ]` advertises the legacy
  #      class name ALONGSIDE its derived capability labels, so a job still
  #      naming `runs-on: eph-linux-x64` is a subset of that pool's tags and is
  #      served; a sibling pool WITHOUT the alias does not match it. Then the
  #      alias is DROPPED (pool tags updated to the derived set only) — the FINAL
  #      RC5 step — after which the legacy-named job is a subset of NO pool's tags
  #      and stays queued. GitHub does the runtime match; the gate proves the tags
  #      the match runs against, exactly as t_garm_pools_labels does.
  #
  #  (C) SCALE-SET RETIREMENT (the config path renders + prunes). The controller
  #      is declared in the END state — `mode = "pools"`, `scaleSets = { }`,
  #      `reconcile.pruneUnmanaged = true` — so pools remain and no scale set is
  #      declared. A leftover scale set (simulating the pre-retirement live fleet)
  #      is created directly, then the module's reconcile PRUNES it while leaving
  #      every pool intact: scale sets gone, pools remain. The rollback is
  #      re-adding the `scaleSets` entries (documented in the runbook); it is the
  #      reconcile's normal additive create path, already covered by
  #      t_garm_pools_labels' COEXISTENCE assertion.
  #
  # ONE node, same shape as t_garm_pools_labels: a real `garm.service` + reconcile
  # against the sanctioned mock GitHub management API, dummy providers (backend
  # adds no host groups) each carrying a DISTINCT RA6 manifest fixture so labels
  # are DERIVED, not hand-kept.
  perSystem =
    {
      pkgs,
      lib,
      self',
      ...
    }:
    let
      flake = top.config.flake;

      mockPort = 8099;
      mockGithub = ./garm-pools-mock-github.py;

      # The SHIPPED alert-rule render (default thresholds) + the library's own
      # promtool unit-test file — the RC5 over-provision cases live in it.
      alertRules = self'.packages.garm-fleet-alert-rules;
      alertTest = ../modules/garm-fleet-alerts/tests/fleet-alerting.test.yml;

      appPem = pkgs.runCommand "garm-cutover-test-app.pem" { nativeBuildInputs = [ pkgs.openssl ]; } ''
        openssl genrsa -traditional 2048 > $out
      '';

      # RA6 manifest fixtures (same shape as t_garm_pools_labels): hms proves
      # x86-64-v3 + incus + libvirt + docker, NO gpu; gpu001 proves gpu + incus.
      mkManifest =
        {
          host,
          keyId,
          archLevel ? "x86-64-v3",
          gpu ? false,
          hypervisors,
        }:
        pkgs.writeText "manifest-${host}.json" (
          builtins.toJSON {
            identity = {
              inherit keyId host;
              issuedAt = 1757440000;
              notAfter = 1757443600;
              alg = "hmac-sha256";
              manifest = {
                manifestVersion = "1";
                os = "linux";
                arch = "x86_64";
                inherit archLevel gpu;
                cpuCount = 32;
                memTotalMb = 128000;
                nestedVirt = true;
                docker = true;
                podman = false;
                rrHwCounters = true;
                inherit hypervisors;
              };
            };
            sig = lib.concatStrings (lib.genList (_: "0") 64);
          }
        );

      manifestHms = mkManifest {
        host = "high-mem-server";
        keyId = "vmh1-hms";
        gpu = false;
        hypervisors = [
          {
            id = "incus";
            available = true;
            guests = [ "linux" ];
          }
          {
            id = "libvirt";
            available = true;
            guests = [
              "windows"
              "linux"
            ];
          }
        ];
      };
      manifestGpu001 = mkManifest {
        host = "gpu-server-001";
        keyId = "vmh1-gpu001";
        gpu = true;
        hypervisors = [
          {
            id = "incus";
            available = true;
            guests = [ "linux" ];
          }
        ];
      };

      dummyProvider = manifest: {
        backend = "qemu-windows-arm";
        vmHarnessPath = "/nonexistent/vm-harness";
        stateDir = "/var/lib/garm-provider-vmharness";
        images.golden.sourceImage = "/nonexistent/golden";
        manifestFile = manifest;
      };
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_pools_cutover_complete = pkgs.testers.nixosTest {
          name = "t_pools_cutover_complete";

          nodes.controller =
            { ... }:
            {
              imports = [ flake.modules.nixos.garm ];
              virtualisation.memorySize = 2048;
              environment.systemPackages = [
                pkgs.curl
                pkgs.jq
                pkgs.prometheus.cli # promtool for assertion (A)
                self'.packages.garm
                self'.packages.runner-label-tool
              ];

              systemd.services.mock-github = {
                description = "Mock GitHub management API for the RC5 cutover gate";
                wantedBy = [ "multi-user.target" ];
                before = [ "garm-reconcile.service" ];
                serviceConfig = {
                  ExecStart = "${pkgs.python3}/bin/python3 ${mockGithub}";
                  Environment = [ "MOCK_PORT=${toString mockPort}" ];
                  Restart = "always";
                };
              };

              services.garm = {
                enable = true;
                package = self'.packages.garm;
                # END-STATE declaration: pool mode, NO scale sets.
                mode = "pools";
                apiServer = {
                  bind = "0.0.0.0";
                  port = 9997;
                };
                metrics = {
                  enable = true;
                  disableAuth = true;
                  period = "2s";
                };

                reconcile = {
                  enable = true;
                  # RC5 retirement realises the prune: a live scale set no longer
                  # declared is removed.
                  pruneUnmanaged = true;
                  forgeEndpoint = "mock-github";
                  apiBaseURL = "http://127.0.0.1:${toString mockPort}";
                  baseURL = "http://127.0.0.1:${toString mockPort}";
                };

                github.mcl-app = {
                  appId = 111;
                  installationId = 222;
                  appKeyFile = appPem;
                };

                providers = {
                  hms = dummyProvider manifestHms;
                  gpu001 = dummyProvider manifestGpu001;
                };

                # END-STATE pools. hms-linux carries the legacy alias during the
                # cutover; gpu001-linux never did.
                pools = {
                  hms-linux = {
                    provider = "hms";
                    org = "metacraft-labs";
                    credentials = "mcl-app";
                    image = "golden";
                    osType = "linux";
                    policyLabels = [ "ephemeral" ];
                    aliasClasses = [ "eph-linux-x64" ];
                    maxRunners = 4;
                    minIdleRunners = 0;
                    priority = 10;
                  };
                  gpu001-linux = {
                    provider = "gpu001";
                    org = "metacraft-labs";
                    credentials = "mcl-app";
                    image = "golden";
                    osType = "linux";
                    maxRunners = 2;
                  };
                };

                # No scaleSets — the retirement END state.
                scaleSets = { };
              };
            };

          testScript = ''
            import json as J

            start_all()

            controller.wait_for_unit("multi-user.target")
            controller.wait_for_unit("mock-github.service")
            controller.wait_for_unit("garm.service")
            controller.wait_for_open_port(${toString mockPort})
            controller.wait_for_open_port(9997)
            controller.wait_for_unit("garm-reconcile.service")

            def gcli(args):
                return controller.succeed(
                    f"sudo -u garm env HOME=/var/lib/garm garm-cli --format json {args}"
                )

            def org_id(name):
                for o in J.loads(gcli(f"organization list --name {name}")):
                    if o.get("name") == name:
                        return o["id"]
                raise Exception(f"org {name} not found")

            def tagset(p):
                return set(t["name"] if isinstance(t, dict) else t for t in (p.get("tags") or []))

            oid = org_id("metacraft-labs")

            # =================================================================
            # (A) OVER-PROVISION rule + alert (promtool, hermetic)
            # =================================================================
            controller.succeed("cp ${alertRules} /tmp/garm-fleet-alerts.yml")
            controller.succeed("cp ${alertTest} /tmp/fleet-alerting.test.yml")
            controller.succeed(
                "grep -q 'record: garm:overprovision_ratio' /tmp/garm-fleet-alerts.yml"
            )
            controller.succeed(
                "grep -q 'alert: GarmFleetOverProvision' /tmp/garm-fleet-alerts.yml"
            )
            # check rules parse + the full fault-injection suite (which includes
            # the RC5 over-provision herd/healthy/floor cases) fires/stays-silent
            # exactly as asserted.
            controller.succeed("cd /tmp && promtool check rules garm-fleet-alerts.yml")
            controller.succeed("cd /tmp && promtool test rules fleet-alerting.test.yml")
            print("[A] over-provision recording-rule + GarmFleetOverProvision alert valid; herd fires, ratio~1 and below-floor stay silent")

            # =================================================================
            # (B) ALIAS-CLASS resolution + drop
            # =================================================================
            pools = J.loads(gcli(f"pool list --org {oid}"))
            by_provider: dict = {}
            for p in pools:
                by_provider.setdefault(p.get("provider_name"), []).append(p)
            assert "hms" in by_provider, f"no pool on provider hms: {pools}"
            assert "gpu001" in by_provider, f"no pool on provider gpu001: {pools}"

            hms_pool = by_provider["hms"][0]
            hms_pid = hms_pool["id"]
            hms_tags = tagset(hms_pool)
            gpu_tags = tagset(by_provider["gpu001"][0])

            # The alias name is advertised ALONGSIDE the derived capability labels.
            assert "eph-linux-x64" in hms_tags, f"hms pool must advertise the legacy alias: {sorted(hms_tags)}"
            for req in {"self-hosted", "linux", "x64", "x86-64-v3", "incus", "libvirt", "ephemeral"}:
                assert req in hms_tags, f"hms pool missing derived label {req}: {sorted(hms_tags)}"
            # The non-aliased sibling does NOT carry the legacy name.
            assert "eph-linux-x64" not in gpu_tags, f"gpu001 pool must NOT advertise the legacy alias: {sorted(gpu_tags)}"
            print(f"[B] alias present: hms tags={sorted(hms_tags)}")

            all_tagsets = [tagset(p) for p in pools]
            def any_serves(job):
                return any(set(job) <= ts for ts in all_tagsets)

            legacy_job = ["eph-linux-x64"]
            assert any_serves(legacy_job), (
                f"a legacy-named job matched NO pool while the alias is live: pools={all_tagsets}"
            )
            # It matches the ALIASED pool, not the sibling.
            assert legacy_job[0] in hms_tags and legacy_job[0] not in gpu_tags
            print("[B] legacy `runs-on: eph-linux-x64` is served by the aliased pool")

            # FINAL RC5 STEP: drop the alias — update the pool to the derived set
            # only (mirrors emptying aliasClasses + reconcile).
            derived_only = sorted(hms_tags - {"eph-linux-x64"})
            gcli(f"pool update {hms_pid} --tags {','.join(derived_only)}")
            pools2 = J.loads(gcli(f"pool list --org {oid}"))
            all_tagsets2 = [tagset(p) for p in pools2]
            def any_serves2(job):
                return any(set(job) <= ts for ts in all_tagsets2)
            assert not any_serves2(legacy_job), (
                f"after dropping the alias a legacy-named job still matched a pool: {all_tagsets2}"
            )
            print("[B] alias dropped -> `runs-on: eph-linux-x64` matches no pool and stays queued (the intended end)")

            # =================================================================
            # (C) SCALE-SET RETIREMENT — the config renders (no scale sets) and
            #     the reconcile PRUNES a leftover one while pools remain.
            # =================================================================
            # No scale set is declared, so at boot none exist.
            scalesets0 = J.loads(gcli(f"scaleset list --org {oid}"))
            assert scalesets0 == [] or all(s.get("name") != "legacy-eph" for s in scalesets0), (
                f"unexpected pre-existing scale set: {scalesets0}"
            )

            # Simulate the pre-retirement live fleet: create a leftover scale set
            # directly (the same CLI the old reconcile used).
            gcli(
                f"scaleset add --org {oid} --provider-name hms --image golden "
                f"--name legacy-eph --flavor default --enabled=true "
                f"--min-idle-runners 0 --max-runners 2 --os-type linux --os-arch amd64 "
                f"--runner-bootstrap-timeout 20"
            )
            names_before = [s.get("name") for s in J.loads(gcli(f"scaleset list --org {oid}"))]
            assert "legacy-eph" in names_before, f"leftover scale set not created: {names_before}"

            # Run the END-STATE reconcile (scaleSets = {} + pruneUnmanaged) — it
            # must prune the undeclared scale set and keep the pools. The unit is
            # a RemainAfterExit oneshot, so `restart` (not `start`) forces a fresh
            # run; `restart` blocks until the oneshot completes.
            controller.succeed("systemctl restart garm-reconcile.service")
            names_after = [s.get("name") for s in J.loads(gcli(f"scaleset list --org {oid}"))]
            assert "legacy-eph" not in names_after, (
                f"retirement reconcile did NOT prune the undeclared scale set: {names_after}"
            )
            pools_after = J.loads(gcli(f"pool list --org {oid}"))
            prov_after = {p.get("provider_name") for p in pools_after}
            assert {"hms", "gpu001"} <= prov_after, (
                f"pools were lost during scale-set retirement: {prov_after}"
            )
            print("[C] scale sets retired (leftover pruned); pools remain")

            print("[t_pools_cutover_complete] PASS")
          '';
        };
      };
    };
}
