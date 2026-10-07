{ withSystem, ... }:
let
  mclHostInfoModule =
    {
      config,
      lib,
      ...
    }:
    {
      config = {
        assertions = [
          {
            assertion = lib.path.subpath.isValid config.mcl.host-info.configPath;
            message = "mcl.host-info.configPath must be a valid relative subpath without '..' components (got '${config.mcl.host-info.configPath}')";
          }
        ];
      };

      options.mcl.host-info = with lib; {
        type = mkOption {
          type = types.enum [
            "notebook"
            "desktop"
            "server"
            "container"
          ];
          example = "desktop";
          description = ''
            Whether this host is a desktop or a server.
          '';
        };

        isDebugVM = mkOption {
          type = types.bool;
          example = false;
          description = ''
            Whether this configuration is a VM variant with extra debug functionality.
          '';
        };

        configPath = mkOption {
          type = types.str;
          example = "./machines/server/example-site-server";
          description = ''
            The configuration path for this host relative to the repo root.
          '';
        };

        sshKey = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "ssh-ed25519 AAAAC3Nza";
          description = ''
            The public ssh key for this host.
          '';
        };

        hosting = mkOption {
          type = types.nullOr (
            types.submodule {
              options = {
                provider = mkOption {
                  type = types.str;
                  example = "hetzner";
                  description = ''
                    The hosting provider that owns the machine.
                  '';
                };

                reference = mkOption {
                  type = types.str;
                  example = "auction #1310140";
                  description = ''
                    The provider's stable identifier for the machine, such as a
                    Hetzner Robot server auction ID. Unlike provider-side labels,
                    it does not change when the machine is renamed.
                  '';
                };

                datacenter = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  example = "FSN1-DC11";
                  description = ''
                    The provider's datacenter or location code.
                  '';
                };

                ipv4 = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  example = "203.0.113.10";
                  description = ''
                    The primary public IPv4 address assigned by the provider.
                  '';
                };

                ipv6Prefix = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  example = "2001:db8:1::/64";
                  description = ''
                    The public IPv6 prefix assigned by the provider.
                  '';
                };
              };
            }
          );
          default = null;
          description = ''
            Informational metadata identifying the machine at its hosting
            provider. It does not affect the system configuration.
          '';
        };
      };
    };
in
{
  flake.modules = {
    nixos.mcl-host-info = mclHostInfoModule;
    darwin.mcl-host-info = mclHostInfoModule;
  };
}
