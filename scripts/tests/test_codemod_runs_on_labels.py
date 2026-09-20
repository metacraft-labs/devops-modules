#!/usr/bin/env python3
"""Tests for scripts/ci/codemod_runs_on_labels.py (RC4 runs-on label codemod).

No mock objects: these exercise the real text-rewriting functions
(``rewrite_text`` / ``scan_needs_decision``) over real workflow snippets. The
codemod is pure text-in/text-out, so there is no filesystem or process boundary
worth mocking — the fixtures ARE the contract.

The load-bearing case is the RC4-audit regression: a legacy
``eph-linux-x64-nested`` class must migrate to ``[self-hosted, linux, x64]`` and
must NOT emit a ``nested`` label — no central pool advertises ``nested``, so
emitting it would pin the job to an empty runner set. The old codemod emitted
``nested``; ``test_nested_class_drops_nested`` fails on that code and passes on
the fix.
"""

from __future__ import annotations

import importlib.util
import os
import sys

_CODEMOD_PATH = os.path.join(
    os.path.dirname(__file__), "..", "ci", "codemod_runs_on_labels.py"
)
_spec = importlib.util.spec_from_file_location("codemod_runs_on_labels", _CODEMOD_PATH)
cm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cm)


_results: list[bool] = []


def check(name: str, cond: bool, detail: str = "") -> None:
    status = "PASS" if cond else "FAIL"
    print(f"  [{status}] {name}")
    if not cond and detail:
        print(f"         {detail}")
    _results.append(cond)


def rw(text: str) -> str:
    """Rewrite a snippet and return the new text."""
    new, _changes = cm.rewrite_text(text)
    return new


# ---------------------------------------------------------------------------
# 1. eph-* scalars / arrays -> correct capability arrays
# ---------------------------------------------------------------------------
def test_scalar_forms() -> None:
    check(
        "runs-on scalar eph-linux-x64 -> [self-hosted, linux, x64]",
        rw("runs-on: eph-linux-x64\n") == "runs-on: [self-hosted, linux, x64]\n",
        detail=repr(rw("runs-on: eph-linux-x64\n")),
    )
    check(
        "runs-on quoted scalar eph-win-x64 -> flow array",
        rw('runs-on: "eph-win-x64"\n')
        == 'runs-on: ["self-hosted", "windows", "x64"]\n',
        detail=repr(rw('runs-on: "eph-win-x64"\n')),
    )
    check(
        "YAML list item - eph-macos-arm64 -> - [self-hosted, macos, arm64]",
        rw("  - eph-macos-arm64\n") == "  - [self-hosted, macos, arm64]\n",
        detail=repr(rw("  - eph-macos-arm64\n")),
    )
    check(
        "quoted JSON matrix default 'eph-linux-arm64' -> JSON array",
        rw('        default: "eph-linux-arm64"\n')
        == '        default: ["self-hosted", "linux", "arm64"]\n',
        detail=repr(rw('        default: "eph-linux-arm64"\n')),
    )


# ---------------------------------------------------------------------------
# 2. THE REGRESSION: eph-linux-x64-nested must NOT emit `nested`
# ---------------------------------------------------------------------------
def test_nested_class_drops_nested() -> None:
    out_scalar = rw("runs-on: eph-linux-x64-nested\n")
    check(
        "eph-linux-x64-nested scalar -> [self-hosted, linux, x64] (no nested)",
        out_scalar == "runs-on: [self-hosted, linux, x64]\n",
        detail=repr(out_scalar),
    )
    out_quoted = rw('runs-on: "eph-linux-x64-nested"\n')
    check(
        "eph-linux-x64-nested quoted -> JSON array (no nested)",
        out_quoted == 'runs-on: ["self-hosted", "linux", "x64"]\n',
        detail=repr(out_quoted),
    )
    # Belt-and-braces: `nested` must appear NOWHERE in any migrated output.
    combined = rw(
        "runs-on: eph-linux-x64-nested\n"
        'other: "eph-linux-x64-nested"\n'
        "  - eph-linux-x64-nested\n"
    )
    check(
        "no `nested` label emitted anywhere for the nested class",
        "nested" not in combined,
        detail=repr(combined),
    )
    check(
        "`nested` is not in the codemod's emitted vocabulary at all",
        all("nested" not in labels for labels in cm.MIGRATION.values()),
        detail=repr(cm.MIGRATION),
    )


# ---------------------------------------------------------------------------
# 3. GPU-host routing aliases (task #50) left ALONE + flagged
# ---------------------------------------------------------------------------
def test_gpu_aliases_left_alone() -> None:
    for tok in ("eph-linux-x64-g1", "eph-linux-x64-g2", "eph-linux-x64-gpu", "eph-linux-x64-gpu-2"):
        src = f"runs-on: {tok}\n"
        check(
            f"{tok} is left verbatim (not rewritten)",
            rw(src) == src,
            detail=repr(rw(src)),
        )
        hits = cm.scan_needs_decision(src)
        check(
            f"{tok} is flagged as needs-decision",
            len(hits) == 1 and hits[0][1] == tok,
            detail=repr(hits),
        )
    # And crucially, none of these are in the auto-migration table.
    check(
        "no GPU-host alias is in the MIGRATION table",
        not (set(cm.NEEDS_DECISION) & set(cm.MIGRATION)),
        detail=repr(set(cm.NEEDS_DECISION) & set(cm.MIGRATION)),
    )


# ---------------------------------------------------------------------------
# 4. Matrix nested-array structure preserved; name keys untouched; comments kept
# ---------------------------------------------------------------------------
MATRIX_FIXTURE = """\
# 5-class build matrix — the label axis migrates, name keys do NOT.
jobs:
  build:
    strategy:
      matrix:
        runner: [eph-linux-x64, eph-win-x64, eph-macos-arm64, eph-linux-arm64, eph-win-arm64]
        include:
          - runner: eph-linux-x64
            artifact: myapp-eph-linux-x64-bundle  # name key: keep verbatim
    runs-on: ${{ matrix.runner }}  # trailing comment stays
"""


def test_matrix_and_comments() -> None:
    out = rw(MATRIX_FIXTURE)
    # The 5-class flow list becomes a nested array of label arrays.
    expected_axis = (
        "        runner: [[self-hosted, linux, x64], [self-hosted, windows, x64], "
        "[self-hosted, macos, arm64], [self-hosted, linux, arm64], "
        "[self-hosted, windows, arm64]]"
    )
    check(
        "5-class matrix axis -> nested array of label arrays",
        expected_axis in out,
        detail=next((l for l in out.splitlines() if "runner:" in l and "[" in l), "<none>"),
    )
    check(
        "artifact name key myapp-eph-linux-x64-bundle untouched",
        "artifact: myapp-eph-linux-x64-bundle" in out,
        detail=next((l for l in out.splitlines() if "artifact:" in l), "<none>"),
    )
    check(
        "top comment preserved",
        "# 5-class build matrix" in out,
    )
    check(
        "trailing comment preserved",
        "# trailing comment stays" in out,
    )
    check(
        "name-key inline comment preserved",
        "# name key: keep verbatim" in out,
    )
    check(
        "no `nested` label leaked into the matrix output",
        "nested" not in out,
        detail=repr(out),
    )


def main() -> int:
    print("test_codemod_runs_on_labels:")
    test_scalar_forms()
    test_nested_class_drops_nested()
    test_gpu_aliases_left_alone()
    test_matrix_and_comments()
    print()
    if all(_results):
        print(f"All {len(_results)} checks passed!")
        return 0
    print(f"{_results.count(False)}/{len(_results)} checks FAILED!")
    return 1


if __name__ == "__main__":
    sys.exit(main())
