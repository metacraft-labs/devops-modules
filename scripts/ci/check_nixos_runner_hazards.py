#!/usr/bin/env python3
"""Flag workflow steps that cannot work on the self-hosted NixOS Linux runners.

Why this exists
---------------
The self-hosted Linux runners (the persistent ``github-runner`` services on the
NixOS hosts and the ephemeral garm/Incus runners) are NixOS. There is no
``/bin/bash``, no FHS ``/usr/bin`` toolchain, no dynamic loader at the glibc
path, no ``apt-get``, and no usable ``sudo``. The job PATH carries Nix and a
small set of base tools; everything else comes from Nix (``nix shell``,
``nix run``, ``nix develop``, or the shared ``setup-nix`` action's dev shell).

Steps written for GitHub-hosted Ubuntu fail there before doing anything, and
several kinds of failure are SILENT: a diagnostic or clean-up command followed
by ``|| true`` reports success, and a link or lint job whose action never
started looks the same as one that ran nothing because nothing was wrong.
The 2026-10-06 audit found, among others:

* ``lycheeverse/lychee-action`` and ``jiro4989/setup-nim-action`` -- the
  entrypoint scripts start with ``#!/bin/bash`` ("bad interpreter");
* ``DeterminateSystems/magic-nix-cache-action`` -- the cache restore pipes
  through ``xz``, which is not on the PATH;
* ``actions/setup-node`` / ``setup-dotnet`` and similar -- they download a
  glibc binary that cannot start ("Could not start dynamically linked
  executable");
* ``sudo apt-get install ...`` steps.

What it flags
-------------
Only jobs whose resolved ``runs-on`` is a self-hosted Linux label set (it
contains ``self-hosted`` and ``linux`` or ``nixos``, and no Windows/macOS
label) are checked. Dynamic ``runs-on`` expressions are skipped, as in the
sibling ``check_over_constrained_runs_on.py``.

* NRH1 -- ``uses:`` an action from ``HAZARDOUS_ACTIONS``;
* NRH2 -- a ``run:`` step that installs with a distro package manager
  (``apt-get install``, ``sudo apt update`` ...);
* NRH3 -- a step whose ``shell:`` is an absolute FHS path (``/bin/bash`` ...);
* NRH4 -- a job ``container:``/``services:`` or a ``docker://`` step: the
  runner starts those with the ``docker`` CLI, which the NixOS runners do not
  have ("docker: command not found"). Steps inside a ``container:`` job are
  then not checked for NRH2, since they would run in the container image.

Suppressing a finding
---------------------
A job that genuinely works (for example a step guarded to run only on a
non-NixOS leg) declares it with a file-scoped comment naming the action or the
rule::

    # nixos-runner-ok: actions/setup-node (leg runs only on the macOS runner)
    # nixos-runner-ok: NRH2 (apt-get runs inside the ubuntu container image)

Exit status is 1 when any finding remains (0 with ``--warn``, which prints
GitHub ``::warning`` annotations instead of failing).

No mock objects: a pure text/AST checker over real workflow files.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

import yaml

# Action (owner/repo[/path], no ref) -> why it cannot run on a NixOS runner and
# what to use instead.
HAZARDOUS_ACTIONS: dict[str, str] = {
    "lycheeverse/lychee-action": "entrypoint.sh starts with #!/bin/bash and downloads a glibc lychee; use `nix shell nixpkgs#lychee -c lychee ...`",
    "jiro4989/setup-nim-action": "install_nim.sh starts with #!/bin/bash; use `nix shell nixpkgs#nim ...` or the repo dev shell",
    "DeterminateSystems/magic-nix-cache-action": "restores through `xz`, which is not on the runner PATH; Nix is already present, use metacraft-labs/devops-modules/.github/setup-nix",
    "DeterminateSystems/nix-installer-action": "Nix is already installed and the installer needs root; use metacraft-labs/devops-modules/.github/setup-nix",
    "actions/setup-node": "downloads a glibc node that cannot start; use `nix shell nixpkgs#nodejs_22 ...` or the repo dev shell",
    "actions/setup-python": "downloads a glibc CPython that cannot start; use `nix shell nixpkgs#python3 ...` or the repo dev shell",
    "actions/setup-dotnet": "downloads a glibc dotnet that cannot start; use dotnet from nixpkgs or the repo dev shell",
    "actions/setup-java": "downloads a glibc JDK that cannot start; use a JDK from nixpkgs or the repo dev shell",
    "ruby/setup-ruby": "downloads a glibc Ruby that cannot start; use ruby from nixpkgs or the repo dev shell",
    "erlef/setup-beam": "downloads glibc Erlang/Elixir builds; use beam packages from nixpkgs",
    "shivammathur/setup-php": "installs PHP with apt; use php from nixpkgs",
    "browser-actions/setup-firefox": "downloads a glibc Firefox; use firefox from nixpkgs",
    "foundry-rs/foundry-toolchain": "downloads glibc foundry binaries; use foundry from nixpkgs or the repo dev shell",
}

# Distro package managers. Bare `sudo` is NOT flagged: the ephemeral Incus
# runners grant passwordless sudo and some self-tests prove exactly that.
RUN_HAZARD = re.compile(
    r"(?:^|[\s;&|(`])(apt-get|apt|yum|dnf|apk|zypper|pacman)\s+(?:-\S+\s+)*(install|update|upgrade|add|-S)\b",
    re.MULTILINE,
)
# A step guarded to a non-Linux leg of a mixed matrix is not run on NixOS.
NON_LINUX_IF = re.compile(r"runner\.os\s*==\s*'(macOS|Windows)'|matrix\.os\s*==\s*'(macos|windows)", re.I)
EXPR = re.compile(r"\$\{\{")
MATRIX_REF = re.compile(r"^\$\{\{\s*matrix\.([A-Za-z0-9_-]+)\s*\}\}$")
SUPPRESS = re.compile(r"#\s*nixos-runner-ok:\s*(\S+)")
NON_LINUX = {"windows", "macos", "macOS", "darwin", "osx"}


def _as_list(v) -> list:
    if v is None:
        return []
    return v if isinstance(v, list) else [v]


def _label_sets(job: dict) -> list[list[str]]:
    """Concrete runs-on label sets of a job; dynamic expressions yield none."""
    runs_on = job.get("runs-on")
    if isinstance(runs_on, dict):
        return [[str(x) for x in _as_list(runs_on.get("labels"))]]
    labels = [str(x) for x in _as_list(runs_on)]
    if len(labels) == 1 and MATRIX_REF.match(labels[0]):
        key = MATRIX_REF.match(labels[0]).group(1)
        matrix = (job.get("strategy") or {}).get("matrix") or {}
        if not isinstance(matrix, dict):
            return []
        vals = list(matrix.get(key) or []) if isinstance(matrix.get(key), list) else []
        vals += [i[key] for i in matrix.get("include") or [] if isinstance(i, dict) and key in i]
        out = []
        for v in vals:
            if isinstance(v, list):
                out.append([str(x) for x in v])
            elif isinstance(v, str):
                s = v.strip()
                if s.startswith("[") and s.endswith("]"):
                    out.append([p.strip().strip("'\"") for p in s[1:-1].split(",") if p.strip()])
                else:
                    out.append([s])
        return out
    static = [l for l in labels if not EXPR.search(l)]
    return [static] if static else []


def _is_nixos_linux(labels: list[str]) -> bool:
    low = {l.lower() for l in labels}
    if "self-hosted" not in low:
        return False
    if low & {x.lower() for x in NON_LINUX}:
        return False
    return "linux" in low or "nixos" in low


def check_file(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8")
    try:
        doc = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        return [f"{path}: not parseable as YAML: {exc}"]
    if not isinstance(doc, dict) or not isinstance(doc.get("jobs"), dict):
        return []
    allowed = set(SUPPRESS.findall(text))
    findings: list[str] = []
    for job_name, job in doc["jobs"].items():
        if not isinstance(job, dict) or "uses" in job:
            continue
        sets = _label_sets(job)
        if not any(_is_nixos_linux(s) for s in sets):
            continue
        in_container = bool(job.get("container"))
        if "NRH4" not in allowed:
            for key in ("container", "services"):
                if job.get(key):
                    findings.append(f"NRH4 {path}: job `{job_name}` declares `{key}:` -- the runner needs the docker CLI for it, and the NixOS runners have none")
        for i, step in enumerate(job.get("steps") or []):
            if not isinstance(step, dict):
                continue
            if NON_LINUX_IF.search(str(step.get("if") or "")):
                continue
            where = f"{path}: job `{job_name}` step {i + 1}"
            if step.get("name"):
                where += f" ({step['name']})"
            uses = step.get("uses")
            if isinstance(uses, str) and uses.startswith("docker://") and "NRH4" not in allowed:
                findings.append(f"NRH4 {where}: `uses: {uses}` needs the docker CLI, which the NixOS runners do not have")
            if isinstance(uses, str):
                action = uses.split("@", 1)[0]
                base = "/".join(action.split("/")[:2])
                for key in (action, base):
                    if key in HAZARDOUS_ACTIONS and key not in allowed and "NRH1" not in allowed:
                        findings.append(f"NRH1 {where}: uses {key} -- {HAZARDOUS_ACTIONS[key]}")
                        break
            shell = str(step.get("shell") or "")
            if shell.startswith(("/bin/", "/usr/")) and "NRH3" not in allowed:
                findings.append(f"NRH3 {where}: shell `{shell}` is an FHS path absent on NixOS; use `shell: bash`")
            run = step.get("run")
            if isinstance(run, str) and not in_container and "NRH2" not in allowed:
                code = "\n".join(l for l in run.splitlines() if not l.lstrip().startswith("#"))
                m = RUN_HAZARD.search(code)
                if m:
                    findings.append(f"NRH2 {where}: runs `{m.group(1)} {m.group(2)}` -- NixOS runners have no distro package manager; take the tool from nixpkgs")
    return findings


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("paths", nargs="*", default=[".github/workflows"])
    ap.add_argument("--warn", action="store_true", help="emit ::warning annotations and exit 0")
    ap.add_argument("--json", action="store_true", help="print findings as a JSON list")
    args = ap.parse_args()
    files: list[Path] = []
    for p in map(Path, args.paths):
        if p.is_dir():
            files += sorted(list(p.glob("*.yml")) + list(p.glob("*.yaml")))
        elif p.exists():
            files.append(p)
    findings = [f for path in files for f in check_file(path)]
    if args.json:
        print(json.dumps(findings, indent=1))
    else:
        for f in findings:
            print(f"::warning::{f}" if args.warn else f, file=sys.stdout if args.warn else sys.stderr)
    if findings and not args.warn:
        print(f"{len(findings)} NixOS-runner hazard(s); see scripts/ci/check_nixos_runner_hazards.py", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
