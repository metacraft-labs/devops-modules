#!/usr/bin/env python3
"""Refuse a flake.lock that fetches an input from an unlisted host.

Every consumer that fetches all locked inputs (`nix flake archive`, a fresh
CI store) depends on every host named in the lock being up. GitHub and GitLab
are taken as given. Any other host must be listed in the allowlist, and a host
in the deny list is refused even when listed.

This exists because microvm.nix locks `spectrum` from spectrum-os.org. That
host stopped answering on 2026-11-19 and every consumer fetching the whole
lock failed with it, although nothing evaluates the input.

A lock may also carry a named exception, `--exception LOCK:NODE:HOST`: that
one node of that one lock may fetch from that host, denied or not. Every other
node, host and lock is checked as usual, and an exception that matches nothing
is itself a problem, so it is deleted when the input it excuses goes away
instead of quietly outliving it.

Usage: check_flake_lock_sources.py [--allowlist FILE]
                                   [--exception LOCK:NODE:HOST]... FLAKE_LOCK...
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


def parse_exception(text):
    """`LOCK:NODE:HOST` -> (LOCK, NODE, HOST). LOCK may itself contain colons."""
    parts = text.rsplit(":", 2)
    if len(parts) != 3 or not all(parts):
        raise argparse.ArgumentTypeError(f"expected LOCK:NODE:HOST, got {text!r}")
    lock, node, host = parts
    return lock, node, host.lower()


def check(lock_path, allowed, excepted=frozenset(), used=None):
    """Problems in one lock. `excepted` holds the (node, host) pairs this lock
    may fetch regardless; each one that matches is added to `used`."""
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
            if (name, host) in excepted:
                if used is not None:
                    used.add((name, host))
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
    ap.add_argument(
        "--exception",
        type=parse_exception,
        action="append",
        default=[],
        metavar="LOCK:NODE:HOST",
        help="let NODE in LOCK (exactly as given among the locks) fetch from HOST",
    )
    ap.add_argument("locks", type=Path, nargs="+")
    args = ap.parse_args(argv)
    allowed = load_allowlist(args.allowlist)
    lock_names = {str(lock) for lock in args.locks}
    exceptions = {}
    for lock, node, host in args.exception:
        if lock not in lock_names:
            ap.error(f"--exception names {lock}, which is not one of the locks checked")
        exceptions.setdefault(lock, set()).add((node, host))
    # Source problems and stale exceptions have different remedies, so they
    # are kept apart and each gets its own closing hint.
    problems = []
    stale = []
    for lock in args.locks:
        excepted = exceptions.get(str(lock), set())
        used = set()
        problems += check(lock, allowed, excepted, used)
        for node, host in sorted(excepted - used):
            stale.append(
                f"{lock}: exception for node '{node}' from {host} is stale: no such "
                "node fetches from that host any more, so delete the exception"
            )
    if problems or stale:
        print("\n".join(problems + stale), file=sys.stderr)
        if problems:
            print(
                f"{len(problems)} problem(s). Pin the input to GitHub/GitLab, drop it with "
                '`inputs.<x>.inputs.<y>.follows = ""`, or, for a host that is genuinely '
                f"needed and reliable, add it to {args.allowlist.name} with a reason.",
                file=sys.stderr,
            )
        if stale:
            print(
                f"{len(stale)} stale exception(s). Remove the matching --exception "
                "argument(s) and the comment that justifies them.",
                file=sys.stderr,
            )
        return 1
    excused = sum(len(pairs) for pairs in exceptions.values())
    print(
        f"ok: {len(args.locks)} lock(s), every input from GitHub/GitLab or an allowlisted host"
        + (f", apart from {excused} named exception(s)" if excused else "")
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
