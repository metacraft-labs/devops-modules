#!/usr/bin/env python3
"""Refuse paths that a commit ADDS.

THE MECHANISM, NOT THE POLICY.  This script decides one thing: of the paths the
hook framework handed it, which are *newly added* by the commit being made.
Which paths are candidates at all is the hook's ``files:`` regex, and what to
say about them is ``--preset`` / ``--message`` / ``--explain``.  So the `.ct`
recording ban, and any future ban of the same shape, is configuration of this
one implementation rather than a separate implementation.

WHY "ADDED" AND NOT "CHANGED".  ``git diff --staged --diff-filter=A`` is the
same set ``check-added-large-files`` intersects against, and for the same
reason: a ban has to be switchable on in repos that ALREADY carry the banned
content without making their every subsequent commit unlandable.  New additions
are refused; the existing ones are a separate cleanup with its own sequencing.
(Measured: blocktracer carries 55 committed recordings, codetracer-wasm-recorder
26, codetracer 20.)  A ban that fired on modifications would be a flag day, and
a flag day across 147 repos does not get rolled out, it gets reverted.

WHY PYTHON AND NOT A SHELL SCRIPT.  Two independent reasons, both measured:

* **Windows has no Nix.**  The previous implementation was a
  ``pkgs.writeShellApplication``, i.e. a /nix/store path.  Every Windows
  developer in this workspace has ``prek`` and whatever winget/scoop installed,
  and no /nix/store at all, so a store-path hook is a hook that does not exist
  for them.  A rule that half the fleet cannot run is not mandatory, whatever
  the requirements document says.
* **prek on Windows funnels a hook entry through an outer**
  ``bash -c "cmd file1 file2 ..."``.  Paths containing shell metacharacters
  (`(` in SolidJS route groups, for instance) kill that outer parser before the
  hook runs.  Python takes argv straight from CreateProcess.  This is not
  hypothetical: ``agent-harbor`` hit it and rewrote three hooks into Python for
  exactly this reason (see its ``scripts/hooks/`` header comments).

No third-party imports, on purpose: this must run under whatever Python a
Windows box happens to have, and under the isolated environment pre-commit and
prek build for a ``language: python`` hook repository.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys

DEFAULT_MESSAGE = "REFUSED: this commit adds banned path(s):"

# WHY THE `.ct` BAN CANNOT BE FOLDED INTO check-added-large-files.  Measured in
# `codetracer` at 547497aa: of its 20 tracked `.ct` files, 19 are between 36 KB
# and 516 KB -- i.e. UNDER a 1 MB ceiling -- and only `nginx.ct` (2.09 MB)
# exceeds it.  A size gate would wave through 19 of 20.  The objection to a
# committed recording is not that it is big, it is that it is DERIVED and
# therefore goes stale; size is a proxy that happens not to correlate.  Keep
# this paragraph: without it a future reader folds the two checks together and
# quietly reopens the hole.
PRESETS = {
    "ct-recordings": (
        "REFUSED: this commit adds CodeTracer recording(s):",
        """Recordings are DERIVED artefacts and may not be committed here.
A committed recording pins a recorder version that nothing tracks, so it
silently goes stale and then fails as a content mismatch rather than as
"the recorder changed".

Instead: have the test RECORD IT ON THE FLY.

Exactly one repository is allowed to commit recordings --
codetracer-example-recordings -- which declares that by setting

  mcl.gitHooks.committedBinaries.allowCommittedCtRecordings = true;

in its flake, or by omitting this hook id from its .pre-commit-config.yaml
with a comment saying why.  Do not set that here to make this message go
away.""",
    ),
}


def added_paths(cwd: str | None = None) -> set:
    """Paths with git status ``A`` in the index.

    Returns an empty set (rather than raising) when git cannot answer, which
    makes the hook fail *open* on a broken repo state instead of blocking every
    commit with a traceback.  A ban that cannot be landed past is worse than one
    that occasionally misses: the miss is caught at review, the unlandable repo
    is caught by someone disabling the hook.
    """
    try:
        out = subprocess.run(
            ["git", "diff", "--staged", "--name-only", "--diff-filter=A"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=True,
            cwd=cwd,
        ).stdout.decode("utf-8", "replace")
    except (OSError, subprocess.CalledProcessError):
        return set()
    return {line.strip() for line in out.splitlines() if line.strip()}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Refuse paths that a commit adds.")
    parser.add_argument(
        "--preset",
        choices=sorted(PRESETS),
        help="Named message/explanation pair. Keeps the wording in ONE place "
        "so the flake entry and the committed YAML entry cannot disagree.",
    )
    parser.add_argument("--message", default=None)
    parser.add_argument(
        "--explain",
        default=None,
        help="Additional lines printed after the offender list.",
    )
    parser.add_argument(
        "--all-staged",
        action="store_true",
        help="Check every staged path, not only added ones. NOT the default, "
        "and enabling it turns adoption into a flag day -- read the module "
        "docstring before you reach for it.",
    )
    parser.add_argument("paths", nargs="*")
    args = parser.parse_args(argv if argv is not None else sys.argv[1:])

    message, explain = DEFAULT_MESSAGE, ""
    if args.preset:
        message, explain = PRESETS[args.preset]
    if args.message is not None:
        message = args.message
    if args.explain is not None:
        explain = args.explain

    if args.all_staged:
        offenders = [p for p in args.paths if os.path.lexists(p)]
    else:
        added = added_paths()
        # Normalise separators: git always reports forward slashes, while the
        # hook framework on Windows may hand us backslashes.
        offenders = [p for p in args.paths if p.replace(os.sep, "/") in added]

    if not offenders:
        return 0

    sys.stderr.write(message + "\n")
    for offender in offenders:
        sys.stderr.write("  " + offender + "\n")
    if explain:
        sys.stderr.write("\n" + explain + "\n")
    return 1


if __name__ == "__main__":
    sys.exit(main())
