#!/usr/bin/env python3
"""RD2 guard — fail public-repo workflows that name a billed GitHub-hosted runner.

Campaign: Runner-Fleet-Capability-Pools-And-Remote-Driving, milestone RD2
(gate ``t_public_repo_free_ci``).

Why this exists
---------------
On a PUBLIC repository, GitHub's *standard* hosted runners (ubuntu-latest,
windows-latest, macos-latest and their pinned-version spellings) are free with
no minute quota, and self-hosted runners are free too. The ONE way a public
repo can still incur charges is a job that targets a **larger or GPU**
GitHub-hosted runner — those bill from the first minute even on public repos
(see research-github-free-ci-hybrid.md §1). With the org Actions budget pinned
to $0 (RD1), such a job does not silently bill — it is *blocked* — so it is both
a cost risk and a correctness risk. This checker fails CI before either happens.

What it does
------------
Parse every workflow, resolve each job's ``runs-on`` (including the common
``${{ matrix.<key> }}`` indirection against ``strategy.matrix``), and classify
each concrete label:

- self-hosted (``self-hosted`` in the set, or a known self-hosted class such as
    ``eph-*``): always OK (free).
- standard GitHub-hosted (ubuntu/windows/macos latest + pinned versions):
    OK (free on public repos).
- larger / GPU GitHub-hosted (``*-gpu*``, ``*-<n>-core(s)``, ``*-large``,
    ``ubuntu-latest-<n>`` size spellings, an explicit extra-denylist):
    FAIL on a public repo.
- an unrecognised bare label: OK, but reported as a warning (it is most likely a
    custom self-hosted label; the guard never fails CI on a label it cannot
    prove is a billed hosted runner).

Dynamic ``runs-on`` — ``${{ fromJson(needs.choose.outputs.runs_on) }}`` (the
RD3 preflight) or any other non-matrix expression — is treated as trusted and
skipped: the RD3 chooser only ever emits ``ubuntu-latest`` or self-hosted
labels, and a static checker cannot evaluate it.

Visibility
----------
The guard only *fails* for a public repository. ``--visibility`` may be given
explicitly; otherwise it is read from ``$GH_REPO_VISIBILITY`` (the reusable
workflow wires ``github.event.repository.private`` into it), defaulting to
``public`` — the safe default, so a mis-wired call fails closed rather than
letting a billed runner through.

No mock objects: this is a pure text/AST checker over real workflow files.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path
from typing import Iterable

import yaml

# Standard GitHub-hosted runner images that are FREE on public repos and consume
# the included-minutes allowance (not a per-minute bill) on private ones.
STANDARD_HOSTED = re.compile(
    r"""^(
        ubuntu (-latest | -\d{2}\.\d{2} | -\d{2}\.\d{2}-arm)
        | windows (-latest | -\d{4} | -\d{4}-arm)
        | macos (-latest | -\d{1,2} | -latest-xlarge? )?
        | macos-\d{1,2} (-large | -xlarge )?
    )$""",
    # NB: macOS "-large"/"-xlarge" is caught as BILLED below (ordered first).
    re.VERBOSE,
)

# macOS "-large"/"-xlarge" and any explicit size/GPU spelling are BILLED even on
# public repos. Ordered checks below make these win over STANDARD_HOSTED.
BILLED_HOSTED = re.compile(
    r"""(
        gpu
        | -\d+-?cores?\b
        | -large\b | -xlarge\b
        | ubuntu-latest-\d
        | windows-latest-\d
        | macos-\d+-(large|xlarge)
        | -megacpu\b
    )""",
    re.VERBOSE | re.IGNORECASE,
)

# Known self-hosted classes in this org (the existing single-name scheme this
# campaign migrates off of). ``self-hosted`` in the label set also qualifies.
SELF_HOSTED_LABEL = re.compile(r"^(self-hosted|eph-.*|garm|nix.*|linux|x64|arm64|windows|macos|gpu-\d+)$")


def _is_self_hosted(labels: list[str]) -> bool:
    if any(label == "self-hosted" for label in labels):
        return True
    # A single-name self-hosted class (e.g. ``eph-linux-x64``) with no hosted
    # image spelling present.
    if len(labels) == 1 and SELF_HOSTED_LABEL.match(labels[0]) and not STANDARD_HOSTED.match(labels[0]):
        return True
    return False


def _classify_label(label: str, extra_billed: set[str]) -> str:
    """Return 'standard', 'billed', or 'unknown' for a single hosted-style label."""
    if label in extra_billed or BILLED_HOSTED.search(label):
        return "billed"
    if STANDARD_HOSTED.match(label):
        return "standard"
    return "unknown"


def _as_list(value) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [str(v) for v in value]
    return [str(value)]


EXPR = re.compile(r"\$\{\{\s*(.+?)\s*\}\}")
MATRIX_REF = re.compile(r"^\$\{\{\s*matrix\.([A-Za-z0-9_-]+)\s*\}\}$")


def _matrix_values(job: dict, key: str) -> list[str]:
    """Collect every concrete value a matrix key can take (top-level + include)."""
    matrix = (job.get("strategy") or {}).get("matrix") or {}
    values: list[str] = []
    if not isinstance(matrix, dict):
        # `matrix: ${{ fromJson(...) }}` — computed at run time; nothing to expand.
        return values
    if key in matrix and isinstance(matrix[key], list):
        for v in matrix[key]:
            if isinstance(v, str):
                values.append(v)
    for inc in matrix.get("include", []) or []:
        if isinstance(inc, dict) and isinstance(inc.get(key), str):
            values.append(inc[key])
    return values


def _resolve_runs_on(job: dict) -> tuple[list[list[str]], list[str]]:
    """Resolve a job's ``runs-on`` to concrete label-sets.

    Returns (concrete_label_sets, dynamic_notes). ``concrete_label_sets`` is a
    list of label lists (one per resolved runner); ``dynamic_notes`` records any
    expression that was skipped as trusted/dynamic.
    """
    runs_on = job.get("runs-on")
    if runs_on is None:
        return [], []

    concrete: list[list[str]] = []
    dynamic: list[str] = []

    # ``runs-on`` may be a scalar, a flow/block list, or a group mapping.
    if isinstance(runs_on, dict):  # { group: ..., labels: [...] }
        labels = _as_list(runs_on.get("labels"))
        if labels:
            concrete.append(labels)
        return concrete, dynamic

    labels = _as_list(runs_on)

    # A single expression element that is exactly a matrix reference expands.
    if len(labels) == 1 and MATRIX_REF.match(labels[0]):
        key = MATRIX_REF.match(labels[0]).group(1)
        expanded = _matrix_values(job, key)
        if expanded:
            for value in expanded:
                # A matrix value may itself be a flow list string like "[a, b]".
                concrete.append(_split_maybe_list(value))
            return concrete, dynamic
        dynamic.append(labels[0])
        return concrete, dynamic

    # Any other expression (fromJson(...), needs.*, vars.*) is trusted/dynamic.
    if any(EXPR.search(label) for label in labels):
        dynamic.extend(label for label in labels if EXPR.search(label))
        static = [label for label in labels if not EXPR.search(label)]
        if static:
            concrete.append(static)
        return concrete, dynamic

    concrete.append(labels)
    return concrete, dynamic


def _split_maybe_list(value: str) -> list[str]:
    value = value.strip()
    if value.startswith("[") and value.endswith("]"):
        inner = value[1:-1]
        return [part.strip().strip("'\"") for part in inner.split(",") if part.strip()]
    return [value]


def check_workflow(path: Path, is_public: bool, extra_billed: set[str]) -> tuple[list[str], list[str]]:
    """Return (violations, warnings) for one workflow file."""
    violations: list[str] = []
    warnings: list[str] = []
    try:
        doc = yaml.safe_load(path.read_text(encoding="utf-8"))
    except yaml.YAMLError as exc:  # pragma: no cover - surfaced as a hard error
        return [f"{path}: not parseable as YAML: {exc}"], warnings
    if not isinstance(doc, dict):
        return violations, warnings

    jobs = doc.get("jobs") or {}
    if not isinstance(jobs, dict):
        return violations, warnings

    for job_name, job in jobs.items():
        if not isinstance(job, dict):
            continue
        label_sets, _dynamic = _resolve_runs_on(job)
        for labels in label_sets:
            if _is_self_hosted(labels):
                continue
            for label in labels:
                if label == "self-hosted":
                    continue
                kind = _classify_label(label, extra_billed)
                if kind == "billed":
                    where = f"{path.name} :: job '{job_name}' :: runs-on '{label}'"
                    if is_public:
                        violations.append(
                            f"{where} — larger/GPU GitHub-hosted runners BILL even on public "
                            f"repos (blocked under the $0 budget). Use ubuntu-latest or a "
                            f"self-hosted class."
                        )
                    else:
                        warnings.append(
                            f"{where} — billed hosted runner on a private repo (consumes/blocks "
                            f"paid minutes; prefer self-hosted)."
                        )
                elif kind == "unknown":
                    warnings.append(
                        f"{path.name} :: job '{job_name}' :: runs-on '{label}' — unrecognised "
                        f"label (assumed self-hosted; not failed)."
                    )
    return violations, warnings


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
        "--visibility",
        choices=["public", "private"],
        default=os.environ.get("GH_REPO_VISIBILITY", "public"),
        help="repo visibility; the guard only FAILS for a public repo (default: public / fail-closed)",
    )
    parser.add_argument(
        "--billed-label",
        action="append",
        default=[],
        help="extra runner label to treat as billed (repeatable)",
    )
    args = parser.parse_args(argv)

    is_public = args.visibility == "public"
    extra_billed = set(args.billed_label)
    workflows = iter_workflows([Path(p) for p in args.paths])
    if not workflows:
        print("check-public-repo-runners: no workflow files found", file=sys.stderr)
        return 0

    all_violations: list[str] = []
    all_warnings: list[str] = []
    for wf in workflows:
        v, w = check_workflow(wf, is_public, extra_billed)
        all_violations.extend(v)
        all_warnings.extend(w)

    for warning in all_warnings:
        print(f"[warn] {warning}", file=sys.stderr)

    if all_violations:
        print(
            f"\ncheck-public-repo-runners: {len(all_violations)} billed-runner "
            f"violation(s) on a PUBLIC repo:\n",
            file=sys.stderr,
        )
        for violation in all_violations:
            print(f"  ✗ {violation}", file=sys.stderr)
        return 1

    scope = "public" if is_public else "private"
    print(
        f"check-public-repo-runners: OK — {len(workflows)} workflow(s) scanned "
        f"({scope} repo), no billed GitHub-hosted runner used."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
