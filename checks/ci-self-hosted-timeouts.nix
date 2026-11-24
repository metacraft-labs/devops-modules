{ ... }:
{
  # t_ci_self_hosted_timeouts: the self-hosted job-timeout linter
  # (scripts/ci/check_self_hosted_timeouts.py) FIRES on every unbounded or
  # over-ceiling self-hosted job, names each one, and PASSES bounded,
  # justified, GitHub-hosted and reusable-call jobs. Policy and the
  # 2026-11-16 m3 cordon incident that motivates it: the linter's docstring.
  perSystem =
    { pkgs, ... }:
    let
      py = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
      linter = "${../scripts/ci}/check_self_hosted_timeouts.py";
      fixtures = ../scripts/tests/fixtures/ci-runners;
    in
    {
      checks.t_ci_self_hosted_timeouts =
        pkgs.runCommand "t_ci_self_hosted_timeouts" { nativeBuildInputs = [ py ]; }
          ''
            set -euo pipefail
            fail() { echo "[t_ci_self_hosted_timeouts][FAIL] $1" >&2; exit 1; }

            if python3 ${linter} ${fixtures}/self-hosted-timeouts-missing.yml 2>missing.err; then
              cat missing.err >&2
              fail "unbounded self-hosted jobs were NOT flagged"
            fi
            for job in no-timeout step-timeout-only legacy-class dynamic-runner matrix-expression; do
              grep -q "job '$job' :: self-hosted job has no timeout-minutes" missing.err \
                || { cat missing.err >&2; fail "the linter did not name $job"; }
            done
            grep -q "job 'over-ceiling' :: timeout-minutes 600 exceeds the 120-minute ceiling" missing.err \
              || { cat missing.err >&2; fail "the linter did not flag the over-ceiling timeout"; }
            [ "$(grep -c ' :: job ' missing.err)" -eq 6 ] \
              || { cat missing.err >&2; fail "the linter flagged an unexpected number of jobs"; }

            python3 ${linter} ${fixtures}/self-hosted-timeouts-ok.yml \
              || fail "bounded/justified/hosted/reusable jobs were wrongly flagged"

            # The ceiling is a parameter, and lowering it turns the justified-free
            # 120-minute job into a violation.
            if python3 ${linter} --max-minutes 60 ${fixtures}/self-hosted-timeouts-ok.yml 2>low.err; then
              fail "a 120-minute job passed a 60-minute ceiling"
            fi
            grep -q "job 'at-ceiling'" low.err || fail "the lowered ceiling did not name at-ceiling"
            ! grep -q "job 'long-justified'" low.err || fail "a justified job was flagged"

            echo "[t_ci_self_hosted_timeouts][PASS]"
            touch $out
          '';
    };
}
