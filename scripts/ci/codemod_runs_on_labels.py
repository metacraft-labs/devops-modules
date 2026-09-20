#!/usr/bin/env python3
"""RC4 codemod — rewrite legacy single-name ``eph-*`` runner classes in a
consumer repo's workflows to their RC1 capability label set.

Campaign: Runner-Fleet-Capability-Pools-And-Remote-Driving, milestone RC4
(gate ``t_ci_runs_on_capability``).

This is the mechanical half of the consumer migration: it turns every retired
``eph-<os>-<arch>`` class token into the minimum capability label set from the
RC1 migration table (``ci-workflow-standards.md``). It is line-oriented and
conservative so it preserves the rest of the file verbatim:

  * a ``runs-on:`` scalar (``runs-on: eph-linux-x64`` or ``runs-on: "eph-linux-x64"``)
    becomes a YAML flow sequence ``runs-on: [self-hosted, linux, x64]``.
  * a quoted class token inside a JSON string (matrix defaults such as
    ``"eph-linux-x64"``) becomes the JSON array ``["self-hosted","linux","x64"]``.
  * a bare YAML list item ``- eph-linux-x64`` becomes ``- [self-hosted, linux, x64]``.

DRY-RUN by default (prints a unified-style diff of what it WOULD change); pass
``--write`` to apply. After running it, ``check_over_constrained_runs_on.py``
should pass — the codemod only removes over-constraint it can prove (a retired
class → its documented minimum set); it never ADDS a narrowing capability, so a
job that truly needs ``gpu``/``x86-64-v3`` still needs a hand-added label plus a
``# cap-justify:`` line.

No mock objects: pure text rewriting over real workflow files.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Iterable

# RC1 migration table — retired class -> minimum capability label set.
#
# Each right-hand side is the set the central controller's pool ACTUALLY
# advertises for that class today (high-mem-server ``central-garm.nix``,
# ``capabilityPoolsFor`` / ``osPoolsFor`` + their ``aliasClasses``). The codemod
# may only emit labels a live pool advertises — emitting a label no pool carries
# turns a job into one that matches NO runner and queues until GitHub culls it
# (the m3 linux/windows-arm64 regression). So the RHS is deliberately the
# MINIMUM proven-routable set, never a "descriptive" superset.
#
# WHY ``eph-linux-x64-nested`` DOES NOT EMIT ``nested`` (was the RC4-audit bug):
# central's ``${org}-linux`` pool advertises ``[self-hosted, linux, x64]`` and
# lists BOTH ``eph-linux-x64`` and ``eph-linux-x64-nested`` as ``aliasClasses``
# of that same pool — i.e. the controller treats the two classes as equivalent
# and routes them to one pool that does NOT advertise a ``nested`` tag. Rewriting
# to ``[self-hosted, linux, x64, nested]`` would over-constrain the job to an
# empty runner set. The safe, alias-guaranteed migration is the plain triple.
MIGRATION = {
    "eph-linux-x64": ["self-hosted", "linux", "x64"],
    "eph-linux-x64-nested": ["self-hosted", "linux", "x64"],
    "eph-linux-arm64": ["self-hosted", "linux", "arm64"],
    "eph-macos-arm64": ["self-hosted", "macos", "arm64"],
    "eph-win-x64": ["self-hosted", "windows", "x64"],
    "eph-win-arm64": ["self-hosted", "windows", "arm64"],
}

# GPU-host routing aliases we deliberately DO NOT rewrite — this is an operator
# decision (campaign task #50), NOT a mechanical migration:
#
#   * ``eph-linux-x64-g1`` / ``-g2`` are the *general-purpose* scale sets that
#     happen to live ON the GPU hosts (gpu-server-001/002). Rewriting them to a
#     plain ``[self-hosted, linux, x64]`` would let those jobs land on ANY linux
#     host and silently vacate the GPU boxes' reserved general-purpose capacity.
#   * ``eph-linux-x64-gpu`` / ``-gpu-2`` route to the GPU pool. Whether migrated
#     jobs should carry a ``gpu`` capability label (and thus stay pinned to the
#     2-slot GPU fleet) or be re-homed is exactly the #50 decision.
#
# Until #50 is decided, the codemod leaves every one of these tokens VERBATIM and
# WARNS when it sees one, so the choice is made deliberately by a human, not by a
# silent rewrite. (The word-boundary regex below already refuses to match the
# ``eph-linux-x64`` PREFIX inside these longer tokens, so "leave verbatim" needs
# no special case in the rewriter — only this explicit, warned exclusion.)
NEEDS_DECISION = {
    "eph-linux-x64-gpu",
    "eph-linux-x64-gpu-2",
    "eph-linux-x64-g1",
    "eph-linux-x64-g2",
}
NEEDS_DECISION_RE = re.compile(
    r"(?<![A-Za-z0-9-])(" + "|".join(map(re.escape, sorted(NEEDS_DECISION, key=len, reverse=True))) + r")(?![A-Za-z0-9-])"
)

# Longest class names first so ``eph-linux-x64-nested`` wins over ``eph-linux-x64``.
CLASSES = sorted(MIGRATION, key=len, reverse=True)
CLASS_RE = re.compile(r"(?<![A-Za-z0-9-])(" + "|".join(map(re.escape, CLASSES)) + r")(?![A-Za-z0-9-])")


def _flow(labels: list[str]) -> str:
    return "[" + ", ".join(labels) + "]"


def _json_arr(labels: list[str]) -> str:
    return "[" + ", ".join(f'"{l}"' for l in labels) + "]"


def rewrite_line(line: str) -> str:
    """Rewrite any legacy class token on one line to its label set."""

    def repl(m: re.Match) -> str:
        cls = m.group(1)
        labels = MIGRATION[cls]
        start = m.start()
        before = line[:start]
        # Inside a JSON/quoted context? Replace the *quoted* token with a JSON
        # array (strip the surrounding quotes the match does not include).
        # Detect a quote immediately before the token.
        if before.rstrip().endswith(('"', "'")):
            return _json_arr(labels)  # caller strips the trailing quote below
        return _flow(labels)

    # Handle the quoted-JSON form first: "eph-..." -> ["self-hosted",...]
    def quoted_repl(m: re.Match) -> str:
        cls = m.group(2)
        return _json_arr(MIGRATION[cls])

    quoted = re.compile(r"([\"'])(" + "|".join(map(re.escape, CLASSES)) + r")\1")
    new = quoted.sub(quoted_repl, line)
    # Then any remaining bare tokens (runs-on scalar / list item).
    new = CLASS_RE.sub(lambda m: _flow(MIGRATION[m.group(1)]), new)
    return new


def rewrite_text(text: str) -> tuple[str, list[tuple[int, str, str]]]:
    out_lines: list[str] = []
    changes: list[tuple[int, str, str]] = []
    for i, line in enumerate(text.splitlines(keepends=True), 1):
        stripped = line.rstrip("\n")
        if CLASS_RE.search(stripped):
            new = rewrite_line(stripped)
            if new != stripped:
                changes.append((i, stripped, new))
                nl = "\n" if line.endswith("\n") else ""
                out_lines.append(new + nl)
                continue
        out_lines.append(line)
    return "".join(out_lines), changes


def scan_needs_decision(text: str) -> list[tuple[int, str, str]]:
    """Find every GPU-host routing alias (task #50) the codemod refuses to touch.

    Returns ``(lineno, token, line)`` for each occurrence so ``main`` can warn.
    These are left VERBATIM — mapping them mechanically is an operator decision.
    """
    hits: list[tuple[int, str, str]] = []
    for i, line in enumerate(text.splitlines(), 1):
        for m in NEEDS_DECISION_RE.finditer(line):
            hits.append((i, m.group(1), line.strip()))
    return hits


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
    parser.add_argument("paths", nargs="*", default=[".github/workflows"])
    parser.add_argument("--write", action="store_true", help="apply changes in place (default: dry-run)")
    args = parser.parse_args(argv)

    workflows = iter_workflows([Path(p) for p in args.paths])
    total = 0
    flagged = 0
    for wf in workflows:
        text = wf.read_text(encoding="utf-8")
        new, changes = rewrite_text(text)
        needs = scan_needs_decision(text)
        if changes:
            total += len(changes)
            print(f"\n{wf}:")
            for lineno, old, rewritten in changes:
                print(f"  - {lineno}: {old.strip()}")
                print(f"  + {lineno}: {rewritten.strip()}")
            if args.write:
                wf.write_text(new, encoding="utf-8")
        if needs:
            flagged += len(needs)
            print(f"\n{wf}: [needs-decision — left UNCHANGED, task #50]")
            for lineno, token, line in needs:
                print(f"  ! {lineno}: {token}  ({line})")

    if flagged:
        print(
            f"\ncodemod-runs-on-labels: left {flagged} GPU-host routing alias "
            "reference(s) UNCHANGED (eph-linux-x64-g1/-g2/-gpu*). Mapping these "
            "is an operator decision (task #50) — the codemod will not rewrite "
            "them.",
            file=sys.stderr,
        )

    if total == 0:
        if flagged == 0:
            print("codemod-runs-on-labels: no legacy eph-* classes found.")
        return 0
    verb = "rewrote" if args.write else "would rewrite"
    print(f"\ncodemod-runs-on-labels: {verb} {total} legacy class reference(s).", file=sys.stderr)
    if not args.write:
        print("Re-run with --write to apply.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
