#!/usr/bin/env python3
"""Tests for tofu-plan-policy.py."""

import os
import subprocess
import sys

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "tofu-plan-policy.py")
CI_RUNNER = os.path.join(os.path.dirname(__file__), "..", "tofu-plan-policy-ci")
FIXTURES = os.path.join(os.path.dirname(__file__), "fixtures")


def run_policy(fixture: str, *args) -> subprocess.CompletedProcess:
    """Run the policy script with a fixture and extra args."""
    return subprocess.run(
        [sys.executable, SCRIPT, os.path.join(FIXTURES, fixture)] + list(args),
        capture_output=True,
        text=True,
    )


def run_policy_ci(fixture: str, *args) -> subprocess.CompletedProcess:
    """Run the CI adapter around the policy script."""
    return subprocess.run(
        ["bash", CI_RUNNER, SCRIPT, os.path.join(FIXTURES, fixture)] + list(args),
        capture_output=True,
        text=True,
    )


def test(name: str, result: subprocess.CompletedProcess, expected_exit: int, expected_in_output: str = ""):
    """Assert a test result."""
    passed = result.returncode == expected_exit
    if expected_in_output and expected_in_output not in result.stdout:
        passed = False

    status = "PASS" if passed else "FAIL"
    print(f"  [{status}] {name}")
    if not passed:
        print(f"         Expected exit code: {expected_exit}, got: {result.returncode}")
        if expected_in_output:
            print(f"         Expected in output: '{expected_in_output}'")
        print(f"         stdout: {result.stdout[:500]}")
        print(f"         stderr: {result.stderr[:500]}")
    return passed


def main():
    all_passed = True
    print("Running policy tests...\n")

    # Test 1: Clean import-only plan
    r = run_policy("import_only_clean.json", "--mode", "import-only", "--expected-types", "cloudflare_r2_bucket")
    all_passed &= test("Clean import-only plan passes", r, 0, "PASSED")

    # Test 2: Import with update (import-only mode)
    r = run_policy("import_with_update.json", "--mode", "import-only")
    all_passed &= test("Import with update fails in import-only mode", r, 1, "Update action")

    # Test 3: Import with update (mixed mode — should pass)
    r = run_policy("import_with_update.json", "--mode", "mixed")
    all_passed &= test("Import with update passes in mixed mode", r, 0)

    # Test 4: Duplicate imports
    r = run_policy("duplicate_import.json", "--mode", "import-only")
    all_passed &= test("Duplicate import detected", r, 1, "Duplicate import")

    # Test 5: Multiple resource types in import
    r = run_policy("multi_type_import.json", "--mode", "import-only")
    all_passed &= test("Multiple resource types rejected in import-only", r, 1, "multiple resource types")

    # Test 6: Blast radius exceeded
    r = run_policy("blast_radius_exceeded.json", "--expected-creates", "1")
    all_passed &= test("Blast radius exceeded detected", r, 1, "Blast radius exceeded")

    # Test 7: Blast radius within limits
    r = run_policy("blast_radius_exceeded.json", "--expected-creates", "3")
    all_passed &= test("Blast radius within limits passes", r, 0)

    # Test 8: Moved blocks missing (advisory warning)
    r = run_policy("moved_blocks_missing.json")
    all_passed &= test("Moved blocks missing gives advisory warning", r, 2, "moved blocks")

    # Test 9: Scope — wrong resource type
    r = run_policy("scope_wrong_type.json", "--expected-types", "cloudflare_r2_bucket")
    all_passed &= test("Wrong resource type rejected by scope check", r, 1, "unexpected resource types")

    # Test 10: Scope — expansion override
    r = run_policy("scope_wrong_type.json", "--expected-types", "cloudflare_r2_bucket", "--scope-expansion")
    all_passed &= test("Scope expansion overrides type check", r, 0)

    # Test 11: No changes plan
    r = run_policy("no_changes.json", "--mode", "import-only")
    all_passed &= test("No changes plan passes in import-only mode", r, 0)

    # Test 12: Expected types with correct types
    r = run_policy("import_only_clean.json", "--expected-types", "cloudflare_r2_bucket")
    all_passed &= test("Correct expected types passes", r, 0)

    # Test 13: Blast radius — expected resource types
    r = run_policy("scope_wrong_type.json", "--expected-resource-types", "cloudflare_r2_bucket")
    all_passed &= test("Blast radius unexpected type detected", r, 1, "unexpected resource types")

    # Test 14: CI treats documented advisory exit 2 as a successful annotation.
    r = run_policy_ci("moved_blocks_missing.json")
    all_passed &= test("CI adapter annotates advisory warnings without failing", r, 0, "::warning::")

    # Test 15: CI preserves hard policy failures.
    r = run_policy_ci("import_with_update.json", "--mode", "import-only")
    all_passed &= test("CI adapter preserves hard policy failure", r, 1, "POLICY VIOLATIONS")

    # Test 16: CI preserves clean success.
    r = run_policy_ci("no_changes.json", "--mode", "import-only")
    all_passed &= test("CI adapter preserves clean success", r, 0, "Policy check PASSED")

    print()
    if all_passed:
        print(f"All tests passed!")
        sys.exit(0)
    else:
        print(f"Some tests FAILED!")
        sys.exit(1)


if __name__ == "__main__":
    main()
