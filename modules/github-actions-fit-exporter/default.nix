# github-actions-fit-exporter — the GENERAL "does this workflow fit
# ubuntu-latest?" exporter (Runner-Fleet-Capability-Pools-And-Remote-Driving RD4,
# gate `t_runner_fit_monitoring`).
#
# Company-agnostic: which orgs/repos, the token, the API base, the lookback and
# the log-scan toggle are all options. The concrete Metacraft instantiation
# (which repos, the agenix token, and the Prometheus wiring) lives in `infra`,
# per the campaign :repo_layering:. The alert rules over the emitted metrics are
# the companion `github-actions-fit-alerts` library.
#
# It runs gh-actions-fit-exporter.py on a timer and writes a node-exporter
# TEXTFILE snapshot, so no new scrape target is needed — the existing
# node-exporter textfile collector picks it up (same shape as
# garm-fleet-external-checks and win-runner-mem-sampler.py).
{ ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      packages.github-actions-fit-exporter =
        pkgs.runCommand "github-actions-fit-exporter" { nativeBuildInputs = [ pkgs.makeWrapper ]; }
          ''
            mkdir -p $out/bin $out/share
            cp ${./gh-actions-fit-exporter.py} $out/share/gh-actions-fit-exporter.py
            makeWrapper ${pkgs.python3}/bin/python3 $out/bin/github-actions-fit-exporter \
              --add-flags $out/share/gh-actions-fit-exporter.py
          '';
    };

  flake.modules.nixos.github-actions-fit-exporter =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.github-actions-fit-exporter;
      inherit (lib)
        mkEnableOption
        mkOption
        mkIf
        types
        ;

      reposJson = builtins.toJSON (
        map (r: {
          inherit (r) owner repo;
        }) cfg.repos
      );

      # The watched-repos list is handed to the exporter as a FILE PATH, not as
      # an inline JSON env value. systemd's `Environment=` directive parses
      # shell-style quoting, so an inline `GHA_REPOS_JSON=[{"owner":…}]` has its
      # double-quotes stripped before the process sees it and `json.loads` then
      # fails at runtime. A path has no shell-special characters, so it survives
      # intact — the exporter reads GHA_REPOS_FILE (falling back to the inline
      # GHA_REPOS_JSON for ad-hoc invocation / tests).
      reposFile = pkgs.writeText "github-actions-fit-repos.json" reposJson;
    in
    {
      options.services.github-actions-fit-exporter = {
        enable = mkEnableOption "the GitHub-Actions ubuntu-latest fit exporter (job duration + resource-limit signatures)";

        package = mkOption {
          type = types.package;
          default =
            pkgs.github-actions-fit-exporter or (throw "set services.github-actions-fit-exporter.package");
          description = "The exporter package (gh-actions-fit-exporter.py, stdlib-only).";
        };

        apiBase = mkOption {
          type = types.str;
          default = "https://api.github.com";
          description = "GitHub API base URL.";
        };

        tokenFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Path to a file containing a GitHub token with `actions:read` +
            `contents:read` on the watched repos (stage via agenix). Optional:
            public repos are readable unauthenticated, but a token raises the
            rate limit and is required for private repos and job logs.
          '';
        };

        textfileDir = mkOption {
          type = types.path;
          default = "/var/lib/prometheus-node-exporter/textfile";
          description = "node-exporter textfile-collector directory to write the .prom snapshot into.";
        };

        interval = mkOption {
          type = types.str;
          default = "15m";
          description = "systemd OnUnitActiveSec interval between exporter cycles.";
        };

        lookbackRuns = mkOption {
          type = types.int;
          default = 40;
          description = "How many recent completed workflow runs to inspect per repo each cycle.";
        };

        scanLogs = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Fetch and scan the logs of non-success jobs for OOM / no-space /
            timeout signatures. Costs one extra API call per failed job; turn off
            to emit duration only.
          '';
        };

        repos = mkOption {
          default = [ ];
          description = "The repositories to inspect (owner/repo).";
          type = types.listOf (
            types.submodule {
              options = {
                owner = mkOption {
                  type = types.str;
                  description = "GitHub owner/org login.";
                };
                repo = mkOption {
                  type = types.str;
                  description = "Repository name.";
                };
              };
            }
          );
        };
      };

      config = mkIf cfg.enable {
        # The textfile-collector output dir must both EXIST before this
        # strict-mounted unit starts AND be writable by the exporter's writer.
        # In production it is the SHARED node-exporter textfile-collector dir,
        # created `root:root 0755` by the sibling win-runner-mem-sampler
        # (infra services/monitoring/win-runner-memory.nix): node-exporter reads
        # it (world-readable), and a writer must be root to create files in it.
        # Declare the identical rule here so the dir also exists when this module
        # is the first/only writer on a host — two modules asserting the same
        # `d … 0755 root root` line is idempotent and conflict-free.
        #
        # NOTE ON POSTURE: the exporter runs as root (below), mirroring the
        # sibling sampler that writes this SAME dir successfully. A hardened
        # DynamicUser could NOT: `ReadWritePaths` only lifts systemd's mount-level
        # read-only bind, it does not bypass the filesystem's DAC ownership check,
        # so a transient DynamicUser uid gets EACCES creating its `.prom` `.tmp`
        # in a `root:root 0755` dir — the `PermissionError: [Errno 13]` observed
        # on hms. We deliberately match the sibling's `root` + `0755` posture
        # rather than widen the shared dir to world-writable (`0777`/`1777`).
        systemd.tmpfiles.rules = [ "d ${cfg.textfileDir} 0755 root root -" ];

        systemd.services.github-actions-fit-exporter = {
          description = "GitHub-Actions ubuntu-latest fit exporter (duration + resource-limit signatures)";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${cfg.package}/bin/github-actions-fit-exporter";
            # Root, matching the sibling win-runner-mem-sampler: the shared
            # node-exporter textfile dir is `root:root 0755`, so the writer that
            # creates the `.tmp`/`.prom` there must be root. Still hardened — the
            # service reads only the (agenix) token file and writes only the
            # textfile dir; ProtectSystem=strict keeps the rest of /var read-only
            # even for root, so ReadWritePaths is still required for the dir.
            User = "root";
            ProtectSystem = "strict";
            ProtectHome = true;
            NoNewPrivileges = true;
            ReadWritePaths = [ cfg.textfileDir ];
            Environment = [
              "GHA_OUTPUT=${cfg.textfileDir}/github-actions-fit.prom"
              "GHA_API=${cfg.apiBase}"
              "GHA_REPOS_FILE=${reposFile}"
              "GHA_LOOKBACK_RUNS=${toString cfg.lookbackRuns}"
              "GHA_SCAN_LOGS=${if cfg.scanLogs then "1" else "0"}"
            ]
            ++ lib.optional (cfg.tokenFile != null) "GHA_TOKEN_FILE=${cfg.tokenFile}";
          };
        };

        systemd.timers.github-actions-fit-exporter = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "3m";
            OnUnitActiveSec = cfg.interval;
          };
        };
      };
    };
}
