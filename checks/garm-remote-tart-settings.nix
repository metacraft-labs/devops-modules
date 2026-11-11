top@{ ... }:
{
  # Remote Tart per-job clone size contract.
  #
  # A hermetic module render/evaluation gate, the Tart sibling of
  # garm-remote-libvirt-settings.nix. It proves `remote.tartCpus` /
  # `remote.tartMemoryMb` reach only the [remote] provider TOML, are absent by
  # default, render when set for both Tart targets, and fail closed for a
  # non-Tart target or a non-remote provider. The argv those keys produce is
  # pinned by the provider's Go tests (TestRemoteCreateTartSize); the resize of
  # the real clone is gosti's (`tart set --cpu/--memory`) and is proven on the
  # consuming host.
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

      size = {
        tartCpus = 4;
        tartMemoryMb = 12288;
      };

      defaultConfig = mkSystem (remoteProvider "tart-linux-arm" { });
      linuxConfig = mkSystem (remoteProvider "tart-linux-arm" size);
      macosConfig = mkSystem (remoteProvider "tart-macos" size);
      badTarget = mkSystem (remoteProvider "libvirt" { tartCpus = 4; });
      badNonRemote = mkSystem {
        backend = "tart-linux-arm";
        remote = {
          targetBackend = "tart-linux-arm";
          tartMemoryMb = 12288;
        };
      };

      failedMessages =
        config: map (a: a.message) (builtins.filter (a: !a.assertion) (config.assertions or [ ]));
      targetMessage = "remote.tartCpus/tartMemoryMb require backend = \"remote\" and remote.targetBackend = \"tart-linux-arm\" or \"tart-macos\"";
      isExactFailure =
        needle: config:
        let
          failures = failedMessages config;
        in
        builtins.length failures == 1 && lib.hasInfix needle (lib.head failures);

      policyFailures =
        lib.optional (
          failedMessages defaultConfig != [ ]
        ) "default remote tart provider was rejected: ${toString (failedMessages defaultConfig)}"
        ++ lib.optional (
          failedMessages linuxConfig != [ ]
        ) "remote tart-linux-arm size was rejected: ${toString (failedMessages linuxConfig)}"
        ++ lib.optional (
          failedMessages macosConfig != [ ]
        ) "remote tart-macos size was rejected: ${toString (failedMessages macosConfig)}"
        ++
          lib.optional (!isExactFailure targetMessage badTarget)
            "remote.tartCpus did not fail exactly once for targetBackend=libvirt: ${toString (failedMessages badTarget)}"
        ++
          lib.optional (!isExactFailure targetMessage badNonRemote)
            "remote.tartMemoryMb did not fail exactly once for a non-remote provider: ${toString (failedMessages badNonRemote)}";
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_garm_remote_tart_settings =
          assert lib.assertMsg (policyFailures == [ ]) (lib.concatStringsSep "\n" policyFailures);
          pkgs.runCommand "t_garm_remote_tart_settings"
            {
              nativeBuildInputs = [ pkgs.coreutils ];
              defaultUnit = defaultConfig.systemd.units."garm.service".unit;
              linuxUnit = linuxConfig.systemd.units."garm.service".unit;
              macosUnit = macosConfig.systemd.units."garm.service".unit;
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
              grep -Fx '[remote]' "$default_config"
              grep -Fx 'target_backend = "tart-linux-arm"' "$default_config"
              if grep -Eq '^tart_(cpus|memory_mb)[[:space:]]*=' "$default_config"; then
                echo "default remote tart provider rendered an unrequested setting" >&2
                cat "$default_config" >&2
                exit 1
              fi

              for unit in "$linuxUnit" "$macosUnit"; do
                config="$(provider_config "$unit")"
                grep -Fx 'tart_cpus = 4' "$config"
                grep -Fx 'tart_memory_mb = 12288' "$config"
              done

              touch "$out"
            '';
      };
    };
}
