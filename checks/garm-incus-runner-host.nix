top@{ ... }:
{
  # Declarative GARM Reconcile — deliverables (2)+(2b)+(3) gate: t_garm_incus_runner_host.
  #
  # Boots a NixOS VM with incus + the `services.garm-incus-runner-host` helper
  # and proves the operator steps it replaces are now declarative:
  #
  #   (2) incus PRESEED triple — after switch, the managed `incusbr0` exists on
  #       the declared per-host subnet (gateway .1/24, ipv4.nat on), plus the
  #       `default` storage pool and the `default` profile's root+eth0 devices,
  #       created by the nixpkgs incus-preseed.service the helper populates.
  #       Replaces the manual `incus admin init` / `incus network create …`.
  #
  #   (2b) convergence ONESHOT — the helper's garm-incus-storage-network oneshot
  #        create-if-missing reconciles the same triple (pool + bridge + default
  #        profile root/eth0) on every switch, so a host whose incus already
  #        self-initialised (where the preseed no-ops) still converges. We assert
  #        it is green, that the triple is present, and that a re-run is a NO-OP
  #        (idempotent — every step logs the "present" short-circuit).
  #
  #   (3) image-import ONESHOT — the helper's garm-incus-image-import oneshot
  #       imports the runner image under the declared alias iff absent, and a
  #       re-run is a NO-OP. We feed it a tiny hand-built incus image tarball
  #       (metadata-only, no rootfs needed to register an alias in the store's
  #       image DB) and assert the alias appears, then re-run and assert the
  #       oneshot stays green + the alias count is unchanged.
  perSystem =
    {
      pkgs,
      lib,
      ...
    }:
    let
      flake = top.config.flake;

      subnet = "10.157.159.0/24";

      # A minimal unified incus image tarball: just a metadata.yaml describing a
      # trivial image. `incus image import <tarball>` registers it (alias) in
      # the local image store without needing a bootable rootfs for THIS gate
      # (we assert registration, not launch).
      testImage =
        pkgs.runCommand "vmh-linux-runner-test-image.tar.gz"
          {
            nativeBuildInputs = [
              pkgs.gnutar
              pkgs.gzip
            ];
          }
          ''
            mkdir -p build/rootfs
            cat > build/metadata.yaml <<EOF
            architecture: x86_64
            creation_date: 1700000000
            properties:
              description: garm reconcile gate test image
              os: debian
              release: bookworm
            EOF
            # An empty rootfs dir is fine for registration.
            tar -C build -czf $out metadata.yaml rootfs
          '';
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_garm_incus_runner_host = pkgs.testers.nixosTest {
          name = "t_garm_incus_runner_host";

          nodes.host =
            { ... }:
            {
              imports = [ flake.modules.nixos.garm-incus-runner-host ];
              networking.nftables.enable = true;
              virtualisation.incus.enable = true;
              # Give the VM enough disk for the incus storage pool.
              virtualisation.diskSize = 4096;
              environment.systemPackages = [ pkgs.jq ];

              services.garm-incus-runner-host = {
                enable = true;
                bridgeSubnet = subnet;
                image = {
                  alias = "vmh-linux-runner";
                  source = testImage;
                };
              };
            };

          testScript = ''
            host.wait_for_unit("multi-user.target")
            host.wait_for_unit("incus.service")
            host.wait_for_unit("incus-preseed.service")

            with subtest("(1) the host provides /dev/fuse for per-job containers"):
                # Incus bind-mounts the host's /dev/fuse into EVERY container
                # (internal/server/instance/drivers/driver_lxc.go puts
                # "/dev/fuse" in the unconditional `bindMounts` list, emitted as
                # `lxc.mount.entry = /dev/fuse dev/fuse none bind,create=file,
                # optional 0 0`), so a per-job eph-linux-x64 container gets FUSE
                # with no container-side config — unprivileged and idmapped
                # included (FUSE mounts in a user namespace have been permitted
                # since Linux 4.18). But that entry is emitted only `if
                # PathExists("/dev/fuse")` on the HOST and carries `optional`,
                # so a host without the `fuse` module produces containers with
                # no device and NO error anywhere. Hence
                # boot.kernelModules = [ "fuse" ].
                #
                # When this regresses, the symptom lands far away and reads as
                # someone else's bug: codetracer's cross-process-linux job
                # fails with `tup error: Unable to mount FUSE on .tup/mnt`,
                # inside a container, with nothing to point at the host.
                #
                # NOTE ON WHAT IS ASSERTED. The runtime facts below are NOT
                # sufficient on their own: `virtualisation.incus.enable` pulls
                # in `virtualisation.lxc.lxcfs.enable`, and lxcfs is itself a
                # FUSE filesystem, so it autoloads the module at boot and
                # /dev/fuse exists on this node whether or not the option is
                # declared. Verified by building this test with the
                # boot.kernelModules line deleted: it still passed. So the
                # DECLARATION is asserted too — that is the part that is ours,
                # and the part that keeps holding if incus ever stops dragging
                # lxcfs in.
                host.succeed("grep -qxF fuse /etc/modules-load.d/nixos.conf")
                host.succeed("test -c /dev/fuse")
                host.succeed("grep -qw fuse /proc/filesystems")

            with subtest("(2) preseed created incusbr0 on the declared subnet"):
                host.succeed("incus network show incusbr0")
                addr = host.succeed(
                    "incus network get incusbr0 ipv4.address"
                ).strip()
                assert addr == "10.157.159.1/24", f"incusbr0 ipv4.address={addr!r}"
                nat = host.succeed("incus network get incusbr0 ipv4.nat").strip()
                assert nat == "true", f"incusbr0 ipv4.nat={nat!r}"

            with subtest("(2b) convergence oneshot converged pool+network+profile"):
                host.wait_for_unit("garm-incus-storage-network.service")
                state = host.succeed(
                    "systemctl show -p Result --value garm-incus-storage-network.service"
                ).strip()
                assert state == "success", f"convergence oneshot result={state!r}"
                # storage pool present.
                host.succeed("incus storage show default")
                pool_driver = host.succeed("incus storage show default | sed -n 's/^driver: //p'").strip()
                assert "dir" in pool_driver, f"default pool driver={pool_driver!r}"
                # default profile has both root (on the pool) and eth0 (on the bridge).
                devs = host.succeed("incus profile device list default")
                assert "root" in devs and "eth0" in devs, f"profile devices missing: {devs!r}"
                rootpool = host.succeed("incus profile device get default root pool").strip()
                assert rootpool == "default", f"root device pool={rootpool!r}"
                eth0net = host.succeed("incus profile device get default eth0 network").strip()
                assert eth0net == "incusbr0", f"eth0 device network={eth0net!r}"

            with subtest("(2b) a re-run of the convergence oneshot is a no-op"):
                host.systemctl("restart garm-incus-storage-network.service")
                host.wait_for_unit("garm-incus-storage-network.service")
                state = host.succeed(
                    "systemctl show -p Result --value garm-incus-storage-network.service"
                ).strip()
                assert state == "success", f"re-run result={state!r}"
                # Every guarded step short-circuited on the already-present entity.
                for token in ("storage pool 'default' present",
                              "network 'incusbr0' present",
                              "profile default root present",
                              "profile default eth0 present"):
                    host.succeed(
                        f"journalctl -u garm-incus-storage-network.service | grep -qF \"{token}\""
                    )
                # The triple is unchanged after the re-run.
                addr = host.succeed("incus network get incusbr0 ipv4.address").strip()
                assert addr == "10.157.159.1/24", f"incusbr0 drifted: {addr!r}"

            with subtest("(3) image-import oneshot registered the alias"):
                host.wait_for_unit("garm-incus-image-import.service")
                aliases = host.succeed("incus image alias list --format csv | cut -d, -f1")
                assert "vmh-linux-runner" in aliases, f"alias missing: {aliases!r}"

            with subtest("(3) a re-run of the image-import oneshot is a no-op"):
                before = host.succeed(
                    "incus image alias list --format csv | grep -c vmh-linux-runner"
                ).strip()
                host.systemctl("restart garm-incus-image-import.service")
                host.wait_for_unit("garm-incus-image-import.service")
                # Still green (the check-then-import short-circuits) and the
                # alias count is unchanged (no duplicate import).
                state = host.succeed(
                    "systemctl show -p Result --value garm-incus-image-import.service"
                ).strip()
                assert state == "success", f"re-run result={state!r}"
                after = host.succeed(
                    "incus image alias list --format csv | grep -c vmh-linux-runner"
                ).strip()
                assert before == after == "1", f"alias count drifted: {before!r} -> {after!r}"
                # The oneshot logged the no-op path.
                host.succeed(
                    "journalctl -u garm-incus-image-import.service | grep -q 'already present'"
                )
          '';
        };
      };
    };
}
