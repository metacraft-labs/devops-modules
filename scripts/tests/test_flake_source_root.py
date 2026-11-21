"""The batch build job roots the flake source before the first build, and the
root survives a garbage collection between two builds.

Why this exists: each output in a build batch is a separate `nix build`, and
nothing rooted the flake's own `/nix/store/<hash>-source` between them. On m3
the daemon's auto-GC ran inside a later invocation, deleted the source, and the
check failed with `error: path '/nix/store/<hash>-source' is not valid`
(metacraft-labs/infra jobs 132677356064, 133483446017, 133658250321).

Nothing here is a double. The workflow's own `run:` blocks are extracted and
executed exactly as a runner executes `shell: bash`
(`bash --noprofile --norc -e -o pipefail <file>`) against the real `nix` CLI,
on a throwaway local store
(`store = local?root=<tmp>`) holding a real two-repo flake, and the store is
collected with the real `nix store gc`. The negative control runs the same
sequence without the rooting step and must see the source collected, which is
what proves the GC in this test can delete the path at all.

The check runs this file once per (bash, nix) pair: bash 3.2 is what the
darwin runners' `shell: bash` resolves to (/bin/bash), and Nix 2.35 no longer
copies the flake source in `nix flake metadata`. A single current bash and Nix
let both of those through when this step first shipped (PR #822).

Environment: BASH_BIN (the shell to run the steps with), EXPECT_BASH_MAJOR
(asserted against that shell, so the pair under test is the pair named), and
`nix` on PATH.

Usage: test_flake_source_root.py [WORKFLOW]
"""

import re

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml


WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/reusable-flake-checks-ci-matrix.yml"
if len(sys.argv) > 1:
    WORKFLOW = Path(sys.argv.pop(1))
BASH = os.environ.get("BASH_BIN", "bash")
EXPECT_BASH_MAJOR = os.environ.get("EXPECT_BASH_MAJOR", "")

# Constructs bash 3.2 (darwin /bin/bash) does not have, plus array expansion,
# which is an unbound variable under `set -u` when empty before bash 4.4.
BASH4_ONLY = re.compile(
    r"\b(mapfile|readarray|coproc)\b|\bdeclare\s+-[a-zA-Z]*A|\blocal\s+-n\b"
    r"|\$\{[^}]*(,,|\^\^|,|\^)\}|&>>|;;&|\[@\]|\[\*\]"
)


def bash4_constructs(script):
    return [m.group(0) for line in script.splitlines()
            if not line.lstrip().startswith("#")
            for m in [BASH4_ONLY.search(line)] if m]

ROOT_STEP = "Root the flake source for this job"
RELEASE_STEP = "Release the flake source roots"

STEPS = yaml.safe_load(WORKFLOW.read_text())["jobs"]["build"]["steps"]
NAMES = [step.get("name", "") for step in STEPS]


def step(name):
    return STEPS[NAMES.index(name)]


def git(cwd, *args):
    subprocess.run(
        ["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid",
         "-c", "init.defaultBranch=main", *args],
        cwd=cwd, check=True, capture_output=True,
    )


class Sandbox:
    """A local store, a nix cache dir and a committed flake with one input."""

    def __init__(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="flake-src-root-"))
        self.runner_temp = self.tmp / "runner-temp"
        self.runner_temp.mkdir()
        (self.tmp / "home").mkdir()
        self.env = dict(os.environ)
        self.env.update({
            "HOME": str(self.tmp / "home"),
            "XDG_CACHE_HOME": str(self.tmp / "cache"),
            "RUNNER_TEMP": str(self.runner_temp),
            "NIX_CONFIG": "\n".join([
                "store = local?root=" + str(self.tmp / "store"),
                "experimental-features = nix-command flakes",
                "substituters =",
                "build-users-group =",
                "sandbox = false",
            ]),
        })
        self.env.pop("NIX_REMOTE", None)

        dep = self.tmp / "dep"
        dep.mkdir()
        (dep / "data").write_text("input payload\n")
        git(dep, "init", "-q")
        git(dep, "add", ".")
        git(dep, "commit", "-qm", "dep")

        self.flake = self.tmp / "flake"
        self.flake.mkdir()
        (self.flake / "flake.nix").write_text(
            '{ inputs.dep = { url = "git+file://%s"; flake = false; };\n'
            '  outputs = { self, dep }: { src = "${self}"; depsrc = "${dep}"; }; }\n' % dep
        )
        git(self.flake, "init", "-q")
        git(self.flake, "add", ".")
        self.nix("flake", "lock")
        git(self.flake, "add", ".")
        git(self.flake, "commit", "-qm", "flake")

    def run(self, argv, check=True):
        return subprocess.run(argv, cwd=self.flake, env=self.env, text=True,
                              capture_output=True, check=check)

    def nix(self, *args):
        return self.run(["nix", *args]).stdout.strip()

    def run_script(self, script):
        path = self.tmp / "step.sh"
        path.write_text(script)
        # What a runner does for `shell: bash`.
        return self.run([BASH, "--noprofile", "--norc", "-e", "-o", "pipefail", str(path)],
                        check=False)

    def run_step(self, name):
        return self.run_script(step(name)["run"])

    def evaluate(self, attr):
        """What one per-output build does first: evaluate `.#<attr>`."""
        return self.nix("eval", "--raw", ".#" + attr)

    def gc(self):
        self.nix("store", "gc")

    def valid(self, path):
        return self.run(["nix-store", "--check-validity", path], check=False).returncode == 0


class FlakeSourceRoot(unittest.TestCase):
    def test_shell_under_test_is_the_one_named(self):
        major = subprocess.run([BASH, "-c", "echo ${BASH_VERSINFO[0]}"], text=True,
                               capture_output=True, check=True).stdout.strip()
        if EXPECT_BASH_MAJOR:
            self.assertEqual(major, EXPECT_BASH_MAJOR)

    def test_steps_use_no_bash4_constructs(self):
        for name in (ROOT_STEP, RELEASE_STEP):
            self.assertEqual(bash4_constructs(step(name)["run"]), [], name)

    def test_bash4_lint_catches_bash4_constructs(self):
        # Negative control for the lint above.
        for bad in ('mapfile -t xs < f', 'readarray xs', 'declare -A m', 'echo "${xs[@]}"',
                    'echo "${#xs[@]}"', 'echo "${v,,}"', 'cmd &>> log'):
            self.assertNotEqual(bash4_constructs(bad), [], bad)

    def test_bash32_rejects_a_bash4_step(self):
        # Negative control for the shell: under bash 3.2 the same step with a
        # bash-4 builtin added must fail, as it did on the darwin runners.
        if EXPECT_BASH_MAJOR != "3":
            self.skipTest("only meaningful under bash 3.2")
        box = Sandbox()
        result = box.run_script("mapfile -t probe < /dev/null\n" + step(ROOT_STEP)["run"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("mapfile: command not found", result.stderr)

    def test_root_step_runs_before_the_first_build(self):
        build = next(i for i, n in enumerate(NAMES) if n.startswith("Build "))
        root = NAMES.index(ROOT_STEP)
        self.assertLess(root, build, "the source must be rooted before the first per-output build")
        self.assertEqual(step(ROOT_STEP)["if"], "${{ !matrix.noop }}")
        self.assertNotIn("continue-on-error", step(ROOT_STEP),
                         "a failure to root the source must fail the job")
        release = NAMES.index(RELEASE_STEP)
        self.assertEqual(release, len(NAMES) - 1, "the roots must be held until the job's last step")
        self.assertIn("always()", step(RELEASE_STEP)["if"])

    def test_builds_evaluate_the_rooted_reference(self):
        # The step roots the source of `.`; the build must evaluate `.` too,
        # and must not re-fetch it into a different path.
        build = next(s for s in STEPS if s.get("name", "").startswith("Build "))["run"]
        self.assertIn('".#$out_attr"', build)
        self.assertIn("nix flake metadata --json . ", step(ROOT_STEP)["run"])
        for script in (build, step(ROOT_STEP)["run"]):
            self.assertNotIn("--refresh", script)

    def test_source_and_inputs_survive_gc_between_builds(self):
        box = Sandbox()
        first = box.evaluate("src")        # build 1: copies self, fetches the input
        dep = box.evaluate("depsrc")
        result = box.run_step(ROOT_STEP)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Rooted the flake source " + first, result.stdout)
        self.assertIn("Rooted 1 of 1 locked input source(s)", result.stdout)

        box.gc()                           # the auto-GC between two builds
        self.assertTrue(box.valid(first), "the rooted flake source was collected")
        self.assertTrue(box.valid(dep), "the rooted input source was collected")
        self.assertEqual(box.evaluate("src"), first, "build 2 must evaluate the rooted path")

        # Releasing the roots makes both collectable again: the roots were
        # the only thing keeping them, and the GC above really could delete.
        result = box.run_step(RELEASE_STEP)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((box.runner_temp / "flake-source-roots").exists())
        box.gc()
        self.assertFalse(box.valid(first))
        self.assertFalse(box.valid(dep))

    def test_root_step_alone_roots_a_fresh_checkout(self):
        # In CI the step runs first, before anything has copied the source.
        box = Sandbox()
        result = box.run_step(ROOT_STEP)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        rows = (box.runner_temp / "flake-source-roots" / "sources.tsv").read_text()
        rooted = rows.split("\n")[0].split("\t")
        self.assertEqual(rooted[0], "self")
        box.gc()
        # Checked before anything evaluates again: an evaluation would re-copy
        # a collected source and hide the loss.
        self.assertTrue(box.valid(rooted[1]), "the rooted flake source was collected")
        self.assertEqual(box.evaluate("src"), rooted[1],
                         "the builds must evaluate the same source path the step rooted")

    def test_negative_control_without_the_root_the_gc_deletes_the_source(self):
        box = Sandbox()
        source = box.evaluate("src")
        self.assertTrue(box.valid(source))
        box.gc()
        self.assertFalse(box.valid(source),
                         "without the rooting step the GC must delete the source; "
                         "otherwise the positive test proves nothing")

    def test_failure_to_root_is_fatal_and_named(self):
        box = Sandbox()
        (box.flake / "flake.nix").write_text("this is not a flake")
        git(box.flake, "commit", "-qam", "break the flake")
        result = box.run_step(ROOT_STEP)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("::error title=Flake source root::", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
