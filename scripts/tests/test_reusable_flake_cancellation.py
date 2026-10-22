"""Check the real workflow's cancellation contract without a scheduler double.

GitHub's cancellation service cannot run locally. These structural assertions
require its documented cancellation-sensitive status function at the job boundary
where runners are allocated, including the no-op fallback. They deliberately do
not simulate concurrency release or claim a cancellation latency. Existing
ci-build-batching tests execute the planner and build scripts from this workflow.
A narrow Boolean expression double is necessary to exercise input/result truth
tables locally because GitHub's expression service is hosted. Exact guard checks
back it up, and selected failure steps execute in a real Bash process.

Status functions override the implicit success() guard, so !cancelled() still
admits failure reporting after an upstream failure or skipped matrix merge:
https://docs.github.com/en/actions/reference/workflows-and-actions/expressions#status-check-functions
https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-cancellation
"""

import json
import os
import re
import subprocess
import sys
import unittest
from pathlib import Path

import yaml


WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/reusable-flake-checks-ci-matrix.yml"
if len(sys.argv) > 1:
    WORKFLOW = Path(sys.argv.pop(1))
JOBS = yaml.safe_load(WORKFLOW.read_text())["jobs"]


def expression(value):
    value = value.strip()
    if value.startswith("${{") and value.endswith("}}"):
        value = value[3:-2]
    return re.sub(r"\s+", "", value)


def evaluate(value, context):
    """Evaluate only the Boolean subset used by the guards under test.

    This is a local expression double: GitHub's scheduler is a hosted service.
    It covers documented status functions, comparisons, Boolean operators and
    contains; it does not simulate job scheduling or runner cancellation.
    Structural assertions additionally require the cancellation status function
    so Python evaluation cannot hide GitHub's implicit success() behavior.
    """
    value = expression(value)
    value = re.sub(r"needs\.[\w*-]+\.(?:outputs\.[\w-]+|result)|inputs\.[\w-]+",
                   lambda match: repr(context[match.group()]), value)
    value = value.replace("&&", " and ").replace("||", " or ")
    value = re.sub(r"!(?!=)", " not ", value)
    return bool(eval(value.strip(), {"__builtins__": {}}, {
        "cancelled": lambda: context["cancelled"],
        "always": lambda: True,
        "success": lambda: all(result == "success" for result in context["needs.*.result"]),
        "failure": lambda: "failure" in context["needs.*.result"],
        "contains": lambda values, value: value in values,
    }))


class CancellationContract(unittest.TestCase):
    def test_job_guard_truth_table(self):
        for cancelled in (False, True):
            for upstream in ("success", "failure", "skipped", "cancelled"):
                for cap, systems in (("{}", ""), ("", ""), ('{"x86_64-linux":1}', ""),
                                     ("{}", '["x86_64-linux"]')):
                    context = {
                        "cancelled": cancelled, "needs.*.result": [upstream],
                        "inputs.build-max-jobs": cap, "inputs.build-systems": systems,
                    }
                    for name in ("build", "results", "plan-build-matrix"):
                        with self.subTest(job=name, cancelled=cancelled, upstream=upstream,
                                          cap=cap, systems=systems):
                            opted_in = cap not in ("", "{}") or bool(systems)
                            expected = not cancelled and (name != "plan-build-matrix" or opted_in)
                            self.assertEqual(evaluate(JOBS[name]["if"], context), expected)

    def test_build_and_results_stop_on_cancellation_but_accept_upstream_failure(self):
        for name in ("build", "results"):
            with self.subTest(job=name):
                # Requiring just !cancelled() also rejects success(), failure(),
                # and needs.result filters that suppress ordinary failure reports.
                self.assertEqual(expression(JOBS[name]["if"]), "!cancelled()")

    def test_opt_in_planner_stops_on_cancellation(self):
        self.assertEqual(
            expression(JOBS["plan-build-matrix"]["if"]),
            "!cancelled()&&((inputs.build-max-jobs!=''&&inputs.build-max-jobs!='{}')"
            "||inputs.build-systems!='')",
        )

    def test_no_runner_allocating_job_is_kept_alive_by_always(self):
        for name, job in JOBS.items():
            if "runs-on" in job:
                with self.subTest(job=name):
                    self.assertNotRegex(job.get("if", ""), r"\balways\s*\(")

    def test_non_cancelled_empty_matrix_retains_successful_noop(self):
        matrix = JOBS["build"]["strategy"]["matrix"]
        fallback = re.search(r"format\(\s*'([^']+)'", matrix).group(1)
        labels = ["self-hosted", "linux", "x64"]
        entry = json.loads(fallback.format(json.dumps(labels)))["include"][0]
        self.assertEqual(entry, {
            "name": "no-builds-required", "system": "x86_64-linux",
            "ghRunner": labels, "allowedToFail": False, "noop": True,
        })
        self.assertIn("toJSON(fromJSON(inputs.runners).x86_64-linux)", matrix)
        self.assertIn("matrix.ghRunner", JOBS["build"]["runs-on"])
        steps = JOBS["build"]["steps"]
        noop = next(step for step in steps if step.get("name") == "No builds required")
        self.assertEqual(expression(noop["if"]), "matrix.noop")
        for step in steps:
            if step.get("uses", "").startswith("actions/checkout@") or "Build " in step.get("name", ""):
                self.assertEqual(expression(step["if"]), "!matrix.noop")

    def test_final_results_retains_upstream_failure_reporting(self):
        reporter = next(step for step in JOBS["results"]["steps"] if step.get("run") == "exit 1")
        self.assertEqual(expression(reporter["if"]), (
            "((needs.merge-matrices.result=='success'&&"
            "needs.merge-matrices.outputs.build_matrix!='{\"include\":[]}')||"
            "needs.shard-matrix.outputs.build_matrix!='{\"include\":[]}')&&"
            "(contains(needs.*.result,'failure')||contains(needs.*.result,'cancelled'))"
        ))
        self.assertFalse(reporter.get("continue-on-error", False))
        self.assertFalse(JOBS["results"].get("continue-on-error", False))
        self.assertIn("build", JOBS["results"]["needs"])

    def test_final_results_exit_step_for_success_failure_and_cancelled_prerequisite(self):
        reporter = next(step for step in JOBS["results"]["steps"] if step.get("run") == "exit 1")
        empty = '{"include":[]}'
        nonempty = '{"include":[{"name":"package"}]}'
        for merge in ("success", "skipped", "failure"):
            for outcome in ("success", "failure", "cancelled"):
                for matrix in (empty, nonempty):
                    with self.subTest(merge=merge, outcome=outcome, matrix=matrix):
                        context = {
                            "needs.merge-matrices.result": merge,
                            "needs.merge-matrices.outputs.build_matrix": matrix,
                            "needs.shard-matrix.outputs.build_matrix": matrix,
                            "needs.*.result": [merge, outcome],
                        }
                        should_fail = matrix != empty and (
                            merge == "failure" or outcome in ("failure", "cancelled")
                        )
                        selected = evaluate(reporter["if"], context)
                        self.assertEqual(selected, should_fail)
                        if selected:
                            result = subprocess.run([os.environ.get("BASH_BIN", "bash"),
                                                     "-c", reporter["run"]], check=False)
                            self.assertEqual(result.returncode, 1)


if __name__ == "__main__":
    unittest.main()
