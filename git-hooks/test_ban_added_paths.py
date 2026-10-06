#!/usr/bin/env python3
"""Tests for the `ban-added-ct-recordings` mechanism.

NO MOCKS.  Every case builds a real git repository in a temporary directory and
runs the real script against the real index.  The thing under test is precisely
the `git diff --staged --diff-filter=A` distinction, so a fake git would be
testing the fake.

BOTH DIRECTIONS FOR EVERY RULE.  A ban that never fires satisfies every
"must not commit" requirement ever written, so each rule here has a planted
defect that MUST be refused and a legitimate case that MUST be accepted.  The
pair is the test; either half alone is not.

    python3 git-hooks/test_ban_added_paths.py
"""

import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))

from mcl_git_hooks import ban_added_paths  # noqa: E402


def git(repo, *args):
    subprocess.run(
        ["git", "-C", repo] + list(args),
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


class BanAddedPathsTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = self._tmp.name
        git(self.repo, "init", "-q", ".")
        git(self.repo, "config", "user.email", "t@example.invalid")
        git(self.repo, "config", "user.name", "t")
        self._cwd = os.getcwd()
        os.chdir(self.repo)

    def tearDown(self):
        os.chdir(self._cwd)
        self._tmp.cleanup()

    def write(self, rel, content=b"x"):
        path = os.path.join(self.repo, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as fh:
            fh.write(content)
        return rel

    def run_hook(self, *paths):
        return ban_added_paths.main(["--preset", "ct-recordings", "--"] + list(paths))

    # -- the defect that must be refused ---------------------------------
    def test_added_recording_is_refused(self):
        rel = self.write("rec/fresh.ct")
        git(self.repo, "add", rel)
        self.assertEqual(self.run_hook(rel), 1)

    # -- the legitimate cases that must be accepted ----------------------
    def test_modified_preexisting_recording_is_accepted(self):
        """The property that makes this adoptable without a flag day.

        blocktracer carries 55 committed recordings, codetracer-wasm-recorder
        26, codetracer 20.  If this case failed, enabling the hook would make
        every subsequent commit in those repos unlandable.
        """
        rel = self.write("rec/existing.ct")
        git(self.repo, "add", rel)
        git(self.repo, "commit", "-qm", "base")
        self.write(rel, b"changed")
        git(self.repo, "add", rel)
        self.assertEqual(self.run_hook(rel), 0)

    def test_deleted_recording_is_accepted(self):
        rel = self.write("rec/existing.ct")
        git(self.repo, "add", rel)
        git(self.repo, "commit", "-qm", "base")
        os.remove(os.path.join(self.repo, rel))
        git(self.repo, "add", "-A")
        self.assertEqual(self.run_hook(rel), 0)

    def test_nothing_staged_is_accepted(self):
        rel = self.write("rec/untracked.ct")
        # Written but never `git add`ed: not in the index, so not "added".
        self.assertEqual(self.run_hook(rel), 0)

    # -- the escape hatch, and its default --------------------------------
    def test_all_staged_flag_also_catches_modifications(self):
        rel = self.write("rec/existing.ct")
        git(self.repo, "add", rel)
        git(self.repo, "commit", "-qm", "base")
        self.write(rel, b"changed")
        git(self.repo, "add", rel)
        self.assertEqual(
            ban_added_paths.main(["--all-staged", "--preset", "ct-recordings", "--", rel]),
            1,
            "--all-staged must be the flag-day behaviour, so that the default "
            "is demonstrably NOT it",
        )

    # -- fail open, not closed --------------------------------------------
    def test_outside_a_git_repo_accepts(self):
        with tempfile.TemporaryDirectory() as nogit:
            os.chdir(nogit)
            open(os.path.join(nogit, "x.ct"), "w").close()
            self.assertEqual(self.run_hook("x.ct"), 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
