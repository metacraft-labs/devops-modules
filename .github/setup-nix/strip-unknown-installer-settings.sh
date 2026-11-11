#!/usr/bin/env bash
#
# strip-unknown-installer-settings.sh — remove installer-written nix.conf
# settings that the Nix it installed does not know.
#
# WHY THIS EXISTS
# ---------------
# `DeterminateSystems/nix-installer-action` (v22 and v23 at the time of
# writing, src/index.ts) unconditionally appends
#
#     build-provenance-tags = {...}
#
# to the installer's extra configuration, even with `determinate: false`. That
# setting belongs to Determinate Nix. The upstream Nix this action installs
# (2.34.x on the ephemeral incus runners) does not know it, so EVERY later nix
# invocation in the job prints
#
#     warning: unknown setting 'build-provenance-tags'
#
# on stderr. Tools that treat stderr as a signal (aztec-avm-runtime's
# verify-m14 asserts an empty stderr) then fail through no fault of their own;
# muting stderr in each consumer would weaken those checks, so the config is
# fixed where it is written.
#
# WHAT IT DOES
# ------------
# For each known installer-only setting, ask the installed Nix whether it
# knows the setting (`nix config show <name>` fails with "could not find
# setting" when it does not) and delete the line from the system nix.conf
# files only if it does not. A Nix that knows the setting (Determinate Nix)
# keeps its configuration untouched. Idempotent; safe when nix is absent.
#
# Environment (for tests): SETUP_NIX_STRIP_CONF_FILES overrides the file list
# (space separated); SETUP_NIX_STRIP_SETTINGS the setting names.

set -euo pipefail

files="${SETUP_NIX_STRIP_CONF_FILES:-/etc/nix/nix.conf /etc/nix/nix.custom.conf}"
settings="${SETUP_NIX_STRIP_SETTINGS:-build-provenance-tags}"

if ! command -v nix >/dev/null 2>&1; then
  echo "strip-unknown-installer-settings: nix is not on PATH; nothing to do"
  exit 0
fi

for setting in $settings; do
  # Only the exact "could not find setting" refusal means "unknown"; any other
  # failure (a broken nix) must not be read as licence to edit configuration.
  if err="$(nix --extra-experimental-features nix-command config show "$setting" 2>&1 >/dev/null)"; then
    echo "strip-unknown-installer-settings: this Nix knows '$setting'; leaving it"
    continue
  fi
  if ! grep -q "could not find setting '$setting'" <<<"$err"; then
    echo "strip-unknown-installer-settings: cannot tell whether Nix knows '$setting' (leaving it): $err" >&2
    continue
  fi
  for f in $files; do
    [ -f "$f" ] || continue
    grep -Eq "^[[:space:]]*(extra-)?${setting}[[:space:]]*=" "$f" || continue
    if [ -w "$f" ]; then
      sed -i -E "/^[[:space:]]*(extra-)?${setting}[[:space:]]*=/d" "$f"
    else
      sudo sed -i -E "/^[[:space:]]*(extra-)?${setting}[[:space:]]*=/d" "$f"
    fi
    echo "strip-unknown-installer-settings: removed '$setting' (unknown to this Nix) from $f"
  done
done
