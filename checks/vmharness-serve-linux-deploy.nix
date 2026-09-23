top@{ ... }:
{
  # Runner-Fleet-Capability-Pools-And-Remote-Driving campaign, milestone RA2.
  #
  # gate: t_vmharness_serve_linux_deploy
  #
  # Boots a Linux host with `services.vm-harness-serve` enabled (the hardened
  # systemd unit from the general nixos-modules module) plus in-guest incus, and
  # a SECOND node acting as the remote controller. It proves the RA2 deployment
  # contract end to end, WITHOUT the infra repo:
  #
  #   (1) DEPLOYED + HARDENED — the daemon runs as a dedicated system user in the
  #       incus-admin group under the systemd hardening profile, with the bearer
  #       token delivered via LoadCredential (never the store), and it comes up
  #       listening.
  #
  #   (2) REMOTE INCUS ROUNDTRIP over the authenticated endpoint — the controller
  #       drives `vm-harness --remote … run --ephemeral --backend incus …`, which
  #       launches a per-job ephemeral incus CONTAINER on the host, execs a probe
  #       in it, and destroys it, leaving NO residue.
  #
  #   (3) AUTH — a correct bearer token is accepted on `GET /v1/info`; a wrong
  #       token and a missing token are both rejected (401), and a wrong-token
  #       `run` fails.
  #
  #   (4) OVERLAY-ONLY REACHABILITY — the listener is bound to the overlay
  #       address ONLY (never 0.0.0.0), and the port is opened on the overlay
  #       interface's firewall zone ONLY; the controller can reach it on the
  #       overlay network but NOT on the host's second ("public") network.
  #
  # Model: checks/garm-incus-runner-host.nix (in-guest incus) + the two-vlan
  # remote-reachability shape. The bootable per-job base image is a minimal
  # NixOS incus container built offline from nixpkgs' release.nix (the same
  # mechanism nixpkgs' own incus tests use), imported under the `vmh-base` alias
  # the vm-harness incus backend launches from.
  perSystem =
    {
      pkgs,
      lib,
      self',
      ...
    }:
    let
      flake = top.config.flake;
      system = pkgs.stdenv.hostPlatform.system;

      vmHarness = self'.packages.vm-harness;

      # Overlay ("NetBird") network = vlan 1; a separate "public" network = vlan 2.
      overlayHostIp = "10.10.10.1";
      overlayCtlIp = "10.10.10.2";
      publicHostIp = "10.20.20.1";
      servePort = 8873;
      token = "vmh-serve-bearer-77aa";

      # The bearer token, delivered the way agenix delivers it on the real hosts:
      # a 0400 file that appears at boot (activation script) and is handed to the
      # unit via LoadCredential. Not a store path — mirrors the production path.
      tokenDropModule =
        { ... }:
        {
          system.activationScripts.vmhServeToken.text = ''
            mkdir -p /run/vmh-secrets
            printf '%s' '${token}' > /run/vmh-secrets/token
            chmod 0400 /run/vmh-secrets/token
          '';
        };

      # A minimal NixOS incus CONTAINER image, built offline (no network) exactly
      # as nixpkgs' own incus tests do — release.nix yields the split
      # metadata-tarball + rootfs-squashfs pair `incus image import` consumes.
      releases = import "${pkgs.path}/nixos/release.nix" {
        configuration =
          { lib, ... }:
          {
            documentation.enable = lib.mkForce false;
            documentation.nixos.enable = lib.mkForce false;
            system.installer.channel.enable = lib.mkForce false;
            environment.etc."nix/registry.json".text = lib.mkForce "{}";
          };
      };
      containerMetaDir = releases.incusContainerMeta.${system};
      containerSquashfs = "${releases.incusContainerImage.${system}}/nixos-lxc-image-${system}.squashfs";

      # Static addressing on both vlans (override the test driver's defaults) so
      # the module's listenAddress can be pinned at build time.
      netModule =
        { hostOctet }:
        { lib, ... }:
        {
          virtualisation.vlans = [
            1
            2
          ];
          networking.useDHCP = false;
          networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
            {
              address = "10.10.10.${hostOctet}";
              prefixLength = 24;
            }
          ];
          networking.interfaces.eth2.ipv4.addresses = lib.mkForce [
            {
              address = "10.20.20.${hostOctet}";
              prefixLength = 24;
            }
          ];
        };
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_vmharness_serve_linux_deploy = pkgs.testers.nixosTest {
          name = "t_vmharness_serve_linux_deploy";

          nodes.host =
            { ... }:
            {
              imports = [
                flake.modules.nixos.vm-harness-serve
                flake.modules.nixos.garm-incus-runner-host
                tokenDropModule
                (netModule { hostOctet = "1"; })
              ];

              # In-guest incus (mirrors garm-incus-runner-host.nix).
              networking.nftables.enable = true;
              virtualisation.incus.enable = true;
              virtualisation.diskSize = 10240;
              virtualisation.memorySize = 4096;
              virtualisation.cores = 4;

              services.garm-incus-runner-host = {
                enable = true;
                bridgeSubnet = "10.157.159.0/24";
                # We import the bootable base image by hand in the testScript
                # (the split metadata+squashfs pair needs two args, whereas this
                # helper's importer is single-file unified). Leave its importer a
                # no-op.
                image.enable = false;
              };

              services.vm-harness-serve = {
                enable = true;
                listenAddress = overlayHostIp; # bind the OVERLAY address only
                port = servePort;
                backend = "incus";
                overlayInterface = "eth1"; # firewall-open on the overlay iface only
                authTokenFile = "/run/vmh-secrets/token";
                # Orphan-detection inventory (driven by hand in subtest 5).
                inventoryExporter = {
                  enable = true;
                  backends = [ "incus" ];
                  interval = "1h";
                };
              };
            };

          nodes.controller =
            { ... }:
            {
              imports = [ (netModule { hostOctet = "2"; }) ];
              environment.systemPackages = [
                vmHarness
                pkgs.curl
              ];
            };

          testScript = ''
            start_all()

            host.wait_for_unit("multi-user.target")
            host.wait_for_unit("incus.service")
            host.wait_for_unit("garm-incus-storage-network.service")
            controller.wait_for_unit("multi-user.target")

            with subtest("(1) the serve daemon is deployed, hardened, and listening"):
                host.wait_for_unit("vm-harness-serve.service")
                # Bearer token arrives via LoadCredential — never the store.
                unit = host.succeed("systemctl cat vm-harness-serve.service")
                assert "LoadCredential=token:/run/vmh-secrets/token" in unit, unit
                assert "User=vm-harness-serve" in unit, unit
                assert "NoNewPrivileges=true" in unit, unit
                assert "ProtectSystem=strict" in unit, unit

                # THE SOFT LIMIT IS THE ONE A PROCESS ACTUALLY HITS, and
                # systemd's default is 1024. Measured on high-mem-server:
                # LimitNOFILE=524288 but LimitNOFILESoft=1024, with the daemon
                # pinned at 1022 open fds — which surfaced on the CONTROLLER as
                # "failed to stage user-data: Too many open files" and read as a
                # remote-driving fault rather than an rlimit. Asserting only the
                # hard bound would pass against exactly that broken shape, so
                # pin BOTH.
                assert "LimitNOFILE=" in unit, unit
                assert "LimitNOFILESoft=" in unit, unit
                soft = int(
                    [l for l in unit.splitlines() if l.startswith("LimitNOFILESoft=")][0]
                    .split("=", 1)[1]
                )
                assert soft > 1024, (
                    f"LimitNOFILESoft={soft} is not above systemd's 1024 default; "
                    "a concurrent serve exhausts it and every pool create fails "
                    "with 'Too many open files'"
                )
                # The daemon joins incus-admin (reaches the incus socket) via the
                # unit's systemd SupplementaryGroups (a runtime grant, so it shows
                # in the unit, not in static NSS `id` output).
                assert "SupplementaryGroups=incus-admin" in unit, unit
                # It reports its bound port when ready.
                host.wait_for_file("/run/vm-harness-serve/port")

            with subtest("(4) listener is bound to the overlay address ONLY"):
                listen = host.succeed("ss -ltnH 'sport = :${toString servePort}'")
                assert "${overlayHostIp}:${toString servePort}" in listen, listen
                for bad in ("0.0.0.0:${toString servePort}", "*:${toString servePort}",
                            "127.0.0.1:${toString servePort}", "${publicHostIp}:${toString servePort}"):
                    assert bad not in listen, f"daemon must not listen on {bad!r}: {listen!r}"

            with subtest("(3) auth: correct token accepted, wrong/missing rejected"):
                controller.succeed(
                    "curl -sf -H 'Authorization: Bearer ${token}' "
                    "http://${overlayHostIp}:${toString servePort}/v1/info"
                )
                controller.fail(
                    "curl -sf -H 'Authorization: Bearer WRONG-TOKEN' "
                    "http://${overlayHostIp}:${toString servePort}/v1/info"
                )
                controller.fail(
                    "curl -sf http://${overlayHostIp}:${toString servePort}/v1/info"
                )

            with subtest("(4) port is NOT reachable off the overlay (public iface)"):
                # Bind-scoped away AND firewall opens the port on eth1 only.
                controller.fail(
                    "curl -sf --max-time 5 "
                    "http://${publicHostIp}:${toString servePort}/v1/info"
                )

            # Import the bootable per-job base image under the alias the
            # vm-harness incus backend launches from.
            with subtest("seed the vmh-base incus image"):
                host.succeed(
                    "incus image import "
                    "${containerMetaDir}/tarball/nixos-image-lxc-*-${system}.tar.xz "
                    "${containerSquashfs} --alias vmh-base"
                )

            with subtest("(2) remote controller drives an ephemeral incus container roundtrip"):
                code, out = controller.execute(
                    "vm-harness --remote ${overlayHostIp}:${toString servePort} "
                    "--auth-token ${token} "
                    "run --ephemeral --backend incus --baseline vmh-serve-job "
                    "--base-image vmh-base --timeout-sec 180 -- true"
                )
                assert code == 0, f"remote run failed (exit {code}):\n{out}"

            with subtest("(2) NO residue — the per-job container is gone"):
                names = host.succeed("incus list --format csv -c n")
                assert "vmh-serve-job" not in names, f"leftover container: {names!r}"

            with subtest("(5) kept instances are listed, attributed, inventoried, and truly destroyed"):
                remote = ("vm-harness --remote ${overlayHostIp}:${toString servePort} "
                          "--auth-token ${token} ")
                # A GARM-style keep: launch and return, runner left running.
                controller.succeed(remote + "run --ephemeral --backend incus "
                                   "--baseline garm-keep1 --base-image vmh-base --keep")
                # Ownership, as the provider records it right after a create.
                controller.succeed(remote + "ephemeral-label --backend incus "
                                   "--baseline garm-keep1 --label garm-pool=P1")
                out = controller.succeed(remote + "ephemeral-list --backend incus "
                                         "--label garm-pool=P1")
                assert '"name":"garm-keep1","state":"running"' in out, out
                # Another pool never sees it (the scale-set reconciler would delete it).
                out = controller.succeed(remote + "ephemeral-list --backend incus "
                                         "--label garm-pool=P2")
                assert "garm-keep1" not in out, out

                # An ORPHAN: a stopped runner-named container nobody owns.
                host.succeed("incus launch vmh-base garm-orphan1 && incus stop --force garm-orphan1")
                host.succeed("systemctl start vm-harness-serve-inventory.service")
                prom = host.succeed("cat /var/lib/prometheus-node-exporter/textfile/vmh-ephemeral.prom")
                assert 'vmh_ephemeral_list_success{backend="incus"} 1' in prom, prom
                assert 'vmh_ephemeral_instances{backend="incus",state="running",attributed="true"} 1' in prom, prom
                assert 'vmh_ephemeral_instances{backend="incus",state="stopped",attributed="false"} 1' in prom, prom

                # Teardown: gone for real, and its ownership record with it.
                controller.succeed(remote + "ephemeral-destroy --backend incus --baseline garm-keep1")
                controller.succeed(remote + "ephemeral-destroy --backend incus --baseline garm-orphan1")
                names = host.succeed("incus list --format csv -c n")
                assert "garm-keep1" not in names and "garm-orphan1" not in names, names
                host.fail("test -e /var/lib/vm-harness-serve/ephemeral-labels/incus/garm-keep1.json")
                # Deleting what is already gone is success (GARM retries deletes).
                controller.succeed(remote + "ephemeral-destroy --backend incus --baseline garm-keep1")

            with subtest("(3) a wrong-token remote run is rejected"):
                code, out = controller.execute(
                    "vm-harness --remote ${overlayHostIp}:${toString servePort} "
                    "--auth-token WRONG-TOKEN "
                    "run --ephemeral --backend incus --baseline vmh-serve-nope "
                    "--base-image vmh-base -- true"
                )
                assert code != 0, f"wrong-token run must fail, got exit 0:\n{out}"
          '';
        };
      };
    };
}
