#!/usr/bin/env bash
# Keep a transient DNS failure from failing the Nix install.
#
# The installer action needs two names: cf.install.determinate.systems (the
# installer binary, unless the Actions cache serves it) and releases.nixos.org
# (the Nix tarball, which the installer fetches itself). On 2026-11-25 infra
# #2480's eval shard 05 failed on runner garm-s6s02y3sz2ix with
#
#   error sending request for url (https://releases.nixos.org/nix/nix-2.35.6/...)
#   dns error: failed to lookup address information: Try again
#
# 11 s after api.github.com and cf.install.determinate.systems had resolved on
# the same runner: a transient resolver failure (EAI_AGAIN), not a missing
# resolver. The caller's fail-fast then cancelled 22 sibling shards.
#
#   wait     Before the install. Wait, bounded, until both names resolve.
#            Never fails the step: the install that follows is the real test.
#   recover  After a failed install. Log the resolver state, revert the
#            partial install, and wait again, so the action can run once more.
#
# Why `recover` must revert: a failed `nix-installer install` writes
# /nix/receipt.json and, under NIX_INSTALLER_NO_CONFIRM (which the action
# sets), does not revert. The action treats that file as "Nix is already
# installed", so a second attempt would report success with no Nix. When the
# receipt cannot be removed, `recover` fails, and the second attempt does not
# run.
#
# Bounds: SETUP_NIX_DNS_ATTEMPTS lookups (default 5), SETUP_NIX_DNS_DELAY
# seconds before the second (default 4), doubling: 4+8+16+32 = 60 s of sleep,
# and each lookup is capped at SETUP_NIX_DNS_LOOKUP_TIMEOUT seconds (default
# 8). About two minutes at worst per call.
#
# This file is kept byte-identical in metacraft-labs/devops-modules
# (.github/setup-nix) and metacraft-labs/metacraft-github-actions (setup-nix);
# devops-modules' scripts/check-setup-nix-alignment.py fails when they differ.

set -uo pipefail

read -r -a hosts <<<"${SETUP_NIX_DNS_HOSTS:-releases.nixos.org cf.install.determinate.systems}"
attempts="${SETUP_NIX_DNS_ATTEMPTS:-5}"
first_delay="${SETUP_NIX_DNS_DELAY:-4}"
lookup_timeout="${SETUP_NIX_DNS_LOOKUP_TIMEOUT:-8}"
nix_dir="${SETUP_NIX_NIX_DIR:-/nix}"
receipt="$nix_dir/receipt.json"
diagnosed=false

with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$lookup_timeout" "$@"
  else
    "$@"
  fi
}

# getaddrinfo through NSS, as the installer resolves. getent is Linux-only;
# elsewhere ask curl: exit 6 is "could not resolve host" and 28 a timeout
# (counted as unresolved, to be safe); any other answer, an HTTP error
# included, means the name resolved.
resolves() {
  if command -v getent >/dev/null 2>&1; then
    with_timeout getent hosts "$1" >/dev/null 2>&1
  else
    local rc=0
    curl -sS -o /dev/null --max-time "$lookup_timeout" "https://$1/" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 6 ] && [ "$rc" -ne 28 ]
  fi
}

diagnose() {
  diagnosed=true
  echo "::group::Resolver state (for: $*)"
  if [ -r /etc/resolv.conf ]; then
    echo "--- /etc/resolv.conf"
    grep -v '^[[:space:]]*#' /etc/resolv.conf
  fi
  if command -v resolvectl >/dev/null 2>&1; then
    echo "--- resolvectl status"
    with_timeout resolvectl status 2>&1 | head -40
  fi
  if command -v scutil >/dev/null 2>&1; then
    echo "--- scutil --dns"
    scutil --dns 2>&1 | head -40
  fi
  if command -v ip >/dev/null 2>&1; then
    echo "--- default route"
    ip route show default 2>&1
  fi
  local host
  for host in "$@"; do
    if command -v getent >/dev/null 2>&1; then
      echo "--- getent ahosts $host"
      with_timeout getent ahosts "$host" 2>&1
      echo "(exit $?)"
    fi
  done
  echo "::endgroup::"
}

# 0 when every host resolves within the bound, 1 otherwise.
wait_for_hosts() {
  local attempt delay=$first_delay host pending
  for ((attempt = 1; ; attempt++)); do
    pending=()
    for host in "${hosts[@]}"; do
      resolves "$host" || pending+=("$host")
    done
    if [ "${#pending[@]}" -eq 0 ]; then
      echo "Resolved ${hosts[*]} (attempt $attempt of $attempts)."
      return 0
    fi
    echo "Attempt $attempt of $attempts: cannot resolve ${pending[*]}."
    if [ "$diagnosed" = false ]; then
      diagnose "${pending[@]}"
    fi
    if [ "$attempt" -ge "$attempts" ]; then
      return 1
    fi
    echo "Retrying in ${delay}s."
    sleep "$delay"
    delay=$((delay * 2))
  done
}

# The installer binary that wrote the receipt: the installed copy if the
# install got that far, else the one the action unpacked into RUNNER_TEMP.
find_installer() {
  if [ -x "$nix_dir/nix-installer" ]; then
    echo "$nix_dir/nix-installer"
    return 0
  fi
  local candidate newest=""
  for candidate in "${RUNNER_TEMP:-/nonexistent}"/nix-installer-*/nix-installer; do
    [ -x "$candidate" ] || continue
    if [ -z "$newest" ] || [ "$candidate" -nt "$newest" ]; then
      newest="$candidate"
    fi
  done
  [ -n "$newest" ] && echo "$newest"
}

revert_partial_install() {
  if [ ! -e "$receipt" ]; then
    echo "No $receipt: the failed attempt left no install to revert."
    return 0
  fi
  local installer sudo=()
  installer="$(find_installer)"
  if [ -z "$installer" ]; then
    echo "::error::The failed Nix install left $receipt, and no nix-installer binary was found to revert it (looked in $nix_dir and ${RUNNER_TEMP:-RUNNER_TEMP}/nix-installer-*). Not retrying: the action would read the receipt as a working install."
    return 1
  fi
  [ "$(id -u)" -eq 0 ] || sudo=(sudo)
  echo "Reverting the partial install with $installer."
  # ${a[@]+...}: bash 3.2 (macOS) rejects an empty "${a[@]}" under set -u.
  if ! ${sudo[@]+"${sudo[@]}"} "$installer" uninstall --no-confirm "$receipt"; then
    echo "::error::'$installer uninstall' failed, so $receipt may describe a broken install. Not retrying."
    return 1
  fi
  if [ -e "$receipt" ]; then
    echo "::error::'$installer uninstall' succeeded but $receipt is still there. Not retrying: the action would read it as a working install."
    return 1
  fi
  echo "Reverted; $receipt is gone."
}

case "${1:-}" in
  wait)
    if ! wait_for_hosts; then
      echo "::warning::${hosts[*]} did not all resolve after $attempts attempts; installing Nix anyway (resolver state is logged above)."
    fi
    ;;
  recover)
    echo "::warning::The first Nix install attempt failed. Reverting it and retrying once; the installer's error is in the previous step."
    diagnose "${hosts[@]}"
    revert_partial_install || exit 1
    if ! wait_for_hosts; then
      echo "::warning::${hosts[*]} still do not all resolve; retrying the install anyway."
    fi
    ;;
  *)
    echo "usage: $0 wait|recover" >&2
    exit 2
    ;;
esac
