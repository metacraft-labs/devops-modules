#!/usr/bin/env python3
"""RC4 lint — flag OVER-CONSTRAINED ``runs-on`` in consumer workflows.

Campaign: Runner-Fleet-Capability-Pools-And-Remote-Driving, milestone RC4
(gate ``t_ci_runs_on_capability``).

Why this exists
---------------
Under the capability-label taxonomy (RC1,
``metacraft-dev-guidelines/policies/ci-workflow-standards.md``) a CI job requests
the **minimum capabilities it needs** as a label set, and ANY runner advertising
a superset serves it::

    runs-on: [self-hosted, linux, x64]            # generic Linux — any host

A job that names a class NARROWER than its real need — a bare single-name
``eph-<os>-<arch>`` class (pinned to one machine), or a capability it does not
actually use (``gpu``, ``x86-64-v3``, ``nested``, a specific hypervisor, …) —
is the exact **starvation-amplifier** the taxonomy calls out: it can only be
served by a strict subset of the fleet, so it queues behind that subset even
when the rest of the fleet is idle. This linter flags those.

What it flags
-------------
For every job's resolved ``runs-on`` label set (matrix ``${{ matrix.<key> }}``
indirection is expanded against ``strategy.matrix``, exactly as the RD2 guard
does):

1. **Bare ephemeral class name** — a single-element ``runs-on`` whose only label
   is a legacy ``eph-*`` class. It must be expressed as a capability label set
   (the migration table in the policy maps each class to its minimum set).

2. **Unjustified narrowing capability** — a label set that requests a
   manifest-derived NARROWING capability (``gpu``, ``nested``, ``docker``,
   ``podman``, ``rr-hw-counters``, ``x86-64-v2/v3/v4``, or a specific hypervisor
   ``incus``/``libvirt``/``hyperv``/``tart``) WITHOUT a documented justification.

The base labels (``self-hosted``, an OS, a CPU arch, and the policy/attested
labels ``ephemeral``/``dev-env-ready``/``org:*``/``benchmark``/…) are never
flagged — they do not narrow routing to specific hardware.

Justifying a genuine need
-------------------------
A job that GENUINELY needs a narrowing capability declares it — file-scoped,
mirroring the ``ci-mainline-exempt`` precedent in the same policy — with a
comment naming the label::

    # cap-justify: gpu (Vulkan visual-replay tests need a real GPU)
    # cap-justify: x86-64-v3 (AVX2 codepath under test)

or, equivalently, the inline form shown in the policy's justification rule::

    # `bare-metal`: nixosTest VMs need /dev/kvm; ephemeral runners have no KVM.

Each ``cap-justify`` line whitelists ONE narrowing label for the whole file.
A narrowing label with a matching justification passes; one without fails.

Dynamic ``runs-on`` — ``${{ fromJson(needs.choose.outputs.runs_on) }}`` (the RD3
preflight) or any other non-matrix expression — is trusted and skipped: the
reusable workflows parameterise ``runs-on`` via inputs, so their concrete label
set is the CONSUMER's choice and is linted in the consumer repo.

No mock objects: this is a pure text/AST checker over real workflow files. It
reuses the ``runs-on`` resolution from the sibling RD2 guard
(``check_public_repo_runners.py``) so the two linters can never disagree on how
a ``runs-on`` resolves.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Iterable

import yaml

# Reuse the RD2 guard's ``runs-on`` resolution so the two linters share ONE
# definition of how a job's ``runs-on`` (incl. ``${{ matrix.* }}``) resolves.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_public_repo_runners import _resolve_runs_on  # noqa: E402

# Manifest-derived NARROWING capability labels (RC1 taxonomy). Requesting any of
# these pins a job to a strict subset of the fleet, so each needs justification.
# The x86-64-v1 baseline is intentionally absent — every x86-64 host has it, so
# it carries no routing value and would never be a targetable label anyway.
NARROWING_LABELS = {
    "gpu",
    "nested",
    "docker",
    "podman",
    "rr-hw-counters",
    "x86-64-v2",
    "x86-64-v3",
    "x86-64-v4",
    "incus",
    "libvirt",
    "hyperv",
    "tart",
    # Persistent-class labels. None of them is advertised by the ephemeral
    # pools, so each one excludes the whole ephemeral fleet (2026-09-24 sweep:
    # agent-harbor CI pinned to [nixos, x86-64-v3, bare-metal] queued on four
    # runners while the org's ephemeral runners sat idle).
    "bare-metal",  # /dev/kvm, kernel access, perf counters, timing-sensitive work
    "nixos",  # host NixOS state only — "uses Nix" is NOT a reason
    "topology-host",
    "microvm",
}

# A legacy single-name ephemeral class (the scheme this campaign migrates OFF).
EPH_CLASS = re.compile(r"^eph-[a-z0-9-]+$")
# Named GARM scale sets that are routed BY NAME on purpose (the release lane —
# infra lib/infra-constants.nix `releaseLane`); not a legacy class.
RELEASE_LANE_NAMES = {"eph-linux-x64-release"}

# ``# cap-justify: <label> [free-text reason]`` — one narrowing label per line.
CAP_JUSTIFY = re.compile(r"#\s*cap-justify:\s*([A-Za-z0-9._:-]+)")
# The inline form the policy's "Justification rule" shows next to a runs-on:
#     # `bare-metal`: nixosTest VMs need /dev/kvm; ephemeral runners have no KVM.
INLINE_JUSTIFY = re.compile(r"#\s*`([A-Za-z0-9._:-]+)`\s*:\s*\S")

# The migration table (RC1) — bare class name -> minimum capability label set.
MIGRATION = {
    "eph-linux-x64": ["self-hosted", "linux", "x64"],
    # No central pool advertises `nested`; the alias routes to the plain
    # ${org}-linux pool, so it migrates to the standard linux label set.
    "eph-linux-x64-nested": ["self-hosted", "linux", "x64"],
    # g1/g2 GPU-host routing aliases: per operator decision 2026-09-20 these
    # jobs do NOT need GPUs → standard linux (they move off the GPU hosts).
    "eph-linux-x64-g1": ["self-hosted", "linux", "x64"],
    "eph-linux-x64-g2": ["self-hosted", "linux", "x64"],
    # Genuine GPU aliases keep the gpu capability.
    "eph-linux-x64-gpu": ["self-hosted", "linux", "x64", "gpu"],
    "eph-linux-x64-gpu-2": ["self-hosted", "linux", "x64", "gpu"],
    "eph-linux-arm64": ["self-hosted", "linux", "arm64"],
    "eph-macos-arm64": ["self-hosted", "macos", "arm64"],
    "eph-win-x64": ["self-hosted", "windows", "x64"],
    "eph-win-arm64": ["self-hosted", "windows", "arm64"],
}


def _justified_labels(text: str) -> set[str]:
    """Every narrowing label whitelisted by a ``# cap-justify:`` line (file-scoped)."""
    return {m.group(1) for m in CAP_JUSTIFY.finditer(text)} | {
        m.group(1) for m in INLINE_JUSTIFY.finditer(text)
    }


def _suggest(cls: str) -> str:
    mapped = MIGRATION.get(cls)
    if mapped:
        return json.dumps(mapped)
    return '[self-hosted, <os>, <arch>, …]'


def check_workflow(path: Path) -> tuple[list[str], list[list[str]]]:
    """Return (violations, resolved_label_sets) for one workflow file.

    ``resolved_label_sets`` is every concrete label set the file's jobs route to
    (used by ``--print-resolved`` to verify a representative matrix routes right).
    """
    violations: list[str] = []
    resolved: list[list[str]] = []
    text = path.read_text(encoding="utf-8")
    try:
        doc = yaml.safe_load(text)
    except yaml.YAMLError as exc:  # pragma: no cover
        return [f"{path}: not parseable as YAML: {exc}"], resolved
    if not isinstance(doc, dict):
        return violations, resolved

    jobs = doc.get("jobs") or {}
    if not isinstance(jobs, dict):
        return violations, resolved

    justified = _justified_labels(text)

    for job_name, job in jobs.items():
        if not isinstance(job, dict):
            continue
        label_sets, _dynamic = _resolve_runs_on(job)
        for labels in label_sets:
            resolved.append(labels)

            # 1. A bare single-name ephemeral class.
            if (
                len(labels) == 1
                and EPH_CLASS.match(labels[0])
                and labels[0] not in RELEASE_LANE_NAMES
            ):
                violations.append(
                    f"{path.name} :: job '{job_name}' :: runs-on '{labels[0]}' — "
                    f"bare ephemeral class name; express it as a capability label "
                    f"set: runs-on: {_suggest(labels[0])} (see the RC1 migration "
                    f"table in ci-workflow-standards.md)."
                )
                continue

            # 2. Unjustified narrowing capability labels.
            requested = {lbl for lbl in labels if lbl in NARROWING_LABELS}
            unjustified = sorted(requested - justified)
            if unjustified:
                violations.append(
                    f"{path.name} :: job '{job_name}' :: runs-on {labels} — "
                    f"over-constrained: narrowing capability label(s) "
                    f"{unjustified} pin the job to a subset of the fleet. Drop "
                    f"them if not truly needed, or justify each with a "
                    f"'# cap-justify: <label> (reason)' comment in this file."
                )
    return violations, resolved


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
        "--print-resolved",
        action="store_true",
        help="print each job's resolved runs-on label set(s) as JSON and exit 0 "
        "(routing inspection; does not lint)",
    )
    args = parser.parse_args(argv)

    workflows = iter_workflows([Path(p) for p in args.paths])
    if not workflows:
        print("check-over-constrained-runs-on: no workflow files found", file=sys.stderr)
        return 0

    if args.print_resolved:
        out: dict[str, list[list[str]]] = {}
        for wf in workflows:
            _v, resolved = check_workflow(wf)
            out[wf.name] = resolved
        print(json.dumps(out, indent=2, sort_keys=True))
        return 0

    all_violations: list[str] = []
    for wf in workflows:
        v, _resolved = check_workflow(wf)
        all_violations.extend(v)

    if all_violations:
        print(
            f"\ncheck-over-constrained-runs-on: {len(all_violations)} "
            f"over-constrained runs-on violation(s):\n",
            file=sys.stderr,
        )
        for violation in all_violations:
            print(f"  ✗ {violation}", file=sys.stderr)
        return 1

    print(
        f"check-over-constrained-runs-on: OK — {len(workflows)} workflow(s) "
        f"scanned, no over-constrained runs-on."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
