_top@{ ... }:
{
  # Runner-Fleet-Capability-Pools-And-Remote-Driving Phase-D gates:
  #   RD2  t_public_repo_free_ci        — the billed-hosted-runner guard.
  #   RD3  t_private_repo_hybrid_fallback — the choose-runner preflight logic.
  #
  # Both run WITHOUT the infra repo and WITHOUT the real GitHub API. The only
  # mock is the GitHub boundary itself: RD3's live-billing branch shells to a
  # stub `gh` (justified — hitting the real billing API from a hermetic build is
  # impossible and would need a privileged token); the org-variable and
  # visibility branches — the production default path — use no mock at all. RD2
  # is a pure text/AST checker over real workflow files, no mock.
  perSystem =
    { pkgs, ... }:
    let
      py = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
      repoRoot = ../.;
      checker = ../scripts/ci/check_public_repo_runners.py;
      cleanFixture = ../scripts/tests/fixtures/ci-runners/clean-public.yml;
      billedFixture = ../scripts/tests/fixtures/ci-runners/billed-public.yml;
      chooseWorkflow = ../.github/workflows/reusable-choose-runner.yml;
      billingFixtures = ./fixtures/billing-usage;
      guardWorkflow = ../.github/workflows/reusable-public-runner-guard.yml;
      reusableWorkflowsDir = ../.github/workflows;
    in
    {
      # ---- RD2 ---------------------------------------------------------------
      checks.t_public_repo_free_ci =
        pkgs.runCommand "t_public_repo_free_ci"
          {
            nativeBuildInputs = [ py ];
          }
          ''
            set -euo pipefail
            fail() { echo "[t_public_repo_free_ci][FAIL] $1" >&2; exit 1; }
            check() { python3 ${checker} "$@"; }

            echo "[t_public_repo_free_ci] compliant public workflow passes"
            check --visibility public ${cleanFixture} \
              || fail "clean public fixture (ubuntu-latest + matrix + self-hosted) was rejected"

            echo "[t_public_repo_free_ci] billed hosted runner on a public repo FAILS"
            if check --visibility public ${billedFixture} 2>guard.err; then
              cat guard.err >&2
              fail "billed/GPU hosted runners on a public repo were NOT rejected"
            fi
            # Every billed job in the fixture must be named in the failure.
            for job in gpu-build big-cores matrix-billed mac-large; do
              grep -q "$job" guard.err \
                || fail "guard failed but did not report the '$job' violation"
            done
            # A standard runner alongside a billed one in the same matrix must NOT
            # be flagged (matrix resolution must keep ubuntu-latest free).
            grep -q "runs-on 'ubuntu-latest' —" guard.err \
              && fail "ubuntu-latest was wrongly flagged as billed"

            echo "[t_public_repo_free_ci] the same billed runners only WARN on a private repo"
            check --visibility private ${billedFixture} \
              || fail "private-repo scan must pass (warn-only) for billed hosted runners"

            echo "[t_public_repo_free_ci] extra --billed-label denylist is honoured"
            printf 'name: x\non: [push]\njobs:\n  j:\n    runs-on: my-fat-runner\n    steps: [{ run: "echo hi" }]\n' > extra.yml
            check --visibility public extra.yml \
              || fail "an unknown label must pass by default (assumed self-hosted)"
            if check --visibility public --billed-label my-fat-runner extra.yml 2>/dev/null; then
              fail "an explicitly denylisted label was not rejected on a public repo"
            fi

            echo "[t_public_repo_free_ci] the repo's own reusable workflows are clean (public posture)"
            check --visibility public ${reusableWorkflowsDir} \
              || fail "a nixos-modules reusable workflow itself names a billed hosted runner"

            echo "[t_public_repo_free_ci] the guard reusable workflow wires visibility from repo.private"
            python3 - <<'PY' || fail "reusable-public-runner-guard.yml does not derive visibility correctly"
            import yaml
            wf = yaml.safe_load(open("${guardWorkflow}"))
            steps = wf["jobs"]["guard"]["steps"]
            run_step = next(s for s in steps if s.get("name", "").startswith("Run the public"))
            env = run_step["env"]
            vis = env["GH_REPO_VISIBILITY"]
            assert "repository.private" in vis and "'private'" in vis and "'public'" in vis, vis
            assert "check_public_repo_runners.py" in run_step["run"]
            PY

            echo "[t_public_repo_free_ci][PASS] guard fails billed public runners, passes ubuntu-latest"
            touch $out
          '';

      # ---- RD3 ---------------------------------------------------------------
      checks.t_private_repo_hybrid_fallback =
        pkgs.runCommand "t_private_repo_hybrid_fallback"
          {
            nativeBuildInputs = [
              py
              pkgs.bash
              pkgs.jq
            ];
          }
          ''
            set -euo pipefail
            fail() { echo "[t_private_repo_hybrid_fallback][FAIL] $1" >&2; exit 1; }

            # Extract the REAL preflight run block from the reusable workflow (not a
            # copy) and syntax-check it, then drive it under mocked env.
            python3 - <<'PY'
            import yaml
            from pathlib import Path
            wf = yaml.safe_load(open("${chooseWorkflow}"))
            step = next(s for s in wf["jobs"]["decide"]["steps"] if s.get("id") == "pick")
            Path("pick.sh").write_text(step["run"])
            # The downstream job consumes fromJson(runs_on) — assert the plumbing.
            # NB: PyYAML parses the `on:` key as the boolean True (YAML 1.1).
            on = wf.get("on", wf.get(True))
            outs = on["workflow_call"]["outputs"]
            assert "runs_on" in outs and "hosted" in outs, outs
            assert "jobs.decide.outputs.runs_on" in outs["runs_on"]["value"], outs["runs_on"]
            job_outs = wf["jobs"]["decide"]["outputs"]
            assert "steps.pick.outputs.runs_on" in job_outs["runs_on"], job_outs
            PY
            ${pkgs.bash}/bin/bash -n pick.sh || fail "preflight run block is not valid bash"

            # A stub `gh` for the live-billing branch (branch 3): it replays the
            # enhanced-billing usage report captured live (2026-09, anonymized) —
            # see fixtures/billing-usage/gh-stub.sh and t_runner_mode_manager.
            mkdir -p mockbin
            { printf '#!%s\n' "${pkgs.bash}/bin/bash"; cat ${billingFixtures}/gh-stub.sh; } > mockbin/gh
            chmod +x mockbin/gh
            export PATH="$PWD/mockbin:${pkgs.jq}/bin:$PATH"

            HOSTED='["ubuntu-latest"]'
            SELF='["self-hosted","linux","x64"]'

            # run_case NAME EXPECT_RUNSON EXPECT_HOSTED  <env assignments...>
            run_case() {
              local name="$1" want_runs="$2" want_hosted="$3"; shift 3
              local out; out="$(mktemp)"
              env -i \
                PATH="$PATH" \
                GITHUB_OUTPUT="$out" \
                PREFERRED="ubuntu-latest" \
                FALLBACK="$SELF" \
                MIN_REMAIN="300" \
                "$@" \
                ${pkgs.bash}/bin/bash pick.sh >/dev/null 2>caselog \
                || { cat caselog >&2; fail "$name: preflight exited non-zero"; }
              local got_runs got_hosted
              got_runs="$(grep '^runs_on=' "$out" | tail -1 | cut -d= -f2-)"
              got_hosted="$(grep '^hosted=' "$out" | tail -1 | cut -d= -f2-)"
              [ "$got_runs" = "$want_runs" ] \
                || fail "$name: runs_on=$got_runs, wanted $want_runs"
              [ "$got_hosted" = "$want_hosted" ] \
                || fail "$name: hosted=$got_hosted, wanted $want_hosted"
              echo "[t_private_repo_hybrid_fallback][ok] $name -> $got_runs"
            }

            # 1. Public repo always hosted, even with GH_HOSTED_OK=false.
            run_case "public/free" "$HOSTED" "true" \
              IS_PRIVATE="false" GH_HOSTED_OK="false"

            # 2. Private + org variable = true -> hosted (production default path).
            run_case "private/GH_HOSTED_OK=true" "$HOSTED" "true" \
              IS_PRIVATE="true" GH_HOSTED_OK="true"

            # 3. Private + org variable = false -> self-hosted (minutes exhausted).
            run_case "private/GH_HOSTED_OK=false" "$SELF" "false" \
              IS_PRIVATE="true" GH_HOSTED_OK="false"

            # 4. Private + no variable + no token -> self-hosted (fail-safe).
            run_case "private/no-signal" "$SELF" "false" \
              IS_PRIVATE="true"

            LIVE=(IS_PRIVATE="true" GH_TOKEN="x" ORG="example-org" INCLUDED_MINUTES="3000"
                  FIXTURES="${billingFixtures}" MOCK_USAGE="org-usage-2026-09.json")

            # 5. Private + no variable + token + plenty remaining -> hosted (live check).
            run_case "private/live-ok" "$HOSTED" "true" "''${LIVE[@]}" MOCK_UNTIL="2026-09-05"

            # 6. Private + no variable + token + pool exhausted -> self-hosted (live check).
            run_case "private/live-exhausted" "$SELF" "false" "''${LIVE[@]}"

            # 7. Private + live check hits a dead endpoint (HTTP 410) -> self-hosted,
            #    and the preflight still EXITS 0 (a crash would skip every
            #    downstream `needs: choose` job).
            run_case "private/live-http-410" "$SELF" "false" "''${LIVE[@]}" MOCK_USAGE_410="1"

            echo "[t_private_repo_hybrid_fallback][PASS] preflight emits hosted while free, self-hosted once exhausted"
            touch $out
          '';
    };
}
