#!/usr/bin/env bash
#
# Prepared upstream PR for the garm busy-runner reap fix (fix + tests in
# runner/pool/busy_runner_reap_test.go, one commit), described by bundle.toml.
#
# This is a thin wrapper around metacraft-dev-guidelines
# scripts/submit-prepared-pr; see policies/preparing-prs-for-internal-review.md
# there. It DRY-RUNS by default: nothing is pushed and gh is not called.
#
#   ./open-pr.sh                              # dry run: build, scan, show the plan
#   ./open-pr.sh --verify --against-head      # does fix.patch apply on base / upstream head?
#   ./open-pr.sh --approve --reviewer NAME    # reviewer: approve the current content
#   ./open-pr.sh --submit --fork <you>/garm   # after approval: push + gh pr create
#
# MDG points at a metacraft-dev-guidelines checkout; the default is the
# workspace sibling.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MDG="${MDG:-${HERE}/../../../metacraft-dev-guidelines}"
TOOL="${MDG}/scripts/submit-prepared-pr"
[ -x "$TOOL" ] || {
  echo "submit-prepared-pr not found at $TOOL; set MDG to a metacraft-dev-guidelines checkout" >&2
  exit 1
}
exec "$TOOL" "$@" "$HERE"
