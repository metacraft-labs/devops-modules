top@{ ... }:
{
  # Remote provider guest URL override contract.
  #
  # A hermetic module render gate. A `remote` provider renders the runner
  # bootstrap on the GARM host, but the guest boots on the remote serve host,
  # whose network may not reach the controller's own metadata/callback URLs
  # (a Tart guest on a darwin serve host cannot reach the controller's overlay
  # address). `guestMetadataURL` / `guestCallbackURL` are the operator's way to
  # hand that guest a reachable route, and the provider reads them as the
  # top-level `guest_metadata_url` / `guest_callback_url` keys (config.Config,
  # applied in CreateInstance for every backend). This check proves a remote
  # provider that sets both renders both, as top-level keys ahead of the
  # `[remote]` table, and that a remote provider without them renders neither,
  # so every existing remote provider keeps a byte-identical config.toml.
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

      remoteProvider =
        extra:
        {
          backend = "remote";
          remote = {
            endpoint = "192.0.2.1:8873";
            targetBackend = "tart-linux-arm";
          };
        }
        // extra;

      plainConfig = mkSystem (remoteProvider { });
      overrideConfig = mkSystem (remoteProvider {
        guestMetadataURL = "https://garm.example.test/api/v1/metadata";
        guestCallbackURL = "https://garm.example.test/api/v1/callbacks";
      });

      failedMessages =
        config: map (a: a.message) (builtins.filter (a: !a.assertion) (config.assertions or [ ]));
      policyFailures =
        lib.optional (
          failedMessages plainConfig != [ ]
        ) "remote provider without overrides was rejected: ${toString (failedMessages plainConfig)}"
        ++
          lib.optional (failedMessages overrideConfig != [ ])
            "remote provider with guest URL overrides was rejected: ${toString (failedMessages overrideConfig)}";
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_garm_remote_guest_urls =
          assert lib.assertMsg (policyFailures == [ ]) (lib.concatStringsSep "\n" policyFailures);
          pkgs.runCommand "t_garm_remote_guest_urls"
            {
              nativeBuildInputs = [ pkgs.coreutils ];
              plainUnit = plainConfig.systemd.units."garm.service".unit;
              overrideUnit = overrideConfig.systemd.units."garm.service".unit;
            }
            ''
              set -euo pipefail

              provider_config() {
                unit="$1/garm.service"
                pre="$(grep '^ExecStartPre=' "$unit" | head -1 | cut -d= -f2-)"
                template="$(grep -oE '/nix/store/[a-z0-9]+-garm-config.toml.tmpl' "$pre" | head -1)"
                grep -oE '/nix/store/[a-z0-9]+-garm-provider-generic.toml' "$template" | head -1
              }

              # Line number of the first line equal to $1 in $2 (0 if absent).
              line_of() {
                grep -nFx "$1" "$2" | head -1 | cut -d: -f1 || true
              }

              plain="$(provider_config "$plainUnit")"
              grep -Fx 'backend = "remote"' "$plain"
              grep -Fx '[remote]' "$plain"
              if grep -Eq '^guest_(metadata|callback)_url[[:space:]]*=' "$plain"; then
                echo "remote provider without overrides rendered a guest URL key" >&2
                cat "$plain" >&2
                exit 1
              fi

              cfg="$(provider_config "$overrideUnit")"
              meta='guest_metadata_url = "https://garm.example.test/api/v1/metadata"'
              cb='guest_callback_url = "https://garm.example.test/api/v1/callbacks"'
              grep -Fx "$meta" "$cfg"
              grep -Fx "$cb" "$cfg"
              # Both must be TOP-LEVEL keys: after `[remote]` opens they would
              # decode into RemoteConfig, which has no such field, and the
              # provider would silently ignore them.
              remote_line="$(line_of '[remote]' "$cfg")"
              for key in "$meta" "$cb"; do
                key_line="$(line_of "$key" "$cfg")"
                if [ -z "$remote_line" ] || [ "$key_line" -ge "$remote_line" ]; then
                  echo "guest URL key is not ahead of the [remote] table: $key" >&2
                  cat "$cfg" >&2
                  exit 1
                fi
              done

              touch "$out"
            '';
      };
    };
}
