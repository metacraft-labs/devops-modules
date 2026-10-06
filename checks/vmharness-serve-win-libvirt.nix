top@{ ... }:
{
  # Runner-Fleet-Capability-Pools-And-Remote-Driving campaign, milestone RA3.
  #
  # gate: t_vmharness_serve_win_libvirt  (host-independent portion)
  #
  # The FULL RA3 gate drives a fresh ephemeral Windows-11 libvirt VM (clone→boot
  # →JIT-probe→destroy) through `vm-harness serve` on high-mem-server. That last
  # mile needs the real host: the Windows golden `/storage/iso/golden-win11-
  # cloudbase.qcow2` AND hardware KVM (the ephemeral clone renders `<domain
  # type='kvm'>`). It CANNOT run in a nixosTest (no nested KVM, no golden). The
  # on-host run instructions are in the campaign RA3 notes + this file's tail.
  #
  # What this test DOES prove, entirely host-independent — the RA3 DEPLOYMENT
  # CONTRACT, i.e. that the hardened serve daemon can drive libvirt at all:
  #
  #   (1) DEPLOYED, HARDENED, BOTH-BACKEND — the daemon comes up as its system
  #       user, still under the full systemd hardening (ProtectSystem=strict et
  #       al.), and its unit carries the libvirt access grants (libvirtd + kvm
  #       groups, the image-pool ReadWritePaths hole, the golden ReadOnlyPaths)
  #       ALONGSIDE incus-admin — one daemon, both backends selectable per
  #       request.
  #
  #   (2) SANDBOX PERMITS LIBVIRT MANAGEMENT — a process wearing the SAME
  #       sandbox shape the daemon runs under (ProtectSystem=strict + the
  #       libvirtd supplementary group, delivered as a runtime grant exactly as
  #       the unit delivers it) can reach libvirtd's system socket and run a
  #       management op. This is the polkit(libvirtd-group) + socket + strict-
  #       sandbox chain the EXP3 root path sidestepped, proven WITHOUT root.
  #
  #   (3) THE SANDBOX HOLES ARE REAL + SUFFICIENT — under ProtectSystem=strict a
  #       process as the serve user can READ the golden's directory and WRITE the
  #       per-job image pool, and actually clone a CoW overlay off a stand-in
  #       golden (`qemu-img create -b …`) — the exact first step of the libvirt
  #       backend's ephemeral clone. Without the ReadWritePaths hole this write
  #       fails (strict mounts the FS read-only), so it is a genuine assertion of
  #       the general module's `readWritePaths`/`readOnlyPaths` knobs.
  #
  #   (4) AUTHENTICATED ENDPOINT LIVE — the daemon listens and rejects an
  #       unauthenticated `GET /v1/info` (the RA1 posture, re-confirmed here so a
  #       libvirt host is held to the same bar as the incus hosts in RA2).
  #
  # The incus ephemeral roundtrip is covered in depth by the sibling RA2 gate
  # t_vmharness_serve_linux_deploy; here incus is enabled only so the
  # `incus-admin` group exists and the daemon can advertise both backends.
  perSystem =
    {
      pkgs,
      lib,
      self',
      ...
    }:
    let
      flake = top.config.flake;

      vmHarness = self'.packages.vm-harness;

      servePort = 8873;
      token = "vmh-serve-libvirt-bearer-42bc";

      # The image pool the libvirt backend writes per-job overlays to, and the
      # directory holding the (stand-in) golden — mirrors the CONCRETE infra
      # wiring in machines/server/high-mem-server/vm-harness-serve-libvirt.nix,
      # but on a throwaway path so the test needs no /storage array.
      imagePool = "/var/lib/vmh-libvirt/images";
      goldenDir = "/var/lib/vmh-libvirt/iso";
      goldenImg = "${goldenDir}/golden-stand-in.qcow2";

      serveUser = "vm-harness-serve";

      virsh = "${pkgs.libvirt}/bin/virsh";
      qemuImg = "${pkgs.qemu-utils}/bin/qemu-img";

      # Bearer token delivered the way agenix delivers it on the real hosts: a
      # 0400 file present at boot, handed to the unit via LoadCredential.
      tokenDropModule =
        { ... }:
        {
          system.activationScripts.vmhServeToken.text = ''
            mkdir -p /run/vmh-secrets
            printf '%s' '${token}' > /run/vmh-secrets/token
            chmod 0400 /run/vmh-secrets/token
          '';
        };
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_vmharness_serve_win_libvirt = pkgs.testers.nixosTest {
          name = "t_vmharness_serve_win_libvirt";

          nodes.host =
            { config, ... }:
            {
              imports = [
                flake.modules.nixos.vm-harness-serve
                tokenDropModule
              ];

              # Both backends live on this host, exactly as high-mem-server:
              # libvirt (the RA3 target) + incus (so incus-admin exists and the
              # daemon can serve both).
              networking.nftables.enable = true; # incus on NixOS requires nftables
              virtualisation.libvirtd.enable = true;
              virtualisation.incus.enable = true;
              virtualisation.diskSize = 6144;
              virtualisation.memorySize = 3072;
              virtualisation.cores = 2;

              # Directories the daemon's sandbox will read/write, owned by the
              # serve user — the CONCRETE infra file does the same via tmpfiles.
              systemd.tmpfiles.rules = [
                "d /var/lib/vmh-libvirt 0755 root root -"
                "d ${goldenDir} 0755 root root -"
                "d ${imagePool} 0750 ${serveUser} ${serveUser} -"
              ];

              services.vm-harness-serve = {
                enable = true;
                listenAddress = "127.0.0.1"; # non-routable placeholder is fine here
                port = servePort;
                backend = "libvirt";
                overlayInterface = null; # no firewall hole needed in this test
                authTokenFile = "/run/vmh-secrets/token";

                # ── the RA3 general-module knobs under test ──
                extraGroups = [ "incus-admin" ]; # incus: runtime SupplementaryGroups
                staticGroups = [
                  "libvirtd"
                  "kvm"
                ]; # libvirt: STATIC/NSS membership (polkit reads the group DB)
                extraPackages = [
                  config.virtualisation.incus.package
                  pkgs.libvirt
                  pkgs.qemu-utils
                ];
                readWritePaths = [ imagePool ];
                readOnlyPaths = [ goldenDir ];
              };

              environment.systemPackages = [
                pkgs.curl
                pkgs.libvirt
                pkgs.qemu-utils
              ];
            };

          testScript = ''
            start_all()

            host.wait_for_unit("multi-user.target")
            host.wait_for_unit("libvirtd.service")
            host.wait_for_unit("incus.service")

            with subtest("(1) daemon deployed, hardened, and carrying BOTH backends' access"):
                host.wait_for_unit("vm-harness-serve.service")
                unit = host.succeed("systemctl cat vm-harness-serve.service")
                # Still fully hardened (libvirt access did NOT relax the sandbox).
                assert "ProtectSystem=strict" in unit, unit
                assert "NoNewPrivileges=true" in unit, unit
                assert "User=vm-harness-serve" in unit, unit
                assert "LoadCredential=token:/run/vmh-secrets/token" in unit, unit
                # incus access is a runtime SupplementaryGroups grant on the unit.
                sup = host.succeed(
                    "systemctl show -p SupplementaryGroups --value vm-harness-serve.service"
                ).strip()
                assert "incus-admin" in sup, f"missing supplementary group incus-admin: {sup!r}"
                # libvirt access is STATIC group-database membership (polkit reads
                # the DB, not the unit's runtime groups) — must show in `id`.
                ids = host.succeed("id vm-harness-serve")
                for g in ("libvirtd", "kvm"):
                    assert g in ids, f"serve user must be a static member of {g!r}: {ids!r}"
                # The strict-sandbox holes the libvirt path needs are rendered.
                rw = host.succeed(
                    "systemctl show -p ReadWritePaths --value vm-harness-serve.service"
                ).strip()
                assert "${imagePool}" in rw, rw
                ro = host.succeed(
                    "systemctl show -p ReadOnlyPaths --value vm-harness-serve.service"
                ).strip()
                assert "${goldenDir}" in ro, ro
                host.wait_for_file("/run/vm-harness-serve/port")

            with subtest("(4) endpoint live + rejects an unauthenticated caller"):
                host.succeed(
                    "curl -sf -H 'Authorization: Bearer ${token}' "
                    "http://127.0.0.1:${toString servePort}/v1/info"
                )
                host.fail(
                    "curl -sf http://127.0.0.1:${toString servePort}/v1/info"
                )

            # A stand-in golden qcow2 in the read-only directory — a real image
            # so qemu-img can back a CoW overlay off it (no OS inside; we never
            # boot it — booting Windows/KVM is the host-gated remainder).
            host.succeed("${qemuImg} create -f qcow2 ${goldenImg} 64M")

            with subtest("(2) the SANDBOX shape permits libvirt management (no root)"):
                # Run AS the serve user (its static libvirtd membership is what
                # polkit authorizes) under a property set mirroring the REAL
                # unit's hardening (strict FS, invisible proc, namespace/realtime
                # restrictions, @system-service filter, unix+inet families). A
                # pass means the daemon's own user+sandbox can drive libvirt —
                # NOT a looser context. No SupplementaryGroups here on purpose:
                # polkit ignores runtime groups, so static membership must carry
                # it, exactly as in production.
                host.succeed(
                    "systemd-run --wait --pipe --collect "
                    "-p User=${serveUser} "
                    "-p ProtectSystem=strict -p ProtectHome=true -p PrivateTmp=true "
                    "-p ProtectProc=invisible -p ProcSubset=pid "
                    "-p RestrictNamespaces=true -p RestrictRealtime=true "
                    "-p LockPersonality=true -p ProtectKernelModules=true "
                    "-p NoNewPrivileges=true "
                    "-p RestrictAddressFamilies='AF_UNIX AF_INET AF_INET6' "
                    "-p 'SystemCallFilter=@system-service' "
                    "-p Environment=HOME=/var/lib/vm-harness-serve "
                    "${virsh} -c qemu:///system version"
                )
                # Negative control: a user NOT in libvirtd (nobody), same
                # sandbox, is refused by polkit — proving the static libvirtd
                # membership the module grants is what authorizes (not something
                # ambient), i.e. the grant is load-bearing.
                host.fail(
                    "systemd-run --wait --pipe --collect "
                    "-p User=nobody "
                    "-p ProtectSystem=strict -p ProtectHome=true -p PrivateTmp=true "
                    "${virsh} -c qemu:///system list --all"
                )

            with subtest("(3) strict sandbox: READ the golden dir, WRITE the image pool"):
                # As the serve user, under ProtectSystem=strict WITH the module's
                # ReadWritePaths/ReadOnlyPaths holes, clone a CoW overlay off the
                # golden — the libvirt backend's ephemeral-clone first step.
                host.succeed(
                    "systemd-run --wait --pipe --collect "
                    "-p User=${serveUser} -p SupplementaryGroups=kvm "
                    "-p ProtectSystem=strict -p ProtectHome=true -p PrivateTmp=true "
                    "-p ReadWritePaths=${imagePool} -p ReadOnlyPaths=${goldenDir} "
                    "${qemuImg} create -f qcow2 -b ${goldenImg} -F qcow2 "
                    "${imagePool}/probe.overlay.qcow2"
                )
                host.succeed("test -f ${imagePool}/probe.overlay.qcow2")
                # NEGATIVE control: the same strict sandbox WITHOUT the
                # ReadWritePaths hole cannot write the pool (FS is read-only) —
                # so the hole the module opens is genuinely what enables it.
                host.fail(
                    "systemd-run --wait --pipe --collect "
                    "-p User=${serveUser} "
                    "-p ProtectSystem=strict "
                    "-p ReadOnlyPaths=${goldenDir} "
                    "${qemuImg} create -f qcow2 -b ${goldenImg} -F qcow2 "
                    "${imagePool}/denied.overlay.qcow2"
                )

            # ── HOST-GATED REMAINDER (NOT runnable here) ──────────────────────
            # The end-to-end Windows-VM drive needs the real high-mem-server (the
            # golden + hardware KVM). After deploying the RA3 config to hms, run
            # from an enrolled NetBird controller:
            #
            #   vm-harness --remote <hms-overlay-ip>:${toString servePort} \
            #     --auth-token "$SERVE_TOKEN" \
            #     run --ephemeral --backend libvirt --acceleration kvm \
            #       --name vmh-win-probe \
            #       --source-image /storage/iso/golden-win11-cloudbase.qcow2 \
            #       --image-pool-dir /storage/vm-harness-serve/images \
            #       --secondary-iso /storage/iso/virtio-win.iso \
            #       --timeout-sec 900 -- <in-guest JIT probe>
            #
            # Expect: clone→boot→probe→destroy with NO residue (domain gone;
            # <name>.overlay.qcow2 + <name>.config-drive.iso removed from the
            # pool). `virsh list --all` on hms shows no vmh-win-probe leftover.
          '';
        };
      };
    };
}
