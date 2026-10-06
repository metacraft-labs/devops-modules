_top@{ ... }:
{
  # Sovereign-CI-Fleet S2 gate: `t_runner_mode_manager`.
  #
  # Proves the managing service (`.github/workflows/reusable-manage-runner-mode.yml`)
  # decides the AUTHORITATIVE `CI_RUNNER_MODE` from an org's billing usage +
  # budget, FAIL-SAFE to self-hosted on any error, and emits the Prometheus
  # signals the alerting fleet pages on.
  #
  # HERMETIC: the test extracts the REAL `decide` and `metrics` run blocks from
  # the workflow (not copies) and drives them under `env -i` with a stub `gh`
  # (fixtures/billing-usage/gh-stub.sh) that serves the ENHANCED-billing usage
  # report CAPTURED LIVE for 2026-09 (names anonymized) — one Team org and one
  # two-org ENTERPRISE pool — and GitHub's real failure shapes (HTTP 410 from the
  # retired classic endpoint, the old classic body, unreachable API). The only
  # `gh` on PATH is the stub, and `env -i` strips the environment, so a real
  # network call cannot happen — a regression that reached the live billing API
  # would fail rather than pass.
  #
  # Mock justification (dev-guidelines): the billing API is a paid, org-private
  # third-party boundary that cannot be driven into a chosen state (a month
  # mid-way through its pool, an exhausted pool, a 410) from a Nix sandbox. The
  # stub replays captured responses verbatim, so the parser runs against the
  # real wire shape; only the transport is replaced.
  #
  # NON-TAUTOLOGICAL: each case pins the exact CI_RUNNER_MODE + failsafe flag
  # for a distinct billing shape, so the decision logic is load-bearing:
  #   * the pool is PRICE-weighted: the enterprise pool through 09-18 still has
  #     4847 Linux-equivalent minutes (a 1x/2x/10x multiplier model says it is
  #     exhausted), and the full month is exhausted at -229 (a raw-minutes model
  #     says 16k remain) — both were confirmed against live job blocking;
  #   * public-repo usage must be excluded (it is ~10x the private usage in the
  #     org fixture), else the healthy cases flip to self-hosted;
  #   * remove the minutes buffer and near-exhaustion flips to github-hosted;
  #   * remove the budget check and over-budget flips to github-hosted; count
  #     storage overage as budget and storage-overage-ignored flips;
  #   * remove any fail-safe (410 / old shape / enterprise plan at org scope /
  #     repo-listing error / unreachable) and that case flips.
  # The metrics assertions pin the stuck-state dead-man's-switch: a successful
  # run advances last_success; a fail-safe run does not.
  perSystem =
    { pkgs, ... }:
    let
      manageWorkflow = ../.github/workflows/reusable-manage-runner-mode.yml;
      chooseWorkflow = ../.github/workflows/reusable-choose-runner.yml;
      syncWorkflow = ../.github/workflows/reusable-sync-hosted-minutes.yml;
      fixtures = ./fixtures/billing-usage;
      py = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
    in
    {
      checks.t_runner_mode_manager =
        pkgs.runCommand "t_runner_mode_manager"
          {
            nativeBuildInputs = [
              py
              pkgs.bash
              pkgs.jq
              pkgs.gawk
              pkgs.gnugrep
              pkgs.coreutils
            ];
          }
          ''
            set -euo pipefail
            fail() { echo "[t_runner_mode_manager][FAIL] $1" >&2; exit 1; }

            # Extract the REAL decide + metrics run blocks and confirm the switch
            # is wired from billing secrets/inputs and plumbs its outputs through.
            python3 - <<'PY'
            import yaml
            from pathlib import Path
            wf = yaml.safe_load(open("${manageWorkflow}"))
            steps = wf["jobs"]["manage"]["steps"]
            decide = next(s for s in steps if s.get("id") == "decide")
            metrics = next(s for s in steps if s.get("id") == "metrics")
            env = decide["env"]
            # Billing read must come from the secret, org/thresholds from inputs.
            assert env.get("GH_TOKEN") == "${"$"}{{ secrets.billing_token }}", env.get("GH_TOKEN")
            assert env.get("MIN_REMAIN") == "${"$"}{{ inputs.min_minutes_remaining }}", env.get("MIN_REMAIN")
            assert env.get("MAX_BILLED") == "${"$"}{{ inputs.max_billed_amount }}", env.get("MAX_BILLED")
            assert env.get("INCLUDED_MINUTES") == "${"$"}{{ inputs.included_minutes }}", env.get("INCLUDED_MINUTES")
            assert env.get("BILLING_ENTERPRISE") == "${"$"}{{ inputs.enterprise }}", env.get("BILLING_ENTERPRISE")
            # The retired classic endpoint (HTTP 410) must not be read anywhere.
            for wfpath in ("${manageWorkflow}", "${chooseWorkflow}", "${syncWorkflow}"):
                assert "settings/billing/actions" not in "".join(
                    l for l in open(wfpath) if not l.lstrip().startswith("#")), wfpath
            # The billing reader is shared: the three copies must be byte-identical.
            import re
            blocks = []
            for wfpath in ("${manageWorkflow}", "${chooseWorkflow}", "${syncWorkflow}"):
                txt = open(wfpath).read()
                m = re.search(r"^( *)# >>> billing-remaining.*?^\1# <<< billing-remaining$", txt, re.S | re.M)
                assert m, f"{wfpath}: shared billing_remaining block missing"
                blocks.append("\n".join(l[len(m.group(1)):] for l in m.group(0).splitlines()))
            assert blocks[0] == blocks[1] == blocks[2], "billing_remaining copies drifted between workflows"
            # The poll must be able to START when the pool is exhausted: hosted
            # only for a public caller, else the self-hosted `runner` input.
            runs_on = wf["jobs"]["manage"]["runs-on"]
            assert "github.event.repository.visibility == 'public'" in runs_on, runs_on
            assert "inputs.runner" in runs_on, runs_on
            on0 = wf.get("on", wf.get(True))
            assert on0["workflow_call"]["inputs"]["runner"]["default"].startswith('["self-hosted"'), on0
            # The written variable is the S1-authoritative CI_RUNNER_MODE.
            writestep = next(s for s in steps if "Write CI_RUNNER_MODE" in s.get("name", ""))
            assert "gh variable set CI_RUNNER_MODE" in writestep["run"], writestep["run"]
            # Outputs plumb decide -> job -> workflow_call.
            on = wf.get("on", wf.get(True))
            outs = on["workflow_call"]["outputs"]
            assert "jobs.manage.outputs.mode" in outs["mode"]["value"], outs["mode"]
            job_outs = wf["jobs"]["manage"]["outputs"]
            assert "steps.decide.outputs.mode" in job_outs["mode"], job_outs
            Path("decide.sh").write_text(decide["run"])
            Path("metrics.sh").write_text(metrics["run"])
            PY
            ${pkgs.bash}/bin/bash -n decide.sh  || fail "decide run block is not valid bash"
            ${pkgs.bash}/bin/bash -n metrics.sh || fail "metrics run block is not valid bash"

            # A stub `gh` = the ONLY network boundary (see gh-stub.sh): it serves
            # the captured usage reports and GitHub's real failure shapes.
            mkdir -p mockbin
            { printf '#!%s\n' "${pkgs.bash}/bin/bash"; cat ${fixtures}/gh-stub.sh; } > mockbin/gh
            chmod +x mockbin/gh
            export PATH="$PWD/mockbin:${pkgs.jq}/bin:${pkgs.gawk}/bin:${pkgs.gnugrep}/bin:${pkgs.coreutils}/bin:$PATH"

            # decide_case NAME EXPECT_MODE EXPECT_FAILSAFE <env assignments...>
            decide_case() {
              local name="$1" want_mode="$2" want_fs="$3"; shift 3
              local out; out="$(mktemp)"
              env -i \
                PATH="$PATH" \
                GITHUB_OUTPUT="$out" \
                FIXTURES="${fixtures}" \
                MIN_REMAIN="300" \
                MAX_BILLED="0" \
                "$@" \
                ${pkgs.bash}/bin/bash decide.sh >/dev/null 2>caselog \
                || { cat caselog >&2; fail "$name: decide exited non-zero"; }
              local got_mode got_fs
              got_mode="$(grep '^mode=' "$out" | tail -1 | cut -d= -f2-)"
              got_fs="$(grep '^failsafe=' "$out" | tail -1 | cut -d= -f2-)"
              [ "$got_mode" = "$want_mode" ] \
                || fail "$name: mode=$got_mode, wanted $want_mode"
              [ "$got_fs" = "$want_fs" ] \
                || fail "$name: failsafe=$got_fs, wanted $want_fs"
              echo "[t_runner_mode_manager][ok] $name -> CI_RUNNER_MODE=$got_mode (failsafe=$got_fs)"
            }

            ORGCASE=(ORG="example-org" INCLUDED_MINUTES="3000" MOCK_USAGE="org-usage-2026-09.json")
            ENTCASE=(ORG="example-ent-org-a" BILLING_ENTERPRISE="example-ent" INCLUDED_MINUTES="50000"
                     MOCK_EXPECT_SCOPE="enterprise" MOCK_USAGE="enterprise-usage-2026-09.json")

            # ---- Team org (3000-minute pool = $18 at the Linux price) --------
            # (a) early month: 2052 Linux-equivalent minutes left -> github-hosted.
            decide_case "org/healthy" "github-hosted" "0" "''${ORGCASE[@]}" MOCK_UNTIL="2026-09-05"
            # (a2) 392 left, just above the 300 buffer -> github-hosted.
            decide_case "org/above-buffer" "github-hosted" "0" "''${ORGCASE[@]}" MOCK_UNTIL="2026-09-11"
            # (b) 148 left, below the 300 buffer -> self-hosted.
            decide_case "org/near-exhaustion" "self-hosted" "0" "''${ORGCASE[@]}" MOCK_UNTIL="2026-09-12"
            # (b2) the real month: the pool ran out on 09-13 (-10) -> self-hosted.
            decide_case "org/exhausted" "self-hosted" "0" "''${ORGCASE[@]}"
            # (c) plenty of pool left but a minutes SKU was net-billed (e.g. a
            #     larger runner, never covered by the pool) -> self-hosted.
            decide_case "org/over-budget" "self-hosted" "0" "''${ORGCASE[@]}" MOCK_UNTIL="2026-09-05" \
              MOCK_INJECT_SKU="Actions Linux 4-core" MOCK_INJECT_NET="0.5"
            # (c2) storage overage is NOT a runner-mode signal (runner choice
            #      cannot change it; it has its own $0 budget) -> github-hosted.
            decide_case "org/storage-overage-ignored" "github-hosted" "0" "''${ORGCASE[@]}" MOCK_UNTIL="2026-09-05" \
              MOCK_INJECT_SKU="Actions storage" MOCK_INJECT_UNIT="GigabyteHours" MOCK_INJECT_NET="0.94"

            # ---- Enterprise pool (50000 minutes = $300, shared by two orgs) --
            # (e) through 09-18: $270.92 drawn -> 4847 left -> github-hosted.
            decide_case "enterprise/healthy" "github-hosted" "0" "''${ENTCASE[@]}" MOCK_UNTIL="2026-09-18"
            # (e2) the real month: exhausted at $301.37 (-229) -> self-hosted.
            decide_case "enterprise/exhausted" "self-hosted" "0" "''${ENTCASE[@]}"

            # ---- Fail-safe: every error path -> self-hosted, failsafe=1 ------
            # (d) billing API unreachable.
            decide_case "billing-unreachable" "self-hosted" "1" "''${ORGCASE[@]}" MOCK_FAIL="1"
            # (d2) the usage endpoint answers HTTP 410 (as billing/actions does now).
            decide_case "usage-http-410" "self-hosted" "1" "''${ORGCASE[@]}" MOCK_USAGE_410="1"
            # (d3) a 200 with the OLD classic body (no usageItems) is ambiguous.
            decide_case "old-response-shape" "self-hosted" "1" "''${ORGCASE[@]}" MOCK_OLD_SHAPE="1"
            # (d4) an enterprise-plan org read at ORG scope sees only its share of
            #      a pooled allowance -> ambiguous, even with the pool left.
            decide_case "enterprise-org-at-org-scope" "self-hosted" "1" \
              ORG="example-ent-org-a" INCLUDED_MINUTES="50000" MOCK_PLAN="enterprise" \
              MOCK_USAGE="enterprise-usage-2026-09.json" MOCK_UNTIL="2026-09-05"
            # (d5) the public-repo listing fails -> cannot separate free usage.
            decide_case "public-repo-listing-error" "self-hosted" "1" "''${ORGCASE[@]}" \
              MOCK_UNTIL="2026-09-05" MOCK_FAIL_REPOS="1"

            # ---- Prometheus signals + stuck-state dead-man's-switch ----------
            run_metrics() {
              # run_metrics MODE REMAINING BILLED FAILSAFE TEXTFILE
              env -i PATH="$PATH" \
                ORG="metacraft-labs" \
                MODE="$1" REMAINING="$2" BILLED="$3" FAILSAFE="$4" \
                TEXTFILE="$5" PUSHGATEWAY_URL="" \
                ${pkgs.bash}/bin/bash metrics.sh >/dev/null 2>metricslog \
                || { cat metricslog >&2; fail "metrics exited non-zero"; }
            }
            tf="$PWD/ci-runner-mode.prom"

            # A successful github-hosted run writes the full series and advances
            # last_success to a non-zero timestamp.
            run_metrics "github-hosted" "2900" "0" "0" "$tf"
            grep -q '^ci_runner_mode_self_hosted{org="metacraft-labs"} 0$' "$tf" \
              || fail "metrics: missing/incorrect ci_runner_mode_self_hosted for github-hosted"
            grep -q '^ci_runner_mode{org="metacraft-labs",mode="github-hosted"} 1$' "$tf" \
              || fail "metrics: missing ci_runner_mode mode label"
            grep -q '^ci_runner_mode_included_minutes_remaining{org="metacraft-labs"} 2900$' "$tf" \
              || fail "metrics: missing remaining-minutes gauge"
            grep -q '^ci_runner_mode_failsafe_active{org="metacraft-labs"} 0$' "$tf" \
              || fail "metrics: failsafe flag should be 0 on a healthy run"
            good_ts="$(grep '^ci_runner_mode_last_success_timestamp_seconds' "$tf" | awk '{print $2}')"
            [ "$good_ts" -gt 0 ] 2>/dev/null \
              || fail "metrics: last_success timestamp must advance on a successful run (got '$good_ts')"
            echo "[t_runner_mode_manager][ok] metrics: healthy run wrote series, last_success=$good_ts"

            # A subsequent FAIL-SAFE run must NOT advance last_success (the stuck
            # signal) even though it rewrites the file with self-hosted=1.
            run_metrics "self-hosted" "-1" "-1" "1" "$tf"
            grep -q '^ci_runner_mode_self_hosted{org="metacraft-labs"} 1$' "$tf" \
              || fail "metrics: fail-safe run must record self_hosted=1"
            grep -q '^ci_runner_mode_failsafe_active{org="metacraft-labs"} 1$' "$tf" \
              || fail "metrics: fail-safe run must record failsafe_active=1"
            stuck_ts="$(grep '^ci_runner_mode_last_success_timestamp_seconds' "$tf" | awk '{print $2}')"
            [ "$stuck_ts" = "$good_ts" ] \
              || fail "metrics: fail-safe run advanced last_success ($stuck_ts != $good_ts) — stuck detection broken"
            echo "[t_runner_mode_manager][ok] metrics: fail-safe run held last_success=$stuck_ts (stuck-state dead-man switch)"

            echo "[t_runner_mode_manager][PASS] billing+budget resolve CI_RUNNER_MODE, fail-safe self-hosted, metrics + stuck signal emitted"
            touch $out
          '';
    };
}
