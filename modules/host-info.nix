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
      };
    };
in
{
  flake.modules = {
    nixos.mcl-host-info = mclHostInfoModule;
    darwin.mcl-host-info = mclHostInfoModule;
  };
}
