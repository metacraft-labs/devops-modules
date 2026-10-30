#!/usr/bin/env bash
#
# prepare hook for submit-prepared-pr (bundle.toml, the garm half): runs in the
# PR tree after fix.patch is applied. It adds the test as a second commit,
# taken from the gate's source of truth (../../checks/garm/macos_pool_ostype_test.go,
# declared in bundle.toml `inputs`). Only the gate preamble is stripped
# (upstream has no checks/ dir); the rest of the header (what is under test,
# why it is an internal test, why nothing is mocked) is kept verbatim. The test
# deliberately carries no private names; bundle.toml [review] forbid keeps it
# that way.
#
# The test commit carries the same author and Signed-off-by as the fix commit.
set -euo pipefail

TEST_SRC="${BUNDLE_DIR:?run me through submit-prepared-pr}/../../checks/garm/macos_pool_ostype_test.go"
DST=runner/macos_pool_ostype_test.go
command -v gofmt >/dev/null || { echo "prepare.sh needs gofmt on PATH (e.g. nix shell nixpkgs#go)" >&2; exit 1; }

sed -e '/^\/\/ Gate t_garm_macos_pools_supported/,/^\/\/ WHAT IS UNDER TEST$/{/^\/\/ WHAT IS UNDER TEST$/!d}' \
  "$TEST_SRC" >"$DST"
gofmt -w "$DST"

AUTHOR="$(git log -1 --format='%an <%ae>')"
git add "$DST"
git commit -q --author="$AUTHOR" -m "Test that the pool path accepts os_type=macos

Drives the real Runner.appendTagsToCreatePoolParams() — the function
that returns the 400 — rather than IsSupportedOSType alone, so the test
keeps meaning something if the caller changes. Covers the macOS case,
that linux and windows are unaffected, that an unknown OS type and an
unsupported architecture are still rejected, and that the provider check
at the end of the function is still reached.

Signed-off-by: $AUTHOR"
echo "added $DST as a second commit"
