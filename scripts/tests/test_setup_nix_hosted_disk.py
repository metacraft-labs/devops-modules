#!/usr/bin/env python3
"""Contract tests for opt-in GitHub-hosted disk reclamation before Nix."""

from __future__ import annotations

import os
import re
import subprocess
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
ACTION_PATH = REPO_ROOT / ".github/setup-nix/action.yml"
SCRIPT_PATH = REPO_ROOT / ".github/setup-nix/reclaim-hosted-runner-disk.sh"
WORKFLOW_PATH = REPO_ROOT / ".github/workflows/reusable-terraform-ci.yml"
EXPECTED_PATHS = (
    "/usr/local/lib/android",
    "/usr/share/dotnet",
    "/opt/ghc",
    "/usr/local/.ghcup",
    "/opt/hostedtoolcache/CodeQL",
)
RELEVANT_JOBS = ("offline-checks", "credentialed-plan", "apply", "drift-check")


def extract_job(workflow: str, name: str) -> str:
    marker = f"  {name}:\n"
    assert workflow.count(marker) == 1, f"expected one Terraform job {name!r}"
    tail = workflow.split(marker, 1)[1]
    following = re.search(r"\n  [a-z0-9-]+:\n", tail)
    return marker + (tail if following is None else tail[: following.start()])


def extract_step(document: str, name: str) -> str:
    marker = f"    - name: {name}\n"
    assert document.count(marker) == 1, f"expected one action step {name!r}"
    tail = document.split(marker, 1)[1]
    following = re.search(r"\n    - name: ", tail)
    return marker + (tail if following is None else tail[: following.start()])


def assert_in_order(text: str, fragments: tuple[str, ...], context: str) -> None:
    cursor = -1
    for fragment in fragments:
        position = text.find(fragment)
        assert position != -1, f"{context}: missing {fragment!r}"
        assert position > cursor, f"{context}: {fragment!r} is out of order"
        cursor = position


def validate(action: str, script: str, workflow: str) -> None:
    action_input = """  reclaim_hosted_runner_disk:
    description: >-
      Reclaim space from a fixed allowlist of preinstalled toolchains before
      Nix setup. This opt-in is accepted only on GitHub-hosted Linux runners.
    type: boolean
    required: false
    default: false
"""
    assert action.count(action_input) == 1, (
        "setup-nix reclamation must be an explicit boolean that defaults off"
    )

    step = extract_step(action, "Reclaim GitHub-hosted runner disk for Nix")
    required_step = (
        "if: ${{ fromJSON(inputs.reclaim_hosted_runner_disk || 'false') }}",
        "SETUP_NIX_RUNNER_ENVIRONMENT: ${{ runner.environment }}",
        "SETUP_NIX_RUNNER_OS: ${{ runner.os }}",
        'run: bash "${{ github.action_path }}/reclaim-hosted-runner-disk.sh"',
    )
    for fragment in required_step:
        assert fragment in step, f"hosted reclamation action step lost {fragment!r}"
    first_action_step = action.index("    - name:", action.index("  steps:\n"))
    assert first_action_step == action.index(
        "    - name: Reclaim GitHub-hosted runner disk for Nix"
    ), "hosted disk reclamation must be the first action step, before Nix setup"
    assert action.count("reclaim-hosted-runner-disk.sh") == 1, (
        "the fixed reclamation helper must execute exactly once"
    )

    path_match = re.search(
        r"readonly reclamation_paths=\(\n(?P<body>(?:  /[^\n]+\n)+)\)", script
    )
    assert path_match is not None, "fixed reclamation path array is missing"
    paths = tuple(line.strip() for line in path_match.group("body").splitlines())
    assert paths == EXPECTED_PATHS, (
        f"reclamation paths must equal the reviewed fixed allowlist, got {paths!r}"
    )
    required_script = (
        '[[ "${GITHUB_ACTIONS:-}" != "true" ]]',
        '[[ "${SETUP_NIX_RUNNER_ENVIRONMENT:-}" != "github-hosted" ]]',
        '[[ "${SETUP_NIX_RUNNER_OS:-}" != "Linux" ]]',
        "readonly minimum_available_kib=20971520",
        'sudo -n rm -rf --one-file-system -- "$path"',
        '[[ -e "$path" || -L "$path" ]]',
        "if ((after_kib < minimum_available_kib)); then",
    )
    for fragment in required_script:
        assert fragment in script, f"reclamation helper lost {fragment!r}"
    assert_in_order(
        script,
        (
            '[[ "${GITHUB_ACTIONS:-}" != "true" ]]',
            '[[ "${SETUP_NIX_RUNNER_ENVIRONMENT:-}" != "github-hosted" ]]',
            '[[ "${SETUP_NIX_RUNNER_OS:-}" != "Linux" ]]',
            'sudo -n rm -rf --one-file-system -- "$path"',
            '[[ -e "$path" || -L "$path" ]]',
            "after_kib=\"$(available_kib)\"",
            "if ((after_kib < minimum_available_kib)); then",
        ),
        "reclamation guard/deletion/postcondition sequence",
    )
    sudo_lines = [
        line.strip() for line in script.splitlines() if line.strip().startswith("sudo ")
    ]
    assert sudo_lines == ['sudo -n rm -rf --one-file-system -- "$path"'], (
        f"reclamation helper must have one exact bounded sudo command, got {sudo_lines!r}"
    )
    assert "sudo -n rm -rf --one-file-system -- \"$path\" || true" not in script, (
        "reclamation failure must not be ignored"
    )
    workflow_input = """      reclaim_hosted_runner_disk:
        description: >-
          Reclaim a fixed allowlist of GitHub-hosted Linux image toolchains
          before Nix setup. Fails closed on every other runner class.
        type: boolean
        required: false
        default: false
"""
    assert workflow.count(workflow_input) == 1, (
        "reusable Terraform reclamation must be an explicit boolean that defaults off"
    )
    propagation = (
        "          reclaim_hosted_runner_disk: "
        "${{ inputs.reclaim_hosted_runner_disk }}\n"
    )
    assert workflow.count(propagation) == len(RELEVANT_JOBS), (
        "every Terraform job must pass the opt-in unchanged to Setup Nix"
    )
    for job_name in RELEVANT_JOBS:
        job = extract_job(workflow, job_name)
        assert job.count(propagation) == 1, (
            f"{job_name}: reclamation input must reach its exact Setup Nix call once"
        )
        assert job.index("- name: Setup Nix") < job.index("nix develop"), (
            f"{job_name}: Setup Nix reclamation must precede every Nix realization"
        )
    assert "default: '[\"self-hosted\", \"Linux\", \"x86-64-v2\"]'" in workflow, (
        "the reusable workflow's self-hosted runner default changed"
    )


def replace_once(text: str, old: str, new: str) -> str:
    assert text.count(old) >= 1, f"mutation target missing: {old!r}"
    return text.replace(old, new, 1)


def expect_rejected(
    name: str,
    action: str,
    script: str,
    workflow: str,
    expected_error: str,
) -> None:
    try:
        validate(action, script, workflow)
    except AssertionError as error:
        assert expected_error in str(error), (
            f"{name}: rejected by wrong guard; expected {expected_error!r}, "
            f"got {str(error)!r}"
        )
        return
    raise AssertionError(f"{name}: weakened reclamation contract was accepted")


def test_hostile_mutations(action: str, script: str, workflow: str) -> None:
    mutations = {
        "enable by default": (
            replace_once(
                action,
                "  reclaim_hosted_runner_disk:\n"
                "    description: >-\n"
                "      Reclaim space from a fixed allowlist of preinstalled toolchains before\n"
                "      Nix setup. This opt-in is accepted only on GitHub-hosted Linux runners.\n"
                "    type: boolean\n"
                "    required: false\n"
                "    default: false\n",
                "  reclaim_hosted_runner_disk:\n"
                "    description: >-\n"
                "      Reclaim space from a fixed allowlist of preinstalled toolchains before\n"
                "      Nix setup. This opt-in is accepted only on GitHub-hosted Linux runners.\n"
                "    type: boolean\n"
                "    required: false\n"
                "    default: true\n",
            ),
            script,
            workflow,
            "defaults off",
        ),
        "remove immutable hosted classification": (
            action,
            replace_once(
                script,
                'if [[ "${SETUP_NIX_RUNNER_ENVIRONMENT:-}" != "github-hosted" ]]; then',
                "if false; then",
            ),
            workflow,
            "lost '[[ \"${SETUP_NIX_RUNNER_ENVIRONMENT:-}\"",
        ),
        "remove Actions guard": (
            action,
            replace_once(
                script,
                'if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then',
                "if false; then",
            ),
            workflow,
            "lost '[[ \"${GITHUB_ACTIONS:-}\"",
        ),
        "remove Linux guard": (
            action,
            replace_once(
                script,
                'if [[ "${SETUP_NIX_RUNNER_OS:-}" != "Linux" ]]; then',
                "if false; then",
            ),
            workflow,
            "lost '[[ \"${SETUP_NIX_RUNNER_OS:-}\"",
        ),
        "bypass direct action opt-in": (
            replace_once(
                action,
                "if: ${{ fromJSON(inputs.reclaim_hosted_runner_disk || 'false') }}",
                "if: ${{ true }}",
            ),
            script,
            workflow,
            "lost \"if: ${{ fromJSON(inputs.reclaim_hosted_runner_disk",
        ),
        "disconnect immutable action identity": (
            replace_once(
                action,
                "SETUP_NIX_RUNNER_ENVIRONMENT: ${{ runner.environment }}",
                "SETUP_NIX_RUNNER_ENVIRONMENT: self-hosted",
            ),
            script,
            workflow,
            "lost 'SETUP_NIX_RUNNER_ENVIRONMENT",
        ),
        "move reclamation after pre-Nix diagnostic": (
            action.replace(
                extract_step(action, "Reclaim GitHub-hosted runner disk for Nix"), ""
            ).replace(
                extract_step(action, "Log GH API rate limits"),
                extract_step(action, "Log GH API rate limits")
                + extract_step(action, "Reclaim GitHub-hosted runner disk for Nix"),
                1,
            ),
            script,
            workflow,
            "must be the first action step",
        ),
        "broaden deletion to opt": (
            action,
            replace_once(script, "  /opt/ghc\n", "  /opt\n"),
            workflow,
            "fixed allowlist",
        ),
        "ignore deletion failure": (
            action,
            replace_once(
                script,
                'sudo -n rm -rf --one-file-system -- "$path"',
                'sudo -n rm -rf --one-file-system -- "$path" || true',
            ),
            workflow,
            "one exact bounded sudo command",
        ),
        "remove post-delete verification": (
            action,
            replace_once(script, '[[ -e "$path" || -L "$path" ]]', "false"),
            workflow,
            "lost '[[ -e \"$path\"",
        ),
        "remove space floor": (
            action,
            replace_once(
                script,
                "if ((after_kib < minimum_available_kib)); then",
                "if false; then",
            ),
            workflow,
            "lost 'if ((after_kib",
        ),
        "move deletion before runner guards": (
            action,
            script.replace(
                'if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then',
                'sudo -n rm -rf --one-file-system -- "$path"\n'
                'if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then',
                1,
            ).replace(
                '  sudo -n rm -rf --one-file-system -- "$path"\n', "", 1
            ),
            workflow,
            "out of order",
        ),
        "drop one Terraform job propagation": (
            action,
            script,
            replace_once(
                workflow,
                "          reclaim_hosted_runner_disk: "
                "${{ inputs.reclaim_hosted_runner_disk }}\n",
                "",
            ),
            "every Terraform job",
        ),
        "enable reusable default": (
            action,
            script,
            replace_once(
                workflow,
                "      reclaim_hosted_runner_disk:\n"
                "        description: >-\n"
                "          Reclaim a fixed allowlist of GitHub-hosted Linux image toolchains\n"
                "          before Nix setup. Fails closed on every other runner class.\n"
                "        type: boolean\n"
                "        required: false\n"
                "        default: false\n",
                "      reclaim_hosted_runner_disk:\n"
                "        description: >-\n"
                "          Reclaim a fixed allowlist of GitHub-hosted Linux image toolchains\n"
                "          before Nix setup. Fails closed on every other runner class.\n"
                "        type: boolean\n"
                "        required: false\n"
                "        default: true\n",
            ),
            "defaults off",
        ),
    }
    for name, (mutated_action, mutated_script, mutated_workflow, error) in mutations.items():
        expect_rejected(name, mutated_action, mutated_script, mutated_workflow, error)


def write_executable(path: Path, text: str) -> None:
    path.write_text(text)
    path.chmod(0o755)


def run_helper(
    script_path: Path,
    temp: Path,
    *,
    environment: str = "github-hosted",
    runner_os: str = "Linux",
    github_actions: str = "true",
    before_kib: str = "10000000",
    after_kib: str = "30000000",
    sudo_status: int = 0,
) -> subprocess.CompletedProcess[str]:
    stub_bin = temp / "bin"
    stub_bin.mkdir(exist_ok=True)
    counter = temp / "df-counter"
    sudo_log = temp / "sudo.log"
    bash = subprocess.run(
        ["bash", "-c", "command -v bash"],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    ).stdout.strip()
    write_executable(
        stub_bin / "df",
        f"#!{bash}\n"
        "set -euo pipefail\n"
        'count=0; [ ! -f "$DF_COUNTER" ] || count="$(cat "$DF_COUNTER")"\n'
        'printf \'%s\\n\' "$((count + 1))" >"$DF_COUNTER"\n'
        "printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\n'\n"
        'if [ "$count" -eq 0 ]; then value="$DF_BEFORE"; else value="$DF_AFTER"; fi\n'
        "printf '/dev/root 80000000 1 %s 1%% /\\n' \"$value\"\n",
    )
    write_executable(
        stub_bin / "sudo",
        f"#!{bash}\n"
        "set -euo pipefail\n"
        "printf '%s\\n' \"$*\" >>\"$SUDO_LOG\"\n"
        "exit \"$SUDO_STATUS\"\n",
    )
    env = os.environ.copy()
    env.update(
        {
            "PATH": str(stub_bin) + os.pathsep + env["PATH"],
            "GITHUB_ACTIONS": github_actions,
            "SETUP_NIX_RUNNER_ENVIRONMENT": environment,
            "SETUP_NIX_RUNNER_OS": runner_os,
            "DF_COUNTER": str(counter),
            "DF_BEFORE": before_kib,
            "DF_AFTER": after_kib,
            "SUDO_LOG": str(sudo_log),
            "SUDO_STATUS": str(sudo_status),
        }
    )
    return subprocess.run(
        ["bash", str(script_path)],
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def test_helper_behavior(script_path: Path) -> None:
    with tempfile.TemporaryDirectory() as raw_temp:
        temp = Path(raw_temp)
        success = run_helper(script_path, temp)
        assert success.returncode == 0, success.stdout + success.stderr
        commands = (temp / "sudo.log").read_text().splitlines()
        assert commands == [
            f"-n rm -rf --one-file-system -- {path}" for path in EXPECTED_PATHS
        ], commands
        assert "available before reclamation: 10000000 KiB" in success.stdout
        assert "available after reclamation: 30000000 KiB" in success.stdout

    for name, arguments, expected in (
        ("self-hosted", {"environment": "self-hosted"}, "refused runner.environment"),
        ("non-Linux", {"runner_os": "macOS"}, "supports only"),
        ("outside Actions", {"github_actions": "false"}, "requires GitHub Actions"),
        ("cleanup error", {"sudo_status": 73}, "Reclaiming fixed"),
        ("insufficient result", {"after_kib": "20000000"}, "at least 20971520"),
        ("invalid measurement", {"after_kib": "unknown"}, "Could not measure"),
    ):
        with tempfile.TemporaryDirectory() as raw_temp:
            failure = run_helper(script_path, Path(raw_temp), **arguments)
            assert failure.returncode != 0, f"{name}: unsafe case unexpectedly passed"
            combined = failure.stdout + failure.stderr
            assert expected in combined, f"{name}: {combined}"


def main() -> None:
    action = ACTION_PATH.read_text()
    script = SCRIPT_PATH.read_text()
    workflow = WORKFLOW_PATH.read_text()
    validate(action, script, workflow)
    test_hostile_mutations(action, script, workflow)
    test_helper_behavior(SCRIPT_PATH)
    print("setup-nix hosted disk reclamation contract: PASS")


if __name__ == "__main__":
    main()
