top@{ ... }:
{
  # Runner-Fleet-Capability-Pools-And-Remote-Driving campaign, milestone RC2.
  #
  # gate: t_garm_pools_labels
  #
  # Proves the Phase-C POOL model at the module level, HERMETICALLY (no live
  # fleet, no real GitHub): the `services.garm` reconcile provisions GARM POOLS
  # (not scale sets) whose classic-runner tag sets are DERIVED at reconcile time
  # from each backing host's RA6-verified `/v1/manifest` via the RC1
  # `runner-label-tool` — closing the RC1(labels)+RA6(manifest) loop the campaign
  # requires ("JIT registration derives the label array from the host's
  # RA6-verified manifest").
  #
  # ONE node: a real `garm.service` (this flake's module) + reconcile pointed at
  # a minimal mock GitHub management API (checks/garm-pools-mock-github.py — the
  # sanctioned stand-in: real GitHub can't be reached hermetically). Three DUMMY
  # providers (backend chosen to add no host groups) each carry a DISTINCT
  # manifest fixture — hms (no GPU, incus+libvirt), gpu-001 & gpu-002 (GPU,
  # incus). `garm-cli pool add` is a pure DB op that never contacts the provider
  # or GitHub, so a dummy provider faithfully exercises the RC2 derive→tag→pool
  # path; the endpoint fetch of `/v1/manifest` is the infra concern (a
  # manifestFile written by the RA6 verify oneshot), modelled here by the fixture.
  #
  # ASSERTIONS:
  #  (1) The reconcile creates one GARM POOL per declared `services.garm.pools`
  #      entry (via `garm-cli pool`, id-tracked — pools have no name).
  #  (2) Each pool's TAGS equal the labels its host's manifest PROVES (RC1
  #      derive): the hms pool carries incus+libvirt+docker+x86-64-v3 but NOT
  #      gpu; the gpu pools carry gpu. Ties RC1+RA6.
  #  (3) `garm_pool_*` metrics APPEAR on /metrics (garm_pool_info with the derived
  #      tags, garm_pool_status, garm_pool_max_runners) — the post-migration
  #      metric family the RE1 alerts key on.
  #  (4) MATCH: a `runs-on: [self-hosted, linux, x64, x86-64-v3]` job's labels are
  #      a subset of a qualifying pool's tags (would be served). NO-MATCH: a job
  #      requesting `x86-64-v4` — which NO host proves — is a subset of NO pool's
  #      tags, so it stays queued (correctly). Asserted over the ACTUAL reconciled
  #      pool tag sets (GitHub does the runtime match; the gate proves the tags).
  #  (5) FAIL-CLOSED: a pool that DECLARES a label its manifest does not prove
  #      (gpu on the non-GPU hms host) is REFUSED by the reconcile (advertised ⊄
  #      derived) — no pool is created for it.
  #  (6) COEXISTENCE: a scale set declared alongside the pools is ALSO reconciled
  #      — scale sets and pools run in parallel for the RC5 cutover.
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

      appPem = pkgs.runCommand "garm-pools-test-app.pem" { nativeBuildInputs = [ pkgs.openssl ]; } ''
        openssl genrsa -traditional 2048 > $out
      '';

      # RA6 manifest fixtures — DISTINCT capability profiles per host. All linux
      # x86_64; hms proves x86-64-v3 + incus + libvirt + docker but NO gpu, the
      # two GPU hosts prove gpu + incus. NONE proves x86-64-v4 (so a v4 job is the
      # unambiguous "stays queued" case) or podman.
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
      manifestGpu002 = mkManifest {
        host = "gpu-server-002";
        keyId = "vmh1-gpu002";
        gpu = true;
        hypervisors = [
          {
            id = "incus";
            available = true;
            guests = [ "linux" ];
          }
        ];
      };

      # A dummy provider whose backend needs no host daemon/groups (mirrors
      # garm-reconcile's approach) — the reconcile only NAMES the provider on
      # pool add; no provider process is ever contacted. manifestFile is what
      # drives label derivation.
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
        t_garm_pools_labels = pkgs.testers.nixosTest {
          name = "t_garm_pools_labels";

          nodes.controller =
            { ... }:
            {
              imports = [ flake.modules.nixos.garm ];
              virtualisation.memorySize = 2048;
              environment.systemPackages = [
                pkgs.curl
                pkgs.jq
                self'.packages.garm
                self'.packages.runner-label-tool
              ];

              systemd.services.mock-github = {
                description = "Mock GitHub management API for the pool gate";
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
                # POOL mode — the declaration the cutover flips.
                mode = "pools";
                apiServer = {
                  bind = "0.0.0.0";
                  port = 9997;
                };
                # Metrics on + unauthenticated + fast refresh so garm_pool_* show
                # up quickly on /metrics.
                metrics = {
                  enable = true;
                  disableAuth = true;
                  period = "2s";
                };

                reconcile = {
                  enable = true;
                  pruneUnmanaged = false;
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
                  gpu002 = dummyProvider manifestGpu002;
                };

                # RC2 explicit capability pools — one per host. Tags DERIVED from
                # each provider's manifestFile.
                pools = {
                  hms-linux = {
                    provider = "hms";
                    org = "metacraft-labs";
                    credentials = "mcl-app";
                    image = "golden";
                    osType = "linux";
                    policyLabels = [ "ephemeral" ];
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
                  gpu002-linux = {
                    provider = "gpu002";
                    org = "metacraft-labs";
                    credentials = "mcl-app";
                    image = "golden";
                    osType = "linux";
                    maxRunners = 2;
                  };
                  # FAIL-CLOSED: declares `gpu` on the NON-GPU hms host — the
                  # reconcile must refuse this pool (advertised ⊄ derived).
                  hms-overclaim = {
                    provider = "hms";
                    org = "metacraft-labs";
                    credentials = "mcl-app";
                    image = "golden";
                    osType = "linux";
                    labels = [
                      "self-hosted"
                      "linux"
                      "x64"
                      "gpu"
                    ];
                    maxRunners = 1;
                  };
                };

                # COEXISTENCE: a scale set beside the pools (RC5 retires it).
                scaleSets.legacy-eph = {
                  provider = "hms";
                  org = "metacraft-labs";
                  credentials = "mcl-app";
                  image = "golden";
                  osType = "linux";
                  maxRunners = 2;
                  scaleSetName = "legacy-eph";
                };
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

            oid = org_id("metacraft-labs")

            # --- (1) POOLS created (not scale sets) --------------------------
            pools = J.loads(gcli(f"pool list --org {oid}"))
            # tags come back as a list of {name:...}; normalise to a set of str.
            def tagset(p):
                return set(t["name"] if isinstance(t, dict) else t for t in (p.get("tags") or []))
            by_provider: dict = {}
            for p in pools:
                by_provider.setdefault(p.get("provider_name"), []).append(p)

            assert "hms" in by_provider, f"no pool on provider hms: {pools}"
            assert "gpu001" in by_provider, f"no pool on provider gpu001: {pools}"
            assert "gpu002" in by_provider, f"no pool on provider gpu002: {pools}"

            # (5) FAIL-CLOSED: hms has exactly ONE pool (the over-claim pool was
            # refused — hms would otherwise have two).
            assert len(by_provider["hms"]) == 1, (
                f"hms should back exactly one pool (over-claim refused), got "
                f"{len(by_provider['hms'])}: {by_provider['hms']}"
            )
            print("[pools] one pool per host; the gpu over-claim on hms was refused")

            # --- (2) TAGS are the DERIVED (proven) label sets ----------------
            hms_tags = tagset(by_provider["hms"][0])
            gpu001_tags = tagset(by_provider["gpu001"][0])
            for req in {"self-hosted", "linux", "x64", "x86-64-v3", "x86-64-v2",
                        "incus", "libvirt", "docker", "ephemeral"}:
                assert req in hms_tags, f"hms pool missing derived label {req}: {hms_tags}"
            assert "gpu" not in hms_tags, f"hms pool must NOT advertise gpu: {hms_tags}"
            assert "podman" not in hms_tags, f"hms pool must NOT advertise podman: {hms_tags}"
            assert "gpu" in gpu001_tags, f"gpu001 pool must advertise gpu: {gpu001_tags}"
            print(f"[derive] hms tags={sorted(hms_tags)}")
            print(f"[derive] gpu001 tags={sorted(gpu001_tags)}")

            # --- (3) garm_pool_* metrics appear ------------------------------
            def metrics():
                return controller.wait_until_succeeds(
                    "curl -sf http://127.0.0.1:9997/metrics | grep '^garm_pool_' | head -200",
                    timeout=30,
                )
            m = metrics()
            assert "garm_pool_info{" in m, f"garm_pool_info missing from /metrics:\n{m}"
            assert "garm_pool_status{" in m, f"garm_pool_status missing:\n{m}"
            assert "garm_pool_max_runners{" in m, f"garm_pool_max_runners missing:\n{m}"
            # the derived tags surface on the info metric's `tags` label
            assert "x86-64-v3" in m, f"derived tags not on garm_pool_info:\n{m}"
            print("[metrics] garm_pool_* present with derived tags")

            # --- (4) MATCH / NO-MATCH (GitHub's job<-runner subset rule) -----
            all_tagsets = [tagset(p) for p in pools]
            def any_serves(job):
                return any(set(job) <= ts for ts in all_tagsets)

            match_job = ["self-hosted", "linux", "x64", "x86-64-v3"]
            assert any_serves(match_job), (
                f"a qualifying v3 job matched NO pool: job={match_job} pools={all_tagsets}"
            )
            # NO host proves x86-64-v4 -> this job matches no pool -> stays queued.
            nomatch_job = ["self-hosted", "linux", "x64", "x86-64-v4"]
            assert not any_serves(nomatch_job), (
                f"a job needing x86-64-v4 (no host proves it) unexpectedly matched: "
                f"pools={all_tagsets}"
            )
            print("[match] v3 job matches a pool; x86-64-v4 job stays queued")

            # --- (6) COEXISTENCE: the scale set is reconciled too ------------
            scalesets = J.loads(gcli(f"scaleset list --org {oid}"))
            names = [s.get("name") for s in scalesets]
            assert "legacy-eph" in names, f"scale set not reconciled alongside pools: {names}"
            print("[coexist] scale set 'legacy-eph' runs in parallel with the pools")

            # --- idempotency: a second reconcile is a no-op on the pool count -
            controller.succeed("systemctl start garm-reconcile.service")
            controller.wait_until_succeeds("systemctl is-active garm-reconcile.service || systemctl show -p Result garm-reconcile.service | grep -q success", timeout=60)
            pools2 = J.loads(gcli(f"pool list --org {oid}"))
            assert len(pools2) == len(pools), (
                f"reconcile not idempotent: {len(pools)} -> {len(pools2)} pools"
            )
            print("[idempotent] second reconcile did not duplicate pools")

            print("[t_garm_pools_labels] PASS")
          '';
        };
      };
    };
}
