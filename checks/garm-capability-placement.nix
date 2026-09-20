top@{ ... }:
{
  # Runner-Fleet-Capability-Pools-And-Remote-Driving campaign, milestone RB3.
  #
  # gate: t_garm_capability_placement
  #
  # Proves fleet-aware placement + capability→host mapping HERMETICALLY. A
  # `services.garm.capabilityPools` entry is a LOGICAL, host-agnostic pool
  # ("provision capability X on every host that PROVES X, balanced by policy Y");
  # the reconcile EXPANDS it into one concrete GARM pool per QUALIFYING provider,
  # placement driven entirely by the RA6 capability manifests. This is the
  # structural fix for the "GPU servers 95% idle vs hms saturated" imbalance.
  #
  # Same hermetic shape as t_garm_pools_labels: ONE real garm.service + reconcile
  # + minimal mock GitHub + three DUMMY providers carrying DISTINCT manifest
  # fixtures — hms (NO gpu), gpu-001 & gpu-002 (gpu). Candidate order is the
  # provider attr order (sorted): gpu001, gpu002, hms.
  #
  # ASSERTIONS:
  #  (1) CAPABILITY PLACEMENT: a capabilityPool requiring `gpu` expands to pools
  #      ONLY on the qualifying GPU hosts (gpu001, gpu002) — NOT hms. A job
  #      needing gpu is therefore placeable only on a qualifying host.
  #  (2) BALANCED GENERIC: a generic capabilityPool (requires linux/x64/x86-64-v3,
  #      which ALL three prove) expands across ALL THREE hosts — a generic job is
  #      no longer pinned to one host but balanced across the least-loaded
  #      qualifying hosts.
  #  (3) SPREAD balancer: the generic pools all get the SAME priority (distribute
  #      across equivalent hosts).
  #  (4) PACK balancer: a packed capabilityPool's per-host pools get DESCENDING,
  #      DISTINCT priorities in candidate order (one host fills before the next).
  #  (5) The expansion is manifest-driven end to end: each expanded pool's tags
  #      are that host's derived label set (gpu pools carry `gpu`, hms does not).
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

      appPem = pkgs.runCommand "garm-cap-test-app.pem" { nativeBuildInputs = [ pkgs.openssl ]; } ''
        openssl genrsa -traditional 2048 > $out
      '';

      mkManifest =
        {
          host,
          keyId,
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
                archLevel = "x86-64-v3";
                inherit gpu;
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
        t_garm_capability_placement = pkgs.testers.nixosTest {
          name = "t_garm_capability_placement";

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
                description = "Mock GitHub management API for the placement gate";
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

                # RB3: capability pools. Candidates default to every provider
                # with a manifestFile (all three), qualified per `requires`.
                capabilityPools = {
                  # Only the GPU hosts qualify.
                  gpu = {
                    requires = [ "gpu" ];
                    balance = "spread";
                    basePriority = 200;
                    org = "metacraft-labs";
                    credentials = "mcl-app";
                    osType = "linux";
                    maxRunners = 2;
                  };
                  # Every host qualifies — the generic pool, balanced (spread).
                  generic = {
                    requires = [
                      "linux"
                      "x64"
                      "x86-64-v3"
                    ];
                    balance = "spread";
                    basePriority = 100;
                    org = "metacraft-labs";
                    credentials = "mcl-app";
                    osType = "linux";
                    maxRunners = 4;
                  };
                  # Same qualifying set, PACK balancer — descending priorities.
                  packed = {
                    requires = [
                      "linux"
                      "x64"
                      "x86-64-v3"
                    ];
                    balance = "pack";
                    basePriority = 50;
                    org = "metacraft-labs";
                    credentials = "mcl-app";
                    osType = "linux";
                    maxRunners = 4;
                  };
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

            # The reconcile persists logical-name -> pool-id, so we can map each
            # expanded pool (<capname>@<provider>) back to its GARM pool.
            id_map = J.loads(controller.succeed("cat /var/lib/garm/managed-pool-ids.json"))

            def pool(logical):
                pid = id_map.get(logical)
                assert pid, f"expected an expanded pool '{logical}', map={id_map}"
                return J.loads(gcli(f"pool show {pid}"))

            def tagset(p):
                return set(t["name"] if isinstance(t, dict) else t for t in (p.get("tags") or []))

            names = set(id_map.keys())

            # --- (1) CAPABILITY PLACEMENT: gpu only on the GPU hosts ----------
            assert "gpu@gpu001" in names, f"gpu pool not placed on gpu001: {names}"
            assert "gpu@gpu002" in names, f"gpu pool not placed on gpu002: {names}"
            assert "gpu@hms" not in names, (
                f"gpu pool WRONGLY placed on the non-GPU hms host: {names}"
            )
            print("[placement] gpu capability placed only on qualifying GPU hosts")

            # --- (2) BALANCED GENERIC: every qualifying host gets a pool ------
            for prov in ("gpu001", "gpu002", "hms"):
                assert f"generic@{prov}" in names, f"generic pool missing on {prov}: {names}"
            print("[balanced] generic capability spread across ALL three hosts")

            # --- (3) SPREAD: equal priority across the generic pools ----------
            gen_prios = {p: pool(f"generic@{p}").get("priority") for p in ("gpu001", "gpu002", "hms")}
            assert len(set(gen_prios.values())) == 1, (
                f"spread balancer must give equal priority, got {gen_prios}"
            )
            print(f"[spread] generic pools share priority {list(gen_prios.values())[0]}")

            # --- (4) PACK: descending, distinct priorities in candidate order -
            # candidate order = sorted provider names: gpu001, gpu002, hms.
            pk = [pool(f"packed@{p}").get("priority") for p in ("gpu001", "gpu002", "hms")]
            assert pk[0] > pk[1] > pk[2], f"pack balancer must be strictly descending: {pk}"
            assert len(set(pk)) == 3, f"pack priorities must be distinct: {pk}"
            print(f"[pack] packed pool priorities descend by host: {pk}")

            # --- (5) tags are the host's derived set (manifest-driven) --------
            assert "gpu" in tagset(pool("gpu@gpu001")), "gpu pool must advertise gpu"
            assert "gpu" not in tagset(pool("generic@hms")), "hms generic pool must NOT advertise gpu"
            for req in {"self-hosted", "linux", "x64", "x86-64-v3"}:
                assert req in tagset(pool("generic@hms")), f"generic hms pool missing {req}"

            # A gpu job is placeable only on the GPU hosts' pools; a generic job
            # on any of the three. (GitHub does the runtime match; we prove tags.)
            gpu_job = {"self-hosted", "linux", "x64", "gpu"}
            gen_job = {"self-hosted", "linux", "x64", "x86-64-v3"}
            gpu_hosts = [p for p in ("gpu001", "gpu002", "hms")
                         if gpu_job <= tagset(pool(f"generic@{p}"))]
            assert gpu_hosts == ["gpu001", "gpu002"], (
                f"gpu job placeable on unexpected hosts: {gpu_hosts}"
            )
            gen_hosts = [p for p in ("gpu001", "gpu002", "hms")
                         if gen_job <= tagset(pool(f"generic@{p}"))]
            assert set(gen_hosts) == {"gpu001", "gpu002", "hms"}, (
                f"generic job should be placeable on all three: {gen_hosts}"
            )
            print("[placement] gpu job -> GPU hosts only; generic job -> all three")

            print("[t_garm_capability_placement] PASS")
          '';
        };
      };
    };
}
