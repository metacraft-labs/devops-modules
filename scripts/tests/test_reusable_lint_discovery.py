#!/usr/bin/env python3
"""Hermetic tests for the hook-entry-point discovery in reusable-lint.yml.

The `Check formatting` step's run block is extracted verbatim from the
workflow and executed with bash against a scratch git checkout. `nix` is
replaced by a stub on PATH: it answers the two attribute-name probes from the
FAKE_SHELLS / FAKE_CHECKS environment variables, and records `develop`,
`build` and `run` invocations instead of performing them. That stub is the
only double here, and it is justified: the property under test is WHICH entry
point the step selects and how it reacts to each outcome — reproducing it for
real would need a Nix daemon, network access and one real flake per shape,
none of which exist in the Nix build sandbox this test runs in. Everything
else (bash, git, the filesystem, the step's own control flow) is real.
"""

from __future__ import annotations

import os
import shutil
import stat
import subprocess
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW_PATH = REPO_ROOT / ".github/workflows/reusable-lint.yml"
STEP_MARKER = "      - name: Check formatting"
RUN_MARKER = "        run: |"
SYSTEM = "x86_64-linux"

# The nix stub. `develop .#<shell> -c <cmd...>` runs <cmd> in a "shell": when
# the shell is listed in FAKE_HOOK_SHELLS it first writes the config (as a
# git-hooks.nix shellHook would) and puts a prek/pre-commit stub on PATH.
NIX_STUB = r"""#!/usr/bin/env bash
log() { printf '%s\n' "$*" >> "$FAKE_LOG"; }
case "$1" in
  eval)
    if [[ " $* " == *" --expr builtins.currentSystem "* ]]; then
      printf '%s' "$FAKE_SYSTEM"; exit 0
    fi
    for a in "$@"; do
      case "$a" in
        .#devShells.*) var=FAKE_SHELLS ;;
        .#checks.*) var=FAKE_CHECKS ;;
      esac
    done
    if [ -z "${!var+x}" ]; then
      echo "error: flake does not provide attribute 'x'" >&2; exit 1
    fi
    if [ "${!var}" = BROKEN ]; then
      echo "error: infinite recursion encountered" >&2; exit 1
    fi
    printf '%s' "${!var}"; exit 0 ;;
  build)
    attr=""
    for a in "$@"; do [[ "$a" == .#* ]] && attr="$a"; done
    log "build $attr"
    exit "${FAKE_BUILD_RC:-0}" ;;
  run)
    log "run ${*:2}"
    exit "${FAKE_HOOK_RC:-0}" ;;
  develop)
    shift
    shell=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -c) shift; break ;;
        .#*) shell="${1#.#}" ;;
      esac
      shift
    done
    log "develop $shell"
    if [[ " $FAKE_HOOK_SHELLS " == *" $shell "* ]]; then
      printf 'x' > "$FAKE_CONFIG_TARGET"
      ln -sf "$FAKE_CONFIG_TARGET" .pre-commit-config.yaml
      export PATH="$FAKE_RUNNER_DIR:$PATH"
    fi
    "$@"
    rc=$?
    [[ " $FAKE_HOOK_SHELLS " == *" $shell "* ]] && [ -z "${FAKE_KEEP_CONFIG:-}" ] &&
      rm -f .pre-commit-config.yaml
    exit $rc ;;
esac
echo "nix stub: unexpected invocation: $*" >&2
exit 2
"""

RUNNER_STUB = r"""#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "$FAKE_LOG"
exit "${FAKE_HOOK_RC:-0}"
"""


def extract_step_script() -> str:
    lines = WORKFLOW_PATH.read_text().splitlines()
    starts = [i for i, line in enumerate(lines) if line == STEP_MARKER]
    assert len(starts) == 1, f"expected one {STEP_MARKER!r} step, got {len(starts)}"
    run_starts = [i for i in range(starts[0], len(lines)) if lines[i] == RUN_MARKER]
    assert run_starts, "run block not found in the Check formatting step"
    body = []
    for line in lines[run_starts[0] + 1 :]:
        if not line.strip():
            body.append("")
            continue
        if len(line) - len(line.lstrip()) < 10:
            break
        body.append(line[10:])
    return "\n".join(body) + "\n"


def write_exe(path: Path, text: str) -> None:
    # No /usr/bin/env in the Nix build sandbox: pin the interpreter.
    bash = shutil.which("bash")
    assert bash, "bash not on PATH"
    path.write_text(text.replace("#!/usr/bin/env bash", f"#!{bash}", 1))
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class Harness:
    def __init__(self, root: Path, script: str) -> None:
        self.root = root
        self.bin = root / "bin"
        self.bin.mkdir()
        write_exe(self.bin / "nix", NIX_STUB)
        # A closed PATH: only the tools the step and the stubs need, so a
        # prek / pre-commit installed on the host cannot leak into a case.
        for tool in TOOLS:
            found = shutil.which(tool)
            assert found, f"required tool {tool!r} not on PATH"
            (self.bin / tool).symlink_to(found)
        self.runner_dir = root / "runner-prek"
        self.runner_dir.mkdir()
        write_exe(self.runner_dir / "prek", RUNNER_STUB)
        self.precommit_dir = root / "runner-pre-commit"
        self.precommit_dir.mkdir()
        write_exe(self.precommit_dir / "pre-commit", RUNNER_STUB)
        self.script = root / "step.sh"
        self.script.write_text(script)
        self.count = 0

    def run(
        self,
        name: str,
        *,
        shells: str | None = None,
        checks: str | None = None,
        hook_shells: str = "",
        runner: str = "prek",
        flake: bool = True,
        committed_config: bool = False,
        inputs: dict[str, str] | None = None,
        extra_env: dict[str, str] | None = None,
    ) -> tuple[int, list[str], str]:
        self.count += 1
        work = self.root / f"case{self.count}"
        work.mkdir()
        subprocess.run(["git", "init", "-q", str(work)], check=True)
        if flake:
            (work / "flake.nix").write_text("{ outputs = _: { }; }\n")
        if committed_config:
            (work / ".pre-commit-config.yaml").write_text("repos: []\n")
            subprocess.run(["git", "-C", str(work), "add", ".pre-commit-config.yaml"], check=True)
        log = self.root / f"case{self.count}.log"
        log.write_text("")
        env = {
            "PATH": str(self.bin),
            "HOME": str(self.root),
            "FAKE_LOG": str(log),
            "FAKE_SYSTEM": SYSTEM,
            "FAKE_HOOK_SHELLS": hook_shells,
            "FAKE_RUNNER_DIR": str(self.runner_dir if runner == "prek" else self.precommit_dir),
            "FAKE_CONFIG_TARGET": str(self.root / f"case{self.count}.config"),
            "LINT_SHELL": "",
            "LINT_CHECK": "",
            "LINT_COMMAND": "",
        }
        if shells is not None:
            env["FAKE_SHELLS"] = shells
        if checks is not None:
            env["FAKE_CHECKS"] = checks
        env.update(inputs or {})
        env.update(extra_env or {})
        # GitHub Actions' default shell: bash --noprofile --norc -eo pipefail
        result = subprocess.run(
            ["bash", "--noprofile", "--norc", "-eo", "pipefail", str(self.script)],
            cwd=work,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        calls = [line for line in log.read_text().splitlines() if line]
        return result.returncode, calls, result.stdout


def expect(name, got, rc, calls, contains=None):
    code, actual_calls, output = got
    assert code == rc, f"{name}: exit {code}, expected {rc}\ncalls={actual_calls}\n{output}"
    assert actual_calls == calls, f"{name}: calls {actual_calls}, expected {calls}\n{output}"
    for needle in contains or []:
        assert needle in output, f"{name}: {needle!r} not in output\n{output}"


TOOLS = ("bash", "env", "git", "grep", "mktemp", "rm", "cat", "ln", "basename")
RUN_ARGS = "run --all-files --show-diff-on-failure --color always"


def main() -> None:
    script = extract_step_script()
    with tempfile.TemporaryDirectory() as tmp:
        h = Harness(Path(tmp), script)

        # 1. Backward compatibility: a pre-commit shell wins over everything
        #    and runs exactly the original command.
        expect(
            "legacy pre-commit shell",
            h.run("legacy", shells="default pre-commit", checks="pre-commit-check",
                  hook_shells="pre-commit"),
            0,
            ["develop pre-commit", f"prek {RUN_ARGS}"],
        )
        expect(
            "legacy pre-commit shell, hooks fail",
            h.run("legacy-red", shells="pre-commit", hook_shells="pre-commit",
                  extra_env={"FAKE_HOOK_RC": "1"}),
            1,
            ["develop pre-commit", f"prek {RUN_ARGS}"],
        )

        # 2. Dev shells: hooks before lint before default; a shell without a
        #    config/runner falls through; a red hook run does NOT fall through.
        #    A hook-carrying dev shell wins over a check derivation.
        expect(
            "default shell preferred over the check",
            h.run("shell-over-check", shells="default", checks="package pre-commit-check",
                  hook_shells="default"),
            0,
            ["develop default", f"prek {RUN_ARGS}"],
            contains=["nix develop --no-write-lock-file --accept-flake-config .#default"],
        )
        expect(
            "hooks shell",
            h.run("hooks", shells="ci default hooks", checks="", hook_shells="hooks default"),
            0,
            ["develop hooks", f"prek {RUN_ARGS}"],
        )
        expect(
            "lint shell without hooks falls through to default",
            h.run("lint", shells="ci default lint", checks="", hook_shells="default"),
            0,
            ["develop lint", "develop default", f"prek {RUN_ARGS}"],
        )
        expect(
            "default shell with pre-commit (not prek)",
            h.run("default-pc", shells="default", hook_shells="default", runner="pre-commit"),
            0,
            ["develop default", f"pre-commit {RUN_ARGS}"],
        )
        expect(
            "red hooks in a shell do not fall through",
            h.run("red", shells="hooks default", hook_shells="hooks default",
                  checks="pre-commit-check", extra_env={"FAKE_HOOK_RC": "1"}),
            1,
            ["develop hooks", f"prek {RUN_ARGS}"],
        )

        # 3. git-hooks.nix checks when no shell carries the hooks,
        #    pre-commit-check preferred over pre-commit.
        expect(
            "check pre-commit-check after a hookless default shell",
            h.run("chk", shells="default", checks="package pre-commit pre-commit-check"),
            0,
            ["develop default", f"build .#checks.{SYSTEM}.pre-commit-check"],
            contains=["nix build -L --no-link --no-write-lock-file"],
        )
        expect(
            "check pre-commit",
            h.run("chk2", shells="", checks="package pre-commit"),
            0,
            [f"build .#checks.{SYSTEM}.pre-commit"],
        )
        expect(
            "check red propagates",
            h.run("chk3", checks="pre-commit-check", extra_env={"FAKE_BUILD_RC": "1"}),
            1,
            [f"build .#checks.{SYSTEM}.pre-commit-check"],
        )

        # 4. Committed config with no usable flake entry point.
        expect(
            "committed config, no flake",
            h.run("nofl", flake=False, committed_config=True),
            0,
            [f"run --accept-flake-config nixpkgs#prek -- {RUN_ARGS}"],
        )
        expect(
            "committed config, shell lacks runner",
            h.run("cfg", shells="default", committed_config=True),
            0,
            ["develop default", f"run --accept-flake-config nixpkgs#prek -- {RUN_ARGS}"],
        )

        # 5. Nothing found: a clear failure, never a silent pass.
        expect(
            "nothing found",
            h.run("none", shells="default", checks="package"),
            1,
            ["develop default"],
            contains=["::error title=reusable-lint::no hook entry point found",
                      f"checks.{SYSTEM}.pre-commit-check"],
        )
        expect(
            "no flake, no config",
            h.run("empty", flake=False),
            1,
            [],
            contains=["no hook entry point found", "no flake.nix"],
        )
        expect(
            "eval error is surfaced, then fails clearly",
            h.run("broken", shells="BROKEN", checks="BROKEN"),
            1,
            [],
            contains=["::warning title=reusable-lint::evaluating .#devShells",
                      "infinite recursion", "no hook entry point found"],
        )

        # 6. Explicit overrides.
        expect(
            "check input",
            h.run("in-check", shells="pre-commit", inputs={"LINT_CHECK": "lint-hooks"}),
            0,
            [f"build .#checks.{SYSTEM}.lint-hooks"],
        )
        expect(
            "shell input",
            h.run("in-shell", shells="pre-commit default", hook_shells="default",
                  inputs={"LINT_SHELL": "default"}),
            0,
            ["develop default", f"prek {RUN_ARGS}"],
        )
        expect(
            "shell input without an entry point fails clearly",
            h.run("in-shell-bad", shells="lint", inputs={"LINT_SHELL": "lint"}),
            1,
            ["develop lint"],
            contains=["provides no hook entry point"],
        )
        expect(
            "shell + command input",
            h.run("in-shell-cmd", inputs={"LINT_SHELL": "lint",
                                          "LINT_COMMAND": 'echo "custom $0" >> "$FAKE_LOG"'}),
            0,
            ["develop lint", "custom bash"],
        )
        expect(
            "command input alone runs in the checkout",
            h.run("in-cmd", shells="pre-commit",
                  inputs={"LINT_COMMAND": 'echo custom-only >> "$FAKE_LOG"; exit 3'}),
            3,
            ["custom-only"],
        )
        expect(
            "check + shell is rejected",
            h.run("in-both", inputs={"LINT_CHECK": "a", "LINT_SHELL": "b"}),
            1,
            [],
            contains=["at most one of the 'check' and 'shell' inputs"],
        )
        expect(
            "check + command is rejected",
            h.run("in-both2", inputs={"LINT_CHECK": "a", "LINT_COMMAND": "true"}),
            1,
            [],
            contains=["'command' cannot be combined with 'check'"],
        )

    print(f"reusable-lint discovery: {h.count} cases passed")


if __name__ == "__main__":
    main()
