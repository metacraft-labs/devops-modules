#!/usr/bin/env python3
"""Contract tests for immutable source use in reusable Terraform CI."""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW_PATH = REPO_ROOT / ".github/workflows/reusable-terraform-ci.yml"
CHECKOUT_ACTION = (
    "actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2"
)
SOURCE_PATH = ".mcl/reusable-terraform-ci"
LOCAL_SETUP_ACTION = f"./{SOURCE_PATH}/.github/setup-nix"
RELEVANT_JOBS = ("offline-checks", "credentialed-plan", "apply", "drift-check")


def extract_indented_block(lines: list[str], start: int, indent: int) -> list[str]:
    end = len(lines)
    for index in range(start + 1, len(lines)):
        line = lines[index]
        if line.strip() and len(line) - len(line.lstrip()) <= indent:
            end = index
            break
    return lines[start:end]


def extract_job(workflow: str, name: str) -> str:
    lines = workflow.splitlines()
    marker = f"  {name}:"
    starts = [index for index, line in enumerate(lines) if line == marker]
    assert len(starts) == 1, f"expected exactly one {name!r} job, got {len(starts)}"
    return "\n".join(extract_indented_block(lines, starts[0], 2)) + "\n"


def named_step(job: str, name: str) -> str:
    lines = job.splitlines()
    marker = f"      - name: {name}"
    starts = [index for index, line in enumerate(lines) if line == marker]
    assert len(starts) == 1, (
        f"expected exactly one {name!r} step in job, got {len(starts)}"
    )
    return "\n".join(extract_indented_block(lines, starts[0], 6)) + "\n"


def job_steps(job: str) -> list[str]:
    lines = job.splitlines()
    starts = [
        index for index, line in enumerate(lines) if line.startswith("      - ")
    ]
    return [
        "\n".join(
            lines[start : starts[position + 1] if position + 1 < len(starts) else len(lines)]
        )
        + "\n"
        for position, start in enumerate(starts)
    ]


def step_name(step: str) -> str:
    first_line = step.splitlines()[0]
    marker = "      - name: "
    assert first_line.startswith(marker), f"Terraform job has an unnamed step: {first_line!r}"
    return first_line.removeprefix(marker)


def run_script(step: str) -> str:
    lines = step.splitlines()
    starts = [index for index, line in enumerate(lines) if line == "        run: |"]
    assert len(starts) == 1, f"expected one run block, got {len(starts)}"
    start = starts[0]
    script_lines = []
    for line in lines[start + 1 :]:
        if not line.strip():
            script_lines.append("")
            continue
        assert line.startswith("          "), f"unexpected run indentation: {line!r}"
        script_lines.append(line[10:])
    return "\n".join(script_lines) + "\n"


def assert_in_order(text: str, fragments: tuple[str, ...], context: str) -> None:
    cursor = -1
    for fragment in fragments:
        position = text.find(fragment, cursor + 1)
        assert position != -1, f"{context}: missing {fragment!r}"
        assert position > cursor, f"{context}: {fragment!r} is out of order"
        cursor = position


def validate(workflow: str) -> None:
    forbidden = (
        "metacraft-labs/devops-modules/.github/setup-nix@dev",
        "github.action_ref",
        "raw.githubusercontent.com",
        "/tmp/tofu-plan-policy",
    )
    for fragment in forbidden:
        assert fragment not in workflow, f"mutable/downloaded source remains: {fragment}"

    setup_uses = [
        line.strip()
        for line in workflow.splitlines()
        if "setup-nix" in line and line.strip().startswith("uses:")
    ]
    assert setup_uses == [f"uses: {LOCAL_SETUP_ACTION}"] * len(RELEVANT_JOBS), (
        "every and only every Terraform job must use Setup Nix from the exact local "
        "called-workflow checkout"
    )
    assert workflow.count(f"uses: {LOCAL_SETUP_ACTION}") == len(RELEVANT_JOBS), (
        "every and only every Terraform job must use Setup Nix from the exact local "
        "called-workflow checkout"
    )
    assert workflow.count("- name: Checkout called workflow source") == len(
        RELEVANT_JOBS
    ), "called-workflow source checkout cardinality changed"
    assert workflow.count("- name: Verify called workflow source") == len(
        RELEVANT_JOBS
    ), "called-workflow source verifier cardinality changed"
    assert workflow.count(f"          path: {SOURCE_PATH}\n") == len(RELEVANT_JOBS), (
        "called-workflow checkout destination cardinality changed"
    )
    assert workflow.count("persist-credentials: false") == len(
        RELEVANT_JOBS
    ), "persist-credentials:false cardinality changed"

    for job_name in RELEVANT_JOBS:
        job = extract_job(workflow, job_name)
        steps = job_steps(job)
        names = [step_name(step) for step in steps]
        assert names[:4] == [
            "Checkout",
            "Checkout called workflow source",
            "Verify called workflow source",
            "Setup Nix",
        ], f"{job_name}: source checkout, verification, and Setup Nix must be adjacent"
        checkout_uses = [
            line.strip()
            for line in job.splitlines()
            if line.strip().startswith("uses: actions/checkout@")
        ]
        assert checkout_uses == [f"uses: {CHECKOUT_ACTION}"] * 2, (
            f"{job_name}: expected only the caller and exact called-workflow checkouts"
        )
        assert_in_order(
            job,
            (
                "- name: Checkout\n",
                "- name: Checkout called workflow source\n",
                "- name: Verify called workflow source\n",
                "- name: Setup Nix\n",
            ),
            job_name,
        )

        source_checkout = named_step(job, "Checkout called workflow source")
        required_checkout_lines = (
            f"uses: {CHECKOUT_ACTION}",
            "repository: ${{ job.workflow_repository }}",
            "ref: ${{ job.workflow_sha }}",
            f"path: {SOURCE_PATH}",
            "persist-credentials: false",
        )
        assert_in_order(source_checkout, required_checkout_lines, f"{job_name} checkout")
        assert "github.repository" not in source_checkout, (
            f"{job_name}: source checkout used the caller repository"
        )
        assert "github.sha" not in source_checkout, (
            f"{job_name}: source checkout used the caller SHA"
        )
        assert " || " not in source_checkout, "called-workflow identity must not fall back"

        verify_step = named_step(job, "Verify called workflow source")
        required_env = (
            "EXPECTED_WORKFLOW_REPOSITORY: ${{ job.workflow_repository }}",
            "EXPECTED_WORKFLOW_SHA: ${{ job.workflow_sha }}",
            "EXPECTED_WORKFLOW_SERVER_URL: ${{ github.server_url }}",
            f"WORKFLOW_SOURCE: ${{{{ github.workspace }}}}/{SOURCE_PATH}",
        )
        assert_in_order(verify_step, required_env, f"{job_name} verification env")
        assert "github.repository" not in verify_step
        assert "github.sha" not in verify_step
        verify_script = run_script(verify_step)
        assert_in_order(
            verify_script,
            (
                "set -euo pipefail",
                '[[ ! "$EXPECTED_WORKFLOW_REPOSITORY" =~',
                '[[ ! "$EXPECTED_WORKFLOW_SHA" =~ ^[0-9a-f]{40}$ ]]',
                '[[ ! "$EXPECTED_WORKFLOW_SERVER_URL" =~',
                '[ ! -d "$WORKFLOW_SOURCE/.git" ]',
                "rev-parse --verify 'HEAD^{commit}'",
                '[ "$actual_sha" != "$EXPECTED_WORKFLOW_SHA" ]',
                'expected_remote="${EXPECTED_WORKFLOW_SERVER_URL}/',
                'remote get-url origin',
                '[ "$actual_remote" != "$expected_remote" ]',
                "status --porcelain=v1 --untracked-files=all",
                "setup_file_count=0",
                'rev-parse --verify "${EXPECTED_WORKFLOW_SHA}:${setup_path}"',
                'hash-object --no-filters -- "$setup_file"',
                '[ "$actual_blob" != "$expected_blob" ]',
                "ls-tree -r --name-only -z",
                '[ "$setup_file_count" -eq 0 ]',
            ),
            f"{job_name} verification",
        )

        setup_step = named_step(job, "Setup Nix")
        assert f"uses: {LOCAL_SETUP_ACTION}" in setup_step
        assert "@main" not in setup_step

    plan_job = extract_job(workflow, "credentialed-plan")
    policy_step = named_step(plan_job, "Plan JSON policy gate")
    assert policy_step.count(
        "EXPECTED_WORKFLOW_REPOSITORY: ${{ job.workflow_repository }}"
    ) == 1
    assert policy_step.count("EXPECTED_WORKFLOW_SHA: ${{ job.workflow_sha }}") == 1
    assert f"WORKFLOW_SOURCE: ${{{{ github.workspace }}}}/{SOURCE_PATH}" in policy_step
    policy_script = run_script(policy_step)
    assert_in_order(
        policy_script,
        (
            "POLICY_ARGS=()",
            '[[ ! "$EXPECTED_WORKFLOW_REPOSITORY" =~',
            '[[ ! "$EXPECTED_WORKFLOW_SHA" =~ ^[0-9a-f]{40}$ ]]',
            "rev-parse --verify 'HEAD^{commit}'",
            '[ "$actual_sha" != "$EXPECTED_WORKFLOW_SHA" ]',
            "remote get-url origin",
            '[ "$actual_remote" != "$expected_remote" ]',
            'policy_script_path="scripts/tofu-plan-policy.py"',
            'policy_runner_path="scripts/tofu-plan-policy-ci"',
            'rev-parse --verify "${EXPECTED_WORKFLOW_SHA}:${policy_path}"',
            'cat-file -t "$expected_blob"',
            'hash-object --no-filters -- "$policy_file"',
            '[ "$actual_blob" != "$expected_blob" ]',
            'policy_dir="$(mktemp -d "$RUNNER_TEMP/reusable-terraform-policy.XXXXXX")"',
            'POLICY_SCRIPT="$policy_dir/tofu-plan-policy.py"',
            'POLICY_RUNNER="$policy_dir/tofu-plan-policy-ci"',
            'cat-file blob "${EXPECTED_WORKFLOW_SHA}:${policy_script_path}"',
            'cat-file blob "${EXPECTED_WORKFLOW_SHA}:${policy_runner_path}"',
            'hash-object --no-filters -- "$POLICY_SCRIPT"',
            'hash-object --no-filters -- "$POLICY_RUNNER"',
            'bash "$POLICY_RUNNER" "$POLICY_SCRIPT" "$PLAN_JSON"',
        ),
        "late policy-source verification",
    )
    policy_invocation = (
        'bash "$POLICY_RUNNER" "$POLICY_SCRIPT" "$PLAN_JSON" "${POLICY_ARGS[@]}"'
    )
    assert policy_script.count(policy_invocation) == 1, (
        "the verified materialized policy helper must execute exactly once"
    )
    assert policy_script.count("POLICY_SCRIPT") == 4, (
        "policy script may only be named, materialized, verified, and executed"
    )
    assert policy_script.count("POLICY_RUNNER") == 4, (
        "policy helper may only be named, materialized, verified, and executed"
    )
    assert policy_script.count("tofu-plan-policy.py") == 2, (
        "policy path may only identify its immutable source and private copy"
    )
    assert policy_script.count("tofu-plan-policy-ci") == 2, (
        "helper path may only identify its immutable source and private copy"
    )
    assert policy_script.count('"$PLAN_JSON"') == 1, (
        "the plan may be passed to exactly one policy execution"
    )
    policy_source_steps = [
        step_name(step)
        for step in job_steps(plan_job)
        if "tofu-plan-policy.py" in step or "tofu-plan-policy-ci" in step
    ]
    assert policy_source_steps == ["Plan JSON policy gate"], (
        "the exact-source plan policy may execute only in its named guarded step"
    )


def replace_once(text: str, old: str, new: str) -> str:
    assert text.count(old) >= 1, f"mutation target missing: {old!r}"
    return text.replace(old, new, 1)


def expect_rejected(
    name: str, mutated: str, original: str, expected_error: str
) -> None:
    assert mutated != original, f"{name}: mutation did not change the workflow"
    try:
        validate(mutated)
    except AssertionError as error:
        assert expected_error in str(error), (
            f"{name}: mutation was rejected by the wrong guard; "
            f"expected {expected_error!r}, got {str(error)!r}"
        )
        return
    raise AssertionError(f"{name}: weakened workflow was accepted")


def test_negative_mutations(workflow: str) -> None:
    checkout_step = named_step(
        extract_job(workflow, "offline-checks"), "Checkout called workflow source"
    )
    verify_step = named_step(
        extract_job(workflow, "offline-checks"), "Verify called workflow source"
    )
    setup_step = named_step(extract_job(workflow, "offline-checks"), "Setup Nix")
    plan_job = extract_job(workflow, "credentialed-plan")
    policy_step = named_step(plan_job, "Plan JSON policy gate")

    late_verification_start = policy_step.index(
        "          # Consumer-controlled plan commands run after the first source check."
    )
    late_verification_end = policy_step.index(
        "          nix shell --accept-flake-config --inputs-from"
    )
    without_late_verification_step = (
        policy_step[:late_verification_start]
        + policy_step[late_verification_end:]
    )

    policy_invocation = (
        '          nix shell --accept-flake-config --inputs-from "$GITHUB_WORKSPACE" '
        "nixpkgs#python3 --command \\\n"
        '            bash "$POLICY_RUNNER" "$POLICY_SCRIPT" "$PLAN_JSON" "${POLICY_ARGS[@]}"'
    )
    assert policy_step.count(policy_invocation) == 1
    policy_verification_marker = (
        "          # Consumer-controlled plan commands run after the first source check."
    )
    invocation_before_verification_step = policy_step.replace(
        policy_invocation, ""
    ).replace(
        policy_verification_marker,
        policy_invocation + "\n\n" + policy_verification_marker,
        1,
    )

    mutations = {
        "remove source checkout": (
            replace_once(workflow, checkout_step, ""),
            "source checkout cardinality",
        ),
        "move source checkout after setup": (
            replace_once(
                workflow,
                checkout_step + verify_step + setup_step,
                verify_step + setup_step + checkout_step,
            ),
            "source checkout, verification, and Setup Nix must be adjacent",
        ),
        "move verification after setup": (
            replace_once(
                workflow,
                verify_step + setup_step,
                setup_step + verify_step,
            ),
            "source checkout, verification, and Setup Nix must be adjacent",
        ),
        "use caller repository": (
            replace_once(
                workflow,
                "repository: ${{ job.workflow_repository }}",
                "repository: ${{ github.repository }}",
            ),
            "offline-checks checkout: missing 'repository: ${{ job.workflow_repository }}'",
        ),
        "use caller sha": (
            replace_once(
                workflow, "ref: ${{ job.workflow_sha }}", "ref: ${{ github.sha }}"
            ),
            "offline-checks checkout: missing 'ref: ${{ job.workflow_sha }}'",
        ),
        "use unrelated literal sha": (
            replace_once(
                workflow,
                "ref: ${{ job.workflow_sha }}",
                f"ref: {'1' * 40}",
            ),
            "offline-checks checkout: missing 'ref: ${{ job.workflow_sha }}'",
        ),
        "add mutable sha fallback": (
            replace_once(
                workflow,
                "ref: ${{ job.workflow_sha }}",
                "ref: ${{ job.workflow_sha || 'main' }}",
            ),
            "offline-checks checkout: missing 'ref: ${{ job.workflow_sha }}'",
        ),
        "persist checkout credential": (
            replace_once(
                workflow, "persist-credentials: false", "persist-credentials: true"
            ),
            "persist-credentials:false cardinality",
        ),
        "remove initial verifier": (
            replace_once(workflow, verify_step, ""),
            "source verifier cardinality",
        ),
        "weaken full sha check": (
            replace_once(
                workflow,
                '[[ ! "$EXPECTED_WORKFLOW_SHA" =~ ^[0-9a-f]{40}$ ]]',
                '[[ -z "$EXPECTED_WORKFLOW_SHA" ]]',
            ),
            "verification: missing '[[ ! \"$EXPECTED_WORKFLOW_SHA\"",
        ),
        "remove initial remote check": (
            replace_once(
                workflow,
                'if [ "$actual_remote" != "$expected_remote" ]; then',
                'if false; then',
            ),
            "verification: missing '[ \"$actual_remote\" != \"$expected_remote\" ]'",
        ),
        "remove initial cleanliness check": (
            replace_once(
                workflow,
                'if [ -n "$(git -C "$WORKFLOW_SOURCE" status --porcelain=v1 --untracked-files=all)" ]; then',
                'if false; then',
            ),
            "verification: missing 'status --porcelain=v1 --untracked-files=all'",
        ),
        "replace initial byte check with index-visible status": (
            replace_once(
                workflow,
                'actual_blob="$(git -C "$WORKFLOW_SOURCE" hash-object --no-filters -- "$setup_file")"',
                'actual_blob="$(git -C "$WORKFLOW_SOURCE" status --porcelain=v1 -- "$setup_path")"',
            ),
            "verification: missing 'hash-object --no-filters -- \"$setup_file\"'",
        ),
        "bind initial byte check to head": (
            replace_once(
                workflow,
                'rev-parse --verify "${EXPECTED_WORKFLOW_SHA}:${setup_path}"',
                'rev-parse --verify "HEAD:${setup_path}"',
            ),
            "verification: missing 'rev-parse --verify \"${EXPECTED_WORKFLOW_SHA}:${setup_path}\"'",
        ),
        "restore mutable setup": (
            replace_once(
                workflow,
                f"uses: {LOCAL_SETUP_ACTION}",
                "uses: metacraft-labs/devops-modules/.github/setup-nix@dev",
            ),
            "mutable/downloaded source remains",
        ),
        "use unrelated immutable setup action": (
            replace_once(
                workflow,
                f"uses: {LOCAL_SETUP_ACTION}",
                "uses: metacraft-labs/devops-modules/.github/setup-nix@"
                + "2" * 40,
            ),
            "every and only every Terraform job must use Setup Nix",
        ),
        "duplicate source checkout": (
            replace_once(workflow, checkout_step, checkout_step + "\n" + checkout_step),
            "source checkout cardinality",
        ),
        "add differently named source checkout after verification": (
            replace_once(
                workflow,
                verify_step + setup_step,
                verify_step
                + checkout_step.replace(
                    "- name: Checkout called workflow source",
                    "- name: Replace verified workflow source",
                    1,
                )
                + setup_step,
            ),
            "called-workflow checkout destination cardinality changed",
        ),
        "duplicate setup execution": (
            replace_once(
                workflow,
                setup_step,
                setup_step
                + setup_step.replace("- name: Setup Nix", "- name: Setup Nix again", 1),
            ),
            "every and only every Terraform job must use Setup Nix",
        ),
        "remove late verification": (
            replace_once(workflow, policy_step, without_late_verification_step),
            "late policy-source verification: missing '[[ ! \"$EXPECTED_WORKFLOW_REPOSITORY\"",
        ),
        "move late verification after policy": (
            replace_once(workflow, policy_step, invocation_before_verification_step),
            "late policy-source verification: missing 'bash \"$POLICY_RUNNER\"",
        ),
        "duplicate verified policy invocation": (
            replace_once(
                workflow,
                policy_invocation,
                policy_invocation + "\n" + policy_invocation,
            ),
            "verified materialized policy helper must execute exactly once",
        ),
        "add unverified worktree policy invocation": (
            replace_once(
                workflow,
                policy_invocation,
                policy_invocation
                + "\n"
                + '          bash "$WORKFLOW_SOURCE/scripts/tofu-plan-policy-ci" '
                + '"$WORKFLOW_SOURCE/scripts/tofu-plan-policy.py" "$PLAN_JSON"',
            ),
            "policy path may only identify its immutable source and private copy",
        ),
        "add differently named policy step": (
            replace_once(
                workflow,
                policy_step,
                policy_step
                + "\n"
                + policy_step.replace(
                    "- name: Plan JSON policy gate",
                    "- name: Run plan policy again",
                    1,
                ),
            ),
            "exact-source plan policy may execute only in its named guarded step",
        ),
        "run consumer policy copy": (
            replace_once(
                workflow,
                'POLICY_SCRIPT="$policy_dir/tofu-plan-policy.py"',
                'POLICY_SCRIPT="$GITHUB_WORKSPACE/scripts/tofu-plan-policy.py"',
            ),
            "late policy-source verification: missing 'POLICY_SCRIPT=",
        ),
        "replace late byte check with index-visible status": (
            replace_once(
                workflow,
                'actual_blob="$(git -C "$WORKFLOW_SOURCE" hash-object --no-filters -- "$policy_file")"',
                'actual_blob="$(git -C "$WORKFLOW_SOURCE" status --porcelain=v1 -- "$policy_path")"',
            ),
            "late policy-source verification: missing 'hash-object --no-filters -- \"$policy_file\"'",
        ),
        "materialize policy from head": (
            replace_once(
                workflow,
                'cat-file blob "${EXPECTED_WORKFLOW_SHA}:${policy_script_path}"',
                'cat-file blob "HEAD:${policy_script_path}"',
            ),
            "late policy-source verification: missing 'cat-file blob \"${EXPECTED_WORKFLOW_SHA}:${policy_script_path}\"'",
        ),
        "materialize helper from head": (
            replace_once(
                workflow,
                'cat-file blob "${EXPECTED_WORKFLOW_SHA}:${policy_runner_path}"',
                'cat-file blob "HEAD:${policy_runner_path}"',
            ),
            "late policy-source verification: missing 'cat-file blob \"${EXPECTED_WORKFLOW_SHA}:${policy_runner_path}\"'",
        ),
        "materialize policy from worktree": (
            replace_once(
                workflow,
                'git -C "$WORKFLOW_SOURCE" cat-file blob "${EXPECTED_WORKFLOW_SHA}:${policy_script_path}" > "$POLICY_SCRIPT"',
                'cp "$WORKFLOW_SOURCE/$policy_script_path" "$POLICY_SCRIPT"',
            ),
            "late policy-source verification: missing 'cat-file blob \"${EXPECTED_WORKFLOW_SHA}:${policy_script_path}\"'",
        ),
        "materialize helper from worktree": (
            replace_once(
                workflow,
                'git -C "$WORKFLOW_SOURCE" cat-file blob "${EXPECTED_WORKFLOW_SHA}:${policy_runner_path}" > "$POLICY_RUNNER"',
                'cp "$WORKFLOW_SOURCE/$policy_runner_path" "$POLICY_RUNNER"',
            ),
            "late policy-source verification: missing 'cat-file blob \"${EXPECTED_WORKFLOW_SHA}:${policy_runner_path}\"'",
        ),
        "download policy again": (
            replace_once(
                workflow,
                'POLICY_SCRIPT="$policy_dir/tofu-plan-policy.py"',
                'POLICY_SCRIPT="/tmp/tofu-plan-policy.py" # raw.githubusercontent.com',
            ),
            "mutable/downloaded source remains",
        ),
    }

    for name, (mutated, expected_error) in mutations.items():
        expect_rejected(name, mutated, workflow, expected_error)


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return result.stdout.strip()


def initialize_source_checkout(path: Path) -> str:
    path.mkdir()
    git(path, "init", "--quiet")
    git(path, "config", "user.name", "Source identity test")
    git(path, "config", "user.email", "source-identity@example.invalid")
    git(
        path,
        "remote",
        "add",
        "origin",
        "https://github.com/metacraft-labs/devops-modules.git",
    )
    scripts = path / "scripts"
    scripts.mkdir()
    for source in (
        REPO_ROOT / "scripts/tofu-plan-policy.py",
        REPO_ROOT / "scripts/tofu-plan-policy-ci",
    ):
        destination = scripts / source.name
        shutil.copyfile(source, destination)
        destination.chmod(0o644)
    shutil.copytree(
        REPO_ROOT / ".github/setup-nix",
        path / ".github/setup-nix",
        copy_function=shutil.copyfile,
    )
    git(path, "add", "scripts", ".github/setup-nix")
    git(path, "commit", "--quiet", "-m", "fixture")
    return git(path, "rev-parse", "HEAD")


def run_shell(script: str, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "-euo", "pipefail", "-c", script],
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def test_verification_behavior(workflow: str) -> None:
    initial_script = run_script(
        named_step(extract_job(workflow, "offline-checks"), "Verify called workflow source")
    )
    late_script = run_script(
        named_step(extract_job(workflow, "credentialed-plan"), "Plan JSON policy gate")
    )

    with tempfile.TemporaryDirectory() as temp:
        temp_path = Path(temp)
        source = temp_path / SOURCE_PATH
        source.parent.mkdir()
        sha = initialize_source_checkout(source)
        env = os.environ.copy()
        env.update(
            {
                "EXPECTED_WORKFLOW_REPOSITORY": "metacraft-labs/devops-modules",
                "EXPECTED_WORKFLOW_SHA": sha,
                "EXPECTED_WORKFLOW_SERVER_URL": "https://github.com",
                "WORKFLOW_SOURCE": str(source),
            }
        )

        success = run_shell(initial_script, env)
        assert success.returncode == 0, success.stderr

        git(
            source,
            "remote",
            "set-url",
            "origin",
            "https://github.enterprise.example/metacraft-labs/devops-modules.git",
        )
        enterprise_env = env | {
            "EXPECTED_WORKFLOW_SERVER_URL": "https://github.enterprise.example"
        }
        enterprise_success = run_shell(initial_script, enterprise_env)
        assert enterprise_success.returncode == 0, enterprise_success.stderr
        git(
            source,
            "remote",
            "set-url",
            "origin",
            "https://github.com/metacraft-labs/devops-modules.git",
        )

        bad_sha_env = env | {"EXPECTED_WORKFLOW_SHA": "main"}
        assert run_shell(initial_script, bad_sha_env).returncode != 0
        wrong_sha_env = env | {"EXPECTED_WORKFLOW_SHA": "0" * 40}
        assert run_shell(initial_script, wrong_sha_env).returncode != 0
        wrong_repo_env = env | {"EXPECTED_WORKFLOW_REPOSITORY": "caller/repository"}
        assert run_shell(initial_script, wrong_repo_env).returncode != 0

        tracked = source / "scripts/tofu-plan-policy.py"
        original_policy = tracked.read_text()
        tracked.write_text(original_policy + "\n# hostile tracked mutation\n")
        assert run_shell(initial_script, env).returncode != 0
        tracked.write_text(original_policy)

        untracked = source / "hostile-untracked"
        untracked.write_text("consumer mutation\n")
        assert run_shell(initial_script, env).returncode != 0
        untracked.unlink()

        setup_action = source / ".github/setup-nix/action.yml"
        original_setup_action = setup_action.read_text()
        setup_action.write_text(original_setup_action + "\n# hidden hostile mutation\n")
        git(source, "update-index", "--assume-unchanged", ".github/setup-nix/action.yml")
        assert git(source, "status", "--porcelain=v1", "--", ".github/setup-nix/action.yml") == ""
        assert run_shell(initial_script, env).returncode != 0, (
            "initial verification accepted an index-hidden Setup Nix mutation"
        )
        git(source, "update-index", "--no-assume-unchanged", ".github/setup-nix/action.yml")
        setup_action.write_text(original_setup_action)

        plan_path = temp_path / "plan.json"
        plan_path.write_text('{"resource_changes": []}\n')
        bin_path = temp_path / "bin"
        bin_path.mkdir()
        bash = shutil.which("bash")
        assert bash is not None, "bash is required for workflow shell tests"
        nix_mock = bin_path / "nix"
        nix_mock.write_text(
            f"#!{bash}\n"
            "set -euo pipefail\n"
            "while [ \"$#\" -gt 0 ]; do\n"
            "  if [ \"$1\" = --command ]; then shift; exec \"$@\"; fi\n"
            "  shift\n"
            "done\n"
            "exit 64\n"
        )
        nix_mock.chmod(0o755)
        gh_mock = bin_path / "gh"
        gh_mock.write_text(f"#!{bash}\nexit 0\n")
        gh_mock.chmod(0o755)

        executable_late_script = late_script.replace(
            "${{ steps.plan.outputs.json_plan_path }}", str(plan_path)
        ).replace("${{ github.event.pull_request.number }}", "1")
        late_env = env | {
            "GITHUB_WORKSPACE": str(temp_path),
            "GH_TOKEN": "test-token",
            "PATH": str(bin_path) + os.pathsep + env["PATH"],
            "RUNNER_TEMP": str(temp_path),
        }
        late_success = run_shell(executable_late_script, late_env)
        assert late_success.returncode == 0, (
            f"late verification failed\nstdout:\n{late_success.stdout}"
            f"\nstderr:\n{late_success.stderr}"
        )

        tracked.write_text(original_policy + "\n# hostile late mutation\n")
        late_failure = run_shell(executable_late_script, late_env)
        assert late_failure.returncode != 0, (
            "late verification accepted a consumer-modified policy file"
        )
        tracked.write_text(original_policy)

        tracked.write_text(original_policy + "\n# index-hidden hostile mutation\n")
        git(source, "update-index", "--assume-unchanged", "scripts/tofu-plan-policy.py")
        assert git(source, "status", "--porcelain=v1", "--", "scripts/tofu-plan-policy.py") == ""
        hidden_failure = run_shell(executable_late_script, late_env)
        assert hidden_failure.returncode != 0, (
            "late verification accepted an index-hidden policy mutation"
        )
        git(source, "update-index", "--no-assume-unchanged", "scripts/tofu-plan-policy.py")
        tracked.write_text(original_policy)

        runner = source / "scripts/tofu-plan-policy-ci"
        original_runner = runner.read_text()
        runner.write_text(original_runner + "\n# hostile helper mutation\n")
        helper_failure = run_shell(executable_late_script, late_env)
        assert helper_failure.returncode != 0, (
            "late verification accepted a consumer-modified policy helper"
        )
        runner.write_text(original_runner)

        git(source, "update-index", "--skip-worktree", "scripts/tofu-plan-policy-ci")
        runner.write_text(original_runner + "\n# skip-worktree-hidden mutation\n")
        assert git(source, "status", "--porcelain=v1", "--", "scripts/tofu-plan-policy-ci") == ""
        skip_worktree_failure = run_shell(executable_late_script, late_env)
        assert skip_worktree_failure.returncode != 0, (
            "late verification accepted a skip-worktree-hidden policy mutation"
        )
        git(source, "update-index", "--no-skip-worktree", "scripts/tofu-plan-policy-ci")
        runner.write_text(original_runner)

        restored_success = run_shell(executable_late_script, late_env)
        assert restored_success.returncode == 0, (
            f"restored exact policy bytes failed\nstdout:\n{restored_success.stdout}"
            f"\nstderr:\n{restored_success.stderr}"
        )

        runner.write_text(original_runner + "\n# bytes from an unrelated valid ref\n")
        git(source, "add", "scripts/tofu-plan-policy-ci")
        git(source, "commit", "--quiet", "-m", "unrelated source ref")
        unrelated_sha = git(source, "rev-parse", "HEAD")
        assert unrelated_sha != sha
        assert run_shell(initial_script, env).returncode != 0, (
            "initial verification accepted a checkout at an unrelated valid ref"
        )
        assert run_shell(executable_late_script, late_env).returncode != 0, (
            "late verification accepted policy-helper bytes from an unrelated valid ref"
        )
        git(source, "reset", "--hard", sha)


def main() -> None:
    workflow = WORKFLOW_PATH.read_text()
    validate(workflow)
    test_negative_mutations(workflow)
    test_verification_behavior(workflow)
    print("reusable Terraform called-workflow source identity contract: PASS")


if __name__ == "__main__":
    main()
