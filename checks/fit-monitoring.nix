_top@{ ... }:
{
  # Runner-Fleet-Capability-Pools-And-Remote-Driving RD4 gate:
  # t_runner_fit_monitoring.
  #
  # Proves the "does this workflow fit ubuntu-latest?" monitoring end to end,
  # WITHOUT the infra repo and WITHOUT the real GitHub API:
  #
  #   (a) the exporter (../modules/github-actions-fit-exporter) emits the right
  #       DURATION metrics — value, github-hosted-vs-self-hosted classification,
  #       and repo visibility — from a MOCK Actions API response;
  #   (b) the RESOURCE-LIMIT signature detector fires on OOM / no-space / timeout
  #       job-log fixtures and stays silent on a clean success;
  #   (c) `promtool test rules` asserts the duration-regression record and the
  #       resource-limit alert on a replayed incident and through the controls
  #       (../modules/github-actions-fit-alerts/tests/fit-monitoring.test.yml),
  #       and the opt-in duration-regression warning on a second render with
  #       `durationRegressionAlert = true` (fit-monitoring-duration-alert.test.yml).
  #
  # Parts (a)+(b) run the packaged exporter as a REAL subprocess against a REAL
  # loopback http.server serving canned Actions-API JSON + logs — the only mock
  # is the GitHub boundary itself (justified in the test header). Part (c) uses
  # the same promtool contract infra's `just check-alert-rules` uses.
  perSystem =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    let
      exporter = config.packages.github-actions-fit-exporter;
      exporterTest = ../modules/github-actions-fit-exporter/tests/fit-exporter-test.py;
      rules = config.packages.github-actions-fit-alert-rules;
      testFile = ../modules/github-actions-fit-alerts/tests/fit-monitoring.test.yml;
      # The opt-in warning, rendered and replayed separately so the option is
      # exercised and not just declared.
      alertRules = pkgs.writeText "github-actions-fit-alerts-duration-alert.yml" (
        import ../modules/github-actions-fit-alerts/rules.nix {
          inherit lib;
          durationRegressionAlert = true;
        }
      );
      alertTestFile = ../modules/github-actions-fit-alerts/tests/fit-monitoring-duration-alert.test.yml;
      promtool = "${pkgs.prometheus.cli}/bin/promtool";
    in
    {
      checks.t_runner_fit_monitoring =
        pkgs.runCommand "t_runner_fit_monitoring"
          {
            nativeBuildInputs = [
              pkgs.python3
              pkgs.prometheus.cli
            ];
          }
          ''
            set -euo pipefail
            fail() { echo "[t_runner_fit_monitoring][FAIL] $1" >&2; exit 1; }

            # (a)+(b) — exporter metrics + resource-limit signatures, against a
            # loopback mock of the GitHub Actions API (no real network, no token).
            echo "[t_runner_fit_monitoring] exporter unit test (mock Actions API)"
            EXPORTER=${exporter}/bin/github-actions-fit-exporter \
              python3 ${exporterTest} \
              || fail "exporter did not emit the expected duration/classification/signature metrics"

            # (c) — the alert-rule library parses + fires as asserted.
            cp ${rules}          github-actions-fit-alerts.yml
            cp ${testFile}       fit-monitoring.test.yml
            cp ${alertRules}     github-actions-fit-alerts-duration-alert.yml
            cp ${alertTestFile}  fit-monitoring-duration-alert.test.yml

            echo "[t_runner_fit_monitoring] promtool check rules"
            ${promtool} check rules github-actions-fit-alerts.yml \
              github-actions-fit-alerts-duration-alert.yml \
              || fail "promtool check rules rejected the fit library"

            echo "[t_runner_fit_monitoring] promtool test rules (fault injection)"
            ${promtool} test rules fit-monitoring.test.yml \
              fit-monitoring-duration-alert.test.yml \
              || fail "a fault-injection unit test did not fire/stay-silent as asserted"

            # Guard against silent shrinkage: the default render carries the
            # resource-limit alert and the duration-regression record; the
            # opt-in render carries the duration-regression alert as well.
            grep -q "alert: GithubActionsUbuntuLatestResourceLimit" github-actions-fit-alerts.yml \
              || fail "alert GithubActionsUbuntuLatestResourceLimit missing from the library"
            grep -q "record: github_actions_fit:duration_regression_ratio" github-actions-fit-alerts.yml \
              || fail "record github_actions_fit:duration_regression_ratio missing from the library"
            if grep -q "alert: GithubActionsUbuntuLatestDurationRegression" github-actions-fit-alerts.yml; then
              fail "the default render emits GithubActionsUbuntuLatestDurationRegression; it is opt-in"
            fi
            grep -q "alert: GithubActionsUbuntuLatestDurationRegression" github-actions-fit-alerts-duration-alert.yml \
              || fail "durationRegressionAlert = true does not emit GithubActionsUbuntuLatestDurationRegression"

            echo "[t_runner_fit_monitoring][PASS] exporter metrics + signatures + alert rules all verified"
            touch $out
          '';
    };
}
