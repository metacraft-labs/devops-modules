top@{ ... }:
{
  # Production-Runners-And-Shared-Store EXP-MP gate: t_garm_multi_provider.
  #
  # Proves the `services.garm` module supports MULTIPLE named providers +
  # MULTIPLE GitHub App credentials in one control plane, with a UNION systemd
  # sandbox, while keeping the provider-OFF posture the M0-strict sandbox.
  #
  # This is an EVAL/BUILD-level gate (like the M6 resource-guard assertion): it
  # builds the module-produced `garm.service` unit for three shapes and asserts
  # on the rendered unit + the rendered config.toml template (a full VM boot of
  # a 2-provider host would need libvirtd + incus enabled just to have the
  # libvirtd/kvm/incus-admin groups exist — the union proof does not require it).
  #
  # Shapes asserted:
  #   (1) MULTI: two providers (an `incus` + a `libvirt` one) + two org App
  #       credentials. The unit's sandbox is the UNION — User=garm,
  #       SupplementaryGroups has BOTH libvirtd+kvm AND incus-admin, DeviceAllow
  #       /dev/kvm present, ProtectSystem=full, SystemCallFilter dropped (libvirt
  #       execs mkisofs), base hardening intact (NoNewPrivileges, empty
  #       CapabilityBoundingSet). The config.toml renders BOTH `[[provider]]`
  #       blocks (one incus-backend, one libvirt-backend) AND BOTH `[[github]]`
  #       blocks (both credential names).
  #   (2) INCUS-ONLY: User=garm, SupplementaryGroups = incus-admin ONLY (no
  #       libvirtd/kvm), and the STRICT knobs stay (ProtectSystem=strict,
  #       PrivateDevices, MemoryDenyWriteExecute, SystemCallFilter present) —
  #       proving the union picks the strict incus posture when no libvirt.
  #   (3) QEMU-WINDOWS-ARM: a vm-harness-run provider renders the qemu Windows
  #       ARM backend config with state_dir/source_image and no libvirt keys.
  #   (4) OFF: the M0 strict DynamicUser sandbox — DynamicUser, ProtectSystem=
  #       strict, PrivateDevices, MemoryDenyWriteExecute, SystemCallFilter
  #       present, and NO dedicated user / supplementary groups.
  perSystem =
    {
      pkgs,
      lib,
      ...
    }:
    let
      flake = top.config.flake;

      # Build just the module-produced garm.service unit derivation for a given
      # `services.garm` shape (no full toplevel needed).
      mkGarmUnit =
        garmCfg:
        (pkgs.nixos (
          { ... }:
          {
            imports = [ flake.modules.nixos.garm ];
            boot.loader.grub.enable = false;
            fileSystems."/" = {
              device = "/dev/vda";
              fsType = "ext4";
            };
            system.stateVersion = "24.11";
            services.garm = garmCfg;
          }
        )).config.systemd.units."garm.service".unit;

      # (1) two providers (incus + libvirt) + two org App credentials.
      multiUnit = mkGarmUnit {
        enable = true;
        openIncusBridgeFirewall = true;
        github.app-primary = {
          appId = 100001;
          installationId = 200001;
          appKeyFile = "/run/agenix/garm/app-primary-key";
        };
        github.app-secondary = {
          appId = 100002;
          installationId = 200002;
          appKeyFile = "/run/agenix/garm/app-secondary-key";
        };
        providers.incus = {
          backend = "incus";
          incusBridge = "incusbr0";
          incusIPv4CIDR = "10.0.100.0/24";
          incusIPv4Gateway = "10.0.100.1";
          images.linux-runner.sourceImage = "runner-linux";
        };
        providers.windows = {
          backend = "libvirt";
          poolDir = "/var/lib/garm/pool-win";
          images.golden.sourceImage = "/var/lib/garm/golden/windows-runner.qcow2";
        };
        scaleSets.incus = {
          provider = "incus";
          org = "org-a";
          credentials = "app-primary";
          image = "linux-runner";
          osType = "linux";
          maxRunners = 4;
        };
        scaleSets.win = {
          provider = "windows";
          org = "org-b";
          credentials = "app-secondary";
          image = "golden";
          osType = "windows";
          maxRunners = 2;
        };
      };

      # (2) incus provider ONLY (a single-backend shape).
      incusUnit = mkGarmUnit {
        enable = true;
        providers.vmharness = {
          backend = "incus";
          incusIPv4CIDR = "10.0.100.0/24";
          incusIPv4Gateway = "10.0.100.1";
          images.linux-runner.sourceImage = "runner-linux";
        };
      };

      # (3) qemu Windows ARM vm-harness-run provider.
      qemuWindowsArmUnit = mkGarmUnit {
        enable = true;
        providers.win-arm = {
          backend = "qemu-windows-arm";
          vmHarnessPath = "/nix/store/test-vm-harness/bin/vm-harness";
          stateDir = "/var/lib/garm-provider-vmharness/win-arm";
          images.win-arm-runner = {
            sourceImage = "/private/var/lib/vm-harness/qemu-windows-arm/golden/win-arm-runner";
            osName = "windows";
            osVersion = "11-arm64";
          };
        };
      };

      # (4) provider OFF (the M0 forge-less boot).
      offUnit = mkGarmUnit {
        enable = true;
      };

      # (5) an incus provider WITH a CPU cap (CIR-M1). Identical to (2) but for
      # `incusLimitsCpu`, so (2) doubles as the negative control: the key must
      # be ABSENT from an uncapped provider's config, not merely empty. That
      # matters because the provider keys "apply no cap at all" off emptiness,
      # and because an emitted-but-empty key would change the rendered
      # config.toml — and therefore restart garm — on every existing host.
      cappedIncusUnit = mkGarmUnit {
        enable = true;
        providers.vmharness = {
          backend = "incus";
          incusIPv4CIDR = "10.0.100.0/24";
          incusIPv4Gateway = "10.0.100.1";
          incusLimitsCpu = "8";
          images.linux-runner.sourceImage = "runner-linux";
        };
      };
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_garm_multi_provider =
          pkgs.runCommand "t_garm_multi_provider"
            {
              inherit
                multiUnit
                incusUnit
                qemuWindowsArmUnit
                offUnit
                cappedIncusUnit
                ;
            }
            ''
              set -euo pipefail
              fail() { echo "[t_garm_multi_provider][FAIL] $1" >&2; exit 1; }
              multi="$multiUnit/garm.service"
              incus="$incusUnit/garm.service"
              qemuWindowsArm="$qemuWindowsArmUnit/garm.service"
              off="$offUnit/garm.service"

              # --- (1) MULTI: union sandbox --------------------------------------
              grep -qx 'User=garm'  "$multi" || fail "multi: User=garm missing"
              grep -qx 'Group=garm' "$multi" || fail "multi: Group=garm missing"
              sg=$(grep '^SupplementaryGroups=' "$multi" || true)
              for g in libvirtd kvm incus-admin; do
                echo "$sg" | grep -qw "$g" || fail "multi: SupplementaryGroups missing '$g' (got: $sg)"
              done
              grep -qx 'DeviceAllow=/dev/kvm rw' "$multi" || fail "multi: DeviceAllow /dev/kvm missing"
              grep -qx 'ProtectSystem=full' "$multi" || fail "multi: ProtectSystem must be full (libvirt union)"
              grep -q  '^ReadWritePaths=' "$multi" || fail "multi: ReadWritePaths missing"
              grep -q  '/var/lib/garm/pool-win' "$multi" || fail "multi: libvirt pool dir not in ReadWritePaths"
              # libvirt posture DROPS the syscall filter + PrivateDevices + MDWE.
              ! grep -q '^SystemCallFilter=' "$multi" || fail "multi: SystemCallFilter must be absent (libvirt execs mkisofs)"
              ! grep -q '^PrivateDevices='   "$multi" || fail "multi: PrivateDevices must be absent (libvirt needs devices)"
              ! grep -q '^MemoryDenyWriteExecute=' "$multi" || fail "multi: MemoryDenyWriteExecute must be absent (qemu JIT)"
              # base hardening intact:
              grep -qx 'NoNewPrivileges=true' "$multi" || fail "multi: NoNewPrivileges missing"
              grep -qx 'CapabilityBoundingSet=' "$multi" || fail "multi: empty CapabilityBoundingSet missing"
              grep -qx 'ProtectKernelTunables=true' "$multi" || fail "multi: ProtectKernelTunables missing"
              grep -qx 'RestrictNamespaces=true' "$multi" || fail "multi: RestrictNamespaces missing"

              # --- (1) MULTI: config.toml renders both blocks --------------------
              pre=$(grep '^ExecStartPre=' "$multi" | head -1 | cut -d= -f2-)
              [ -f "$pre" ] || fail "multi: render script not found at $pre"
              tmpl=$(grep -ohE '/nix/store/[a-z0-9]+-garm-config.toml.tmpl' "$pre" | head -1)
              [ -f "$tmpl" ] || fail "multi: config template not found (from $pre)"
              nprov=$(grep -c '^\[\[provider\]\]' "$tmpl" || true)
              ngh=$(grep -c '^\[\[github\]\]' "$tmpl" || true)
              [ "$nprov" = 2 ] || fail "multi: expected 2 [[provider]] blocks, got $nprov"
              [ "$ngh" = 2 ]   || fail "multi: expected 2 [[github]] blocks, got $ngh"
              grep -q 'name = "incus"'   "$tmpl" || fail "multi: [[provider]] 'incus' missing"
              grep -q 'name = "windows"' "$tmpl" || fail "multi: [[provider]] 'windows' missing"
              grep -q 'name = "app-primary"'   "$tmpl" || fail "multi: [[github]] 'app-primary' missing"
              grep -q 'name = "app-secondary"' "$tmpl" || fail "multi: [[github]] 'app-secondary' missing"
              # both backends present across the two provider config files:
              provcfgs=$(grep -ohE '/nix/store/[a-z0-9]+-garm-provider-[a-z0-9_]+\.toml' "$tmpl" | sort -u)
              [ "$(echo "$provcfgs" | wc -l)" = 2 ] || fail "multi: expected 2 provider config files"
              cat $provcfgs > backends.txt
              grep -q 'backend = "incus"'   backends.txt || fail "multi: no incus-backend provider config"
              grep -q 'backend = "libvirt"' backends.txt || fail "multi: no libvirt-backend provider config"

              # --- (2) INCUS-ONLY: strict-but-incus-admin posture ----------------
              grep -qx 'User=garm' "$incus" || fail "incus: User=garm missing"
              sgi=$(grep '^SupplementaryGroups=' "$incus" || true)
              echo "$sgi" | grep -qw 'incus-admin' || fail "incus: incus-admin group missing"
              echo "$sgi" | grep -qw 'libvirtd' && fail "incus: libvirtd must NOT be present (no libvirt provider)" || true
              echo "$sgi" | grep -qw 'kvm' && fail "incus: kvm must NOT be present (no libvirt provider)" || true
              grep -qx 'ProtectSystem=strict' "$incus" || fail "incus: ProtectSystem must stay strict"
              grep -qx 'PrivateDevices=true' "$incus" || fail "incus: PrivateDevices must stay on"
              grep -qx 'MemoryDenyWriteExecute=true' "$incus" || fail "incus: MDWE must stay on"
              grep -q  '^SystemCallFilter=@system-service' "$incus" || fail "incus: SystemCallFilter must stay on"
              ! grep -q '^DeviceAllow=/dev/kvm' "$incus" || fail "incus: /dev/kvm must NOT be allowed"

              # --- (3) QEMU-WINDOWS-ARM: vm-harness-run config -------------------
              qpre=$(grep '^ExecStartPre=' "$qemuWindowsArm" | head -1 | cut -d= -f2-)
              [ -f "$qpre" ] || fail "qemu-windows-arm: render script not found at $qpre"
              qtmpl=$(grep -ohE '/nix/store/[a-z0-9]+-garm-config.toml.tmpl' "$qpre" | head -1)
              [ -f "$qtmpl" ] || fail "qemu-windows-arm: config template not found (from $qpre)"
              qprovcfg=$(grep -ohE '/nix/store/[a-z0-9]+-garm-provider-win_arm\.toml' "$qtmpl" | head -1)
              [ -f "$qprovcfg" ] || fail "qemu-windows-arm: provider config not found"
              grep -q 'backend = "qemu-windows-arm"' "$qprovcfg" || fail "qemu-windows-arm: backend missing"
              grep -q 'vm_harness_path = "/nix/store/test-vm-harness/bin/vm-harness"' "$qprovcfg" || fail "qemu-windows-arm: vm_harness_path missing"
              grep -q 'state_dir = "/var/lib/garm-provider-vmharness/win-arm"' "$qprovcfg" || fail "qemu-windows-arm: state_dir missing"
              grep -q 'source_image = "/private/var/lib/vm-harness/qemu-windows-arm/golden/win-arm-runner"' "$qprovcfg" || fail "qemu-windows-arm: source_image missing"
              grep -q 'os_name = "windows"' "$qprovcfg" || fail "qemu-windows-arm: Windows OS mapping missing"
              ! grep -q 'virsh_path' "$qprovcfg" || fail "qemu-windows-arm: must not render libvirt keys"

              # --- (4) OFF: M0 strict DynamicUser sandbox ------------------------
              grep -qx 'DynamicUser=true' "$off" || fail "off: DynamicUser must be true"
              grep -qx 'ProtectSystem=strict' "$off" || fail "off: ProtectSystem must be strict"
              grep -qx 'PrivateDevices=true' "$off" || fail "off: PrivateDevices must be on"
              grep -qx 'MemoryDenyWriteExecute=true' "$off" || fail "off: MDWE must be on"
              grep -q  '^SystemCallFilter=@system-service' "$off" || fail "off: SystemCallFilter must be on"
              ! grep -q '^User=garm' "$off" || fail "off: must NOT run as a dedicated user"
              ! grep -q '^SupplementaryGroups=' "$off" || fail "off: must have NO supplementary groups"
              ! grep -q '^DeviceAllow=' "$off" || fail "off: must have NO DeviceAllow"

              # --- (5) CIR-M1: the incus CPU cap renders, and only on request ---
              #
              # The cap exists because the per-job containers are uncapped
              # (`cpu.max=max`, `cpuset.cpus=0-31` on a 32-thread host), so each
              # one reports every host thread to `nproc` and self-sizes its build
              # parallelism to the whole machine — the demand that drives the
              # co-resident Windows guests past GitHub's ~300 s assignment
              # window. This asserts the option reaches the rendered TOML, which
              # is the only contract between the NixOS option and the provider.
              cpre=$(grep '^ExecStartPre=' "$cappedIncusUnit/garm.service" | head -1 | cut -d= -f2-)
              [ -f "$cpre" ] || fail "incus-capped: render script not found at $cpre"
              ctmpl=$(grep -ohE '/nix/store/[a-z0-9]+-garm-config.toml.tmpl' "$cpre" | head -1)
              [ -f "$ctmpl" ] || fail "incus-capped: config template not found (from $cpre)"
              ccfg=$(grep -ohE '/nix/store/[a-z0-9]+-garm-provider-vmharness\.toml' "$ctmpl" | head -1)
              [ -f "$ccfg" ] || fail "incus-capped: provider config not found"
              grep -qx 'incus_limits_cpu = "8"' "$ccfg" \
                || fail "incus-capped: incus_limits_cpu not rendered (got: $(grep -c . "$ccfg") lines, none matching)"

              # NEGATIVE CONTROL: shape (2) differs ONLY in not setting the
              # option, and its config must not carry the key AT ALL. An
              # emitted-but-empty key would restart garm on every existing host
              # and would hand the provider a cap it was never asked for.
              ipre=$(grep '^ExecStartPre=' "$incus" | head -1 | cut -d= -f2-)
              itmpl=$(grep -ohE '/nix/store/[a-z0-9]+-garm-config.toml.tmpl' "$ipre" | head -1)
              icfg=$(grep -ohE '/nix/store/[a-z0-9]+-garm-provider-vmharness\.toml' "$itmpl" | head -1)
              [ -f "$icfg" ] || fail "incus-uncapped: provider config not found"
              ! grep -q 'incus_limits_cpu' "$icfg" \
                || fail "incus-uncapped: incus_limits_cpu present without the option being set; the key must be inert by default"

              echo "[t_garm_multi_provider][PASS] union sandbox, incus-only strict posture, qemu-windows-arm provider config, the incus CPU cap (present when set, absent when not), and provider-off M0 posture all verified"
              touch $out
            '';
      };
    };
}
