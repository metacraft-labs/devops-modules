# garm-webhook-endpoint — the GENERAL, parametric public front door for the
# central GARM's `/webhooks` endpoint (Runner-Fleet-Capability-Pools campaign,
# milestone RC3, gate t_garm_webhook_delivery).
#
# In POOL mode GitHub delivers `workflow_job` webhooks to GARM's HTTP endpoint
# (scale-set mode long-polled outbound and needed NO inbound path — pool mode
# gives that property up). This module re-adds a reachable public endpoint
# WITHOUT punching an inbound firewall hole into the private NetBird fleet, and
# leaves HMAC-SHA256 validation to GARM itself (GARM rejects a bad signature and
# increments `garm_webhook_received{valid="false"}`; this front door never sees
# the secret in `netbird-relay` mode and only proxies the RAW body so the HMAC
# GitHub computed still verifies at GARM).
#
# Two selectable transports, BOTH implemented (`mode`):
#
#   * "netbird-relay"   (DEFAULT — the lower-external-dependency choice):
#       an nginx TLS reverse proxy on a public relay host that is ALSO on the
#       NetBird overlay; it terminates TLS, pins the source to GitHub's
#       published hook IP ranges (`allow`/`deny`), and forwards the untouched
#       body to the central GARM's `:9997/webhooks` over the overlay. Reuses
#       NetBird, which the fleet already runs — it adds NO new external SaaS
#       account. The cost is one inbound TLS port (443) on the relay, pinned to
#       GitHub ranges, with GARM's HMAC as the real security boundary.
#
#   * "cloudflare-tunnel" (the security-optimal alternative; a NEW external
#       dependency — a Cloudflare account): a `cloudflared` daemon holding an
#       OUTBOUND-only tunnel to Cloudflare's edge, with an ingress rule mapping
#       the public hostname to the local GARM. No inbound firewall port at all.
#       GitHub-IP pinning is enforced at the Cloudflare edge (a WAF rule — it
#       cannot be expressed in NixOS, so it is documented, not configured here;
#       a local `allow`/`deny` would break because cloudflared originates from
#       Cloudflare edge IPs, not GitHub's).
#
# RECOMMENDATION (per the RC3 directive to minimize external dependencies):
# DEFAULT to `netbird-relay`. NetBird is already a fleet dependency; a
# Cloudflare account is a brand-new external dependency and a third party in the
# webhook trust path. `cloudflare-tunnel` remains fully implemented and is the
# stronger no-inbound-hole posture — pick it when a Cloudflare account is
# acceptable and the extra hardening is wanted. See README.md.
#
# Company-agnostic: hostnames/creds/orgs are all options with sane defaults and
# NO baked-in Metacraft specifics. The concrete instantiation (the real relay
# host or Cloudflare account, agenix secrets, NetBird addresses, the three orgs'
# webhook registrations) lives in `infra`, per the campaign :repo_layering:.
{ ... }:
{
  flake.modules.nixos.garm-webhook-endpoint =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.garm-webhook-endpoint;
      inherit (lib)
        mkEnableOption
        mkOption
        mkIf
        mkMerge
        types
        concatStringsSep
        optionalString
        optionals
        ;

      webhookUrl = "https://${cfg.publicHostname}${cfg.webhookPath}";

      # The org-webhook REGISTRATION SHAPE. This is exactly the JSON body an
      # operator (or `gh api -X POST /orgs/{org}/hooks`) posts to GitHub to point
      # an org at this endpoint. Non-secret: the HMAC secret is referenced by
      # file, never embedded — the operator injects it when registering.
      registrationFor = w: {
        name = "web";
        active = true;
        events = cfg.events;
        config = {
          url = webhookUrl;
          content_type = "json";
          insecure_ssl = "0";
          # secret is supplied by the operator from ${cfg.hmacSecretFile} at
          # registration time; it is intentionally NOT written to the store.
          secret = "@SECRET_FROM_${
            lib.toUpper (builtins.replaceStrings [ "/" "." "-" ] [ "_" "_" "_" ] (toString cfg.hmacSecretFile))
          }@";
        };
      };

      # GitHub's published hook source ranges (api.github.com/meta -> "hooks").
      # Refresh from /meta periodically; pinned here as a sane default so the
      # relay is closed to the internet at large out of the box.
      githubHookCidrsDefault = [
        "192.30.252.0/22"
        "185.199.108.0/22"
        "140.82.112.0/20"
        "143.55.64.0/20"
        "2a0a:a440::/29"
        "2606:50c0::/32"
      ];
    in
    {
      options.services.garm-webhook-endpoint = {
        enable = mkEnableOption "the public webhook endpoint fronting the central GARM /webhooks (RC3)";

        mode = mkOption {
          type = types.enum [
            "netbird-relay"
            "cloudflare-tunnel"
          ];
          default = "netbird-relay";
          description = ''
            Transport for the public endpoint.

            "netbird-relay" (default, lowest external dependency): an nginx TLS
            reverse proxy on a NetBird-connected relay, GitHub-IP-pinned,
            forwarding the raw body to GARM over the overlay.

            "cloudflare-tunnel": an outbound-only cloudflared tunnel (no inbound
            port) — the stronger posture, at the cost of a Cloudflare account.
          '';
        };

        publicHostname = mkOption {
          type = types.str;
          example = "ci-webhook.example.com";
          description = "Public FQDN GitHub delivers webhooks to.";
        };

        webhookPath = mkOption {
          type = types.str;
          default = "/webhooks";
          description = ''
            Path GARM serves the workflow_job handler on. Bare `/webhooks`, or
            the controller-scoped `/webhooks/<controller-webhook-uuid>` form.
          '';
        };

        upstream = mkOption {
          type = types.str;
          default = "http://127.0.0.1:9997";
          example = "http://100.83.0.10:9997";
          description = ''
            The central GARM apiserver base URL the endpoint forwards to
            (typically its NetBird overlay address on :9997, or loopback when
            the relay runs on the GARM host).
          '';
        };

        events = mkOption {
          type = types.listOf types.str;
          default = [ "workflow_job" ];
          description = "GitHub events the org webhook subscribes to (registration shape).";
        };

        pinToGithubRanges = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Restrict the endpoint to GitHub's published hook source ranges.
            Enforced in nginx (allow/deny) for netbird-relay; for
            cloudflare-tunnel this is a documented Cloudflare WAF rule (edge
            enforcement) and cannot be set from NixOS.
          '';
        };

        githubHookCidrs = mkOption {
          type = types.listOf types.str;
          default = githubHookCidrsDefault;
          description = "GitHub hook source CIDRs to allow (refresh from api.github.com/meta).";
        };

        hmacSecretFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "/run/agenix/garm-webhook-secret";
          description = ''
            Path to the per-entity HMAC-SHA256 webhook secret (stage via
            agenix). GARM validates the signature against this; the endpoint
            references it only for the registration shape and never embeds it in
            the store. Required to render org registrations.
          '';
        };

        orgWebhooks = mkOption {
          default = [ ];
          description = "Orgs to emit a webhook registration shape for (written to /etc/garm-webhook).";
          type = types.listOf (
            types.submodule {
              options = {
                org = mkOption {
                  type = types.str;
                  description = "GitHub org login.";
                };
              };
            }
          );
        };

        # netbird-relay TLS material.
        tls = {
          certFile = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "TLS certificate (fullchain) for the public hostname (netbird-relay).";
          };
          keyFile = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "TLS private key for the public hostname (netbird-relay).";
          };
          enableACME = mkOption {
            type = types.bool;
            default = false;
            description = "Use ACME/Let's Encrypt for the public hostname instead of certFile/keyFile.";
          };
        };

        # cloudflare-tunnel material.
        cloudflare = {
          tunnelName = mkOption {
            type = types.str;
            default = "garm-webhook";
            description = "cloudflared tunnel name.";
          };
          credentialsFile = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "cloudflared tunnel credentials JSON (stage via agenix).";
          };
        };

        # Read-only computed artifacts consumers (infra, external-checks) reuse.
        webhookUrl = mkOption {
          type = types.str;
          readOnly = true;
          default = webhookUrl;
          description = "The full public webhook URL (https://<publicHostname><webhookPath>).";
        };
      };

      config = mkIf cfg.enable (mkMerge [
        # ── common: emit the registration shapes for the operator ────────────
        {
          assertions = [
            {
              assertion = cfg.orgWebhooks == [ ] || cfg.hmacSecretFile != null;
              message = "services.garm-webhook-endpoint: orgWebhooks set but hmacSecretFile is null — the registration shape needs the secret file reference.";
            }
          ];
          environment.etc = lib.listToAttrs (
            map (w: {
              name = "garm-webhook/registration-${w.org}.json";
              value = {
                text = builtins.toJSON (registrationFor w);
                mode = "0444";
              };
            }) cfg.orgWebhooks
          );
        }

        # ── netbird-relay: nginx TLS reverse proxy, GitHub-IP-pinned ─────────
        (mkIf (cfg.mode == "netbird-relay") {
          assertions = [
            {
              assertion = cfg.tls.enableACME || (cfg.tls.certFile != null && cfg.tls.keyFile != null);
              message = "services.garm-webhook-endpoint (netbird-relay): set tls.enableACME or both tls.certFile and tls.keyFile.";
            }
          ];

          services.nginx = {
            enable = true;
            recommendedProxySettings = true;
            virtualHosts.${cfg.publicHostname} = {
              forceSSL = true;
              enableACME = cfg.tls.enableACME;
              sslCertificate = mkIf (!cfg.tls.enableACME) cfg.tls.certFile;
              sslCertificateKey = mkIf (!cfg.tls.enableACME) cfg.tls.keyFile;
              locations.${cfg.webhookPath} = {
                # Forward the RAW body unchanged — any rewrite would break the
                # HMAC GitHub computed over the exact bytes.
                proxyPass = "${cfg.upstream}${cfg.webhookPath}";
                extraConfig = ''
                  proxy_request_buffering off;
                  proxy_http_version 1.1;
                  ${optionalString cfg.pinToGithubRanges (
                    (concatStringsSep "\n" (map (c: "allow ${c};") cfg.githubHookCidrs)) + "\ndeny all;"
                  )}
                '';
              };
              # Everything else is closed.
              locations."/" = {
                extraConfig = "return 404;";
              };
            };
          };

          networking.firewall.allowedTCPPorts = [ 443 ] ++ optionals cfg.tls.enableACME [ 80 ];
        })

        # ── cloudflare-tunnel: outbound-only, no inbound port ────────────────
        (mkIf (cfg.mode == "cloudflare-tunnel") {
          assertions = [
            {
              assertion = cfg.cloudflare.credentialsFile != null;
              message = "services.garm-webhook-endpoint (cloudflare-tunnel): set cloudflare.credentialsFile (stage via agenix).";
            }
          ];

          services.cloudflared = {
            enable = true;
            tunnels.${cfg.cloudflare.tunnelName} = {
              credentialsFile = cfg.cloudflare.credentialsFile;
              default = "http_status:404";
              ingress.${cfg.publicHostname} = {
                service = cfg.upstream;
                # cloudflared only forwards this hostname's traffic to GARM;
                # GitHub-IP pinning is a Cloudflare edge WAF rule (documented in
                # README.md), NOT a NixOS-expressible allow/deny.
              };
            };
          };
          # No inbound firewall port: the tunnel is OUTBOUND only.
        })
      ]);
    };
}
