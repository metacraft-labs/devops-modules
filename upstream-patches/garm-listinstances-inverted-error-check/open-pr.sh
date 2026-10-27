#!/usr/bin/env bash
#
# Prepared upstream PR for the garm ListInstances inverted-error-check fix,
# described by bundle.toml.
#
# This is a thin wrapper around metacraft-dev-guidelines
# scripts/submit-prepared-pr; see policies/preparing-prs-for-internal-review.md
# there. It DRY-RUNS by default: nothing is pushed and gh is not called.
#
# RETIRED: fixed upstream in cloudbase/garm 488cf98b. The wrapper refuses
# --submit and --approve; dry run and --verify still work, as a record of what
# was prepared.
#
#   ./open-pr.sh                              # dry run: build, scan, show the plan
#   ./open-pr.sh --verify --against-head      # does fix.patch apply on base / upstream head?
#
# MDG points at a metacraft-dev-guidelines checkout; the default is the
# workspace sibling.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for a in "$@"; do
  case "$a" in
  --submit | --approve)
    echo "refusing $a: this bundle is retired (fixed upstream in cloudbase/garm 488cf98b); see bundle.toml" >&2
    exit 1
    ;;
  esac
done
MDG="${MDG:-${HERE}/../../../metacraft-dev-guidelines}"
TOOL="${MDG}/scripts/submit-prepared-pr"
[ -x "$TOOL" ] || {
  echo "submit-prepared-pr not found at $TOOL; set MDG to a metacraft-dev-guidelines checkout" >&2
  exit 1
}
exec "$TOOL" "$@" "$HERE"
