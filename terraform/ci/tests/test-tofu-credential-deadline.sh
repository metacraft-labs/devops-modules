#!/usr/bin/env bash
# Contract tests for tofu-credential-deadline. No credentials, network or tofu.
#
# No mocks of the unit under test: the real script runs real child processes
# under a real `timeout`. The child stands in for tofu only in the one property
# the script relies on — it traps SIGINT, "releases its lock" (writes a marker
# file) and exits — because exercising a real state lock needs a real backend.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
script="${TOFU_CREDENTIAL_DEADLINE_SCRIPT:-${here}/../tofu-credential-deadline}"
bash_bin="${TOFU_CREDENTIAL_DEADLINE_BASH:-bash}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

run() { "$bash_bin" "$script" "$@"; }

# expect_eq LABEL WANT GOT
expect_eq() {
  if [ "$2" != "$3" ]; then
    fail "$1: want '$2', got '$3'"
  fi
}

# --- not-after -----------------------------------------------------------------

expect_eq "app only" 4600 "$(run not-after --github-app true --aws-duration '' --now 1000)"
expect_eq "aws only" 8200 "$(run not-after --github-app false --aws-duration 7200 --now 1000)"
expect_eq "earliest wins (aws shorter)" 2800 "$(run not-after --github-app true --aws-duration 1800 --now 1000)"
expect_eq "earliest wins (app shorter)" 4600 "$(run not-after --github-app true --aws-duration 7200 --now 1000)"
expect_eq "no short-lived credential" "" "$(run not-after --github-app false --aws-duration '' --now 1000)"

if run not-after --github-app maybe --now 1 >/dev/null 2>&1; then
  fail "not-after accepted --github-app maybe"
fi

# --- run -----------------------------------------------------------------------

now="$(date +%s)"

# Unbounded (no deadline): the command's own status passes through.
rc=0
run run --not-after '' -- "$bash_bin" -c 'exit 3' || rc=$?
expect_eq "unbounded exit status" 3 "$rc"

# Comfortable deadline: command finishes, status passes through.
rc=0
run run --not-after $((now + 3600)) -- "$bash_bin" -c 'exit 0' || rc=$?
expect_eq "within deadline" 0 "$rc"
rc=0
run run --not-after $((now + 3600)) -- "$bash_bin" -c 'exit 2' || rc=$?
expect_eq "within deadline, plan-with-changes status" 2 "$rc"

# Too close to expiry: refuse to start at all (the command must not run).
rc=0
run run --not-after $((now + 700)) --margin 600 --min-runtime 300 -- \
  "$bash_bin" -c "touch '$tmp/started'" >"$tmp/refuse.err" 2>&1 || rc=$?
expect_eq "refuse near expiry" 75 "$rc"
[ ! -e "$tmp/started" ] || fail "refused command still ran"
grep -q 'Refusing to start' "$tmp/refuse.err" || fail "refusal did not explain itself"

# Deadline reached: the child gets SIGINT (not SIGKILL), gets to clean up —
# i.e. release its lock — and the script reports 124.
cat >"$tmp/lockholder" <<EOF
trap 'echo released > "$tmp/lock-released"; exit 1' INT
echo held > "$tmp/lock-held"
while :; do sleep 0.1; done
EOF
rc=0
start="$(date +%s)"
run run --not-after $((start + 600 + 3)) --margin 600 --kill-after 5 --min-runtime 1 -- \
  "$bash_bin" "$tmp/lockholder" >"$tmp/int.err" 2>&1 || rc=$?
elapsed=$(($(date +%s) - start))
expect_eq "interrupted at deadline" 124 "$rc"
[ -e "$tmp/lock-held" ] || fail "lock holder never started"
[ -e "$tmp/lock-released" ] || fail "lock holder was not given SIGINT to release its lock"
[ "$elapsed" -le 8 ] || fail "interrupt came late (${elapsed}s)"
grep -q 'interrupted (SIGINT)' "$tmp/int.err" || fail "interrupt was not reported"

# A child that ignores SIGINT is killed kill-after seconds later.
cat >"$tmp/stubborn" <<EOF
trap '' INT
while :; do sleep 0.1; done
EOF
rc=0
start="$(date +%s)"
run run --not-after $((start + 600 + 2)) --margin 600 --kill-after 2 --min-runtime 1 -- \
  "$bash_bin" "$tmp/stubborn" 2>/dev/null || rc=$?
elapsed=$(($(date +%s) - start))
expect_eq "stubborn child killed" 124 "$rc"
[ "$elapsed" -le 9 ] || fail "SIGKILL fallback came late (${elapsed}s)"

# kill-after must land inside the margin, before the credentials expire.
if run run --not-after $((now + 3600)) --margin 60 --kill-after 60 -- true 2>/dev/null; then
  fail "accepted --kill-after >= --margin"
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures failure(s)" >&2
  exit 1
fi
echo "tofu-credential-deadline: all tests passed"
