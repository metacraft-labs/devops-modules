top@{ ... }:
{
  # Remote libvirt firmware + per-job size contract.
  #
  # A hermetic module render/evaluation gate, the libvirt sibling of
  # garm-remote-incus-capabilities.nix. It proves the four provider-admin
  # settings reach only the [remote] provider TOML, are absent by default,
  # render when set, and fail closed for a non-libvirt target, a non-remote
  # provider, or a half-specified firmware pair. The argv those keys produce is
  # pinned by the provider's Go tests (TestRemoteCreateLibvirtUEFIAndSize); the
  # real boot of a UEFI Windows golden is proven on the consuming host.
  perSystem =
    {
      pkgs,
      lib,
      ...
    }:
    let
      flake = top.config.flake;

      mkSystem =
        provider:
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
            services.garm = {
              enable = true;
              providers.generic = provider;
            };
          }
        )).config;

      remoteProvider = targetBackend: settings: {
        backend = "remote";
        remote = {
          endpoint = "192.0.2.1:8873";
          inherit targetBackend;
        }
        // settings;
      };

      firmware = {
        libvirtUefiLoader = "/run/libvirt/nix-ovmf/edk2-x86_64-code.fd";
        libvirtUefiNvramTemplate = "/run/libvirt/nix-ovmf/edk2-i386-vars.fd";
      };

      defaultConfig = mkSystem (remoteProvider "libvirt" { });
      enabledConfig = mkSystem (
        remoteProvider "libvirt" (
          firmware
          // {
            libvirtCpus = 4;
            libvirtMemoryMb = 16384;
          }
        )
      );
      badTarget = mkSystem (remoteProvider "incus" { libvirtCpus = 4; });
      badNonRemote = mkSystem {
        backend = "libvirt";
        remote = {
          targetBackend = "libvirt";
          libvirtMemoryMb = 16384;
        };
      };
      badHalfPair = mkSystem (
        remoteProvider "libvirt" { libvirtUefiLoader = "/run/libvirt/nix-ovmf/edk2-x86_64-code.fd"; }
      );

      failedMessages =
        config: map (a: a.message) (builtins.filter (a: !a.assertion) (config.assertions or [ ]));
      targetMessage = "remote.libvirt* require backend = \"remote\" and remote.targetBackend = \"libvirt\"";
      pairMessage = "remote.libvirtUefiLoader and libvirtUefiNvramTemplate must be set together";
      isExactFailure =
        needle: config:
        let
          failures = failedMessages config;
        in
        builtins.length failures == 1 && lib.hasInfix needle (lib.head failures);

      policyFailures =
        lib.optional (
          failedMessages defaultConfig != [ ]
        ) "default remote libvirt provider was rejected: ${toString (failedMessages defaultConfig)}"
        ++ lib.optional (
          failedMessages enabledConfig != [ ]
        ) "remote libvirt settings were rejected: ${toString (failedMessages enabledConfig)}"
        ++
          lib.optional (!isExactFailure targetMessage badTarget)
            "remote.libvirtCpus did not fail exactly once for targetBackend=incus: ${toString (failedMessages badTarget)}"
        ++
          lib.optional (!isExactFailure targetMessage badNonRemote)
            "remote.libvirtMemoryMb did not fail exactly once for a non-remote provider: ${toString (failedMessages badNonRemote)}"
        ++ lib.optional (
          !isExactFailure pairMessage badHalfPair
        ) "a lone libvirtUefiLoader did not fail exactly once: ${toString (failedMessages badHalfPair)}";
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_garm_remote_libvirt_settings =
          assert lib.assertMsg (policyFailures == [ ]) (lib.concatStringsSep "\n" policyFailures);
          pkgs.runCommand "t_garm_remote_libvirt_settings"
            {
              nativeBuildInputs = [ pkgs.coreutils ];
              defaultUnit = defaultConfig.systemd.units."garm.service".unit;
              enabledUnit = enabledConfig.systemd.units."garm.service".unit;
            }
            ''
              set -euo pipefail

              provider_config() {
                unit="$1/garm.service"
                pre="$(grep '^ExecStartPre=' "$unit" | head -1 | cut -d= -f2-)"
                template="$(grep -oE '/nix/store/[a-z0-9]+-garm-config.toml.tmpl' "$pre" | head -1)"
                grep -oE '/nix/store/[a-z0-9]+-garm-provider-generic.toml' "$template" | head -1
              }

              default_config="$(provider_config "$defaultUnit")"
              enabled_config="$(provider_config "$enabledUnit")"

              grep -Fx '[remote]' "$default_config"
              grep -Fx 'target_backend = "libvirt"' "$default_config"
              if grep -Eq '^libvirt_(uefi_loader|uefi_nvram_template|cpus|memory_mb)[[:space:]]*=' "$default_config"; then
                echo "default remote libvirt provider rendered an unrequested setting" >&2
                cat "$default_config" >&2
                exit 1
              fi

              grep -Fx 'libvirt_uefi_loader = "/run/libvirt/nix-ovmf/edk2-x86_64-code.fd"' "$enabled_config"
              grep -Fx 'libvirt_uefi_nvram_template = "/run/libvirt/nix-ovmf/edk2-i386-vars.fd"' "$enabled_config"
              grep -Fx 'libvirt_cpus = 4' "$enabled_config"
              grep -Fx 'libvirt_memory_mb = 16384' "$enabled_config"

              touch "$out"
            '';
      };
    };
}
