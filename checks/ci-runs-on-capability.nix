{ ... }:
{
  # Runner-Fleet-Capability-Pools-And-Remote-Driving RC4 gate:
  # t_ci_runs_on_capability.
  #
  # Proves — WITHOUT the infra repo — that RC4's two deliverables hold:
  #
  #   1. REWRITE: the reusable CI workflows (.github/workflows/reusable-*) express
  #      `runs-on` as MINIMAL capability LABEL SETS (RC1 taxonomy), not the legacy
  #      single-name `eph-<os>-<arch>` classes. The parametric `runner`/`runners`
  #      input DEFAULTS are asserted to be `[self-hosted, …]` label sets with no
  #      bare `eph-*` name surviving.
  #
  #   2. LINT: the over-constrained-runs-on linter (scripts/ci) FIRES on a
  #      too-narrow `runs-on` (a bare ephemeral class name; an unjustified gpu /
  #      x86-64-v3 capability — the starvation-amplifier) and PASSES a minimal /
  #      justified one. A representative matrix (v3-only / gpu / generic-linux /
  #      windows) resolves to the right label sets.
  #
  # The linter reuses the RD2 guard's runs-on resolution, so the two can never
  # disagree on how a `runs-on` (incl. `${{ matrix.* }}`) resolves.
  perSystem =
    { pkgs, ... }:
    let
      py = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
      ciDir = ../scripts/ci;
      linter = "${ciDir}/check_over_constrained_runs_on.py";
      fixtures = ../scripts/tests/fixtures/ci-runners;
      workflowsDir = ../.github/workflows;
    in
    {
      checks.t_ci_runs_on_capability =
        pkgs.runCommand "t_ci_runs_on_capability"
          {
            nativeBuildInputs = [
              py
              pkgs.jq
            ];
          }
          ''
            set -euo pipefail
            fail() { echo "[t_ci_runs_on_capability][FAIL] $1" >&2; exit 1; }
            lint() { python3 ${linter} "$@"; }

            # ---- 1. REWRITE: reusable-workflow runs-on defaults are label sets ----
            echo "[t_ci_runs_on_capability] reusable workflows default runs-on to capability label sets"
            python3 - <<'PY' || fail "a reusable workflow still defaults runs-on to a bare eph-* class"
            import json, re, sys, yaml
            from pathlib import Path

            wfdir = Path("${workflowsDir}")
            # input name -> the reusable workflow(s) whose runner input it is.
            targets = {
                "reusable-lint.yml": "runner",
                "reusable-merge.yml": "runner",
                "reusable-nix-diff.yml": "runner",
                "reusable-recorder-ci.yml": "runners",
                # flake-checks matrix carries three runner inputs.
                "reusable-flake-checks-ci-matrix.yml": ["runners", "non-nix-runner", "results-runner"],
            }
            EPH = re.compile(r"^eph-")

            def leaves(v):
                if isinstance(v, str):
                    yield v
                elif isinstance(v, list):
                    for x in v:
                        yield from leaves(x)
                elif isinstance(v, dict):
                    for x in v.values():
                        yield from leaves(x)

            bad = []
            for fname, keys in targets.items():
                keys = [keys] if isinstance(keys, str) else keys
                wf = yaml.safe_load((wfdir / fname).read_text())
                # PyYAML parses the `on:` key as boolean True (YAML 1.1).
                on = wf.get("on", wf.get(True))
                inputs = on["workflow_call"]["inputs"]
                for key in keys:
                    default = inputs[key]["default"]
                    parsed = json.loads(default)
                    labels = list(leaves(parsed))
                    if not labels:
                        bad.append(f"{fname}:{key} default has no labels")
                        continue
                    if any(EPH.match(l) for l in labels):
                        bad.append(f"{fname}:{key} still names a bare eph-* class: {labels}")
                    if "self-hosted" not in labels:
                        bad.append(f"{fname}:{key} default is not a [self-hosted, …] label set: {labels}")
            if bad:
                print("\n".join(bad), file=sys.stderr)
                sys.exit(1)
            print("[ok] all reusable-workflow runner defaults are capability label sets")
            PY

            # ---- 2a. LINT FIRES on the over-constrained fixture ------------------
            echo "[t_ci_runs_on_capability] linter FAILS an over-constrained workflow"
            if lint ${fixtures}/over-constrained-runs-on.yml 2>oc.err; then
              cat oc.err >&2
              fail "over-constrained runs-on (bare class + unjustified gpu/v3) was NOT flagged"
            fi
            # It must name each offending job/label, not fail generically.
            grep -q "eph-linux-x64" oc.err   || fail "linter did not flag the bare eph-linux-x64 class"
            grep -q "legacy-class"  oc.err   || fail "linter did not name the legacy-class job"
            grep -q "gpu"           oc.err   || fail "linter did not flag the needless gpu capability"
            grep -q "x86-64-v3"     oc.err   || fail "linter did not flag the needless x86-64-v3 capability"
            # And it suggests the migration-table label set for the bare class.
            grep -q "self-hosted" oc.err     || fail "linter did not suggest the capability label set"

            # ---- 2b. LINT PASSES the minimal/justified representative matrix -----
            echo "[t_ci_runs_on_capability] linter PASSES a minimal + justified workflow"
            lint ${fixtures}/representative-matrix.yml \
              || fail "a minimal/justified representative matrix was wrongly flagged"

            # ---- 2c. ROUTING: representative matrix resolves to the right sets ---
            echo "[t_ci_runs_on_capability] representative matrix routes correctly (v3/gpu/linux/windows)"
            lint --print-resolved ${fixtures}/representative-matrix.yml > resolved.json
            check_route() { # job -> expected JSON label set (order-insensitive)
              local want="$2"
              jq -e --argjson want "$want" \
                '(($want | sort) as $w | ."representative-matrix.yml" | any(.[]; (sort) == $w))' \
                resolved.json >/dev/null \
                || { cat resolved.json >&2; fail "$1 did not route to $want"; }
            }
            check_route "generic-linux" '["self-hosted","linux","x64"]'
            check_route "v3-only"       '["self-hosted","linux","x64","x86-64-v3"]'
            check_route "gpu"           '["self-hosted","linux","x64","gpu"]'
            check_route "windows"       '["self-hosted","windows","x64"]'

            # ---- 2d. the repo's OWN reusable workflows pass the lint -------------
            # Their runs-on is parameterised (fromJSON(inputs.*)) -> dynamic ->
            # trusted/skipped, so none is over-constrained. (The non-reusable
            # workflows in this repo — ci.yml etc. — still carry bare eph-*
            # classes and are a separate consumer-style migration, out of RC4's
            # reusable-* scope.)
            echo "[t_ci_runs_on_capability] the reusable workflows themselves are clean"
            lint ${workflowsDir}/reusable-*.yml \
              || fail "a nixos-modules reusable workflow has an over-constrained static runs-on"

            echo "[t_ci_runs_on_capability][PASS] reusable runs-on are minimal label sets; lint fires on too-narrow, passes minimal; matrix routes right"
            touch $out
          '';
    };
}
