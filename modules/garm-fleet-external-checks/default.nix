# garm-fleet-external-checks — the GENERAL exporter for the two runner-chain
# checks garm_* cannot see (GitHub App token minting + webhook delivery health).
#
# Company-agnostic: hosts/orgs/creds are all options. The concrete Metacraft
# instantiation (which orgs, which App ids, which agenix key files, and the
# Prometheus scrape wiring) lives in `infra`, per the campaign :repo_layering:.
#
# It runs github-fleet-checks.py on a timer and writes a node-exporter TEXTFILE
# snapshot, so no new scrape target is needed — the existing node-exporter
# textfile collector picks it up. The garm-fleet-alerts library carries the
# alert rules over the emitted metrics.
{ ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      py = pkgs.python3.withPackages (p: [
        p.pyjwt
        p.cryptography
      ]);
    in
    {
      packages.garm-fleet-external-checks =
        pkgs.runCommand "garm-fleet-external-checks" { nativeBuildInputs = [ pkgs.makeWrapper ]; }
          ''
            mkdir -p $out/bin $out/share
            cp ${./github-fleet-checks.py} $out/share/github-fleet-checks.py
            makeWrapper ${py}/bin/python3 $out/bin/garm-fleet-external-checks \
              --add-flags $out/share/github-fleet-checks.py
          '';
    };

  flake.modules.nixos.garm-fleet-external-checks =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.garm-fleet-external-checks;
      inherit (lib)
        mkEnableOption
        mkOption
        mkIf
        types
        mapAttrsToList
        ;

      pkg = mkOption {
        type = types.package;
        default =
          pkgs.garm-fleet-external-checks or (throw "set services.garm-fleet-external-checks.package");
        description = "The exporter package (github-fleet-checks.py wrapped with PyJWT).";
      };

      appsJson = builtins.toJSON (
        mapAttrsToList (name: a: {
          app = name;
          app_id = a.appId;
          installation_id = a.installationId;
          private_key_file = a.privateKeyFile;
        }) cfg.apps
      );
      webhooksJson = builtins.toJSON (
        map (w: {
          inherit (w) org;
          hook_id = w.hookId;
          token_file = w.tokenFile;
        }) cfg.webhooks
      );
      # RC3 — blackbox probes of the public webhook endpoint(s). Distinct from
      # the App-token / delivery-ledger checks above; feeds RE1b's
      # GithubWebhookEndpointProbeDown (probe_success).
      probesJson = builtins.toJSON (
        map (p: {
          inherit (p) name url;
          expect_reject = p.expectReject;
        }) cfg.probes
      );
      # Pass the (non-secret: ids/paths/orgs/urls only) config as a single store
      # FILE rather than JSON-in-Environment: systemd's own quote parsing strips
      # the double-quotes out of a JSON value in `Environment=`, corrupting it.
      # A file is quote-safe for any content.
      configFile = pkgs.writeText "garm-fleet-external-checks.json" (
        builtins.toJSON {
          apps = builtins.fromJSON appsJson;
          webhooks = builtins.fromJSON webhooksJson;
          probes = builtins.fromJSON probesJson;
        }
      );
    in
    {
      options.services.garm-fleet-external-checks = {
        enable = mkEnableOption "the GARM fleet external-checks exporter (App token + webhook delivery)";
        package = pkg;

        apiBase = mkOption {
          type = types.str;
          default = "https://api.github.com";
          description = "GitHub API base URL.";
        };

        textfileDir = mkOption {
          type = types.path;
          default = "/var/lib/node-exporter/textfile";
          description = "node-exporter textfile-collector directory to write the .prom snapshot into.";
        };

        interval = mkOption {
          type = types.str;
          default = "5m";
          description = "systemd OnUnitActiveSec interval between check cycles.";
        };

        apps = mkOption {
          default = { };
          description = "GitHub Apps whose installation-token minting is checked (keyed by a display name used as the `app` label).";
          type = types.attrsOf (
            types.submodule {
              options = {
                appId = mkOption {
                  type = types.either types.int types.str;
                  description = "GitHub App id.";
                };
                installationId = mkOption {
                  type = types.either types.int types.str;
                  description = "Installation id to mint a token for.";
                };
                privateKeyFile = mkOption {
                  type = types.str;
                  description = "Path to the App private key (PEM); stage via agenix.";
                };
              };
            }
          );
        };

        webhooks = mkOption {
          default = [ ];
          description = "Org webhooks whose GitHub delivery ledger is checked (POST-PHASE-C).";
          type = types.listOf (
            types.submodule {
              options = {
                org = mkOption {
                  type = types.str;
                  description = "GitHub org login.";
                };
                hookId = mkOption {
                  type = types.either types.int types.str;
                  description = "The org webhook (hook) id.";
                };
                tokenFile = mkOption {
                  type = types.str;
                  description = "Path to a token with admin:org_hook read (or an App token file); stage via agenix.";
                };
              };
            }
          );
        };

        probes = mkOption {
          default = [ ];
          description = "Public webhook endpoints to blackbox-probe (RC3 delivery-health; feeds RE1b probe_success).";
          type = types.listOf (
            types.submodule {
              options = {
                name = mkOption {
                  type = types.str;
                  description = "Probe label (e.g. the org or hostname).";
                };
                url = mkOption {
                  type = types.str;
                  description = "Full public webhook URL to POST an unsigned probe at.";
                };
                expectReject = mkOption {
                  type = types.bool;
                  default = true;
                  description = "Treat a 2xx to an unsigned probe as a FAILURE (HMAC not enforced).";
                };
              };
            }
          );
        };
      };

      config = mkIf cfg.enable {
        # The textfile-collector output dir must EXIST before the hardened unit
        # starts: with `ProtectSystem = "strict"` + `ReadWritePaths = [ dir ]`,
        # systemd bind-mounts it read-write, and a missing dir fails mount-
        # namespace setup outright (`226/NAMESPACE: … No such file or directory`)
        # — the unit never runs. Create it world-writable so both node-exporter
        # (which READS the .prom snapshots) and this DynamicUser service (which
        # WRITES them) can use it without a shared owner.
        systemd.tmpfiles.rules = [ "d ${cfg.textfileDir} 0777 root root -" ];

        systemd.services.garm-fleet-external-checks = {
          description = "GARM fleet external checks (GitHub App token + webhook delivery)";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${cfg.package}/bin/garm-fleet-external-checks";
            # Hardened: only needs to read the (agenix) key files and write the
            # textfile dir.
            DynamicUser = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            NoNewPrivileges = true;
            ReadWritePaths = [ cfg.textfileDir ];
            Environment = [
              "GFC_OUTPUT=${cfg.textfileDir}/garm-fleet-external-checks.prom"
              "GFC_API=${cfg.apiBase}"
              "GFC_CONFIG_FILE=${configFile}"
            ];
          };
        };

        systemd.timers.garm-fleet-external-checks = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "2m";
            OnUnitActiveSec = cfg.interval;
          };
        };
      };
    };
}
