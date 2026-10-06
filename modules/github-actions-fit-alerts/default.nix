# github-actions-fit alerting — the GENERAL, parametric NixOS + package surface
# (Runner-Fleet-Capability-Pools-And-Remote-Driving RD4, gate
# `t_runner_fit_monitoring`).
#
# The company-agnostic alert-rule LIBRARY lives here; the concrete
# routing/targets/thresholds + the pinned ubuntu-latest baseline for a specific
# fleet live in that operator's `infra`. Mirrors modules/garm-fleet-alerts.
#
#   * `services.github-actions-fit-alerts` — renders ./rules.nix with the
#     operator's thresholds into `services.prometheus.ruleFiles`.
#   * `packages.github-actions-fit-alert-rules` — the default-threshold render,
#     so the rules are build-testable with promtool WITHOUT any infra (the gate
#     checks/fit-monitoring.nix consumes it).
{ ... }:
{
  perSystem =
    { pkgs, lib, ... }:
    {
      packages.github-actions-fit-alert-rules = pkgs.writeText "github-actions-fit-alerts.yml" (
        import ./rules.nix { inherit lib; }
      );
    };

  flake.modules.nixos.github-actions-fit-alerts =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.github-actions-fit-alerts;
      inherit (lib)
        mkEnableOption
        mkOption
        mkIf
        types
        ;

      rendered = import ./rules.nix {
        inherit lib;
        inherit (cfg)
          runnerType
          visibility
          baselineWindow
          baselineOffset
          regressionFactor
          durationRegressionFor
          resourceLimitFor
          ;
        inherit (cfg) minDurationSeconds;
      };
    in
    {
      options.services.github-actions-fit-alerts = {
        enable = mkEnableOption "the GitHub-Actions ubuntu-latest fit alert-rule library";

        runnerType = mkOption {
          type = types.str;
          default = "github-hosted";
          description = "The `runner_type` label the fit question is scoped to.";
        };
        visibility = mkOption {
          type = types.str;
          default = "public";
          description = "The repo `visibility` the fit question is scoped to (public repos get the free hosted minutes).";
        };
        baselineWindow = mkOption {
          type = types.str;
          default = "30m";
          description = "Trailing window for the duration baseline (a recording rule).";
        };
        baselineOffset = mkOption {
          type = types.str;
          default = "30m";
          description = "Offset applied to the baseline window so it excludes the regression it is compared against.";
        };
        regressionFactor = mkOption {
          type = types.str;
          default = "1.5";
          description = "Multiple of the baseline a duration must exceed to be a regression.";
        };
        minDurationSeconds = mkOption {
          type = types.int;
          default = 120;
          description = "Floor (seconds) below which a duration regression never pages (a fast job doubling is noise).";
        };
        durationRegressionFor = mkOption {
          type = types.str;
          default = "10m";
          description = "`for:` on the duration-regression alert.";
        };
        resourceLimitFor = mkOption {
          type = types.str;
          default = "10m";
          description = "`for:` on the resource-limit alert.";
        };
      };

      config = mkIf cfg.enable {
        services.prometheus.ruleFiles = [
          (pkgs.writeText "github-actions-fit-alerts.yml" rendered)
        ];
      };
    };
}
