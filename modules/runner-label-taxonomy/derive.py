#!/usr/bin/env python3
"""runner-label derivation + linter — the RC1 MECHANISM (company-agnostic).

Runner-Fleet-Capability-Pools-And-Remote-Driving RC1 (gate
``t_runner_label_taxonomy``).

This is the *machine-checkable derivation* from an RA6 signed capability
manifest (``GET /v1/manifest`` — see
``vm-harness/docs/serve-enrollment.md``) to the GitHub runner label set a host
may advertise, plus the ``advertised ⊆ derived`` LINTER.

Repo layering (campaign ``:repo_layering:``): the label *vocabulary* and the
``runs-on`` *conventions* are POLICY and live in
``metacraft-dev-guidelines/policies/ci-workflow-standards.md``. This file is the
company-agnostic MECHANISM: it bakes in NO Metacraft host list, secret, or
org — it only knows how a manifest maps to labels. The concrete
per-host advertised sets live in ``infra`` and are validated by this linter.

Single source of truth: both ``derive`` and ``lint`` share one derivation, so
the linter can never drift from what the controller (RB2/RC2) actually derives
at JIT-registration time. Downstream:

  * RB2 / RC2 (GARM central controller + pools) run ``derive`` at runtime after
    verifying the fetched manifest's signature, to compute a classic runner's
    JIT label array from proven hardware — no hand-maintained class name.
  * RC2 / infra CI run ``lint`` to prove every host's advertised label set is a
    subset of what its manifest proves (this gate is that contract, hermetic).
  * RC4 (reusable-workflow ``runs-on`` migration) consumes the same vocabulary
    to rewrite class names into minimal capability label sets.

SIGNATURE BOUNDARY: this tool operates on an *already-verified* manifest. The
RA6 contract is explicit — "an unverifiable manifest yields no labels"; the
controller ``verify()``s the HMAC/identity BEFORE calling ``derive``. This tool
does the field→label mapping only; it does not (and must not) re-implement the
crypto. It DOES fail closed on an unsupported ``manifestVersion``.
"""

from __future__ import annotations

import argparse
import json
import sys
from typing import Any

# The taxonomy is VERSIONED and pinned to the manifest schema it reads. Bump
# TAXONOMY_VERSION on any change to the label vocabulary or a mapping rule; keep
# SUPPORTED_MANIFEST_VERSIONS in lock-step with the RA6 manifestVersion(s) this
# derivation understands. A manifest outside this set fails closed (no labels)
# rather than being interpreted under the wrong schema.
TAXONOMY_VERSION = "1"
SUPPORTED_MANIFEST_VERSIONS = {"1"}

# The closed vocabulary the MANIFEST is authoritative over — the only labels the
# ``advertised ⊆ derived`` check governs. A label OUTSIDE this set is a POLICY /
# attested label (dev-env-ready, org:<name>, ephemeral, benchmark, …): the
# hardware manifest can neither prove nor disprove it, so the linter passes it
# through (a different, policy-owned check governs those). This is the precise
# reading of ``advertised ⊆ derived``: the manifest only vetoes labels it owns.
OS_LABELS = {"linux", "windows", "macos"}
ARCH_LABELS = {"x64", "arm64"}
ARCH_LEVEL_LABELS = {"x86-64-v1", "x86-64-v2", "x86-64-v3", "x86-64-v4"}
CAP_LABELS = {"gpu", "nested", "docker", "podman", "rr-hw-counters"}
HYPERVISOR_LABELS = {"incus", "libvirt", "hyperv", "tart"}
# self-hosted is structural for any serve-host runner — always derived, always
# governed (so a manifest that is, say, a hosted-runner shape can't claim it).
STRUCTURAL_LABELS = {"self-hosted"}

MANIFEST_GOVERNED_VOCAB = (
    OS_LABELS
    | ARCH_LABELS
    | ARCH_LEVEL_LABELS
    | CAP_LABELS
    | HYPERVISOR_LABELS
    | STRUCTURAL_LABELS
)


class DerivationError(Exception):
    """Raised when a manifest cannot be interpreted (fail closed → no labels)."""


def _extract_manifest(doc: dict[str, Any]) -> dict[str, Any]:
    """Accept either the full ``/v1/manifest`` envelope (``identity.manifest``)
    or a bare manifest object, and return the inner manifest.

    The controller fetches the envelope; ``vm-harness manifest`` prints the bare
    object. Both are valid inputs so the derivation is identical whether you
    prototype from a local dump or run against a live host.
    """
    if "identity" in doc and isinstance(doc["identity"], dict):
        inner = doc["identity"].get("manifest")
        if not isinstance(inner, dict):
            raise DerivationError("envelope has no identity.manifest object")
        return inner
    if "manifestVersion" in doc:
        return doc
    raise DerivationError(
        "input is neither a /v1/manifest envelope nor a bare manifest "
        "(no identity.manifest and no manifestVersion)"
    )


def _arch_label(arch: str) -> str | None:
    a = (arch or "").lower()
    if a in ("x86_64", "amd64", "x64"):
        return "x64"
    if a in ("arm64", "aarch64"):
        return "arm64"
    return None


def _arch_level_labels(arch_level: str) -> list[str]:
    """A host proving x86-64-vN also satisfies every lower level, so emit the
    whole ladder up to N. Non-x86 hosts carry no arch-level label."""
    if not arch_level:
        return []
    ladder = ["x86-64-v1", "x86-64-v2", "x86-64-v3", "x86-64-v4"]
    if arch_level not in ladder:
        raise DerivationError(f"unknown archLevel {arch_level!r}")
    # v1 is the bare 64-bit baseline; we do not advertise it as a targetable
    # capability label (every x86-64 host has it — it carries no routing value).
    upto = ladder.index(arch_level)
    return [lbl for lbl in ladder[1 : upto + 1]]


def derive_labels(doc: dict[str, Any]) -> list[str]:
    """The canonical manifest → runner-label derivation.

    Returns the SORTED set of labels the host's manifest PROVES. Fails closed
    (raises DerivationError) on an unsupported manifest version — never emits a
    partial/guessed set.
    """
    manifest = _extract_manifest(doc)

    mv = str(manifest.get("manifestVersion", ""))
    if mv not in SUPPORTED_MANIFEST_VERSIONS:
        raise DerivationError(
            f"unsupported manifestVersion {mv!r} "
            f"(this taxonomy v{TAXONOMY_VERSION} supports "
            f"{sorted(SUPPORTED_MANIFEST_VERSIONS)})"
        )

    labels: set[str] = set(STRUCTURAL_LABELS)  # self-hosted

    os_ = str(manifest.get("os", "")).lower()
    if os_ in OS_LABELS:
        labels.add(os_)
    else:
        raise DerivationError(f"manifest os {os_!r} is not one of {sorted(OS_LABELS)}")

    arch = _arch_label(str(manifest.get("arch", "")))
    if arch:
        labels.add(arch)

    labels.update(_arch_level_labels(str(manifest.get("archLevel", "")).strip()))

    # Boolean hardware capabilities — only a proven ``true`` yields the label.
    if manifest.get("gpu") is True:
        labels.add("gpu")
    if manifest.get("nestedVirt") is True:
        labels.add("nested")
    if manifest.get("docker") is True:
        labels.add("docker")
    if manifest.get("podman") is True:
        labels.add("podman")
    if manifest.get("rrHwCounters") is True:
        labels.add("rr-hw-counters")

    # Drivable hypervisors — only entries the daemon reports ``available``.
    for hv in manifest.get("hypervisors", []) or []:
        if isinstance(hv, dict) and hv.get("available") is True:
            hid = str(hv.get("id", "")).lower()
            if hid in HYPERVISOR_LABELS:
                labels.add(hid)

    return sorted(labels)


def lint_advertised(doc: dict[str, Any], advertised: list[str]) -> list[str]:
    """Enforce ``advertised ⊆ derived`` over the MANIFEST-GOVERNED vocabulary.

    Returns the list of VIOLATIONS: advertised labels that fall inside the set
    the manifest is authoritative over yet are NOT in the derived set. Policy /
    attested labels (dev-env-ready, org:<name>, ephemeral, …) are outside that
    vocabulary and pass through untouched. Empty list ⇒ the host's advertised
    set is a valid subset of what its manifest proves.
    """
    derived = set(derive_labels(doc))
    violations = []
    for lbl in advertised:
        lbl = lbl.strip()
        if not lbl:
            continue
        if lbl in MANIFEST_GOVERNED_VOCAB and lbl not in derived:
            violations.append(lbl)
    return sorted(violations)


def _load(path: str | None) -> dict[str, Any]:
    raw = sys.stdin.read() if path in (None, "-") else open(path, encoding="utf-8").read()
    try:
        return json.loads(raw)
    except json.JSONDecodeError as e:
        raise DerivationError(f"input is not valid JSON: {e}") from e


def _split_labels(args: argparse.Namespace) -> list[str]:
    if args.advertised_file:
        with open(args.advertised_file, encoding="utf-8") as f:
            text = f.read()
        # Accept a JSON array or a newline/comma list.
        text_s = text.strip()
        if text_s.startswith("["):
            return [str(x) for x in json.loads(text_s)]
        return [t for t in text.replace(",", "\n").split() if t]
    if args.advertised is not None:
        return [t for t in args.advertised.replace(",", "\n").split() if t]
    return []


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        prog="runner-label-tool",
        description="RC1 manifest→label derivation + advertised⊆derived linter",
    )
    p.add_argument("--version", action="store_true", help="print taxonomy version and exit")
    sub = p.add_subparsers(dest="cmd")

    d = sub.add_parser("derive", help="print the labels a manifest proves")
    d.add_argument("--manifest", "-m", default="-", help="manifest JSON file (default: stdin)")
    d.add_argument("--json", action="store_true", help="emit a JSON array (default: one per line)")

    lt = sub.add_parser("lint", help="assert advertised ⊆ derived; exit 1 on a violation")
    lt.add_argument("--manifest", "-m", default="-", help="manifest JSON file (default: stdin)")
    lt.add_argument("--advertised", "-a", default=None, help="comma/space list of advertised labels")
    lt.add_argument("--advertised-file", default=None, help="file with advertised labels (JSON array or list)")

    args = p.parse_args(argv)

    if args.version:
        print(f"runner-label-taxonomy v{TAXONOMY_VERSION} "
              f"(manifestVersion {sorted(SUPPORTED_MANIFEST_VERSIONS)})")
        return 0

    if args.cmd == "derive":
        try:
            labels = derive_labels(_load(args.manifest))
        except DerivationError as e:
            print(f"[derive][ERROR] {e}", file=sys.stderr)
            return 2
        if args.json:
            print(json.dumps(labels))
        else:
            for lbl in labels:
                print(lbl)
        return 0

    if args.cmd == "lint":
        try:
            doc = _load(args.manifest)
            advertised = _split_labels(args)
            violations = lint_advertised(doc, advertised)
        except DerivationError as e:
            print(f"[lint][ERROR] {e}", file=sys.stderr)
            return 2
        if violations:
            derived = derive_labels(doc)
            print(
                "[lint][FAIL] advertised labels NOT proven by the manifest "
                f"(advertised ⊄ derived): {violations}",
                file=sys.stderr,
            )
            print(f"[lint]        derived (proven) set: {derived}", file=sys.stderr)
            return 1
        print("[lint][PASS] advertised ⊆ derived")
        return 0

    p.print_help(sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
