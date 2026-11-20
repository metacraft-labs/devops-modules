#!/usr/bin/env python3
"""Refuse a flake.lock that fetches an input from an unlisted host.

Every consumer that fetches all locked inputs (`nix flake archive`, a fresh
CI store) depends on every host named in the lock being up. GitHub and GitLab
are taken as given. Any other host must be listed in the allowlist, and a host
in the deny list is refused even when listed.

This exists because microvm.nix locks `spectrum` from spectrum-os.org. That
host stopped answering on 2026-11-19 and every consumer fetching the whole
lock failed with it, although nothing evaluates the input.

Usage: check_flake_lock_sources.py [--allowlist FILE] FLAKE_LOCK...
Exit 0 when every lock is clean, 1 when one is not, 2 on a usage error.
"""

import argparse
import json
import sys
from pathlib import Path
from urllib.parse import urlparse

DEFAULT_ALLOWLIST = Path(__file__).with_name("flake-lock-allowed-hosts.txt")

# Hosts a forge-typed input reaches when it names no `host`.
FORGE_DEFAULT_HOSTS = {
    "github": "github.com",
    "gitlab": "gitlab.com",
    "sourcehut": "git.sr.ht",
}
ALWAYS_ALLOWED = {"github.com", "gitlab.com"}

# Refused even if a later edit lists them.
DENIED = {"spectrum-os.org"}


def source_host(ref):
    """The host a lock reference fetches from, or None for local sources."""
    kind = ref.get("type")
    if kind in FORGE_DEFAULT_HOSTS:
        return (ref.get("host") or FORGE_DEFAULT_HOSTS[kind]).lower()
    if kind in ("path", "indirect"):
        return None
    url = ref.get("url")
    if not url:
        return f"<{kind} input without a url>"
    # Also covers `git+https://…`: the hostname is parsed the same way.
    parsed = urlparse(url)
    if parsed.scheme == "file" or parsed.scheme.endswith("+file"):
        return None
    return (parsed.hostname or f"<unparsable url {url}>").lower()


def load_allowlist(path):
    hosts = set()
    for line in path.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            hosts.add(line.lower())
    return hosts


def check(lock_path, allowed):
    nodes = json.loads(lock_path.read_text())["nodes"]
    problems = []
    for name, node in sorted(nodes.items()):
        for field in ("locked", "original"):
            ref = node.get(field)
            if not ref:
                continue
            host = source_host(ref)
            if host is None:
                continue
            if host in DENIED:
                problems.append(
                    f"{lock_path}: node '{name}' ({field}) fetches from {host}, which is denied"
                )
            elif host not in ALWAYS_ALLOWED and host not in allowed:
                problems.append(
                    f"{lock_path}: node '{name}' ({field}) fetches from {host}, which is not allowlisted"
                )
    return problems


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--allowlist", type=Path, default=DEFAULT_ALLOWLIST)
    ap.add_argument("locks", type=Path, nargs="+")
    args = ap.parse_args(argv)
    allowed = load_allowlist(args.allowlist)
    problems = []
    for lock in args.locks:
        problems += check(lock, allowed)
    if problems:
        print("\n".join(problems), file=sys.stderr)
        print(
            f"{len(problems)} problem(s). Pin the input to GitHub/GitLab, drop it with "
            '`inputs.<x>.inputs.<y>.follows = ""`, or, for a host that is genuinely '
            f"needed and reliable, add it to {args.allowlist.name} with a reason.",
            file=sys.stderr,
        )
        return 1
    print(
        f"ok: {len(args.locks)} lock(s), every input from GitHub/GitLab or an allowlisted host"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
