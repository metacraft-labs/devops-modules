#!/usr/bin/env bash
#
# prepare hook for submit-prepared-pr: runs in the PR tree after fix.patch is
# applied. It adds the test as a second commit, taken from the gate's source of
# truth (../../checks/garm/instance_lifecycle_test.go, declared in bundle.toml
# `inputs`): the gate preamble is stripped (upstream has no checks/ dir) and
# private identifiers are replaced. bundle.toml [review] forbid is the
# backstop: the scan fails loudly if a rewording makes these rules stop
# matching.
#
# The test commit carries the same author and Signed-off-by as the fix commit.
set -euo pipefail

TEST_SRC="${BUNDLE_DIR:?run me through submit-prepared-pr}/../../checks/garm/instance_lifecycle_test.go"
DST=runner/pool/instance_lifecycle_test.go
command -v gofmt >/dev/null || { echo "prepare.sh needs gofmt on PATH (e.g. nix shell nixpkgs#go)" >&2; exit 1; }

sed -e '/^\/\/ Gate t_garm_instance_lifecycle/,/^\/\/ WHAT IS UNDER TEST$/{/^\/\/ WHAT IS UNDER TEST$/!d}' \
  -e '/^\/\/ THE PRODUCTION DEFECTS/,/^\/\/ WHY IT DISCRIMINATES$/{/^\/\/ WHY IT DISCRIMINATES$/!d}' \
  -e '/^\/\/ WHY IT DISCRIMINATES$/,/^package pool$/{/^package pool$/!d}' \
  -e 's|"metacraft-labs"|"example-org"|g' \
  -e 's|"hms-libvirt"|"test-provider"|g' \
  -e 's|garm-qglasrc9bvey|garm-dropped|g' \
  -e 's|100\.83\.174\.120:8873|192.0.2.10:8873|g' \
  "$TEST_SRC" >"$DST"
# The gate compiles the test against our pin, where InitController() takes no
# argument. Upstream bf79e351 added a context parameter; adapt the call when
# the PR tree has it.
if grep -q 'InitController(ctx context.Context)' database/common/store.go; then
  sed -i 's|db\.InitController()|db.InitController(context.Background())|g' "$DST"
fi
gofmt -w "$DST"

AUTHOR="$(git log -1 --format='%an <%ae>')"
git add "$DST"
git commit -q --author="$AUTHOR" -m "Test instance-lifecycle handling in the pool manager

Drives cleanupOrphanedGithubRunners() and retryFailedInstancesForOnePool()
against the real SQLite store with a mocked provider and forge: an instance
absent from ListInstances is routed through DeleteInstance, a failing delete
neither cancels its siblings nor is retried every tick, create retries
are spaced out, and a pool whose provider cannot be listed does not stop
the orphan sweep for the others.

Signed-off-by: $AUTHOR"
echo "added $DST as a second commit"
