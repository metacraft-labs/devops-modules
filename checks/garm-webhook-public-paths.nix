top@{ ... }:
{
  # t_garm_webhook_public_paths: the public webhook hostname forwards ONLY the
  # webhook path (and, with `exposeInstanceAPI`, GARM's instance-facing
  # metadata/callback paths), never the rest of the GARM API.
  #
  # Before 2026-10-07 the cloudflare-tunnel ingress rule had no `path`, so the
  # whole API, admin login included, answered on the public hostname (measured:
  # /api/v1/metadata/... and /api/v1/callbacks/... returned 401, not 404).
  #
  # Eval/build only, no VM and no mocks: it evaluates the real module in both
  # modes, reads the cloudflared config the NixOS module renders (the exact
  # file cloudflared runs with) and the nginx locations, and matches the
  # rendered ingress regex against allowed and refused paths with grep -E (the
  # regex uses only constructs on which POSIX ERE and Go RE2 agree).
  perSystem =
    { pkgs, lib, ... }:
    let
      flake = top.config.flake;
      evalHost =
        endpoint:
        (pkgs.nixos (
          { ... }:
          {
            imports = [ flake.modules.nixos.garm-webhook-endpoint ];
            boot.loader.grub.enable = false;
            fileSystems."/" = {
              device = "/dev/vda";
              fsType = "ext4";
            };
            system.stateVersion = "24.11";
            services.garm-webhook-endpoint = {
              enable = true;
              publicHostname = "ci-webhook.test";
              hmacSecretFile = "/run/secret";
            }
            // endpoint;
          }
        )).config;

      tunnel =
        expose:
        evalHost {
          mode = "cloudflare-tunnel";
          cloudflare.credentialsFile = "/run/cf.json";
          exposeInstanceAPI = expose;
        };
      # The unit's ExecStart (string context intact, so the config file is a
      # build input); the shell extracts the --config= path.
      unitExecStart =
        cfg:
        cfg.systemd.services."cloudflared-tunnel-${cfg.services.garm-webhook-endpoint.cloudflare.tunnelName}".serviceConfig.ExecStart;
      nginxLocations =
        expose:
        builtins.attrNames
          (evalHost {
            mode = "netbird-relay";
            tls = {
              enableACME = false;
              certFile = "/run/c.pem";
              keyFile = "/run/k.pem";
            };
            exposeInstanceAPI = expose;
          }).services.nginx.virtualHosts."ci-webhook.test".locations;
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_garm_webhook_public_paths =
          pkgs.runCommand "t_garm_webhook_public_paths"
            {
              nativeBuildInputs = [ pkgs.jq ];
              closedExec = unitExecStart (tunnel false);
              openExec = unitExecStart (tunnel true);
              nginxClosed = builtins.toJSON (nginxLocations false);
              nginxOpen = builtins.toJSON (nginxLocations true);
            }
            ''
              set -euo pipefail
              fail() { echo "[t_garm_webhook_public_paths][FAIL] $1" >&2; exit 1; }
              cfgOf() { echo "$1" | grep -oE -- '--config[= ][^ ]+' | head -1 | sed -E 's/^--config[= ]//'; }
              closedCfg=$(cfgOf "$closedExec"); openCfg=$(cfgOf "$openExec")
              [ -f "$closedCfg" ] && [ -f "$openCfg" ] || fail "cloudflared config not found in ExecStart: $closedExec"
              rx() { jq -r '.ingress[] | select(.hostname=="ci-webhook.test") | .path // ""' "$1"; }
              allows() { printf '%s\n' "$2" | grep -Eq -- "$1"; }

              for f in "$closedCfg" "$openCfg"; do
                jq -e '.ingress[-1].service == "http_status:404"' "$f" >/dev/null || fail "$f: catch-all is not http_status:404"
                [ -n "$(rx "$f")" ] || fail "$f: the public hostname's ingress rule has no path restriction"
              done

              closed=$(rx "$closedCfg"); open=$(rx "$openCfg")
              echo "closed: $closed"; echo "open:   $open"
              for p in /webhooks /webhooks/0b6f3c1e-uuid; do
                allows "$closed" "$p" || fail "closed tunnel refuses $p"
                allows "$open" "$p" || fail "open tunnel refuses $p"
              done
              for p in /api/v1/metadata/runner-registration-token/ /api/v1/callbacks/status; do
                ! allows "$closed" "$p" || fail "closed tunnel forwards instance path $p"
                allows "$open" "$p" || fail "exposeInstanceAPI tunnel refuses $p"
              done
              for p in /api/v1/auth/login /api/v1/pools /api/v1/credentials / /api/v1/metadataX /webhooksX /x/webhooks; do
                ! allows "$closed" "$p" || fail "closed tunnel forwards $p"
                ! allows "$open" "$p" || fail "open tunnel forwards $p"
              done

              echo "$nginxClosed" | jq -e '. == ["/","/webhooks"]' >/dev/null || fail "nginx (closed) locations: $nginxClosed"
              echo "$nginxOpen" | jq -e '. == ["/","/api/v1/callbacks","/api/v1/metadata","/webhooks"]' >/dev/null || fail "nginx (exposeInstanceAPI) locations: $nginxOpen"

              echo "[t_garm_webhook_public_paths][PASS]"
              touch "$out"
            '';
      };
    };
}
