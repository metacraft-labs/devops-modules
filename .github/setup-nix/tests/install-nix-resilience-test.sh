#!/usr/bin/env bash
# Contract test for ../install-nix-resilience.sh.
#
# Stubs, and why each is one: `getent` (a resolver that fails on demand is
# the condition under test, and a real one cannot be made to fail
# transiently), `sleep` (records the backoff instead of spending a minute),
# `sudo` (runs its arguments; the sandbox has no root) and the nix-installer
# binary (records its arguments; uninstalling a real Nix is not something a
# test may do). The script itself, its receipt handling and its bounds are
# real. Every failure case is paired with the case that must succeed, so a
# script that always passes or always fails cannot pass this suite.
#
# This file is kept byte-identical in metacraft-labs/devops-modules
# (.github/setup-nix/tests) and metacraft-labs/metacraft-github-actions
# (setup-nix/tests).

# `A && check .. ok || check .. bad` is intended: check always returns 0, so
# the `bad` branch runs exactly when A fails.
# shellcheck disable=SC2015

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../install-nix-resilience.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp:?}"' EXIT
fail=0
check() { if [ "$2" = ok ]; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }

stubs="$tmp/bin"
mkdir -p "$stubs"
# Stubs run this bash: the Nix build sandbox has no /usr/bin/env.
stub() { { printf '#!%s\n' "$BASH"; cat; } >"$1"; chmod +x "$1"; }
# getent: fails the first $GETENT_FAILURES calls (counted in $tmp/getent.n),
# then answers. GETENT_FAILURES=always never answers.
# Only `getent hosts` (the readiness probe) counts; `ahosts` (diagnostics)
# just reports.
stub "$stubs/getent" <<'EOF'
[ "$1" = hosts ] || { echo "diagnostic lookup of $2"; exit 0; }
n=$(( $(cat "$STUB_DIR/getent.n" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$STUB_DIR/getent.n"
echo "$*" >>"$STUB_DIR/getent.calls"
if [ "$GETENT_FAILURES" = always ] || [ "$n" -le "$GETENT_FAILURES" ]; then exit 2; fi
echo "192.0.2.1 $2"
EOF
stub "$stubs/sleep" <<'EOF'
echo "$1" >>"$STUB_DIR/sleeps"
EOF
stub "$stubs/sudo" <<'EOF'
exec "$@"
EOF

# A fake RUNNER_TEMP holding the installer the action unpacked. INSTALLER_MODE:
# remove = a working uninstall, fail = exits 1, keep = exits 0 but leaves the
# receipt (the trap: the action would then report a broken install as fine).
make_installer() {
  mkdir -p "$tmp/runner-temp/nix-installer-0000"
  stub "$tmp/runner-temp/nix-installer-0000/nix-installer" <<'EOF'
echo "$*" >>"$STUB_DIR/installer.calls"
case "$INSTALLER_MODE" in
  remove) rm -f "$3" ;;
  fail) exit 1 ;;
  keep) ;;
esac
EOF
}

# $1 = subcommand; remaining args are VAR=value overrides. Output in $tmp/out.
run() {
  local sub="$1"; shift
  rm -f "$tmp/getent.n" "$tmp/getent.calls" "$tmp/sleeps" "$tmp/installer.calls"
  env PATH="$stubs:$PATH" STUB_DIR="$tmp" RUNNER_TEMP="$tmp/runner-temp" \
    SETUP_NIX_NIX_DIR="$tmp/nix" GETENT_FAILURES=0 INSTALLER_MODE=remove "$@" \
    bash "$script" "$sub" >"$tmp/out" 2>&1
}
sleeps() { tr '\n' ' ' <"$tmp/sleeps" 2>/dev/null | sed 's/ $//'; }

# --- wait -------------------------------------------------------------------
run wait && rc=0 || rc=$?
[ "$rc" = 0 ] && [ ! -e "$tmp/sleeps" ] && grep -q 'Resolved releases.nixos.org cf.install.determinate.systems (attempt 1 of 5)' "$tmp/out" \
  && check "wait: both names resolve at once, no sleep" ok || check "wait: both names resolve at once, no sleep" bad
[ "$(wc -l <"$tmp/getent.calls")" -eq 2 ] && check "wait: asks for each name" ok || check "wait: asks for each name" bad

# Transient: the first three lookups fail (attempt 1 both names, attempt 2 the
# first), then everything answers.
run wait GETENT_FAILURES=3 && rc=0 || rc=$?
[ "$rc" = 0 ] && [ "$(sleeps)" = "4 8" ] && grep -q '(attempt 3 of 5)' "$tmp/out" \
  && check "wait: transient failure is retried with backoff 4 8" ok || check "wait: transient failure is retried with backoff 4 8 (got '$(sleeps)')" bad
[ "$(grep -c '::group::Resolver state' "$tmp/out")" -eq 1 ] \
  && check "wait: resolver state is logged once" ok || check "wait: resolver state is logged once" bad

# Never resolves: bounded at 5 attempts and 60 s of sleep, warns, exits 0.
run wait GETENT_FAILURES=always && rc=0 || rc=$?
[ "$rc" = 0 ] && check "wait: never fails the step" ok || check "wait: never fails the step (rc $rc)" bad
[ "$(sleeps)" = "4 8 16 32" ] && check "wait: bounded at 5 attempts, 60 s of sleep" ok || check "wait: bounded at 5 attempts, 60 s of sleep (got '$(sleeps)')" bad
grep -q '^::warning::.*did not all resolve after 5 attempts' "$tmp/out" && check "wait: exhaustion is a warning" ok || check "wait: exhaustion is a warning" bad

# --- recover ----------------------------------------------------------------
# Positive control for the trap: the failed install left a receipt.
mkdir -p "$tmp/nix"
make_installer

echo '{}' >"$tmp/nix/receipt.json"
run recover && rc=0 || rc=$?
[ "$rc" = 0 ] && [ ! -e "$tmp/nix/receipt.json" ] && check "recover: reverts the partial install" ok || check "recover: reverts the partial install (rc $rc)" bad
grep -qx "uninstall --no-confirm $tmp/nix/receipt.json" "$tmp/installer.calls" 2>/dev/null \
  && check "recover: runs the action's installer with uninstall --no-confirm <receipt>" ok \
  || check "recover: runs the action's installer with uninstall --no-confirm <receipt>" bad
grep -q '::group::Resolver state' "$tmp/out" && check "recover: logs resolver state" ok || check "recover: logs resolver state" bad

# The installed copy, when present, is preferred over RUNNER_TEMP's.
echo '{}' >"$tmp/nix/receipt.json"
cp "$tmp/runner-temp/nix-installer-0000/nix-installer" "$tmp/nix/nix-installer"
run recover && rc=0 || rc=$?
[ "$rc" = 0 ] && [ ! -e "$tmp/nix/receipt.json" ] && check "recover: uses /nix/nix-installer when present" ok || check "recover: uses /nix/nix-installer when present" bad
rm -f "$tmp/nix/nix-installer"

echo '{}' >"$tmp/nix/receipt.json"
run recover INSTALLER_MODE=fail && rc=0 || rc=$?
[ "$rc" = 1 ] && grep -q '^::error::.*uninstall. failed' "$tmp/out" \
  && check "recover: a failed uninstall stops the retry" ok || check "recover: a failed uninstall stops the retry (rc $rc)" bad

echo '{}' >"$tmp/nix/receipt.json"
run recover INSTALLER_MODE=keep && rc=0 || rc=$?
[ "$rc" = 1 ] && grep -q 'is still there' "$tmp/out" \
  && check "recover: a receipt that survives the uninstall stops the retry" ok || check "recover: a receipt that survives the uninstall stops the retry (rc $rc)" bad

echo '{}' >"$tmp/nix/receipt.json"
rm -rf "${tmp:?}/runner-temp"
run recover && rc=0 || rc=$?
[ "$rc" = 1 ] && grep -q 'no nix-installer binary was found' "$tmp/out" \
  && check "recover: no installer to revert with stops the retry" ok || check "recover: no installer to revert with stops the retry (rc $rc)" bad

rm -f "$tmp/nix/receipt.json"
run recover && rc=0 || rc=$?
[ "$rc" = 0 ] && [ ! -e "$tmp/installer.calls" ] && grep -q 'left no install to revert' "$tmp/out" \
  && check "recover: nothing to revert, retry goes ahead" ok || check "recover: nothing to revert, retry goes ahead (rc $rc)" bad

run recover GETENT_FAILURES=always && rc=0 || rc=$?
[ "$rc" = 0 ] && [ "$(sleeps)" = "4 8 16 32" ] \
  && check "recover: still-failing DNS waits the same bound, then retries anyway" ok \
  || check "recover: still-failing DNS waits the same bound, then retries anyway (rc $rc, '$(sleeps)')" bad

run bogus && rc=0 || rc=$?
[ "$rc" = 2 ] && check "unknown subcommand is a usage error" ok || check "unknown subcommand is a usage error (rc $rc)" bad

exit "$fail"
