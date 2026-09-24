#!/usr/bin/env python3
"""Hermetic tests for reusable-lint.yml's pre-hook steps.

Each step's run block is extracted verbatim from the workflow and executed
with bash against scratch git checkouts.

`Check formatting` (hook-entry-point discovery): `nix` is replaced by a stub
on PATH that answers the two attribute-name probes from the FAKE_SHELLS /
FAKE_CHECKS environment variables, and records `develop`, `build` and `run`
invocations instead of performing them.

`Materialize the develop set`: `repro` is replaced by a stub that prints a
canned `repro develop --all --dry-run --json` document (and `nix build`, when
the step has to install repro, by the same nix stub printing the stub's
directory). Everything the step DOES with that answer is real: the sibling
"remotes" are real git repositories reached over file://, and the test checks
that each sibling lands on the exact locked commit — deliberately NOT the
branch tip — and that no credential is persisted into any .git/config.

`Initialize submodules`: no double at all — a real superproject with a real
submodule over file://.

The two stubs are the only doubles, and they are justified: the real `nix`
needs a daemon, network access and one real flake per shape, and the real
`repro` is built from a flake input fetched over the network; none of that
exists in the Nix build sandbox this test runs in. The property under test is
how each step reacts to what those tools answer, which the stubs pin exactly.
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
        .*#devShells.*) var=FAKE_SHELLS ;;
        .*#checks.*) var=FAKE_CHECKS ;;
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
    if [[ " $* " == *" --print-out-paths "* ]]; then
      log "build-repro"
      [ -n "${FAKE_REPRO_OUT:-}" ] || exit 1
      printf '%s\n' "$FAKE_REPRO_OUT"; exit 0
    fi
    attr=""
    for a in "$@"; do [[ "$a" == .*#* ]] && attr="$a"; done
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
        .*#*) shell="${1#*#}" ;;
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


def extract_step_script(marker: str = STEP_MARKER) -> str:
    lines = WORKFLOW_PATH.read_text().splitlines()
    starts = [i for i, line in enumerate(lines) if line == marker]
    assert len(starts) == 1, f"expected one {marker!r} step, got {len(starts)}"
    run_starts = [i for i in range(starts[0], len(lines)) if lines[i] == RUN_MARKER]
    assert run_starts, f"run block not found in {marker!r}"
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
        gitmodules: bool = False,
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
        if gitmodules:
            (work / ".gitmodules").write_text('[submodule "x"]\n\tpath = x\n\turl = ../x\n')
            subprocess.run(["git", "-C", str(work), "add", ".gitmodules"], check=True)
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

        # 5b. Submodules: the flake is evaluated WITH them once initialized,
        #     otherwise a flake reading one cannot evaluate; `off` keeps `.`.
        expect(
            "tracked .gitmodules evaluates the flake with submodules",
            h.run("sub", shells="default", hook_shells="default", gitmodules=True),
            0,
            ["develop default", f"prek {RUN_ARGS}"],
            contains=["--accept-flake-config .?submodules=1#default"],
        )
        expect(
            "submodules off keeps the plain flake ref",
            h.run("sub-off", shells="pre-commit", hook_shells="pre-commit", gitmodules=True,
                  extra_env={"LINT_SUBMODULES": "off"}),
            0,
            ["develop pre-commit", f"prek {RUN_ARGS}"],
            contains=["--accept-flake-config .#pre-commit"],
        )
        expect(
            "submodule-aware check",
            h.run("sub-chk", checks="pre-commit-check", gitmodules=True),
            0,
            [f"build .?submodules=1#checks.{SYSTEM}.pre-commit-check"],
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
    test_develop_set()
    test_submodules()


# ---------------------------------------------------------------------------
# `Materialize the develop set` and `Initialize submodules`
# ---------------------------------------------------------------------------

DEVSET_MARKER = "      - name: Materialize the develop set"
SUBMODULE_MARKER = "      - name: Initialize submodules"
STEP_TOOLS = ("bash", "env", "git", "grep", "mktemp", "rm", "cat", "base64", "tr", "sh")
TOKEN = "test-token-value"

# `repro develop --all --dry-run --json` stand-in: logs its argv, prints the
# document in $FAKE_REPRO_JSON, exits $FAKE_REPRO_RC.
REPRO_STUB = r"""#!/usr/bin/env bash
printf 'repro %s\n' "$*" >> "$FAKE_LOG"
cat "$FAKE_REPRO_JSON"
exit "${FAKE_REPRO_RC:-0}"
"""


def git(*args: str, cwd: Path | None = None) -> str:
    env = {
        "PATH": os.environ["PATH"],
        "HOME": os.environ.get("HOME", "/tmp"),
        "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
        "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "protocol.file.allow",
        "GIT_CONFIG_VALUE_0": "always",
    }
    return subprocess.run(["git", *args], cwd=cwd, env=env, check=True, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.strip()


def make_remote(path: Path, commits: int = 2) -> list[str]:
    """A real repo with `commits` commits; returns their SHAs, oldest first."""
    git("init", "-q", "-b", "dev", str(path))
    shas = []
    for i in range(commits):
        (path / "file.txt").write_text(f"v{i}\n")
        git("add", "file.txt", cwd=path)
        git("commit", "-q", "-m", f"c{i}", cwd=path)
        shas.append(git("rev-parse", "HEAD", cwd=path))
    return shas


def lock_text(entries: list[tuple[str, str, str, str]]) -> str:
    """entries: (name, path, url, revision); the first is the root."""
    deps = ", ".join(
        f'{{ name = "{n}", path = "{p}", coord_kind = "vcs", url = "{u}", '
        f'ref = "never-pushed", revision = "{r}", integrity = "git-sha1:{r}", '
        f'version = "", visibility = "public", participation = "", depends = "", groups = "" }}'
        for n, p, u, r in entries)
    return ('schema = "reprobuild.solved-graph-lock.v2"\n\n[lock]\nplatform = "amd64-linux"\n'
            'packages = [{ name = "decoy", version = "1", source = "decoy" }]\n'
            f"deps = [{deps}]\n")


def develop_json(nodes: list[tuple[str, str, str, bool]], exit_code: int = 0) -> str:
    """The shape `repro develop --all --dry-run --json` pretty-prints."""
    items = []
    for name, path, rev, ok in nodes:
        items.append(
            "    {\n"
            f'      "node": "{name}",\n'
            f'      "path": "{path}",\n'
            f'      "revision": "{rev}",\n'
            '      "mode": "would-clone",\n'
            f'      "ok": {"true" if ok else "false"}\n'
            "    }")
    nodes_txt = ("[\n" + ",\n".join(items) + "\n  ]") if items else "[]"
    return ("{\n"
            '  "schemaId": "reprobuild.develop-all.v1",\n'
            '  "workspaceRoot": "/x",\n'
            f'  "nodes": {nodes_txt},\n'
            '  "notices": [],\n'
            '  "backends": [\n    {\n      "tier": "public",\n      "repos": []\n    }\n  ],\n'
            f'  "exitCode": {exit_code}\n'
            "}\n")


class StepHarness:
    def __init__(self, root: Path, marker: str) -> None:
        self.root = root / marker.split("name: ")[1].replace(" ", "-")
        self.root.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        write_exe(self.bin / "nix", NIX_STUB)
        for tool in STEP_TOOLS:
            found = shutil.which(tool)
            assert found, f"required tool {tool!r} not on PATH"
            (self.bin / tool).symlink_to(found)
        self.repro_dir = self.root / "repro-pkg" / "bin"
        self.repro_dir.mkdir(parents=True)
        write_exe(self.repro_dir / "repro", REPRO_STUB)
        self.script = self.root / "step.sh"
        self.script.write_text(extract_step_script(marker))
        self.count = 0

    def case(self) -> Path:
        self.count += 1
        base = self.root / f"case{self.count}"
        base.mkdir()
        return base

    def run(self, work: Path, *, env: dict[str, str], repro_on_path: bool = True,
            json_doc: str | None = None) -> tuple[int, list[str], str]:
        log = work.parent / "calls.log"
        log.write_text("")
        doc = work.parent / "develop.json"
        doc.write_text(json_doc or "")
        path = str(self.bin)
        if repro_on_path:
            path = f"{self.repro_dir}:{path}"
        full = {
            "PATH": path,
            "HOME": str(self.root),
            "FAKE_LOG": str(log),
            "FAKE_REPRO_JSON": str(doc),
            "FAKE_REPRO_OUT": str(self.repro_dir.parent),
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "protocol.file.allow",
            "GIT_CONFIG_VALUE_0": "always",
            "LINT_GIT_TOKEN": TOKEN,
            "LINT_REPRO_FLAKE": "github:example/devops-modules/dev",
        }
        full.update(env)
        result = subprocess.run(
            ["bash", "--noprofile", "--norc", "-eo", "pipefail", str(self.script)],
            cwd=work, env=full, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        calls = [line for line in log.read_text().splitlines() if line]
        return result.returncode, calls, result.stdout


def check(name: str, got, rc: int, contains=(), calls=None) -> None:
    code, actual_calls, output = got
    assert code == rc, f"{name}: exit {code}, expected {rc}\ncalls={actual_calls}\n{output}"
    if calls is not None:
        assert actual_calls == calls, f"{name}: calls {actual_calls}, expected {calls}\n{output}"
    for needle in contains:
        assert needle in output, f"{name}: {needle!r} not in output\n{output}"
    assert TOKEN not in output, f"{name}: the raw token leaked into the log\n{output}"


def assert_no_persisted_credential(repo: Path) -> None:
    config = (repo / ".git" / "config").read_text()
    assert "extraheader" not in config.lower() and TOKEN not in config, \
        f"credential persisted in {repo}/.git/config:\n{config}"


DRY_RUN = "repro develop --all --dry-run --json"


def test_develop_set() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        h = StepHarness(Path(tmp), DEVSET_MARKER)
        auto = {"LINT_DEVELOP_SET": "auto"}

        def workspace(with_siblings: bool = True):
            base = h.case()
            a = make_remote(base / "remotes" / "sib-a")
            b = make_remote(base / "remotes" / "sib-b")
            work = base / "ws" / "host"
            git("init", "-q", str(work))
            entries = [("host", ".", "https://example.invalid/host", "0" * 40)]
            if with_siblings:
                entries += [
                    ("sib-a", "../sib-a", f"file://{base}/remotes/sib-a", a[0]),
                    ("sib-b", "../sib-b", f"file://{base}/remotes/sib-b", b[0]),
                ]
            (work / "repro.lock").write_text(lock_text(entries))
            nodes = [("sib-a", str(base / "ws" / "sib-a"), a[0], True),
                     ("sib-b", str(base / "ws" / "sib-b"), b[0], True)]
            return base, work, a, b, nodes

        # No lock / root-only lock: nothing is installed, nothing is cloned.
        base = h.case()
        work = base / "host"
        git("init", "-q", str(work))
        check("no repro.lock", h.run(work, env=auto), 0,
              contains=["no repro.lock"], calls=[])
        base, work, a, b, nodes = workspace(with_siblings=False)
        check("root-only lock", h.run(work, env=auto, repro_on_path=False), 0,
              contains=["pins no sibling"], calls=[])

        # The happy path: every sibling lands on the LOCKED commit, which is
        # deliberately not its remote's tip, with no credential persisted.
        base, work, a, b, nodes = workspace()
        check("siblings materialized", h.run(work, env=auto, json_doc=develop_json(nodes)), 0,
              contains=["materialized 2 develop-set sibling(s)", "::add-mask::"],
              calls=[DRY_RUN])
        for name, shas in (("sib-a", a), ("sib-b", b)):
            sib = base / "ws" / name
            assert git("rev-parse", "HEAD", cwd=sib) == shas[0] != shas[1], name
            assert_no_persisted_credential(sib)
        assert (work / "repro.lock").exists()

        # Re-running over existing checkouts (a persistent runner) re-pins them.
        (base / "ws" / "sib-a" / "stray").write_text("x")
        check("rerun over existing checkouts", h.run(work, env=auto, json_doc=develop_json(nodes)),
              0, contains=["materialized 2"])
        assert not (base / "ws" / "sib-a" / "stray").exists()

        # A sibling's own submodules are initialized (unless submodules: off).
        base, work, a, b, nodes = workspace()
        vendor = make_remote(base / "remotes" / "vendor", commits=1)
        sib_a = base / "remotes" / "sib-a"
        git("submodule", "add", "-q", f"file://{base}/remotes/vendor", "third_party/v", cwd=sib_a)
        git("commit", "-q", "-m", "vendor", cwd=sib_a)
        a_with_sub = git("rev-parse", "HEAD", cwd=sib_a)
        (work / "repro.lock").write_text(lock_text([
            ("host", ".", "https://example.invalid/host", "0" * 40),
            ("sib-a", "../sib-a", f"file://{sib_a}", a_with_sub),
        ]))
        one = [("sib-a", str(base / "ws" / "sib-a"), a_with_sub, True)]
        check("sibling submodules off", h.run(work, env={**auto, "LINT_SUBMODULES": "off"},
                                              json_doc=develop_json(one)), 0,
              contains=["materialized 1"])
        assert not (base / "ws" / "sib-a" / "third_party" / "v" / "file.txt").exists()
        check("sibling submodules initialized", h.run(work, env=auto, json_doc=develop_json(one)),
              0, contains=["materialized 1"])
        sub = base / "ws" / "sib-a" / "third_party" / "v"
        assert git("rev-parse", "HEAD", cwd=sub) == vendor[0]
        assert_no_persisted_credential(base / "ws" / "sib-a")

        # repro absent from PATH: installed through nix from the pinned flake.
        base, work, a, b, nodes = workspace()
        check("repro installed via nix",
              h.run(work, env=auto, repro_on_path=False, json_doc=develop_json(nodes)), 0,
              contains=["materialized 2"], calls=["build-repro", DRY_RUN])

        # Failures are loud and leave nothing half-done behind them.
        base, work, a, b, nodes = workspace()
        check("repro reports an error",
              h.run(work, env=auto, json_doc=develop_json(nodes, exit_code=1)), 1,
              contains=["::error title=reusable-lint develop-set::repro could not resolve"])
        check("repro process fails",
              h.run(work, env={**auto, "FAKE_REPRO_RC": "2"}, json_doc=develop_json(nodes)), 1,
              contains=["repro could not resolve"])
        check("unparseable repro output", h.run(work, env=auto, json_doc="garbage\n"), 1,
              contains=["repro could not resolve"])
        check("repro resolves nothing", h.run(work, env=auto, json_doc=develop_json([])), 1,
              contains=["pins 2 sibling(s) but repro resolved none"])
        bad = [(n, p, r, False) if n == "sib-b" else (n, p, r, ok) for n, p, r, ok in nodes]
        check("node rejected", h.run(work, env=auto, json_doc=develop_json(bad)), 1,
              contains=["repro rejected develop-set node 'sib-b'"])
        short = [(n, p, r[:12], ok) for n, p, r, ok in nodes]
        check("abbreviated revision", h.run(work, env=auto, json_doc=develop_json(short)), 1,
              contains=["not pinned to an exact 40-hex revision"])
        ghost = [(n, p, "f" * 40, ok) for n, p, r, ok in nodes]
        check("unfetchable revision", h.run(work, env=auto, json_doc=develop_json(ghost)), 1,
              contains=["could not fetch 'sib-a'"])
        unknown = [("sib-z", str(base / "ws" / "sib-z"), a[0], True)]
        check("node missing from the lock", h.run(work, env=auto, json_doc=develop_json(unknown)), 1,
              contains=["'sib-z' has no deps entry in repro.lock"])

        base, work, a, b, nodes = workspace()
        occupied = base / "ws" / "sib-a"
        occupied.mkdir()
        (occupied / "keep").write_text("mine")
        check("occupied non-git path", h.run(work, env=auto, json_doc=develop_json(nodes)), 1,
              contains=["exists and is not a git checkout"])
        assert (occupied / "keep").read_text() == "mine"

        # Opt-out and input validation.
        check("develop-set off", h.run(work, env={"LINT_DEVELOP_SET": "off"}), 0,
              contains=["develop-set: off"], calls=[])
        check("bad develop-set value", h.run(work, env={"LINT_DEVELOP_SET": "yes"}), 1,
              contains=["'develop-set' must be auto or off"], calls=[])
    print(f"reusable-lint develop-set: {h.count} workspaces passed")


def test_submodules() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        h = StepHarness(Path(tmp), SUBMODULE_MARKER)
        auto = {"LINT_SUBMODULES": "auto"}

        base = h.case()
        work = base / "plain"
        git("init", "-q", str(work))
        check("no .gitmodules", h.run(work, env=auto), 0, contains=["no tracked .gitmodules"])

        # A real superproject with a nested submodule, cloned fresh (as
        # actions/checkout leaves it: submodules registered, not populated).
        base = h.case()
        inner = make_remote(base / "inner", commits=1)
        lib = make_remote(base / "lib", commits=1)
        git("submodule", "add", "-q", f"file://{base}/inner", "vendor/inner", cwd=base / "lib")
        git("commit", "-q", "-m", "nest", cwd=base / "lib")
        sup = base / "super"
        make_remote(sup, commits=1)
        git("submodule", "add", "-q", f"file://{base}/lib", "libs/lib", cwd=sup)
        git("commit", "-q", "-m", "sub", cwd=sup)
        work = base / "checkout"
        git("clone", "-q", f"file://{sup}", str(work))
        assert not (work / "libs" / "lib" / "file.txt").exists()
        check("submodules initialized recursively", h.run(work, env=auto), 0,
              contains=["git submodule update --init --recursive", "::add-mask::"])
        assert (work / "libs" / "lib" / "file.txt").exists()
        assert (work / "libs" / "lib" / "vendor" / "inner" / "file.txt").exists()
        assert git("rev-parse", "HEAD", cwd=work / "libs" / "lib" / "vendor" / "inner") == inner[0]
        assert_no_persisted_credential(work)
        assert "extraheader" not in git("config", "--list", "--show-origin",
                                         cwd=work / "libs" / "lib").lower()
        del lib

        base = h.case()
        work2 = base / "c2"
        git("clone", "-q", f"file://{sup}", str(work2))
        check("submodules off", h.run(work2, env={"LINT_SUBMODULES": "off"}), 0,
              contains=["submodules: off"])
        assert not (work2 / "libs" / "lib" / "file.txt").exists()
        check("bad submodules value", h.run(work2, env={"LINT_SUBMODULES": "always"}), 1,
              contains=["'submodules' must be auto or off"])
    print(f"reusable-lint submodules: {h.count} checkouts passed")


if __name__ == "__main__":
    main()
