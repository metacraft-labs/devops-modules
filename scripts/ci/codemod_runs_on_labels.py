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
#
# GPU-host routing aliases — the operator decision (campaign task #50) landed
# 2026-09-20, so these are now mechanical migrations too:
#
#   * ``eph-linux-x64-g1`` / ``-g2`` are the *general-purpose* scale sets that
#     happen to live ON the GPU hosts (gpu-server-001/002). Their jobs do NOT
#     need a GPU, so by operator decision they migrate to the STANDARD triple
#     ``[self-hosted, linux, x64]`` and move off the GPU hosts by design — any
#     linux x64 host may serve them, which is the intended de-pinning.
#   * ``eph-linux-x64-gpu`` / ``-gpu-2`` route to the GPU pool and their jobs
#     genuinely need a GPU, so they keep the ``gpu`` capability label and stay
#     pinned to the 2-slot GPU fleet: ``[self-hosted, linux, x64, gpu]`` (this
#     is the one alias-set the codemod is permitted to emit ``gpu`` for — the
#     job was already gpu-pinned by name, so the label adds no new constraint).
MIGRATION = {
    "eph-linux-x64": ["self-hosted", "linux", "x64"],
    "eph-linux-x64-nested": ["self-hosted", "linux", "x64"],
    "eph-linux-x64-g1": ["self-hosted", "linux", "x64"],
    "eph-linux-x64-g2": ["self-hosted", "linux", "x64"],
    "eph-linux-x64-gpu": ["self-hosted", "linux", "x64", "gpu"],
    "eph-linux-x64-gpu-2": ["self-hosted", "linux", "x64", "gpu"],
    "eph-linux-arm64": ["self-hosted", "linux", "arm64"],
    "eph-macos-arm64": ["self-hosted", "macos", "arm64"],
    "eph-win-x64": ["self-hosted", "windows", "x64"],
    "eph-win-arm64": ["self-hosted", "windows", "arm64"],
}

# Longest class names first so ``eph-linux-x64-nested`` / ``-gpu-2`` win over
# their ``eph-linux-x64`` / ``eph-linux-x64-gpu`` prefixes.
CLASSES = sorted(MIGRATION, key=len, reverse=True)
CLASS_RE = re.compile(r"(?<![A-Za-z0-9-])(" + "|".join(map(re.escape, CLASSES)) + r")(?![A-Za-z0-9-])")

# An exact-quoted class token, e.g. ``"eph-linux-x64"`` — a JSON/YAML matrix
# default whose ENTIRE quoted content is the class. Prose that merely MENTIONS a
# class inside a longer quoted string (``"the eph-win-x64 base image"``) does
# NOT match this and is therefore left verbatim.
EXACT_QUOTED_RE = re.compile(r"([\"'])(" + "|".join(map(re.escape, CLASSES)) + r")\1")

# A quoted string span (single- or double-quoted). Bare-token rewriting skips
# these so a human-readable string that mentions a class is never mangled.
QUOTED_SPAN_RE = re.compile(r"\"[^\"]*\"|'[^']*'")


def _flow(labels: list[str]) -> str:
    return "[" + ", ".join(labels) + "]"


def _json_arr(labels: list[str]) -> str:
    return "[" + ", ".join(f'"{l}"' for l in labels) + "]"


def _split_comment(line: str) -> tuple[str, str]:
    """Split ``line`` into ``(code, comment)`` at the first ``#`` that is not
    inside a quoted string. The comment (with its ``#``) is returned verbatim so
    the rewriter never touches a class name that only appears in a comment."""
    inq: str | None = None
    for i, ch in enumerate(line):
        if inq:
            if ch == inq:
                inq = None
        elif ch in ('"', "'"):
            inq = ch
        elif ch == "#":
            return line[:i], line[i:]
    return line, ""


def _rewrite_bare_outside_quotes(code: str) -> str:
    """Rewrite bare class tokens to flow arrays, but only in the spans of
    ``code`` that are NOT inside a quoted string (so prose strings survive)."""
    out: list[str] = []
    last = 0
    for m in QUOTED_SPAN_RE.finditer(code):
        out.append(CLASS_RE.sub(lambda mm: _flow(MIGRATION[mm.group(1)]), code[last : m.start()]))
        out.append(m.group(0))  # quoted span left verbatim
        last = m.end()
    out.append(CLASS_RE.sub(lambda mm: _flow(MIGRATION[mm.group(1)]), code[last:]))
    return "".join(out)


def rewrite_line(line: str) -> str:
    """Rewrite legacy class tokens in the CODE portion of one line to their label
    set, leaving comments and human-readable strings verbatim.

    Only two positions are rewritten:
      * an exact-quoted class token (a matrix ``default: "eph-…"``) -> JSON array;
      * a bare class token outside any quote (a ``runs-on:`` scalar, a matrix
        flow-list item, or a ``- eph-…`` list item) -> YAML flow array.
    A class name inside a trailing/leading comment or embedded in a longer quoted
    string is left exactly as it was.
    """
    code, comment = _split_comment(line)
    # 1. exact-quoted class token ("eph-…") -> JSON label array.
    code = EXACT_QUOTED_RE.sub(lambda m: _json_arr(MIGRATION[m.group(2)]), code)
    # 2. bare class tokens outside any remaining quote -> YAML flow array.
    code = _rewrite_bare_outside_quotes(code)
    return code + comment


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
    for wf in workflows:
        text = wf.read_text(encoding="utf-8")
        new, changes = rewrite_text(text)
        if changes:
            total += len(changes)
            print(f"\n{wf}:")
            for lineno, old, rewritten in changes:
                print(f"  - {lineno}: {old.strip()}")
                print(f"  + {lineno}: {rewritten.strip()}")
            if args.write:
                wf.write_text(new, encoding="utf-8")

    if total == 0:
        print("codemod-runs-on-labels: no legacy eph-* classes found.")
        return 0
    verb = "rewrote" if args.write else "would rewrite"
    print(f"\ncodemod-runs-on-labels: {verb} {total} legacy class reference(s).", file=sys.stderr)
    if not args.write:
        print("Re-run with --write to apply.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
