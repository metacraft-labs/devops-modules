#!/usr/bin/env python3
"""Contract: every reusable Terraform job sets the provider cache and download
retries before its first `tofu init`.

Without them a GitHub release-asset blip failed `tofu init` within about three
seconds ("giving up after 3 attempt(s)"), and every job downloaded its providers
from scratch. The step exports TF_PLUGIN_CACHE_DIR (under $HOME, so it persists
on persistent runners), TF_PROVIDER_DOWNLOAD_RETRY and
TF_REGISTRY_DISCOVERY_RETRY. TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE, the
one setting that would let a cached provider skip the lock-file hashes, is
refused.

Each assertion has a hostile mutation below that must make it fail.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW_PATH = REPO_ROOT / ".github/workflows/reusable-terraform-ci.yml"
STEP_NAME = "OpenTofu provider cache and download retries"
RELEVANT_JOBS = ("offline-checks", "credentialed-plan", "apply", "drift-check")
EXPORTS = (
    'echo "TF_PLUGIN_CACHE_DIR=$cache"',
    'echo "TF_PROVIDER_DOWNLOAD_RETRY=8"',
    'echo "TF_REGISTRY_DISCOVERY_RETRY=8"',
)
BREAK_LOCK = "TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE"
INIT_RE = re.compile(r"""(?:\btofu|\$\{?tofu_bin\}?"?|\brun_tofu(?:_bounded)?)\s+init\b""")


def first_init(steps: list[dict]) -> int | None:
    for index, step in enumerate(steps):
        run = step.get("run")
        if isinstance(run, str) and INIT_RE.search(run):
            return index
    return None


def validate(workflow: str) -> None:
    code = "\n".join(l for l in workflow.splitlines() if not l.lstrip().startswith("#"))
    assert BREAK_LOCK not in code, f"the workflow must not set {BREAK_LOCK}"
    jobs = yaml.safe_load(workflow)["jobs"]
    bodies = set()
    init_jobs = []
    for name, job in jobs.items():
        steps = job.get("steps") or []
        init_at = first_init(steps)
        if init_at is None:
            continue
        init_jobs.append(name)
        setup = [i for i, step in enumerate(steps) if step.get("name") == STEP_NAME]
        assert len(setup) == 1, f"job {name}: expected one {STEP_NAME!r} step, got {len(setup)}"
        assert setup[0] < init_at, (
            f"job {name}: {STEP_NAME!r} must come before the first `tofu init` "
            f"(step {steps[init_at].get('name')!r})"
        )
        run = steps[setup[0]].get("run", "")
        for export in EXPORTS:
            assert export in run, f"job {name}: the step no longer runs {export}"
        assert '${HOME:-}/.cache' in run, f"job {name}: the cache is no longer under $HOME"
        bodies.add(run)
    missing = set(RELEVANT_JOBS) - set(init_jobs)
    assert not missing, f"jobs that no longer run `tofu init` (detector drift?): {sorted(missing)}"
    assert len(bodies) == 1, "the provider-cache step differs between jobs; keep one body"


def mutate_drop_step(workflow: str, job: str) -> str:
    lines = workflow.split("\n")
    start = lines.index(f"  {job}:")
    at = next(i for i in range(start, len(lines)) if lines[i] == f"      - name: {STEP_NAME}")
    end = next(i for i in range(at + 1, len(lines)) if lines[i].startswith("      - ") or lines[i].startswith("      # "))
    return "\n".join(lines[:at] + lines[end:])


def expect_failure(label: str, workflow: str, reason: str) -> None:
    try:
        validate(workflow)
    except AssertionError as error:
        assert reason in str(error), f"control {label!r} failed for the wrong reason: {error}"
        print(f"control {label!r}: rejected, as expected")
        return
    raise AssertionError(f"control {label!r} passed; the contract cannot see what it exists to catch")


def main() -> None:
    workflow = WORKFLOW_PATH.read_text()
    validate(workflow)
    expect_failure(
        "plan job loses the step",
        mutate_drop_step(workflow, "credentialed-plan"),
        "job credentialed-plan: expected one",
    )
    expect_failure(
        "retry budget dropped",
        workflow.replace('            echo "TF_PROVIDER_DOWNLOAD_RETRY=8"\n', "", 1),
        "no longer runs echo \"TF_PROVIDER_DOWNLOAD_RETRY=8\"",
    )
    expect_failure(
        "lock-file bypass",
        workflow.replace(
            'echo "TF_REGISTRY_DISCOVERY_RETRY=8"',
            'echo "TF_REGISTRY_DISCOVERY_RETRY=8"; echo "' + BREAK_LOCK + '=1"',
            1,
        ),
        BREAK_LOCK,
    )
    # A step placed after the init: move offline-checks' init above the setup.
    jobs_text = workflow.split("\n  offline-checks:\n", 1)
    init_step = "      - name: Init (offline)\n"
    head, tail = jobs_text[1].split(init_step, 1)
    init_body, rest = tail.split("\n      - name: ", 1)
    moved = head.replace(
        f"      - name: {STEP_NAME}\n",
        init_step + init_body + "\n\n" + f"      - name: {STEP_NAME}\n",
        1,
    )
    expect_failure(
        "step after the init",
        jobs_text[0] + "\n  offline-checks:\n" + moved + "\n      - name: " + rest,
        "must come before the first `tofu init`",
    )
    print("reusable Terraform provider cache contract: PASS")


if __name__ == "__main__":
    try:
        main()
    except AssertionError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
