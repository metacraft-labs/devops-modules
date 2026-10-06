#!/usr/bin/env bash
# Reclaim enough space for large Nix realizations on a disposable standard
# GitHub-hosted Linux runner. This is deliberately not a general cleanup
# helper: the fixed allowlist contains only preinstalled toolchains that an
# opted-in Nix job has declared it does not need.

set -euo pipefail

readonly minimum_available_kib=20971520
readonly reclamation_paths=(
  /usr/local/lib/android
  /usr/share/dotnet
  /opt/ghc
  /usr/local/.ghcup
  /opt/hostedtoolcache/CodeQL
)

fail() {
  echo "::error::$*" >&2
  exit 1
}

if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
  fail "Hosted-runner disk reclamation requires GitHub Actions."
fi
if [[ "${SETUP_NIX_RUNNER_ENVIRONMENT:-}" != "github-hosted" ]]; then
  fail "Hosted-runner disk reclamation refused runner.environment=${SETUP_NIX_RUNNER_ENVIRONMENT:-<unset>}."
fi
if [[ "${SETUP_NIX_RUNNER_OS:-}" != "Linux" ]]; then
  fail "Hosted-runner disk reclamation supports only GitHub-hosted Linux runners."
fi

for utility in awk df sudo; do
  command -v "$utility" >/dev/null 2>&1 || fail "Required pre-Nix utility is unavailable: $utility"
done

available_kib() {
  local value
  value="$(LC_ALL=C df -Pk / | awk 'NR == 2 { print $4 }')"
  case "$value" in
    '' | *[!0-9]*) fail "Could not measure available root-filesystem space." ;;
  esac
  printf '%s\n' "$value"
}

before_kib="$(available_kib)"
echo "Root filesystem available before reclamation: ${before_kib} KiB"

for path in "${reclamation_paths[@]}"; do
  echo "Reclaiming fixed GitHub image path: $path"
  sudo -n rm -rf --one-file-system -- "$path"
  if [[ -e "$path" || -L "$path" ]]; then
    fail "Fixed reclamation path remains after removal: $path"
  fi
done

after_kib="$(available_kib)"
echo "Root filesystem available after reclamation: ${after_kib} KiB"
if ((after_kib < minimum_available_kib)); then
  fail "Only ${after_kib} KiB is available after reclamation; at least ${minimum_available_kib} KiB is required."
fi

echo "GitHub-hosted runner disk reclamation passed."
