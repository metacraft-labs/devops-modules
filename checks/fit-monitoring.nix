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
  #   (c) `promtool test rules` asserts the duration-regression + resource-limit
  #       alerts fire on a replayed incident and stay silent through the controls
  #       (../modules/github-actions-fit-alerts/tests/fit-monitoring.test.yml).
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
            cp ${rules}    github-actions-fit-alerts.yml
            cp ${testFile} fit-monitoring.test.yml

            echo "[t_runner_fit_monitoring] promtool check rules"
            ${promtool} check rules github-actions-fit-alerts.yml \
              || fail "promtool check rules rejected the fit library"

            echo "[t_runner_fit_monitoring] promtool test rules (fault injection)"
            ${promtool} test rules fit-monitoring.test.yml \
              || fail "a fault-injection unit test did not fire/stay-silent as asserted"

            # Guard against silent shrinkage: both fit alerts must exist.
            for a in GithubActionsUbuntuLatestDurationRegression \
                     GithubActionsUbuntuLatestResourceLimit; do
              grep -q "alert: $a" github-actions-fit-alerts.yml \
                || fail "alert $a missing from the library"
            done

            echo "[t_runner_fit_monitoring][PASS] exporter metrics + signatures + alert rules all verified"
            touch $out
          '';
    };
}
