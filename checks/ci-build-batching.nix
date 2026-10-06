{ ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      flakeChecksWorkflow = ../.github/workflows/reusable-flake-checks-ci-matrix.yml;
      repoWorkflow = ../.github/workflows/ci.yml;
    in
    {
      # Guards the `build-max-jobs` fan-out cap that keeps this repo from
      # monopolising the 2-runner `eph-macos-arm64` pool. Two properties matter
      # and both are asserted against fixtures rather than described in prose:
      #
      #   1. Batching never changes WHICH flake outputs get built.
      #   2. A batch runs every output it owns and still fails when any failed.
      #
      # (2) is the trap: a runner that loops under `set -e` stops at the first
      # failure, reports one broken output and hides the rest.
      checks.ci-build-batching =
        pkgs.runCommand "ci-build-batching"
          {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.python3
            ];
          }
          ''
            export WORKFLOW="${flakeChecksWorkflow}"
            export REPO_WORKFLOW="${repoWorkflow}"
            export BASH_BIN="${pkgs.bash}/bin/bash"
            python3 - <<'PY'
            import json
            import os
            import subprocess
            import tempfile
            from pathlib import Path

            workflow = Path(os.environ["WORKFLOW"]).read_text()
            repo_workflow = Path(os.environ["REPO_WORKFLOW"]).read_text()
            bash_bin = os.environ["BASH_BIN"]
            lines = workflow.splitlines()

            failures = []

            def check(condition, message):
                if not condition:
                    failures.append(message)

            # ---------------------------------------------------------------
            # Extract the two scripts under test straight out of the workflow,
            # so this check can never drift from what CI actually runs.
            # ---------------------------------------------------------------
            def step_bounds(name_prefix):
                start = None
                for index, line in enumerate(lines):
                    if line.strip().startswith(name_prefix):
                        start = index
                        break
                assert start is not None, "step not found: " + name_prefix
                indent = len(lines[start]) - len(lines[start].lstrip())
                end = len(lines)
                for index in range(start + 1, len(lines)):
                    stripped = lines[index].strip()
                    if stripped and (len(lines[index]) - len(lines[index].lstrip())) <= indent:
                        end = index
                        break
                return start, end

            def run_block(name_prefix):
                start, end = step_bounds(name_prefix)
                run_index = None
                for index in range(start, end):
                    if lines[index].strip() == "run: |":
                        run_index = index
                        break
                assert run_index is not None, "run block not found: " + name_prefix
                block_indent = (len(lines[run_index]) - len(lines[run_index].lstrip())) + 2
                body = []
                for line in lines[run_index + 1:end]:
                    if not line.strip():
                        body.append("")
                        continue
                    assert len(line) - len(line.lstrip()) >= block_indent, (
                        "unexpected indentation in " + name_prefix + ": " + repr(line)
                    )
                    body.append(line[block_indent:])
                return "\n".join(body).rstrip() + "\n"

            planner_shell = run_block("- name: Group flake outputs into build jobs")
            build_shell = run_block("- name: Build ")

            # The planner's python lives in a quoted heredoc inside that step.
            planner_lines = planner_shell.splitlines()
            open_index = None
            for index, line in enumerate(planner_lines):
                if line.rstrip().endswith("<<'PY'"):
                    open_index = index
                    break
            assert open_index is not None, "planner heredoc not found"
            close_index = None
            for index in range(open_index + 1, len(planner_lines)):
                if planner_lines[index].strip() == "PY":
                    close_index = index
                    break
            assert close_index is not None, "planner heredoc not terminated"
            planner_py = "\n".join(planner_lines[open_index + 1:close_index]) + "\n"

            # ---------------------------------------------------------------
            # Static guards on how the scripts are wired.
            # ---------------------------------------------------------------
            build_code = [
                line for line in build_shell.splitlines() if not line.lstrip().startswith("#")
            ]
            check(
                not [
                    line for line in build_code
                    if len(line.split()) > 1 and line.split()[0] == "set"
                    and "e" in line.split()[1].lstrip("-").split("o")[0]
                ],
                "the build step must not enable `errexit`: it would abandon the rest of the "
                "batch at the first failing output",
            )
            check(
                any(line.strip() == "set -uo pipefail" for line in build_code),
                "the build step must still run under `set -u` and `pipefail`",
            )
            check(
                "nix build -L --no-link --keep-going --show-trace" in build_shell,
                "the build step must keep the documented nix build invocation",
            )
            check(
                "build-max-jobs:" in workflow,
                "reusable workflow must expose the build-max-jobs input",
            )
            check(
                "default: '{}'" in workflow,
                "build-max-jobs must default to {} so callers that do not opt in are unaffected",
            )
            check(
                "build-max-jobs: |" in repo_workflow and '"aarch64-darwin": 6' in repo_workflow,
                "this repo's CI must cap its aarch64-darwin build fan-out",
            )
            check(
                "BATCH_TSV: " in workflow,
                "batch members must reach the build step through env, not string interpolation",
            )

            # ---------------------------------------------------------------
            # Planner fixtures.
            # ---------------------------------------------------------------
            def package(name, system="aarch64-darwin", **extra):
                pkg = {
                    "name": name,
                    "allowedToFail": False,
                    "attrPath": "checks." + system + "." + name,
                    "cachedAt": [],
                    "ghRunner": ["eph-macos-arm64"] if "darwin" in system else ["eph-linux-x64"],
                    "system": system,
                    "derivation": "/nix/store/" + name + ".drv",
                    "output": "/nix/store/" + name,
                    "deploymentTarget": False,
                    "deploymentKind": "",
                }
                pkg.update(extra)
                return pkg

            def plan(packages, max_jobs, foundry="", push="false"):
                with tempfile.TemporaryDirectory() as temp:
                    out = Path(temp) / "gh-output.env"
                    out.write_text("")
                    env = os.environ.copy()
                    env.update({
                        "SOURCE_BUILD_MATRIX": json.dumps({"include": packages}),
                        "BUILD_MAX_JOBS": json.dumps(max_jobs),
                        "FOUNDRY_DARWIN_BOOTSTRAP_RUNNER": foundry,
                        "PUSH_DEPLOYMENT_CACHES": push,
                        "GITHUB_OUTPUT": str(out),
                        "GITHUB_STEP_SUMMARY": str(Path(temp) / "summary.md"),
                    })
                    proc = subprocess.run(
                        ["python3", "-c", planner_py],
                        env=env, capture_output=True, text=True,
                    )
                    if proc.returncode != 0:
                        raise AssertionError("planner failed: " + proc.stderr)
                    text = out.read_text()
                    prefix = "build_matrix="
                    for line in text.splitlines():
                        if line.startswith(prefix):
                            return json.loads(line[len(prefix):])
                    raise AssertionError("planner emitted no build_matrix: " + repr(text))

            def outputs_of(matrix):
                return sorted(
                    (entry.get("system", ""), item["name"], item["attrPath"])
                    for entry in matrix["include"]
                    for item in entry["batch"]
                )

            def population(packages):
                return sorted(
                    (p.get("system", ""), p["name"], p["attrPath"]) for p in packages
                )

            # -- A. The real shape: 51 Darwin outputs capped at 6 jobs. -------
            fifty_one = [package("pkg-%02d" % n) for n in range(51)]
            planned = plan(fifty_one, {"aarch64-darwin": 6})
            check(
                len(planned["include"]) == 6,
                "51 Darwin outputs capped at 6 must yield 6 jobs, got %d"
                % len(planned["include"]),
            )
            check(
                outputs_of(planned) == population(fifty_one),
                "batching must preserve the exact set of flake outputs (51 in)",
            )
            check(
                sum(e["batchSize"] for e in planned["include"]) == 51,
                "batchSize values must account for all 51 outputs",
            )
            check(
                sorted(e["batchSize"] for e in planned["include"]) == [8, 8, 8, 9, 9, 9],
                "51 outputs across 6 jobs must split evenly, got %r"
                % sorted(e["batchSize"] for e in planned["include"]),
            )
            for entry in planned["include"]:
                rows = [r for r in entry["batchTsv"].split("\n") if r]
                check(
                    len(rows) == entry["batchSize"],
                    "batchTsv row count must match batchSize for %r" % entry["name"],
                )
                check(
                    [r.split("\t")[1] for r in rows] == [m["attrPath"] for m in entry["batch"]],
                    "batchTsv must carry the same attributes as the batch list",
                )

            # -- B. No cap for the system: one job per output, unchanged. -----
            unplanned = plan(fifty_one, {})
            check(
                len(unplanned["include"]) == 51,
                "an uncapped system must keep one job per flake output",
            )
            check(
                outputs_of(unplanned) == population(fifty_one),
                "the uncapped path must preserve the output set",
            )
            for entry, original in zip(unplanned["include"], fifty_one):
                for key, value in original.items():
                    check(
                        entry.get(key) == value,
                        "uncapped entries must preserve every original field (%s)" % key,
                    )

            # -- C. A cap larger than the population changes nothing. ---------
            small = [package("only-%d" % n) for n in range(3)]
            check(
                len(plan(small, {"aarch64-darwin": 6})["include"]) == 3,
                "a cap above the population must not create empty jobs",
            )

            # -- D. allowedToFail never mixes into a strict batch. ------------
            mixed = [package("strict-%02d" % n) for n in range(10)]
            mixed += [package("soft-%02d" % n, allowedToFail=True) for n in range(4)]
            planned = plan(mixed, {"aarch64-darwin": 3})
            check(
                outputs_of(planned) == population(mixed),
                "mixed allowedToFail batching must preserve the output set",
            )
            allowed_by_name = {p["name"]: p["allowedToFail"] for p in mixed}
            for entry in planned["include"]:
                flags = {allowed_by_name[m["name"]] for m in entry["batch"]}
                check(
                    len(flags) == 1 and flags.pop() == entry["allowedToFail"],
                    "batch %r mixes allowedToFail values; continue-on-error would be wrong"
                    % entry["name"],
                )

            # -- E. Runner classes never mix inside a batch. ------------------
            two_runners = [package("a-%d" % n) for n in range(6)]
            two_runners += [
                package("b-%d" % n, ghRunner=["eph-macos-arm64-big"]) for n in range(6)
            ]
            planned = plan(two_runners, {"aarch64-darwin": 2})
            runner_by_name = {p["name"]: tuple(p["ghRunner"]) for p in two_runners}
            for entry in planned["include"]:
                runners = {runner_by_name[m["name"]] for m in entry["batch"]}
                check(
                    len(runners) == 1 and runners.pop() == tuple(entry["ghRunner"]),
                    "batch %r mixes runner classes" % entry["name"],
                )
            check(
                outputs_of(planned) == population(two_runners),
                "runner-split batching must preserve the output set",
            )

            # -- F. Deployment targets stay alone when their closures are pushed.
            deploy = [package("plain-%d" % n) for n in range(8)]
            deploy += [
                package("target-%d" % n, deploymentTarget=True, deploymentKind="darwin")
                for n in range(2)
            ]
            pushed = plan(deploy, {"aarch64-darwin": 2}, push="true")
            check(
                outputs_of(pushed) == population(deploy),
                "deployment-target batching must preserve the output set",
            )
            for entry in pushed["include"]:
                if entry.get("deploymentTarget"):
                    check(
                        entry["batchSize"] == 1 and entry["output"].startswith("/nix/store/"),
                        "a deployment target must keep its own job and its own output path",
                    )
            check(
                sum(1 for e in pushed["include"] if e.get("deploymentTarget")) == 2,
                "both deployment targets must survive as their own jobs",
            )
            # With pushing disabled the per-target steps are skipped anyway, so
            # those outputs are ordinary builds and may be batched.
            not_pushed = plan(deploy, {"aarch64-darwin": 2}, push="false")
            check(
                len(not_pushed["include"]) == 2,
                "with cache pushing off, deployment targets are batchable",
            )
            check(
                outputs_of(not_pushed) == population(deploy),
                "batching deployment targets must still preserve the output set",
            )

            # -- G. Foundry keeps its own job when the bootstrap override is on.
            foundry_pkgs = [package("pkg-%d" % n) for n in range(8)]
            foundry_pkgs.append(package("foundry"))
            planned = plan(
                foundry_pkgs, {"aarch64-darwin": 2}, foundry='["aarch64-darwin"]'
            )
            foundry_entries = [e for e in planned["include"] if e["name"] == "foundry"]
            check(
                len(foundry_entries) == 1 and foundry_entries[0]["batchSize"] == 1,
                "foundry must stay a named single-output job so its runs-on override applies",
            )
            check(
                outputs_of(planned) == population(foundry_pkgs),
                "foundry carve-out must preserve the output set",
            )

            # -- H. Systems are capped independently. ------------------------
            multi = [package("d-%02d" % n) for n in range(20)]
            multi += [package("l-%02d" % n, system="x86_64-linux") for n in range(20)]
            planned = plan(multi, {"aarch64-darwin": 4})
            darwin_entries = [e for e in planned["include"] if e["system"] == "aarch64-darwin"]
            linux_entries = [e for e in planned["include"] if e["system"] == "x86_64-linux"]
            check(len(darwin_entries) == 4, "Darwin must be capped at 4 jobs")
            check(len(linux_entries) == 20, "x86_64-linux must stay uncapped at 1 job per output")
            check(
                outputs_of(planned) == population(multi),
                "per-system capping must preserve the output set",
            )

            # -- I. noop passthrough and empty input. ------------------------
            noop = [{
                "name": "no-builds-required", "system": "x86_64-linux",
                "ghRunner": ["eph-linux-x64"], "allowedToFail": False,
                "noop": True, "attrPath": "",
            }]
            check(
                len(plan(noop, {"x86_64-linux": 1})["include"]) == 1,
                "the synthetic no-op entry must pass through untouched",
            )
            check(
                plan([], {"aarch64-darwin": 6})["include"] == [],
                "an empty source matrix must plan no jobs",
            )

            # ---------------------------------------------------------------
            # Build-loop fixtures. This is the aggregate-failure proof.
            # ---------------------------------------------------------------
            def run_batch(rows, failing, fallback_name="batch", fallback_attr=""):
                temp = tempfile.mkdtemp()
                temp_path = Path(temp)
                attempts = temp_path / "attempts"
                attempts.write_text("")
                summary = temp_path / "summary.md"
                summary.write_text("")
                fake = temp_path / "fake-build"
                deny = " ".join(failing)
                fake.write_text(
                    "#!" + bash_bin + "\n"
                    "printf '%s\\n' \"$1\" >> " + str(attempts) + "\n"
                    "for bad in " + deny + "; do\n"
                    "  if [ \"$1\" = \".#$bad\" ]; then exit 7; fi\n"
                    "done\n"
                    "exit 0\n"
                )
                fake.chmod(0o755)

                script = temp_path / "build-step.sh"
                script.write_text(build_shell)

                env = os.environ.copy()
                env.update({
                    "BATCH_TSV": rows,
                    "BATCH_FALLBACK_NAME": fallback_name,
                    "BATCH_FALLBACK_ATTR": fallback_attr,
                    "CI_MATRIX_BUILD_COMMAND": str(fake),
                    "GITHUB_STEP_SUMMARY": str(summary),
                })
                proc = subprocess.run(
                    [bash_bin, str(script)], env=env, capture_output=True, text=True
                )
                attempted = [a for a in attempts.read_text().splitlines() if a]
                return proc, attempted, summary.read_text()

            def tsv(*names):
                return "\n".join(n + "\t" + n for n in names)

            # I.1 THE CORE PROOF: outputs after a failure still run, and the
            #     job still fails, naming every output that failed.
            proc, attempted, summary = run_batch(tsv("a", "b", "c", "d"), ["b", "d"])
            check(
                attempted == [".#a", ".#b", ".#c", ".#d"],
                "every output in the batch must be attempted even after a failure; got %r"
                % attempted,
            )
            check(
                proc.returncode != 0,
                "a batch containing a failing output must fail the job",
            )
            check(
                "::error title=Flake output build failed::b" in proc.stdout,
                "the failure must name output 'b'",
            )
            check(
                "::error title=Flake output build failed::d" in proc.stdout,
                "the failure must name output 'd'",
            )
            check(
                "::error title=Flake output build failed::a" not in proc.stdout
                and "::error title=Flake output build failed::c" not in proc.stdout,
                "passing outputs must not be reported as failures",
            )
            check(
                "Attempted 4 flake output(s): 2 passed, 2 failed." in proc.stdout,
                "the job must state its per-output tally; got: %r" % proc.stdout[-400:],
            )
            for name, marker in [("a", "pass"), ("b", "FAIL"), ("c", "pass"), ("d", "FAIL")]:
                check(
                    ("`" + name + "` | `" + name + "` | ") in summary
                    and marker in summary.split("`" + name + "` | `" + name + "` | ")[1][:12],
                    "the step summary must record %r as %s" % (name, marker),
                )

            # I.2 The last output failing must still fail the job (guards a
            #     loop that only remembers the final exit status incorrectly).
            proc, attempted, _ = run_batch(tsv("a", "b", "c"), ["c"])
            check(attempted == [".#a", ".#b", ".#c"], "all three outputs must be attempted")
            check(proc.returncode != 0, "a failure in the last output must fail the job")

            # I.3 The first output failing must not stop the others.
            proc, attempted, _ = run_batch(tsv("a", "b", "c"), ["a"])
            check(
                attempted == [".#a", ".#b", ".#c"],
                "a failure in the first output must not abandon the rest; got %r" % attempted,
            )
            check(proc.returncode != 0, "a failure in the first output must fail the job")

            # I.4 Every output failing.
            proc, attempted, _ = run_batch(tsv("a", "b"), ["a", "b"])
            check(attempted == [".#a", ".#b"], "both outputs must be attempted")
            check(proc.returncode != 0, "an all-failing batch must fail the job")

            # I.5 A clean batch passes.
            proc, attempted, _ = run_batch(tsv("a", "b", "c"), [])
            check(attempted == [".#a", ".#b", ".#c"], "a clean batch must attempt everything")
            check(
                proc.returncode == 0,
                "a batch with no failures must pass; stderr: %s" % proc.stderr[-400:],
            )

            # I.6 A planner-produced singleton (one row) drives exactly one
            #     build. This is what an opted-in caller gets for outputs that
            #     must stay alone, e.g. deployment targets and Foundry.
            proc, attempted, _ = run_batch(tsv("solo"), [])
            check(attempted == [".#solo"], "a one-row batch must build exactly one output")
            check(proc.returncode == 0, "a passing one-row batch must pass")
            proc, attempted, _ = run_batch(tsv("solo"), ["solo"])
            check(attempted == [".#solo"], "a failing one-row batch must still be attempted")
            check(proc.returncode != 0, "a failing one-row batch must fail the job")

            # I.7 Unbatched fallback: no BATCH_TSV, behave exactly as before.
            proc, attempted, _ = run_batch("", [], fallback_name="solo", fallback_attr="solo")
            check(
                attempted == [".#solo"],
                "without a batch the job must build its single matrix attribute; got %r"
                % attempted,
            )
            check(proc.returncode == 0, "the unbatched success path must pass")

            proc, attempted, _ = run_batch("", ["solo"], fallback_name="solo", fallback_attr="solo")
            check(
                proc.returncode != 0,
                "the unbatched failure path must still fail the job",
            )

            # I.8 Zero resolved outputs is never a green build.
            proc, attempted, _ = run_batch("", [], fallback_name="empty", fallback_attr="")
            check(attempted == [], "an empty batch must attempt nothing")
            check(
                proc.returncode != 0 and "Empty build batch" in proc.stdout,
                "a job that resolved no outputs must fail rather than report success",
            )

            if failures:
                raise SystemExit(
                    "ci-build-batching: %d assertion(s) failed:\n  - %s"
                    % (len(failures), "\n  - ".join(failures))
                )
            print("ci-build-batching: all assertions passed")
            PY
            touch "$out"
          '';
    };
}
