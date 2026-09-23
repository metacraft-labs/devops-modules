{ ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      flakeChecksWorkflow = ../.github/workflows/reusable-flake-checks-ci-matrix.yml;
      terraformWorkflow = ../.github/workflows/reusable-terraform-ci.yml;
    in
    {
      checks.reusable-flake-checks-mcl-ref =
        pkgs.runCommand "reusable-flake-checks-mcl-ref"
          {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.python3
            ];
          }
          ''
            python3 - <<'PY'
            import os
            import subprocess
            import tempfile
            from pathlib import Path

            workflow = Path("${flakeChecksWorkflow}").read_text()
            lines = workflow.splitlines()

            step_index = None
            for index, line in enumerate(lines):
                if "- name: Compute reusable workflow SHA and set mcl nix run command" in line:
                    step_index = index
                    break
            assert step_index is not None, "compute-mcl-ref step not found"

            step_indent = len(lines[step_index]) - len(lines[step_index].lstrip())
            next_step_index = len(lines)
            for index in range(step_index + 1, len(lines)):
                if lines[index].strip() and (
                    len(lines[index]) - len(lines[index].lstrip())
                ) <= step_indent:
                    next_step_index = index
                    break
            compute_step = "\n".join(lines[step_index:next_step_index])

            assert "gh api" not in compute_step, "compute step must not call GitHub APIs"
            assert "/actions/runs/" not in compute_step, "compute step must not inspect caller workflow runs"
            assert "GITHUB_WORKFLOW_REF" in compute_step
            assert "GITHUB_WORKFLOW_SHA" in compute_step
            assert "is_commit_sha" in compute_step, "compute step must validate refs before building flake URI"

            run_index = None
            for index in range(step_index + 1, next_step_index):
                if lines[index].strip() == "run: |":
                    run_index = index
                    break
            assert run_index is not None, "compute-mcl-ref run block not found"

            run_indent = len(lines[run_index]) - len(lines[run_index].lstrip())
            block_indent = run_indent + 2
            block = []
            for line in lines[run_index + 1:next_step_index]:
                if not line.strip():
                    block.append("")
                    continue
                indent = len(line) - len(line.lstrip())
                assert indent >= block_indent, f"unexpected run block indentation: {line!r}"
                block.append(line[block_indent:])
            script = "\n".join(block) + "\n"

            with tempfile.TemporaryDirectory() as temp:
                temp_path = Path(temp)
                script_path = temp_path / "compute-mcl-ref.sh"
                script_path.write_text(script)
                subprocess.run(["${pkgs.bash}/bin/bash", "-n", str(script_path)], check=True)

                def run_case(name, env_updates, expected_ref):
                    output_path = temp_path / f"{name}.out"
                    env = os.environ.copy()
                    env.update(
                        {
                            "GITHUB_OUTPUT": str(output_path),
                            "GITHUB_REPOSITORY": "",
                            "GITHUB_SHA": "",
                            "GITHUB_WORKFLOW_REF": "",
                            "GITHUB_WORKFLOW_SHA": "",
                        }
                    )
                    env.update(env_updates)
                    result = subprocess.run(
                        ["${pkgs.bash}/bin/bash", str(script_path)],
                        env=env,
                        text=True,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                    )
                    assert result.returncode == 0, (
                        f"{name}: exit {result.returncode}\n"
                        f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
                    )
                    outputs = dict(
                        line.split("=", 1)
                        for line in output_path.read_text().splitlines()
                        if "=" in line
                    )
                    assert outputs["workflow_sha"] == expected_ref, (name, outputs)
                    expected_cmd = (
                        "nix --option download-attempts 5 run --accept-flake-config "
                        f"github:metacraft-labs/devops-modules/{expected_ref}#mcl-devops"
                    )
                    assert outputs["mcl_flake_cmd"] == expected_cmd, (name, outputs)
                    assert "{" not in outputs["mcl_flake_cmd"], (name, outputs)
                    assert "Resource not accessible" not in outputs["mcl_flake_cmd"], (name, outputs)

                workflow_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                caller_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

                run_case(
                    "reusable_workflow_sha",
                    {
                        "GITHUB_WORKFLOW_REF": (
                            "metacraft-labs/devops-modules/.github/workflows/"
                            "reusable-flake-checks-ci-matrix.yml@refs/heads/dev"
                        ),
                        "GITHUB_WORKFLOW_SHA": workflow_sha,
                        "GITHUB_REPOSITORY": "metacraft-labs/infra",
                        "GITHUB_SHA": caller_sha,
                    },
                    workflow_sha,
                )
                run_case(
                    "local_repo_pr_sha",
                    {
                        "GITHUB_REPOSITORY": "metacraft-labs/devops-modules",
                        "GITHUB_SHA": caller_sha,
                        "GITHUB_WORKFLOW_REF": (
                            "metacraft-labs/devops-modules/.github/workflows/"
                            "reusable-flake-checks-ci-matrix.yml@refs/pull/1/merge"
                        ),
                        "GITHUB_WORKFLOW_SHA": workflow_sha,
                    },
                    caller_sha,
                )
                run_case(
                    "forbidden_api_json_falls_back",
                    {
                        "GITHUB_WORKFLOW_REF": (
                            "metacraft-labs/devops-modules/.github/workflows/"
                            "reusable-flake-checks-ci-matrix.yml@refs/heads/dev"
                        ),
                        "GITHUB_WORKFLOW_SHA": '{"message":"Resource not accessible by integration","status":"403"}',
                        "GITHUB_REPOSITORY": "metacraft-labs/infra",
                        "GITHUB_SHA": caller_sha,
                    },
                    "dev",
                )
                run_case("empty_context_falls_back", {}, "dev")
            PY

            touch "$out"
          '';

      checks.reusable-flake-checks-attic-credentials =
        pkgs.runCommand "reusable-flake-checks-attic-credentials"
          {
            nativeBuildInputs = [ pkgs.python3 ];
          }
          ''
            python3 - <<'PY'
            from pathlib import Path

            workflow = Path("${flakeChecksWorkflow}").read_text()
            lines = workflow.splitlines()

            def named_steps(name):
                blocks = []
                for start, line in enumerate(lines):
                    if line.strip() != f"- name: {name}":
                        continue
                    step_indent = len(line) - len(line.lstrip())
                    end = len(lines)
                    for index in range(start + 1, len(lines)):
                        if lines[index].strip() and (
                            len(lines[index]) - len(lines[index].lstrip())
                        ) <= step_indent:
                            end = index
                            break
                    blocks.append("\n".join(lines[start:end]))
                return blocks

            declaration = workflow.split("\njobs:\n", 1)[0]
            assert "      ATTIC_PULL_TOKEN:\n" in declaration
            assert "      ATTIC_TOKEN:\n" in declaration

            pull_expression = (
                "ATTIC_TOKEN: "
                + "$"
                + "{{ secrets.ATTIC_PULL_TOKEN || secrets.ATTIC_TOKEN }}"
            )

            auth_steps = named_steps("Authenticate nix to the private Attic cache")
            assert len(auth_steps) == 4, f"expected four Nix pull-auth steps, got {len(auth_steps)}"
            for step in auth_steps:
                assert pull_expression in step, "Nix cache auth must prefer the pull-only token"

            probe_step_names = [
                "Generate Shard Matrix",
                "Generate CI Matrix",
                "Regenerate CI matrix shards when artifacts are unavailable",
                "Generate CI matrix comment",
                "Print CI Matrix",
            ]
            for name in probe_step_names:
                steps = named_steps(name)
                assert len(steps) == 1, f"expected one {name!r} step, got {len(steps)}"
                assert pull_expression in steps[0], f"{name} must prefer the pull-only token"

            merge_steps = named_steps("Merge matrices")
            assert len(merge_steps) == 1
            assert "ATTIC_" not in merge_steps[0], "matrix merging does not need Attic credentials"

            push_step_name = "Push deployment closure caches " + "$" + "{{ matrix.name }}"
            push_steps = named_steps(push_step_name)
            assert len(push_steps) == 1
            assert "secrets.ATTIC_TOKEN" in push_steps[0]
            assert "secrets.ATTIC_PULL_TOKEN" not in push_steps[0], (
                "deployment cache publication must retain the push credential"
            )
            PY

            touch "$out"
          '';

      checks.reusable-flake-checks-artifact-fallback =
        pkgs.runCommand "reusable-flake-checks-artifact-fallback"
          {
            nativeBuildInputs = [ pkgs.python3 ];
          }
          ''
            python3 - <<'PY'
            import re
            from pathlib import Path

            workflow = Path("${flakeChecksWorkflow}").read_text()
            merge_job = workflow.split("\n  merge-matrices:\n", 1)[1]
            next_job = re.search(r"\n  [a-z0-9-]+:\n", merge_job)
            assert next_job is not None, "job following merge-matrices disappeared"
            merge_job = merge_job[: next_job.start()]

            checkout = "uses: actions/checkout@v6.0.2"
            fallback = "name: Regenerate CI matrix shards when artifacts are unavailable"
            assert checkout in merge_job, "matrix artifact fallback requires a caller-repository checkout"
            assert fallback in merge_job, "matrix artifact fallback step disappeared"
            assert merge_job.index(checkout) < merge_job.index(fallback), (
                "caller-repository checkout must precede matrix artifact regeneration"
            )
            PY

            touch "$out"
          '';

      checks.reusable-flake-checks-s3-mirror-compat =
        pkgs.runCommand "reusable-flake-checks-s3-mirror-compat"
          {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.python3
            ];
          }
          ''
            python3 - <<'PY'
            import os
            import subprocess
            import tempfile
            from pathlib import Path

            workflow = Path("${flakeChecksWorkflow}").read_text()
            lines = workflow.splitlines()
            step_name = "Upload CI artifacts to S3 (non-blocking mirror)"

            step_indexes = [
                index
                for index, line in enumerate(lines)
                if line.strip() == f"- name: {step_name}"
            ]
            assert len(step_indexes) == 1, (
                f"expected exactly one {step_name!r} step, got {len(step_indexes)}"
            )

            step_start = step_indexes[0]
            step_indent = len(lines[step_start]) - len(lines[step_start].lstrip())
            step_end = len(lines)
            for index in range(step_start + 1, len(lines)):
                if lines[index].strip() and (
                    len(lines[index]) - len(lines[index].lstrip())
                ) <= step_indent:
                    step_end = index
                    break
            step_lines = lines[step_start:step_end]
            step = "\n".join(step_lines)

            env_index = next(
                (
                    index
                    for index, line in enumerate(step_lines)
                    if line.strip() == "env:"
                    and len(line) - len(line.lstrip()) == step_indent + 2
                ),
                None,
            )
            assert env_index is not None, "S3 mirror step has no step-scoped env block"
            env_indent = step_indent + 4
            step_env = {}
            step_env_line_indexes = {}
            for step_line_index, line in enumerate(
                step_lines[env_index + 1:], start=env_index + 1
            ):
                if not line.strip():
                    continue
                indent = len(line) - len(line.lstrip())
                if indent < env_indent:
                    break
                if indent != env_indent:
                    continue
                key, separator, value = line.strip().partition(":")
                assert separator, f"invalid S3 mirror env entry: {line!r}"
                step_env[key] = value.strip().strip("'\"")
                step_env_line_indexes[key] = step_start + step_line_index

            compatibility_env = {
                "AWS_REQUEST_CHECKSUM_CALCULATION": "WHEN_REQUIRED",
                "AWS_RESPONSE_CHECKSUM_VALIDATION": "WHEN_REQUIRED",
            }
            for key, expected_value in compatibility_env.items():
                assert step_env.get(key) == expected_value, (
                    f"{key} must equal {expected_value} in the S3 mirror step env"
                )
                occurrences = [
                    index
                    for index, line in enumerate(lines)
                    if line.strip().startswith(f"{key}:")
                ]
                assert occurrences == [step_env_line_indexes[key]], (
                    f"{key} must be declared exactly once and only in the credentialed "
                    f"S3 mirror step; found workflow lines {[index + 1 for index in occurrences]}"
                )

            assert "secrets.MCL_S3_ARTIFACTS_ACCESS_KEY_ID" in step_env.get(
                "AWS_ACCESS_KEY_ID", ""
            ), "checksum compatibility must stay scoped to the credentialed mirror step"
            assert "secrets.MCL_S3_ARTIFACTS_SECRET_ACCESS_KEY" in step_env.get(
                "AWS_SECRET_ACCESS_KEY", ""
            ), "checksum compatibility must stay scoped to the credentialed mirror step"
            assert chr(39) * 2 + "$" + "{" not in step, (
                "raw YAML run block must use shell parameter expansion without Nix escaping"
            )

            run_index = next(
                (
                    index
                    for index, line in enumerate(step_lines)
                    if line.strip() == "run: |"
                    and len(line) - len(line.lstrip()) == step_indent + 2
                ),
                None,
            )
            assert run_index is not None, "S3 mirror run block not found"
            run_indent = len(step_lines[run_index]) - len(
                step_lines[run_index].lstrip()
            )
            block_indent = run_indent + 2
            script_lines = []
            for line in step_lines[run_index + 1:]:
                if not line.strip():
                    script_lines.append("")
                    continue
                indent = len(line) - len(line.lstrip())
                assert indent >= block_indent, (
                    f"unexpected S3 mirror run-block indentation: {line!r}"
                )
                script_lines.append(line[block_indent:])
            script = "\n".join(script_lines) + "\n"

            with tempfile.TemporaryDirectory() as temp:
                temp_path = Path(temp)
                bin_path = temp_path / "bin"
                result_path = temp_path / ".result"
                bin_path.mkdir()
                result_path.mkdir()
                (result_path / "deployment-cache-push-events.jsonl").write_text(
                    '{"event":"compatibility-test"}\n'
                )

                script_path = temp_path / "s3-mirror.sh"
                script_path.write_text(script)
                subprocess.run(
                    ["${pkgs.bash}/bin/bash", "-n", str(script_path)], check=True
                )

                nix_mock = bin_path / "nix"
                nix_mock.write_text(
                    "#!${pkgs.bash}/bin/bash\n"
                    "set -euo pipefail\n"
                    '[[ "$1" == shell && "$2" == nixpkgs#awscli2 && "$3" == -c ]]\n'
                    "shift 3\n"
                    'exec "$@"\n'
                )
                nix_mock.chmod(0o755)

                aws_mock = bin_path / "aws"
                aws_mock.write_text(
                    "#!${pkgs.bash}/bin/bash\n"
                    "set -euo pipefail\n"
                    '{ printf "request=%s\\n" "$AWS_REQUEST_CHECKSUM_CALCULATION"; '
                    'printf "response=%s\\n" "$AWS_RESPONSE_CHECKSUM_VALIDATION"; '
                    'printf "arg=%s\\n" "$@"; } >"$MOCK_AWS_CAPTURE"\n'
                )
                aws_mock.chmod(0o755)

                capture_path = temp_path / "aws.capture"
                env = os.environ.copy()
                env.update(step_env)
                env.update(
                    {
                        "AWS_ACCESS_KEY_ID": "test-access-key",
                        "AWS_SECRET_ACCESS_KEY": "test-secret-key",
                        "MCL_S3_ARTIFACTS_ENDPOINT": "https://garage.example.test",
                        "MCL_S3_ARTIFACTS_BUCKET": "compat-bucket",
                        "MCL_S3_ARTIFACTS_REGION": "garage",
                        "S3_OBJECT_PREFIX": "deployment-cache-push/123/0",
                        "MOCK_AWS_CAPTURE": str(capture_path),
                        "PATH": str(bin_path) + os.pathsep + env["PATH"],
                    }
                )
                result = subprocess.run(
                    ["${pkgs.bash}/bin/bash", str(script_path)],
                    cwd=temp_path,
                    env=env,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                assert result.returncode == 0, (
                    f"S3 mirror mock exited {result.returncode}\n"
                    f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
                )
                assert capture_path.exists(), (
                    "mock aws was not invoked; non-blocking error handling must not hide "
                    "a pre-upload regression\n"
                    f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
                )
                capture = capture_path.read_text().splitlines()
                assert capture[:2] == [
                    "request=WHEN_REQUIRED",
                    "response=WHEN_REQUIRED",
                ], f"mock aws received wrong checksum environment: {capture[:2]!r}"
                assert capture[2:] == [
                    "arg=--endpoint-url",
                    "arg=https://garage.example.test",
                    "arg=--region",
                    "arg=garage",
                    "arg=s3",
                    "arg=cp",
                    "arg=.result/deployment-cache-push-events.jsonl",
                    (
                        "arg=s3://compat-bucket/deployment-cache-push/123/0/"
                        "deployment-cache-push-events.jsonl"
                    ),
                ], f"mock aws received unexpected argv: {capture[2:]!r}"
                assert "Mirrored deployment-cache-push-events.jsonl" in result.stdout
            PY

            touch "$out"
          '';

      checks.reusable-terraform-drift-workflow =
        pkgs.runCommand "reusable-terraform-drift-workflow"
          {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.python3
            ];
          }
          ''
            python3 - <<'PY'
            import subprocess
            import tempfile
            from pathlib import Path

            workflow = Path("${terraformWorkflow}").read_text()
            lines = workflow.splitlines()

            def extract_named_block(start_text, base_indent=None):
                start = None
                for index, line in enumerate(lines):
                    if line.strip() == start_text:
                        start = index
                        break
                assert start is not None, f"{start_text!r} not found"

                if base_indent is None:
                    base_indent = len(lines[start]) - len(lines[start].lstrip())

                end = len(lines)
                for index in range(start + 1, len(lines)):
                    if lines[index].strip() and (
                        len(lines[index]) - len(lines[index].lstrip())
                    ) <= base_indent:
                        end = index
                        break
                return lines[start:end]

            def extract_run_script(block_lines, step_name):
                step_index = None
                for index, line in enumerate(block_lines):
                    if line.strip() == f"- name: {step_name}":
                        step_index = index
                        break
                assert step_index is not None, f"{step_name!r} step not found"

                step_indent = len(block_lines[step_index]) - len(block_lines[step_index].lstrip())
                step_end = len(block_lines)
                for index in range(step_index + 1, len(block_lines)):
                    if block_lines[index].strip() and (
                        len(block_lines[index]) - len(block_lines[index].lstrip())
                    ) <= step_indent:
                        step_end = index
                        break

                run_index = None
                for index in range(step_index + 1, step_end):
                    if block_lines[index].strip() == "run: |":
                        run_index = index
                        break
                assert run_index is not None, f"{step_name!r} run block not found"

                run_indent = len(block_lines[run_index]) - len(block_lines[run_index].lstrip())
                block_indent = run_indent + 2
                script_lines = []
                for line in block_lines[run_index + 1:step_end]:
                    if not line.strip():
                        script_lines.append("")
                        continue
                    indent = len(line) - len(line.lstrip())
                    assert indent >= block_indent, f"unexpected run block indentation: {line!r}"
                    script_lines.append(line[block_indent:])
                return "\n".join(script_lines) + "\n"

            drift_job = extract_named_block("drift-check:", base_indent=2)
            drift_text = "\n".join(drift_job)

            terranix_index = drift_text.find("- name: Terranix")
            init_index = drift_text.find("- name: Init")
            detect_index = drift_text.find("- name: Detect drift")
            assert terranix_index != -1, "drift job must generate Terranix before init"
            assert init_index != -1, "drift job Init step not found"
            assert detect_index != -1, "drift job Detect drift step not found"
            assert terranix_index < init_index < detect_index, (
                "drift job must generate Terranix before init and plan"
            )

            script = extract_run_script(drift_job, "Detect drift")
            assert "set -euo pipefail" in script
            assert "run_tofu()" in script
            assert "plan_exit=$?" in script
            assert "| tee /tmp/drift-plan.txt" not in script, (
                "drift plan exit code must not be hidden behind tee"
            )

            with tempfile.TemporaryDirectory() as temp:
                script_path = Path(temp) / "detect-drift.sh"
                script_path.write_text(script)
                subprocess.run(["${pkgs.bash}/bin/bash", "-n", str(script_path)], check=True)

            issue_script = extract_run_script(drift_job, "Open drift issue")
            label_view = issue_script.find("gh label view drift")
            label_create = issue_script.find("gh label create drift")
            issue_create = issue_script.find(
                'gh issue create "' + "$" + '{issue_args[@]}"'
            )
            assert label_view != -1, "drift notification must probe for its label"
            assert label_create != -1, "drift notification must create a missing label"
            assert issue_create != -1, "drift notification issue creation disappeared"
            assert label_view < label_create < issue_create, (
                "the reusable workflow must ensure its optional label before opening the issue"
            )
            assert "opening the drift issue without it" in issue_script, (
                "label failure must not suppress the drift issue"
            )

            with tempfile.TemporaryDirectory() as temp:
                script_path = Path(temp) / "open-drift-issue.sh"
                script_path.write_text(issue_script)
                subprocess.run(["${pkgs.bash}/bin/bash", "-n", str(script_path)], check=True)
            PY

            touch "$out"
          '';

      checks.reusable-terraform-policy-advisories =
        pkgs.runCommand "reusable-terraform-policy-advisories"
          {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.python3
            ];
          }
          ''
            python3 - <<'PY'
            from pathlib import Path

            workflow = Path("${terraformWorkflow}").read_text()
            assert 'POLICY_RUNNER="$policy_dir/tofu-plan-policy-ci"' in workflow
            assert 'POLICY_SCRIPT="$policy_dir/tofu-plan-policy.py"' in workflow
            assert 'cat-file blob "''${EXPECTED_WORKFLOW_SHA}:''${policy_script_path}"' in workflow
            assert 'cat-file blob "''${EXPECTED_WORKFLOW_SHA}:''${policy_runner_path}"' in workflow
            assert "tofu-plan-policy-ci" in workflow
            expected = (
                'bash "$POLICY_RUNNER" "$POLICY_SCRIPT" "$PLAN_JSON" "'
                + "$"
                + '{POLICY_ARGS[@]}"'
            )
            assert expected in workflow
            PY

            cd ${../.}
            python3 scripts/tests/test_policy.py
            touch "$out"
          '';

      # reusable-lint.yml hook-entry-point discovery: the `Check formatting`
      # step is extracted verbatim and run against scratch checkouts with a
      # stubbed `nix` (see the test's header for why that stub is justified).
      checks.reusable-lint-hook-discovery =
        pkgs.runCommand "reusable-lint-hook-discovery"
          {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.gitMinimal
              pkgs.gnugrep
              pkgs.python3
            ];
          }
          ''
            cd ${../.}
            python3 scripts/tests/test_reusable_lint_discovery.py
            touch "$out"
          '';

      checks.reusable-terraform-source-identity =
        pkgs.runCommand "reusable-terraform-source-identity"
          {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.gitMinimal
              pkgs.python3
            ];
          }
          ''
            cd ${../.}
            python3 scripts/tests/test_reusable_terraform_source_identity.py
            touch "$out"
          '';
    };
}
