"""Every setup-nix step that names the private cache must also authenticate to it.

`vars.SUBSTITUTERS` in this org is the private Attic cache, which answers 401
to anonymous reads. A setup-nix step given that substituter but no
`attic-token` makes Nix read the cache anonymously; the action's preflight then
drops it and every path not on cache.nixos.org is built from source. Persistent
runners hide this because their daemon netrc already carries the credential;
ephemeral runners start with an empty store and no such netrc, so the same job
goes from seconds to the 30-minute ceiling (test-mcl on the 2026-10-27
promotion).

The test parses the committed workflows, no mocks: it is a static contract over
the exact YAML GitHub evaluates.
"""

import sys
from pathlib import Path

import yaml

SETUP_ACTIONS = ("setup-nix", "install-nix", "setup-dev-env")


def offending_steps(workflow_dir: Path):
    for path in sorted(workflow_dir.glob("*.y*ml")):
        doc = yaml.safe_load(path.read_text()) or {}
        for job_name, job in (doc.get("jobs") or {}).items():
            for step in job.get("steps") or []:
                uses = str(step.get("uses", ""))
                if not any(action in uses for action in SETUP_ACTIONS):
                    continue
                inputs = step.get("with") or {}
                if not str(inputs.get("substituters", "")).strip():
                    continue  # cache.nixos.org only: no credential needed
                if str(inputs.get("attic-token", "")).strip():
                    continue
                yield f"{path.name}: job {job_name!r} step {step.get('name', uses)!r}"


def main() -> int:
    workflow_dir = Path(sys.argv[1] if len(sys.argv) > 1 else ".github/workflows")
    bad = list(offending_steps(workflow_dir))
    for entry in bad:
        print(f"missing attic-token next to a private substituter: {entry}")
    if bad:
        print(
            "Pass `attic-token: ${{ secrets.ATTIC_PULL_TOKEN || secrets.ATTIC_TOKEN }}` "
            "to each of these steps."
        )
        return 1
    print("OK: every setup-nix step with extra substituters passes an attic-token")
    return 0


if __name__ == "__main__":
    sys.exit(main())
