{ withSystem, ... }:
{
  flake.modules.nixos.nix-topology-extractors =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib) mkIf mkMerge;

      getFileFromZip =
        {
          url,
          hash,
          path,
          stripRoot ? true,
        }:
        let
          zip = pkgs.fetchzip {
            inherit stripRoot url hash;
          };
        in
        zip + path;
    in
    {
      config.topology.self.services = mkIf config.topology.extractors.services.enable {
        tailscale = mkIf config.services.tailscale.enable {
          name = "Tailscale";
          icon = getFileFromZip {
            url = "https://cdn.sanity.io/files/w77i7m8x/production/a426ba5f63316745e108a18a6dbbfed6970752fd.zip";
            hash = "sha256-dcxxIKa7d6FyGQdQ3xJBoV+sSTOYcvD//UUFqTERQsw=";
            path = "/Tailscale Logo/svg/Wht/Tailscale_icon_wht_rgb.svg";
            stripRoot = false;
          };
        };

        # NixOS 26.05 removed promtail: reading `config.services.promtail`
        # there throws (a removed option, not an unset one), failing the
        # topology build for every machine on 26.05. `&&` short-circuits, so
        # the option is only read on releases that still have it. (Alloy, its
        # replacement, is covered by nix-topology's own extractor.)
        promtail = mkIf (lib.versionOlder lib.trivial.release "26.05" && config.services.promtail.enable) {
          name = "Promtail";
          icon = "services.loki";
        };

        prometheus-exporters-node = mkIf config.services.prometheus.exporters.node.enable {
          name = "Prometheus node exporter";
          icon = "services.prometheus";
        };

        gitlab = mkIf config.services.gitlab.enable {
          name = "GitLab";
          icon = pkgs.fetchurl {
            url = "https://about.gitlab.com/images/press/gitlab-logo-500-rgb.svg";
            hash = "sha256-2FIvm7g7Nbzwq25/wloxLCYSACivMIvsHdnSDhXBphU=";
          };
        };

        vscode-server = mkIf (config.services ? vscode-server && config.services.vscode-server.enable) {
          name = "VSCode Server";
          icon = getFileFromZip {
            url = "https://code.visualstudio.com/assets/branding/visual-studio-code-icons.zip";
            hash = "sha256-ePUcc/ePGJeMw1U3LVuPDx0XDgb4PIkfCJM3zSO9gsk=";
            path = "/vscode.svg";
          };
        };

        ethereum = mkIf (config.services ? ethereum) {
          name = "Ethereum services";
          icon = pkgs.fetchurl {
            url = "https://ethereum.org/images/assets/svgs/eth-diamond-purple.svg";
            hash = "sha256-cyDmTiEdt0cwjMPlRuU2DULzeQt6FPugUEVzeQ4X8SQ=";
          };
          details = mkMerge [
            (mkIf
              (config.services.ethereum ? nimbus-eth2 && config.services.ethereum.nimbus-eth2.enable or false)
              {
                Nimbus.text = "";
              }
            )
            (mkIf (config.services.ethereum ? geth && config.services.ethereum.geth.enable or false) {
              Geth.text = "";
            })
            (mkIf (config.services.ethereum ? nethermind && config.services.ethereum.nethermind.enable or false)
              {
                Nethermind.text = "";
              }
            )
            (mkIf (config.services.ethereum ? erigon && config.services.ethereum.erigon.enable or false) {
              Erigon.text = "";
            })
          ];
        };
      };
    };
}
