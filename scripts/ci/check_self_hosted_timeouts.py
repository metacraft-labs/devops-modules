#!/usr/bin/env python3
"""Lint: every self-hosted job declares ``timeout-minutes`` within a ceiling.

Why this exists
---------------
A job without ``timeout-minutes`` runs for up to GitHub's default of
**360 minutes**. On a GitHub-hosted runner that only costs minutes. On a
self-hosted runner it holds a scarce machine, and anything that waits for the
machine to drain waits with it. On 2026-11-16 one
``codetracer-trace-format`` "windows-test (eph-win-arm64)" job with no
timeout held m3's deployment cordon from 04:42Z until an operator cancelled
it at about 06:05Z. Every ``ci-darwin`` job in the org queued behind it. The
job had been running since 03:48Z, and nothing would have stopped it before
09:48Z.

What it flags
-------------
For every job whose ``runs-on`` can resolve to a self-hosted runner:

1. **Missing timeout.** The job has no job-level ``timeout-minutes``. A
   step-level timeout does not count: it bounds one step, not the job.

2. **Timeout above the ceiling.** A literal ``timeout-minutes`` larger than
   ``--max-minutes`` (default 120) needs a justification in the same file::

       # timeout-justify: <job-id> (full nixosTest matrix takes ~3 h)

A job counts as self-hosted when any resolved label set contains
``self-hosted`` or a legacy ``eph-*`` class, or when its ``runs-on`` is an
expression (``fromJSON(inputs.runner)``, ``needs.choose.outputs.runs_on``, a
``matrix`` value the linter cannot expand). Expressions are included on
purpose, because the org-wide ``CI_RUNNER_MODE`` switch resolves them to
self-hosted runners. A job that only names GitHub-hosted images
(``ubuntu-latest``, ``macos-14``, ...) is skipped. A job that calls a reusable
workflow (``uses:``) is skipped too: GitHub accepts no ``timeout-minutes`` on
it, so the called workflow's jobs carry their own.

An expression value (``timeout-minutes: ${{ inputs.timeout }}``) is accepted:
its bound is whatever the caller passes, and the caller's file is linted
separately.

The default ceiling
-------------------
120 minutes. The 240 jobs that completed on m3 from 2026-11-02 to
2026-11-16 had a median of 11 minutes, a p90 of 83 and a p95 of 119. The few
legitimate runs past 120 (agent-harbor's aarch64-darwin package build at
132-138 minutes, devops-modules' darwin flake-check batches at 127-157) are
known long builds, and each one says so with a ``timeout-justify`` comment. Pick a job's own value from its measured
durations, roughly twice its usual run, not the ceiling.

No mock objects: a pure YAML/text checker over real workflow files. It reuses
the RD2 guard's ``runs-on`` resolution (``check_public_repo_runners.py``) so
every workflow linter in this directory reads ``runs-on`` the same way.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Iterable

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_public_repo_runners import _resolve_runs_on  # noqa: E402

DEFAULT_MAX_MINUTES = 120
EPH_CLASS = re.compile(r"^eph-[a-z0-9-]+$")
EXPR = re.compile(r"\$\{\{")
TIMEOUT_JUSTIFY = re.compile(r"#\s*timeout-justify:\s*([A-Za-z0-9_.-]+)")


def _is_self_hosted(job: dict) -> bool:
    """True when the job's ``runs-on`` can resolve to a self-hosted runner."""
    if job.get("runs-on") is None:
        return False
    label_sets, dynamic = _resolve_runs_on(job)
    if dynamic:
        return True
    for labels in label_sets:
        for label in labels:
            text = str(label)
            if text.lower() == "self-hosted" or EPH_CLASS.match(text) or EXPR.search(text):
                return True
    return False


def check_workflow(path: Path, max_minutes: int) -> tuple[list[str], list[str]]:
    """Return (violations, self_hosted_job_ids) for one workflow file."""
    violations: list[str] = []
    checked: list[str] = []
    text = path.read_text(encoding="utf-8")
    try:
        doc = yaml.safe_load(text)
    except yaml.YAMLError as exc:  # pragma: no cover
        return [f"{path}: not parseable as YAML: {exc}"], checked
    if not isinstance(doc, dict):
        return violations, checked
    jobs = doc.get("jobs") or {}
    if not isinstance(jobs, dict):
        return violations, checked

    justified = {m.group(1) for m in TIMEOUT_JUSTIFY.finditer(text)}

    for job_id, job in jobs.items():
        if not isinstance(job, dict) or "uses" in job:
            continue
        if not _is_self_hosted(job):
            continue
        checked.append(str(job_id))
        timeout = job.get("timeout-minutes")
        if timeout is None:
            violations.append(
                f"{path.name} :: job '{job_id}' :: self-hosted job has no "
                f"timeout-minutes, so GitHub's 360-minute default applies and "
                f"one hung run holds the runner (and any cordon draining it) "
                f"for six hours. Add a job-level 'timeout-minutes:' at about "
                f"twice the job's usual duration, at most {max_minutes}."
            )
            continue
        if isinstance(timeout, bool):
            violations.append(
                f"{path.name} :: job '{job_id}' :: timeout-minutes must be a number."
            )
            continue
        if isinstance(timeout, (int, float)):
            if timeout <= 0:
                violations.append(
                    f"{path.name} :: job '{job_id}' :: timeout-minutes must be positive."
                )
            elif timeout > max_minutes and str(job_id) not in justified:
                violations.append(
                    f"{path.name} :: job '{job_id}' :: timeout-minutes {timeout:g} "
                    f"exceeds the {max_minutes}-minute ceiling for self-hosted "
                    f"jobs. Lower it, or justify it in this file with "
                    f"'# timeout-justify: {job_id} (reason)'."
                )
            continue
        if isinstance(timeout, str) and EXPR.search(timeout):
            continue  # the caller supplies the bound
        violations.append(
            f"{path.name} :: job '{job_id}' :: timeout-minutes {timeout!r} is "
            f"neither a number nor an expression."
        )
    return violations, checked


def iter_workflows(paths: Iterable[Path]) -> list[Path]:
    out: list[Path] = []
    for p in paths:
        if p.is_dir():
            for ext in ("*.yml", "*.yaml"):
                out.extend(sorted(p.glob(ext)))
        elif p.exists():
            out.append(p)
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "paths",
        nargs="*",
        default=[".github/workflows"],
        help="workflow files or directories (default: .github/workflows)",
    )
    parser.add_argument(
        "--max-minutes",
        type=int,
        default=DEFAULT_MAX_MINUTES,
        help=f"ceiling for a literal timeout-minutes (default {DEFAULT_MAX_MINUTES})",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="print {file: [violation, ...]} as JSON (exit status unchanged)",
    )
    args = parser.parse_args(argv)

    workflows = iter_workflows([Path(p) for p in args.paths])
    if not workflows:
        print("check-self-hosted-timeouts: no workflow files found", file=sys.stderr)
        return 0

    by_file: dict[str, list[str]] = {}
    all_violations: list[str] = []
    checked = 0
    for wf in workflows:
        v, jobs = check_workflow(wf, args.max_minutes)
        checked += len(jobs)
        if v:
            by_file[str(wf)] = v
        all_violations.extend(v)

    if args.json:
        print(json.dumps(by_file, indent=2, sort_keys=True))
    if all_violations:
        print(
            f"\ncheck-self-hosted-timeouts: {len(all_violations)} self-hosted "
            f"job timeout violation(s):\n",
            file=sys.stderr,
        )
        for violation in all_violations:
            print(f"  ✗ {violation}", file=sys.stderr)
        return 1
    print(
        f"check-self-hosted-timeouts: OK — {len(workflows)} workflow(s), "
        f"{checked} self-hosted job(s), every one bounded."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
