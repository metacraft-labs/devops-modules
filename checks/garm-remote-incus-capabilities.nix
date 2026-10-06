top@{ ... }:
{
  # Remote Incus capability-grant contract.
  #
  # This is a hermetic module render/evaluation gate. It proves the two
  # provider-admin booleans reach only the [remote] provider TOML, are absent by
  # default, render in deterministic order when enabled, and fail closed for a
  # non-Incus remote target or a non-remote provider. The real /dev/kvm attach
  # and read/write-open proof lives in vm-harness; concrete host enablement and
  # a live runner build requiring the `kvm` Nix system feature belong in the
  # consuming private infrastructure repository.
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

      remoteProvider = targetBackend: capability: {
        backend = "remote";
        remote = {
          endpoint = "192.0.2.1:8873";
          inherit targetBackend;
        }
        // capability;
      };

      defaultConfig = mkSystem (remoteProvider "incus" { });
      enabledConfig = mkSystem (
        remoteProvider "incus" {
          incusSecurityNesting = true;
          incusNestedKvm = true;
          incusLimitsCpu = 6;
          incusLimitsMemoryMb = 16384;
        }
      );
      badLimitsTarget = mkSystem (
        remoteProvider "libvirt" {
          incusLimitsCpu = 6;
        }
      );
      badSecurityTarget = mkSystem (
        remoteProvider "noop" {
          incusSecurityNesting = true;
        }
      );
      badKvmTarget = mkSystem (
        remoteProvider "libvirt" {
          incusNestedKvm = true;
        }
      );
      badNonRemote = mkSystem {
        backend = "libvirt";
        remote = {
          targetBackend = "incus";
          incusNestedKvm = true;
        };
      };

      failedMessages =
        config: map (a: a.message) (builtins.filter (a: !a.assertion) (config.assertions or [ ]));
      securityMessage = "remote.incusSecurityNesting requires backend = \"remote\" and remote.targetBackend = \"incus\"";
      kvmMessage = "remote.incusNestedKvm requires backend = \"remote\" and remote.targetBackend = \"incus\"";
      limitsMessage = "remote.incusLimitsCpu/incusLimitsMemoryMb require backend = \"remote\" and remote.targetBackend = \"incus\"";
      isExactFailure =
        needle: config:
        let
          failures = failedMessages config;
        in
        builtins.length failures == 1 && lib.hasInfix needle (lib.head failures);

      policyFailures =
        lib.optional (
          failedMessages defaultConfig != [ ]
        ) "default remote Incus provider was rejected: ${toString (failedMessages defaultConfig)}"
        ++ lib.optional (
          failedMessages enabledConfig != [ ]
        ) "enabled remote Incus capabilities were rejected: ${toString (failedMessages enabledConfig)}"
        ++
          lib.optional (!isExactFailure securityMessage badSecurityTarget)
            "remote.incusSecurityNesting did not fail exactly once for targetBackend=noop: ${toString (failedMessages badSecurityTarget)}"
        ++
          lib.optional (!isExactFailure kvmMessage badKvmTarget)
            "remote.incusNestedKvm did not fail exactly once for targetBackend=libvirt: ${toString (failedMessages badKvmTarget)}"
        ++
          lib.optional (!isExactFailure kvmMessage badNonRemote)
            "remote.incusNestedKvm did not fail exactly once for a non-remote provider: ${toString (failedMessages badNonRemote)}"
        ++
          lib.optional (!isExactFailure limitsMessage badLimitsTarget)
            "remote.incusLimitsCpu did not fail exactly once for targetBackend=libvirt: ${toString (failedMessages badLimitsTarget)}";
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_garm_remote_incus_capabilities =
          assert lib.assertMsg (policyFailures == [ ]) (lib.concatStringsSep "\n" policyFailures);
          pkgs.runCommand "t_garm_remote_incus_capabilities"
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
              grep -Fx 'target_backend = "incus"' "$default_config"
              if grep -Eq '^incus_(security_nesting|nested_kvm|limits_cpu|limits_memory_mb)[[:space:]]*=' "$default_config"; then
                echo "default remote provider rendered an unrequested Incus capability" >&2
                cat "$default_config" >&2
                exit 1
              fi

              grep -Fx '[remote]' "$enabled_config"
              grep -Fx 'incus_security_nesting = true' "$enabled_config"
              grep -Fx 'incus_nested_kvm = true' "$enabled_config"
              nesting_line="$(grep -nFx 'incus_security_nesting = true' "$enabled_config" | cut -d: -f1)"
              kvm_line="$(grep -nFx 'incus_nested_kvm = true' "$enabled_config" | cut -d: -f1)"
              test "$nesting_line" -lt "$kvm_line"
              grep -Fx 'incus_limits_cpu = 6' "$enabled_config"
              grep -Fx 'incus_limits_memory_mb = 16384' "$enabled_config"

              # The module exposes only booleans that map to vm-harness's fixed
              # flags: never a caller-selected Incus key, path, type, or mode.
              if grep -Eq '^incus_(config|device|device_path|device_mode)[[:space:]]*=' "$enabled_config"; then
                echo "remote provider rendered an arbitrary Incus privilege field" >&2
                cat "$enabled_config" >&2
                exit 1
              fi

              touch "$out"
            '';
      };
    };
}
