"""Exercise the gate's restart paths with deterministic driver outcomes.

A fake Machine is necessary here: the real Type=simple race is explicitly
nondeterministic. It raises the driver's timeout exception on every control
start, so a hidden assertion cannot pass merely because this host won the race.
Only the restart subtests are executed; the VM check covers real systemd,
credentials, warning detection and service readiness.
"""

import ast
from contextlib import nullcontext, redirect_stdout
from io import StringIO
from pathlib import Path
import re
import sys
import textwrap
import unittest


class RequestedAssertionFailed(Exception):
    pass


class Machine:
    def __init__(self, timeout=False):
        self.timeout = timeout
        self.restarts = 0
        self.waits = 0
        self.failures = 0
        self.error = None

    def succeed(self, command):
        if command == "systemctl restart garm.service || true":
            self.restarts += 1
        return ""

    def wait_for_open_port(self, port, timeout):
        assert (port, timeout) == (9997, 120)
        self.waits += 1
        if self.error is not None:
            raise self.error
        if self.timeout:
            raise RequestedAssertionFailed("action timed out after 120 tries")

    def wait_for_unit(self, unit):
        if self.timeout:
            raise RequestedAssertionFailed("unit never became active")


source = Path(sys.argv.pop(1)).read_text()
script = source.split("testScript = ''\n", 1)[1].rsplit("          '';", 1)[0]
script = re.sub(r"\$\{lib.escapeShellArg [^\n]+", "control-warning\"", script)
script = re.sub(r"\$\{[^}]+\}", "15", textwrap.dedent(script))
tree = ast.parse(script)
helpers = [node for node in tree.body if isinstance(node, ast.FunctionDef)
           and node.name.startswith("restart_cycle")]
subtests = {node.items[0].context_expr.args[0].value: node
            for node in tree.body if isinstance(node, ast.With)}


class RestartContract(unittest.TestCase):
    def setUp(self):
        self.fixed = Machine()
        self.racy = Machine(timeout=True)
        self.env = dict(fixed=self.fixed, racy=self.racy,
                        RequestedAssertionFailed=RequestedAssertionFailed,
                        subtest=lambda name: nullcontext(),
                        credential_failures=lambda m: m.failures)
        exec(compile(ast.Module(body=helpers, type_ignores=[]), "helpers", "exec"), self.env)

    def run_subtest(self, name):
        node = subtests[name]
        exec(compile(ast.Module(body=[node], type_ignores=[]), name, "exec"), self.env)

    def test_control_timeouts_are_reported_through_all_cycles(self):
        output = StringIO()
        with redirect_stdout(output):
            self.run_subtest("the control's exposure is reported, never asserted")
        self.assertEqual(output.getvalue().count("action timed out after 120 tries"), 15)
        self.assertIn("negative control: 0 credential-setup failure line(s)", output.getvalue())
        self.assertEqual(self.racy.restarts, 15)
        self.assertEqual(self.racy.waits, 15)

    def test_initial_control_timeout_is_not_a_gate(self):
        name = next(name for name in subtests if name in (
            "both nodes start and serve", "the fixed node starts and serves"))
        self.run_subtest(name)
        initial = "the control's initial readiness is reported, never asserted"
        if initial in subtests:
            output = StringIO()
            with redirect_stdout(output):
                self.run_subtest(initial)
            self.assertIn("action timed out after 120 tries", output.getvalue())
        self.assertGreater(self.fixed.waits, 0)
        self.assertEqual(self.racy.waits, 1)
        self.assertEqual(self.racy.restarts, 1)

    def test_unexpected_control_error_is_not_swallowed(self):
        self.racy.error = RuntimeError("driver connection failed")
        with self.assertRaisesRegex(RuntimeError, "driver connection failed"):
            self.run_subtest("the control's exposure is reported, never asserted")

    def test_fixed_timeout_still_fails_the_gate(self):
        self.fixed.timeout = True
        with self.assertRaises(RequestedAssertionFailed):
            self.run_subtest("15 restarts leave the fixed unit with zero 243/CREDENTIALS")

    def test_fixed_credential_failure_still_fails_the_gate(self):
        self.fixed.failures = 1
        with self.assertRaises(AssertionError):
            self.run_subtest("15 restarts leave the fixed unit with zero 243/CREDENTIALS")


unittest.main()
