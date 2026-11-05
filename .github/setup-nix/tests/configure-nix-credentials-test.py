#!/usr/bin/env python3
"""Contract suite for the "Configure Nix" step's credentials and caches.

No mocks. The real step body is taken from action.yml, its `${{ }}`
expressions are rendered with fixed inputs (the only thing the runner would do
to it), and it is executed with bash against an isolated HOME, RUNNER_TEMP and
system nix.conf directory. What the step achieved is then read back from the
REAL Nix configuration parser (`nix config show`), not from the files.

It pins, each with the defect it prevents:

  * no token is written into $HOME (persistent runners carried a dead token
    into later jobs: codetracer-launcher job 126423778474), and none into the
    rendered script body;
  * the host's own substituters and keys stay in effect (a replacing
    `substituters =` dropped the host's cache: nim-agents job 126423740106);
  * without an attic-token the host's netrc-file stays in force (it holds the
    host's cache pull token); with one, the job's netrc is used;
  * once the runner empties RUNNER_TEMP, no setting names a credential.

Credentials are inert sentinels; nothing touches the network.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ACTION = HERE.parent / "action.yml"
NIX = shutil.which("nix")
if not NIX:
    sys.exit("configure-nix-credentials-test: nix is required for the real parser controls")

failures = 0


def check(name: str, ok: bool, detail: str = "") -> None:
    global failures
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f" -- {detail}"))
    if not ok:
        failures += 1


def step_body() -> str:
    text = ACTION.read_text()
    marker = "    - name: Configure Nix\n"
    assert text.count(marker) == 1, "exactly one 'Configure Nix' step"
    step = text.split(marker, 1)[1].split("\n    - name:", 1)[0]
    lines = step.split("      run: |\n", 1)[1].split("\n")
    body = []
    for line in lines:
        if line.strip() and not line.startswith("        "):
            break
        body.append(line[8:])
    return "\n".join(body)


def render(body: str, substituters: str, keys: str) -> str:
    values = {
        r"\$\{\{ github\.action_path \}\}": str(HERE.parent),
        r"\$\{\{ steps\.check-nix\.outputs\.symlinked_store \}\}": "false",
        r"\$\{\{ inputs\.fallback == 'false' && 'false' \|\| 'true' \}\}": "true",
        r"\$\{\{ inputs\.experimental-features \}\}": "nix-command flakes",
        r"\$\{\{inputs\.substituters\}\}": substituters,
        r"\$\{\{inputs\.trusted-public-keys\}\}": keys,
    }
    for pattern, value in values.items():
        body = re.sub(pattern, lambda _m, v=value: v, body)
    left = re.findall(r"\$\{\{.*?\}\}", body, flags=re.S)
    assert not left, f"unrendered expressions in the step body: {left}"
    return body


def show(env: dict, name: str):
    out = subprocess.check_output(
        [NIX, "--extra-experimental-features", "nix-command", "config", "show", "--json"],
        env=env, text=True, stderr=subprocess.DEVNULL,
    )
    return json.loads(out)[name]["value"]


HOST_CONF = (
    "substituters = https://host.example/cache https://cache.nixos.org/\n"
    "trusted-public-keys = host:BBBB cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=\n"
    "netrc-file = {netrc}\n"
)


def run(case: str, attic: bool) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        home, runner_temp, system = root / "home", root / "runner-temp", root / "system"
        for d in (home, runner_temp, system):
            d.mkdir()
        host_netrc = system / "netrc"
        host_netrc.write_text("machine cache.example.com password host-pull-sentinel\n")
        (system / "nix.conf").write_text(HOST_CONF.format(netrc=host_netrc))
        # What an earlier job left in this runner's persistent HOME.
        (home / ".config/nix").mkdir(parents=True)
        (home / ".config/nix/netrc").write_text("machine github.com login x password leaked-sentinel\n")
        job_env = root / "github-env"
        job_env.write_text("")
        env = {
            "PATH": os.environ["PATH"],
            "HOME": str(home),
            "XDG_CONFIG_HOME": str(home / ".config"),
            "XDG_CONFIG_DIRS": str(root / "no-xdg"),
            "NIX_CONF_DIR": str(system),
            "RUNNER_TEMP": str(runner_temp),
            "GITHUB_ENV": str(job_env),
            "SETUP_NIX_GITHUB_TOKEN": "job-gh-sentinel",
            "SETUP_NIX_GITLAB_TOKEN": "",
            "SETUP_NIX_GITLAB_DOMAIN": "",
            "SETUP_NIX_ATTIC_TOKEN": "job-attic-sentinel" if attic else "",
            "SETUP_NIX_ATTIC_ENDPOINT": "https://cache.example.com/" if attic else "",
            "SETUP_NIX_SUBSTITUTERS": "https://cache.example.com/private",
        }
        body = render(step_body(), "https://cache.example.com/private", "private:AAAA")
        check(f"{case}: no token in the rendered script", "job-gh-sentinel" not in body)
        proc = subprocess.run(["bash", "-e", "-c", body], env=env, capture_output=True, text=True)
        check(f"{case}: the step succeeds", proc.returncode == 0, proc.stdout + proc.stderr)
        if proc.returncode != 0:
            return
        conf = (home / ".config/nix/nix.conf").read_text()
        check(f"{case}: no token in HOME nix.conf", "job-gh-sentinel" not in conf)
        check(f"{case}: HOME netrc emptied", (home / ".config/nix/netrc").read_text() == "")
        dir_ = Path(re.search(r"^MCL_JOB_CREDENTIALS_DIR=(.*)$", job_env.read_text(), re.M).group(1))
        check(f"{case}: job directory is private", (dir_.stat().st_mode & 0o077) == 0)
        tokens = show(env, "access-tokens")
        check(f"{case}: the job token is in effect", tokens.get("github.com") == "job-gh-sentinel", str(tokens.keys()))
        subs = show(env, "substituters")
        check(f"{case}: the host cache is kept", "https://host.example/cache" in subs, str(subs))
        check(f"{case}: the declared cache is added", "https://cache.example.com/private" in subs, str(subs))
        keys = show(env, "trusted-public-keys")
        check(f"{case}: host and declared keys both trusted", "host:BBBB" in keys and "private:AAAA" in keys, str(keys))
        netrc = show(env, "netrc-file")
        if attic:
            check(f"{case}: the job netrc is in force", netrc == str(dir_ / "netrc"), netrc)
            check(f"{case}: it carries the attic credential",
                  "job-attic-sentinel" in (dir_ / "netrc").read_text())
        else:
            check(f"{case}: the host netrc stays in force", netrc == str(host_netrc), netrc)
        shutil.rmtree(dir_)
        check(f"{case}: no token once RUNNER_TEMP is emptied", "github.com" not in show(env, "access-tokens"))
        check(f"{case}: no setting names the deleted directory", not show(env, "netrc-file").startswith(str(dir_)))


run("without attic-token", attic=False)
run("with attic-token", attic=True)
print(f"configure-nix-credentials-test: {'FAILED' if failures else 'all contracts hold'} ({failures} failure(s))")
sys.exit(1 if failures else 0)
