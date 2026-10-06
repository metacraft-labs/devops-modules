_top@{ ... }:
{
  # Sovereign-CI-Fleet S1 gate: `t_runner_mode_switch`.
  #
  # Proves the org/repo Actions variable `CI_RUNNER_MODE` + repo visibility
  # deterministically resolve the `runs-on` value that a downstream job uses,
  # so flipping ONE variable reroutes CI across the fleet with no per-repo edit.
  #
  # HERMETIC: the test extracts the REAL resolution shell block from
  # `.github/workflows/reusable-choose-runner.yml` (not a copy) and drives it
  # under mocked env. The CI_RUNNER_MODE branches touch NO network and NO
  # GitHub API — the only reason `gh`/`jq` are on PATH is the shared `emit`
  # helper (`jq` builds the hosted array) and the unrelated RD3 live-billing
  # branch, which these cases never reach. No mock stands in for the resolution
  # logic itself; the assertions pin the exact runs-on for each (mode,
  # visibility) pair, including the fail-safe defaults, so the test cannot pass
  # tautologically.
  #
  # It also pins WHERE the preflight runs: the REAL `decide.runs-on` expression is
  # evaluated over a truth table, so a private repo whose hosted minutes are not
  # known to be affordable runs the preflight SELF-HOSTED (a hosted preflight
  # cannot start once the included pool is exhausted, which would skip every
  # downstream job). And it drives the live-billing branch through the shared
  # billing stub (fixtures/billing-usage/gh-stub.sh — the captured enhanced-
  # billing report; mock justified there: the paid billing API cannot be put
  # into a chosen state from a sandbox), including the HTTP 410 that the retired
  # classic endpoint returns, which must resolve self-hosted WITHOUT failing
  # the preflight.
  perSystem =
    { pkgs, ... }:
    let
      chooseWorkflow = ../.github/workflows/reusable-choose-runner.yml;
      billingFixtures = ./fixtures/billing-usage;
      py = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
    in
    {
      checks.t_runner_mode_switch =
        pkgs.runCommand "t_runner_mode_switch"
          {
            nativeBuildInputs = [
              py
              pkgs.bash
              pkgs.jq
            ];
          }
          ''
            set -euo pipefail
            fail() { echo "[t_runner_mode_switch][FAIL] $1" >&2; exit 1; }

            # Extract the REAL `pick` step run block from the reusable workflow
            # and confirm it (a) is valid bash and (b) reads CI_RUNNER_MODE from
            # the org/repo Actions variable `vars.CI_RUNNER_MODE`.
            python3 - <<'PY'
            import yaml
            from pathlib import Path
            wf = yaml.safe_load(open("${chooseWorkflow}"))
            step = next(s for s in wf["jobs"]["decide"]["steps"] if s.get("id") == "pick")
            # The switch must be wired from the Actions VARIABLE, not an input/secret.
            env = step["env"]
            assert env.get("CI_RUNNER_MODE") == "${"$"}{{ vars.CI_RUNNER_MODE }}", env.get("CI_RUNNER_MODE")
            Path("pick.sh").write_text(step["run"])
            # The declared outputs plumb through to the downstream `runs-on`.
            on = wf.get("on", wf.get(True))
            outs = on["workflow_call"]["outputs"]
            assert "jobs.decide.outputs.runs_on" in outs["runs_on"]["value"], outs["runs_on"]
            assert env.get("INCLUDED_MINUTES") == "${"$"}{{ inputs.included_minutes }}", env
            assert env.get("BILLING_ENTERPRISE") == "${"$"}{{ inputs.billing_enterprise }}", env

            # WHERE the preflight runs: evaluate the REAL runs-on expression.
            # GitHub's `a && b || c` has Python's and/or operand semantics, so a
            # token-level translation evaluates it faithfully for this grammar.
            import json, re
            expr = wf["jobs"]["decide"]["runs-on"]
            m = re.fullmatch(r"\$\{\{(.*)\}\}", expr.strip(), re.S)
            assert m, f"decide.runs-on must be an expression, got {expr!r}"
            pyexpr = (m.group(1).replace("&&", " and ").replace("||", " or ")
                      .replace("fromJSON(", "json.loads("))
            class NS:
                def __init__(self, **kw): self.__dict__.update(kw)
                def __getattr__(self, k): return ""  # unset vars/inputs read as the empty string
            PRE = on["workflow_call"]["inputs"]["preflight_runner"]["default"]
            assert json.loads(PRE)[0] == "self-hosted", PRE
            def where(vis, **vars_):
                ctx = {"json": json,
                       "github": NS(event=NS(repository=NS(visibility=vis) if vis else NS())),
                       "vars": NS(**vars_), "inputs": NS(preflight_runner=PRE)}
                return eval(pyexpr, ctx)
            HOSTED, SELF = ["ubuntu-latest"], json.loads(PRE)
            table = [
                ("public, no vars",                 where("public"), HOSTED),
                ("private, no vars",                where("private"), SELF),
                ("internal, no vars",               where("internal"), SELF),
                ("no repository payload",           where(None), SELF),
                ("private, mode=github-hosted",     where("private", CI_RUNNER_MODE="github-hosted"), HOSTED),
                ("private, mode=self-hosted",       where("private", CI_RUNNER_MODE="self-hosted", GH_HOSTED_OK="true"), SELF),
                ("private, mode invalid",           where("private", CI_RUNNER_MODE="on"), SELF),
                ("private, unset, GH_HOSTED_OK=true",  where("private", GH_HOSTED_OK="true"), HOSTED),
                ("private, unset, GH_HOSTED_OK=false", where("private", GH_HOSTED_OK="false"), SELF),
            ]
            for name, got, want in table:
                assert got == want, f"preflight runs-on for {name}: {got} != {want}"
                print(f"[t_runner_mode_switch][ok] preflight runs-on: {name} -> {got}")
            PY
            ${pkgs.bash}/bin/bash -n pick.sh || fail "resolution run block is not valid bash"

            # A stub `gh` guarantees hermeticity: if any CI_RUNNER_MODE case ever
            # regressed into the live-billing branch, this would surface loudly
            # rather than reaching the network.
            mkdir -p mockbin
            printf '#!%s\necho "[t_runner_mode_switch] gh must not be called for a CI_RUNNER_MODE case" >&2\nexit 97\n' \
              "${pkgs.bash}/bin/bash" > mockbin/gh
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
                || { cat caselog >&2; fail "$name: resolution exited non-zero"; }
              local got_runs got_hosted
              got_runs="$(grep '^runs_on=' "$out" | tail -1 | cut -d= -f2-)"
              got_hosted="$(grep '^hosted=' "$out" | tail -1 | cut -d= -f2-)"
              [ "$got_runs" = "$want_runs" ] \
                || fail "$name: runs_on=$got_runs, wanted $want_runs"
              [ "$got_hosted" = "$want_hosted" ] \
                || fail "$name: hosted=$got_hosted, wanted $want_hosted"
              echo "[t_runner_mode_switch][ok] $name -> $got_runs"
            }

            # ---- The runner-mode switch is authoritative when set ------------

            # public + github-hosted -> free hosted runner.
            run_case "public/github-hosted" "$HOSTED" "true" \
              IS_PRIVATE="false" CI_RUNNER_MODE="github-hosted"

            # public + self-hosted -> operator forced the fleet even for a
            # public repo (routes to the RC4 capability-label array).
            run_case "public/self-hosted" "$SELF" "false" \
              IS_PRIVATE="false" CI_RUNNER_MODE="self-hosted"

            # internal/private + github-hosted -> rides included minutes (the S2
            # managing service flips this to self-hosted before overage).
            run_case "internal/github-hosted" "$HOSTED" "true" \
              IS_PRIVATE="true" CI_RUNNER_MODE="github-hosted"

            # private + self-hosted -> RC4 capability-label array.
            run_case "private/self-hosted" "$SELF" "false" \
              IS_PRIVATE="true" CI_RUNNER_MODE="self-hosted"

            # ---- Fail-safe: never a billable mode under the $0 cap -----------

            # A set-but-INVALID mode is an error -> self-hosted, on a private
            # repo (a bad value must not leak onto billable private minutes).
            run_case "private/invalid-mode" "$SELF" "false" \
              IS_PRIVATE="true" CI_RUNNER_MODE="hoste-github"

            # ...and on a public repo too: an unrecognized mode still resolves
            # deterministically to self-hosted rather than guessing hosted.
            run_case "public/invalid-mode" "$SELF" "false" \
              IS_PRIVATE="false" CI_RUNNER_MODE="on"

            # ---- Unset mode falls through to the RD3 visibility default ------

            # Unset CI_RUNNER_MODE on a private repo with no other signal ->
            # self-hosted (RD3 branch 4 fail-safe, preserved beneath the switch).
            run_case "private/unset-mode" "$SELF" "false" \
              IS_PRIVATE="true"

            # Unset CI_RUNNER_MODE on a public repo -> free hosted (public repos
            # default to free GitHub-hosted; RD3 branch 1).
            run_case "public/unset-mode" "$HOSTED" "true" \
              IS_PRIVATE="false"

            # ---- The live-billing branch (CI_RUNNER_MODE + GH_HOSTED_OK unset) --
            # Swap in the billing stub: from here on `gh` serves the captured
            # enhanced-billing report instead of refusing every call.
            { printf '#!%s\n' "${pkgs.bash}/bin/bash"; cat ${billingFixtures}/gh-stub.sh; } > mockbin/gh
            LIVE=(IS_PRIVATE="true" GH_TOKEN="x" ORG="example-org" INCLUDED_MINUTES="3000"
                  FIXTURES="${billingFixtures}" MOCK_USAGE="org-usage-2026-09.json")

            run_case "private/live-healthy" "$HOSTED" "true" "''${LIVE[@]}" MOCK_UNTIL="2026-09-05"
            run_case "private/live-exhausted" "$SELF" "false" "''${LIVE[@]}"
            run_case "private/live-overage-billed" "$SELF" "false" "''${LIVE[@]}" MOCK_UNTIL="2026-09-05" \
              MOCK_INJECT_SKU="Actions Linux 4-core" MOCK_INJECT_NET="0.5"
            # The fail-safe cases must also EXIT 0 (run_case fails otherwise): a
            # crashed preflight skips every downstream job instead of routing it.
            run_case "private/live-http-410" "$SELF" "false" "''${LIVE[@]}" MOCK_USAGE_410="1"
            run_case "private/live-unreachable" "$SELF" "false" "''${LIVE[@]}" MOCK_FAIL="1"
            run_case "private/live-enterprise-org-at-org-scope" "$SELF" "false" "''${LIVE[@]}" \
              MOCK_PLAN="enterprise" MOCK_UNTIL="2026-09-05"
            run_case "private/live-enterprise-pool" "$HOSTED" "true" \
              IS_PRIVATE="true" GH_TOKEN="x" ORG="example-ent-org-a" INCLUDED_MINUTES="50000" \
              BILLING_ENTERPRISE="example-ent" MOCK_EXPECT_SCOPE="enterprise" \
              FIXTURES="${billingFixtures}" MOCK_USAGE="enterprise-usage-2026-09.json" MOCK_UNTIL="2026-09-18"

            echo "[t_runner_mode_switch][PASS] CI_RUNNER_MODE + visibility deterministically resolve runs-on"
            touch $out
          '';
    };
}
