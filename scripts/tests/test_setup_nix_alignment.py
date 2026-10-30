#!/usr/bin/env python3
"""Contract tests for scripts/check-setup-nix-alignment.py.

The fixture `fixtures/setup-nix-alignment/metacraft-github-actions-setup-nix-action.yml`
is metacraft-labs/metacraft-github-actions `setup-nix/action.yml` at 063cb33,
the commit that aligned it with this repository's `.github/setup-nix`.

It is compared against THIS repository's real action, so the first test also
works as an offline drift guard from this side: change a nix.conf setting or
the preflight here and it fails until metacraft-github-actions is changed the
same way and the fixture is refreshed from it. The cross-repository check
against the other repository's live mainline runs in the
`setup-nix alignment` workflow.

Every other test mutates one thing and asserts the checker names it, so a
checker that passes everything cannot pass this suite.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
CHECKER = REPO_ROOT / "scripts/check-setup-nix-alignment.py"
FIXTURE = REPO_ROOT / "scripts/tests/fixtures/setup-nix-alignment/metacraft-github-actions-setup-nix-action.yml"
DEVOPS_SETUP_NIX = REPO_ROOT / ".github/setup-nix"


def make_mga(root: Path) -> Path:
    setup_nix = root / "setup-nix"
    (setup_nix / "tests").mkdir(parents=True)
    shutil.copyfile(FIXTURE, setup_nix / "action.yml")
    shutil.copyfile(DEVOPS_SETUP_NIX / "probe-substituters.sh", setup_nix / "probe-substituters.sh")
    shutil.copyfile(DEVOPS_SETUP_NIX / "tests/probe-substituters-test.sh", setup_nix / "tests/probe-substituters-test.sh")
    return setup_nix


def run(mga_root: Path, devops_root: Path = REPO_ROOT) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(CHECKER), "--devops-root", str(devops_root), "--mga-root", str(mga_root)],
        capture_output=True,
        text=True,
        check=False,
    )


def edit(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    assert text.count(old) == 1, f"fixture edit anchor {old!r} not unique in {path}"
    path.write_text(text.replace(old, new))


def expect_drift(name: str, mutate, needle: str) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        setup_nix = make_mga(root)
        mutate(setup_nix)
        result = run(root)
        assert result.returncode == 1, f"{name}: expected drift, got rc={result.returncode}\n{result.stdout}{result.stderr}"
        assert needle in result.stdout, f"{name}: expected {needle!r} in:\n{result.stdout}"
        print(f"ok   {name}")


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        make_mga(Path(tmp))
        result = run(Path(tmp))
        assert result.returncode == 0, (
            "this repository's setup-nix no longer matches metacraft-github-actions "
            "(as of the fixture). Change both actions and refresh the fixture:\n" + result.stdout + result.stderr
        )
        print("ok   aligned: this repo's action agrees with the metacraft-github-actions fixture")

    ttl = "narinfo-cache-negative-ttl = 0\n"
    expect_drift("negative TTL value", lambda d: edit(d / "action.yml", ttl, "narinfo-cache-negative-ttl = 120\n"), "narinfo-cache-negative-ttl differs")
    expect_drift("http2 removed", lambda d: edit(d / "action.yml", "          http2 = false\n", ""), "http2 = false is set only in devops-modules")
    expect_drift("key added on one side", lambda d: edit(d / "action.yml", ttl, ttl + "          max-jobs = 4\n"), "max-jobs = 4 is set only in metacraft-github-actions")
    expect_drift("fallback flipped", lambda d: edit(d / "action.yml", "          fallback = true\n", "          fallback = false\n"), "fallback differs")
    expect_drift(
        "substituter base changed",
        lambda d: edit(d / "action.yml", "substituters = https://cache.nixos.org $EXTRA_SUBSTITUTERS", "substituters = https://example.invalid $EXTRA_SUBSTITUTERS"),
        "substituters differs",
    )
    expect_drift("preflight default", lambda d: edit(d / "action.yml", '    default: "warn"\n', '    default: "fail"\n'), "substituter-preflight default differs")
    expect_drift("probe step removed", lambda d: edit(d / "action.yml", "    - name: Probe binary caches\n", "    - name: Probe caches later\n"), "expected exactly one 'Probe binary caches' step")
    expect_drift(
        "probe script diverged",
        lambda d: (d / "probe-substituters.sh").write_text((d / "probe-substituters.sh").read_text() + "# local tweak\n"),
        "probe-substituters.sh differs",
    )
    expect_drift("probe suite missing", lambda d: (d / "tests/probe-substituters-test.sh").unlink(), "missing setup-nix/tests/probe-substituters-test.sh")

    # Caller-supplied extras are interpolated differently on each side
    # (`${{ inputs.substituters }}` vs `$EXTRA_SUBSTITUTERS`); that alone is
    # not drift, which the aligned case above already proves.

    # The devops-modules fallback is a `${{ ... }}` ternary over its input: the
    # checker must resolve it against the input default, not compare the text.
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        make_mga(root)
        devops = root / "devops"
        shutil.copytree(DEVOPS_SETUP_NIX, devops / ".github/setup-nix", copy_function=shutil.copyfile)
        edit(devops / ".github/setup-nix/action.yml", "    default: 'true'\n  substituter-preflight:", "    default: 'false'\n  substituter-preflight:")
        result = run(root, devops)
        assert result.returncode == 1 and "fallback differs" in result.stdout, result.stdout
        print("ok   fallback input default resolved through the ternary")

    print("setup-nix alignment checker: all contracts hold.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
