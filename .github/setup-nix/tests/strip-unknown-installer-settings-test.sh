#!/usr/bin/env bash
# Contract test for ../strip-unknown-installer-settings.sh.
#
# No mocks: the real script runs against the real `nix` on PATH, reading a
# scratch config directory through NIX_CONF_DIR. Each case first proves the
# fixture reproduces the defect (nix prints the unknown-setting warning), so a
# fixture that stopped warning would fail loudly instead of passing vacuously.
# The scratch directory doubles as the "system" config the script edits.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../strip-unknown-installer-settings.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0
# Without a real nix every nix-dependent case would pass or fail vacuously
# (the script itself exits 0 when nix is absent), so refuse to run.
command -v nix >/dev/null 2>&1 || { echo "FAIL - nix is not on PATH; this suite needs a real nix" >&2; exit 1; }
check() { if [ "$2" = ok ]; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }

nix_stderr() {
  NIX_CONF_DIR="$tmp" nix --extra-experimental-features nix-command eval --expr '1' >/dev/null 2>"$tmp/stderr" || true
  cat "$tmp/stderr"
}
# An invented name no Nix knows, so the strip cases mean the same on any Nix
# (a Determinate-flavoured or newer Nix knows the real `build-provenance-tags`).
bogus=metacraft-test-unknown-setting
run_script() { # $1 = setting names
  NIX_CONF_DIR="$tmp" SETUP_NIX_STRIP_CONF_FILES="$tmp/nix.conf" SETUP_NIX_STRIP_SETTINGS="$1" bash "$script" >/dev/null
}
reset_conf() {
  printf '%s = {"k":"v"}\nmax-jobs = 3\n' "$bogus" >"$tmp/nix.conf"
}

# 1. Positive control: the unmodified config reproduces the defect.
reset_conf
if grep -q "unknown setting '$bogus'" <<<"$(nix_stderr)"; then
  check "fixture reproduces the unknown-setting warning" ok
else
  check "fixture reproduces the unknown-setting warning" bad
fi

# 2. The script removes the line and nix is silent afterwards.
run_script "$bogus"
[ -z "$(nix_stderr)" ] && check "stderr is empty after the strip" ok || check "stderr is empty after the strip" bad

# 3. Other settings survive.
grep -qx 'max-jobs = 3' "$tmp/nix.conf" && check "unrelated settings are kept" ok || check "unrelated settings are kept" bad

# 4. Idempotent.
run_script "$bogus" && check "second run succeeds" ok || check "second run succeeds" bad

# 4b. The real default setting: whichever applies to THIS nix, asked of nix.
printf 'build-provenance-tags = {"k":"v"}\nmax-jobs = 3\n' >"$tmp/nix.conf"
NIX_CONF_DIR="$tmp" SETUP_NIX_STRIP_CONF_FILES="$tmp/nix.conf" bash "$script" >/dev/null
if NIX_CONF_DIR="$tmp" nix --extra-experimental-features nix-command config show build-provenance-tags >/dev/null 2>&1; then
  grep -q '^build-provenance-tags' "$tmp/nix.conf" && check "default setting known to this nix => untouched" ok || check "default setting known to this nix => untouched" bad
else
  grep -q '^build-provenance-tags' "$tmp/nix.conf" && check "default setting unknown to this nix => stripped" bad || check "default setting unknown to this nix => stripped" ok
fi

# 5. A setting this nix DOES know is never touched.
printf 'max-jobs = 3\n' >"$tmp/nix.conf"
NIX_CONF_DIR="$tmp" SETUP_NIX_STRIP_CONF_FILES="$tmp/nix.conf" SETUP_NIX_STRIP_SETTINGS=max-jobs bash "$script" >/dev/null
grep -qx 'max-jobs = 3' "$tmp/nix.conf" && check "a known setting is left alone" ok || check "a known setting is left alone" bad

# 6. The action actually invokes the script after installing Nix.
action="$here/../action.yml"
grep -q 'strip-unknown-installer-settings.sh' "$action" && check "action.yml invokes the script" ok || check "action.yml invokes the script" bad

exit "$fail"
