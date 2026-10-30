#!/usr/bin/env python3
"""Fail when the two setup-nix composite actions drift apart.

Two actions provision Nix for CI in this org:

  * metacraft-labs/devops-modules          .github/setup-nix
  * metacraft-labs/metacraft-github-actions setup-nix (used by setup-dev-env)

They write their own nix.conf. When a transfer setting is tuned in one and not
the other, half the org keeps the failure the tuning fixed (on 2026-09-25 one
had connect-timeout = 3 with one download attempt while the other had 20 and
5). This compares what the two actually write:

  1. Every `key = value` line of the nix.conf heredoc. Any key present in
     one and not the other, or with a different value, fails, unless the key
     is listed in INTENTIONAL_DIFFERENCES with the reason. A key added to one
     side only is therefore caught without anyone updating a list here.
     `${{ inputs.X == 'a' && 'b' || 'c' }}` is resolved against the input's
     default. Interpolations of caller-supplied extras (`${{ inputs.* }}`,
     `$VAR`) are removed before comparing `substituters` and
     `trusted-public-keys`, so the fixed base must match.
  2. The binary-cache preflight: both declare `substituter-preflight` with the
     same default, both run probe-substituters.sh from a step named
     "Probe binary caches" after the netrc is written, and the script and its
     contract suite are byte-identical in the two repositories.

Usage:
  check-setup-nix-alignment.py --devops-root DIR --mga-root DIR

Exit status 0 when aligned, 1 with one line per difference otherwise.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path

DEVOPS_FILES = {
    "action": ".github/setup-nix/action.yml",
    "probe": ".github/setup-nix/probe-substituters.sh",
    "probe-test": ".github/setup-nix/tests/probe-substituters-test.sh",
}
MGA_FILES = {
    "action": "setup-nix/action.yml",
    "probe": "setup-nix/probe-substituters.sh",
    "probe-test": "setup-nix/tests/probe-substituters-test.sh",
}

# Keys the two actions set differently on purpose. Each needs a reason; adding
# a key here is a decision that half the org should behave differently.
INTENTIONAL_DIFFERENCES = {
    "experimental-features": (
        "devops-modules REPLACES the feature list from its experimental-features "
        "input and then verifies it took effect"
    ),
    "extra-experimental-features": (
        "metacraft-github-actions APPENDS, because it skips the installer when "
        "Nix is preinstalled and must keep the system's own features"
    ),
    "accept-flake-config": (
        "setup-dev-env consumers rely on their flakes' nixConfig; devops-modules "
        "callers pass caches explicitly"
    ),
    "access-tokens": (
        "devops-modules takes optional GitHub/GitLab tokens as inputs; "
        "metacraft-github-actions always installs its required gh-token"
    ),
}

# Compared after removing caller-supplied interpolations.
BASE_COMPARED = ("substituters", "trusted-public-keys")

HEREDOC_START = 'cat << EOF > "$HOME/.config/nix/nix.conf"'
TERNARY = re.compile(
    r"^\$\{\{\s*inputs\.([A-Za-z0-9_-]+)\s*==\s*'([^']*)'\s*&&\s*'([^']*)'"
    r"\s*\|\|\s*'([^']*)'\s*\}\}$"
)


def input_default(action: str, name: str) -> str | None:
    block = re.search(
        rf"\n  {re.escape(name)}:\n((?:    .*\n|\s*\n)+)", action
    )
    if not block:
        return None
    default = re.search(r"^    default:\s*(.*)$", block.group(1), re.M)
    if not default:
        return None
    return default.group(1).strip().strip("'\"")


def nix_conf(action: str, label: str, problems: list[str]) -> dict[str, str]:
    if action.count(HEREDOC_START) != 1:
        problems.append(f"{label}: expected exactly one nix.conf heredoc")
        return {}
    body = action.split(HEREDOC_START, 1)[1]
    body = re.split(r"\n\s*EOF\s*\n", body, maxsplit=1)[0]
    # Drop multi-line `${{ ... }}` blocks (devops-modules' access-tokens).
    body = re.sub(r"\$\{\{(?:(?!\}\}).)*\}\}", lambda m: "" if "\n" in m.group(0) else m.group(0), body, flags=re.S)
    settings: dict[str, str] = {}
    for raw in body.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = re.match(r"^([A-Za-z0-9-]+)\s*=\s*(.*)$", line)
        if not match:
            continue
        key, value = match.group(1), match.group(2).strip()
        ternary = TERNARY.match(value)
        if ternary:
            name, compare, then, otherwise = ternary.groups()
            default = input_default(action, name)
            if default is None:
                problems.append(f"{label}: {key} depends on input {name!r}, which has no default")
            value = then if default == compare else otherwise
        if key in settings:
            problems.append(f"{label}: nix.conf sets {key} twice")
        settings[key] = value
    return settings


def strip_interpolations(value: str) -> str:
    value = re.sub(r"\$\{\{[^}]*\}\}", "", value)
    value = re.sub(r"\$[A-Z_][A-Z0-9_]*", "", value)
    return " ".join(value.split())


def preflight(action: str, label: str, problems: list[str]) -> str | None:
    default = input_default(action, "substituter-preflight")
    if default is None:
        problems.append(f"{label}: no substituter-preflight input with a default")
    marker = "    - name: Probe binary caches\n"
    if action.count(marker) != 1:
        problems.append(f"{label}: expected exactly one 'Probe binary caches' step")
        return default
    step = action.split(marker, 1)[1].split("\n    - name: ", 1)[0]
    if "probe-substituters.sh" not in step:
        problems.append(f"{label}: the 'Probe binary caches' step does not run probe-substituters.sh")
    if "inputs.substituter-preflight" not in step:
        problems.append(f"{label}: the probe step ignores the substituter-preflight input")
    if "SETUP_NIX_PROBE_NIX_CONF=" not in step:
        problems.append(f"{label}: the probe step is not handed nix.conf to prune")
    netrc = max(action.find("write-netrc.sh"), action.find("write-nix-netrc.sh"))
    if netrc < 0 or action.index(marker) < netrc:
        problems.append(f"{label}: the probe runs before the netrc is written")
    return default


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def compare(devops_root: Path, mga_root: Path) -> list[str]:
    problems: list[str] = []
    paths = {}
    for side, root, files in (("devops-modules", devops_root, DEVOPS_FILES), ("metacraft-github-actions", mga_root, MGA_FILES)):
        for kind, rel in files.items():
            path = root / rel
            if not path.is_file():
                problems.append(f"{side}: missing {rel}")
            paths[(side, kind)] = path
    if not (paths[("devops-modules", "action")].is_file() and paths[("metacraft-github-actions", "action")].is_file()):
        return problems

    devops_action = paths[("devops-modules", "action")].read_text()
    mga_action = paths[("metacraft-github-actions", "action")].read_text()
    devops_conf = nix_conf(devops_action, "devops-modules", problems)
    mga_conf = nix_conf(mga_action, "metacraft-github-actions", problems)

    for key in sorted(set(devops_conf) | set(mga_conf)):
        if key in INTENTIONAL_DIFFERENCES:
            continue
        if key not in devops_conf or key not in mga_conf:
            only = "devops-modules" if key in devops_conf else "metacraft-github-actions"
            value = (devops_conf if key in devops_conf else mga_conf)[key]
            problems.append(f"nix.conf: {key} = {value} is set only in {only}")
            continue
        left, right = devops_conf[key], mga_conf[key]
        if key in BASE_COMPARED:
            left, right = strip_interpolations(left), strip_interpolations(right)
        if left != right:
            problems.append(f"nix.conf: {key} differs: devops-modules {left!r}, metacraft-github-actions {right!r}")

    devops_mode = preflight(devops_action, "devops-modules", problems)
    mga_mode = preflight(mga_action, "metacraft-github-actions", problems)
    if devops_mode is not None and mga_mode is not None and devops_mode != mga_mode:
        problems.append(f"substituter-preflight default differs: devops-modules {devops_mode!r}, metacraft-github-actions {mga_mode!r}")

    for kind in ("probe", "probe-test"):
        left, right = paths[("devops-modules", kind)], paths[("metacraft-github-actions", kind)]
        if not (left.is_file() and right.is_file()):
            continue
        if digest(left) != digest(right):
            problems.append(f"{left.name} differs between {DEVOPS_FILES[kind]} and {MGA_FILES[kind]}; copy one over the other")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--devops-root", type=Path, required=True)
    parser.add_argument("--mga-root", type=Path, required=True)
    args = parser.parse_args()
    problems = compare(args.devops_root, args.mga_root)
    for problem in problems:
        print(f"setup-nix drift: {problem}")
    if problems:
        print(f"setup-nix alignment: {len(problems)} difference(s). Change BOTH actions, or record an intentional difference with its reason.")
        return 1
    print("setup-nix alignment: devops-modules and metacraft-github-actions agree.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
