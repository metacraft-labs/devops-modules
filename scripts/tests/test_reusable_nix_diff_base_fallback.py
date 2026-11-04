#!/usr/bin/env python3
"""Contract test: nix-diff's synthetic base falls back when it cannot evaluate.

reusable-nix-diff.yml pins the base branch's `base-input-overrides` inputs to
the PR's lock, so the diff isolates the PR's own change. A PR that moves its
configuration together with a changed interface of such an input (a renamed
module) leaves the synthetic base unable to evaluate, and nix-diff used to fail
without diffing anything (infra #2056, the vm-harness -> gosti rename). The
step must then diff against the UNMODIFIED base and say so.

This runs the step's real `run:` script, extracted from the workflow, in real
git repositories. TEST DOUBLE, JUSTIFIED: `nix` is a stub. Evaluating a real
NixOS flake needs a fleet's inputs and network access the build sandbox does
not have, and the contract under test is the step's control flow -- which base
`origin` it leaves behind -- for which nix's only relevant behaviour is the exit
status of `nix eval` per machine. The stub also answers `flake metadata` and
`flake lock`, the two other commands the step runs.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = REPO_ROOT / ".github/workflows/reusable-nix-diff.yml"
STEP = "Prepare synthetic base flake inputs"

NIX_STUB = r"""#!__BASH__
set -euo pipefail
case "$1 $2" in
  "flake metadata")
    echo '{"locks":{"nodes":{"root":{"inputs":{"mods":"mods"}},"mods":{"locked":{"type":"github","owner":"o","repo":"mods","rev":"pr-rev"}}}}}'
    exit 0 ;;
  "flake lock")
    echo "locked-with: $*" >> flake.lock
    exit 0 ;;
esac
if [ "$1" = eval ]; then
  for a in "$@"; do
    case "$a" in
      .#nixosConfigurations.*)
        m="${a#.#nixosConfigurations.}"; m="${m%%.*}"
        for bad in ${FAIL_MACHINES:-}; do
          if [ "$bad" = "$m" ]; then
            echo "error: attribute 'vm-harness-serve' missing" >&2
            exit 1
          fi
        done
        echo "/nix/store/stub-$m.drv"; exit 0 ;;
    esac
  done
fi
echo "unexpected nix invocation: $*" >&2
exit 2
"""


def step_script() -> str:
    doc = yaml.safe_load(WORKFLOW.read_text())
    steps = doc["jobs"]["nix-diff"]["steps"]
    matches = [s for s in steps if s.get("name") == STEP]
    assert len(matches) == 1, f"expected one step named {STEP!r}"
    step = matches[0]
    assert "steps.discover.outputs.machines" in step.get("env", {}).get("DIFF_MACHINES", ""), \
        "the step no longer receives the discovered machines"
    script = step["run"]
    for expr, value in (
        ("${{ github.event.pull_request.base.ref }}", "live"),
        ("${{ inputs.base-input-overrides }}", "mods"),
    ):
        assert expr in script, f"expected {expr} in the step script"
        script = script.replace(expr, value)
    assert "${{" not in script, "an unhandled GitHub expression remains in the step script"
    return script


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


def run_case(name: str, fail_machines: str) -> tuple[str, str, str]:
    script = step_script()
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        home = tmp / "home"
        home.mkdir()
        env = dict(os.environ, HOME=str(home), GIT_CONFIG_NOSYSTEM="1")
        upstream = tmp / "upstream.git"
        subprocess.run(["git", "init", "-q", "--bare", "-b", "live", str(upstream)], check=True, env=env)
        work = tmp / "work"
        subprocess.run(["git", "clone", "-q", str(upstream), str(work)], check=True, env=env, capture_output=True)
        for k, v in (("user.name", "t"), ("user.email", "t@example.invalid"), ("commit.gpgsign", "false")):
            git(work, "config", k, v)
        (work / "flake.lock").write_text("{}\n")
        git(work, "add", "flake.lock")
        git(work, "commit", "-q", "-m", "base")
        git(work, "push", "-q", "origin", "HEAD:live")
        before = git(work, "remote", "get-url", "origin")

        bindir = tmp / "bin"
        bindir.mkdir()
        # The build sandbox has no /usr/bin/env: name bash by absolute path.
        (bindir / "nix").write_text(NIX_STUB.replace("__BASH__", shutil.which("bash") or "/bin/bash"))
        (bindir / "nix").chmod(0o755)
        runner_temp = tmp / "runner-temp"
        runner_temp.mkdir()
        env.update(
            PATH=f"{bindir}:{env['PATH']}",
            RUNNER_TEMP=str(runner_temp),
            GITHUB_RUN_ID="1",
            DIFF_MACHINES='["hms","gpu"]',
            FAIL_MACHINES=fail_machines,
        )
        result = subprocess.run(["bash", "-c", script], cwd=work, env=env, capture_output=True, text=True)
        assert result.returncode == 0, f"{name}: step failed rc={result.returncode}\n{result.stdout}{result.stderr}"
        after = git(work, "remote", "get-url", "origin")
        return before, after, result.stdout + result.stderr


def main() -> int:
    before, after, out = run_case("evaluates", "")
    assert after != before and after.endswith("origin.git"), \
        f"a base that evaluates must be the synthetic one (origin {before} -> {after})\n{out}"
    assert "fallback" not in out.lower() and "does not evaluate" not in out, out
    print("ok   a synthetic base that evaluates replaces origin, as before")

    before, after, out = run_case("does-not-evaluate", "gpu")
    assert after == before, f"a synthetic base that cannot evaluate must NOT replace origin ({before} -> {after})\n{out}"
    assert "does not evaluate for: gpu" in out, f"the fallback is not announced by machine:\n{out}"
    assert "diffed against the unmodified live" in out, out
    assert "attribute 'vm-harness-serve' missing" in out, f"the first evaluation error is not shown:\n{out}"
    print("ok   a synthetic base that cannot evaluate falls back to the unmodified base, with a notice naming the machine and the error")

    print("reusable-nix-diff base fallback: all contracts hold.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
