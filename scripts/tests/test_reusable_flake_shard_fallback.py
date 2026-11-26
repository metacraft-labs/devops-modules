"""Run the real `Regenerate CI matrix shards` step against shard fixtures.

The step's script is taken from the workflow and run in a real Bash process.
`MCL_FLAKE_CMD` points at a stub: the real one evaluates a flake, which is what
the bound under test exists to avoid. The stub records each shard it is asked
for and writes the `matrix-pre.json` the real command would.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml


WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/reusable-flake-checks-ci-matrix.yml"
if len(sys.argv) > 1:
    WORKFLOW = Path(sys.argv.pop(1))
STEP_NAME = "Regenerate CI matrix shards when artifacts are unavailable"
STEP = next(
    step
    for step in yaml.safe_load(WORKFLOW.read_text())["jobs"]["merge-matrices"]["steps"]
    if step.get("name") == STEP_NAME
)
BASH = os.environ.get("BASH_BIN") or shutil.which("bash")

STUB = """set -euo pipefail
attr=""
while (( $# )); do
  [[ "$1" == --flake-attribute-path ]] && attr="$2"
  shift
done
printf '%s\\n' "$attr" >> "$STUB_LOG"
printf '{"include":[]}' > matrix-pre.json
"""


def shards(count):
    return [
        {"filename": f"matrix-pre-x86_64-linux-shard-{i:02}.json",
         "flakeAttrPath": f"mcl.shard-matrix.result.shardsPerSystem.x86_64-linux.shard-{i:02}"}
        for i in range(count)
    ]


class ShardFallback(unittest.TestCase):
    def run_step(self, matrix, present):
        work = Path(tempfile.mkdtemp())
        stub = work / "mcl-stub"
        stub.write_text(f"#!{BASH}\n" + STUB)
        stub.chmod(0o755)
        log = work / "stub.log"
        log.touch()
        checkout = work / "checkout"
        checkout.mkdir()
        for shard in present:
            (checkout / shard["filename"]).mkdir()
            (checkout / shard["filename"] / "matrix-pre.json").write_text('{"include":[]}')
        env = {
            "PATH": os.environ["PATH"],
            "EVAL_MATRIX": json.dumps({"include": matrix}),
            "MCL_FLAKE_CMD": str(stub),
            "MAX_REGENERATED_SHARDS": STEP["env"]["MAX_REGENERATED_SHARDS"],
            "STUB_LOG": str(log),
        }
        result = subprocess.run([BASH, "-c", STEP["run"]], cwd=checkout, env=env,
                                capture_output=True, text=True)
        return result, log.read_text().split(), checkout

    def test_all_present_evaluates_nothing(self):
        matrix = shards(26)
        result, evaluated, _ = self.run_step(matrix, matrix)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(evaluated, [])
        self.assertIn("Found all 26", result.stdout)

    def test_all_missing_fails_fast_naming_every_shard(self):
        # infra#2455: a merge-only re-run after the shards had expired.
        matrix = shards(26)
        result, evaluated, _ = self.run_step(matrix, [])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(evaluated, [], "must not re-evaluate expired shards")
        self.assertIn("::error", result.stdout)
        self.assertIn("found 0 of 26", result.stdout)
        self.assertIn("re-run the shard/eval-matrix jobs", result.stdout.lower())
        for shard in matrix:
            self.assertIn(shard["filename"], result.stdout)

    def test_more_than_the_bound_missing_fails_fast(self):
        matrix = shards(26)
        result, evaluated, _ = self.run_step(matrix, matrix[2:])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(evaluated, [])
        self.assertIn(matrix[0]["filename"], result.stdout)
        self.assertIn(matrix[1]["filename"], result.stdout)
        self.assertNotIn(matrix[2]["filename"], result.stdout)

    def test_one_failed_upload_is_re_evaluated_alone(self):
        matrix = shards(26)
        result, evaluated, checkout = self.run_step(matrix, matrix[:5] + matrix[6:])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(evaluated, [matrix[5]["flakeAttrPath"]])
        self.assertTrue((checkout / matrix[5]["filename"] / "matrix-pre.json").is_file())
        self.assertFalse((checkout / "matrix-pre.json").exists())

    def test_single_shard_matrix_never_re_evaluates_everything(self):
        matrix = shards(1)
        result, evaluated, _ = self.run_step(matrix, [])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(evaluated, [])


if __name__ == "__main__":
    unittest.main()
