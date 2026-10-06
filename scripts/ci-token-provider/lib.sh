#!/usr/bin/env bash
# Org-agnostic helpers for provisioning the CI-token-provider GitHub App
# secrets onto repositories.
#
# Model
# -----
# A GitHub App with a non-expiring private key mints short-lived
# installation tokens on demand (in CI via the `create-app-token`
# composite action in this repo). Consumers store the App ID and the
# App private key as per-repo Actions secrets:
#
#   * CI_TOKEN_PROVIDER_APP_ID      — numeric App ID (public)
#   * CI_TOKEN_PROVIDER_PRIVATE_KEY — App RSA private key, PEM
#
# This library is deliberately company-agnostic: the App ID, the agenix
# file holding the private key, the age identity, the target repos, and
# (optionally) the secret names are all provided by the caller. Each
# company's infra repo supplies those values; the logic lives here.
#
# Required inputs (env):
#   CTP_APP_ID        numeric GitHub App ID
#   CTP_KEY_AGE       path to the agenix file holding the App private key
#   CTP_AGE_IDENTITY  path to an age identity that can decrypt CTP_KEY_AGE
#
# Optional inputs (env), with defaults:
#   CTP_APP_ID_SECRET_NAME       (default: CI_TOKEN_PROVIDER_APP_ID)
#   CTP_PRIVATE_KEY_SECRET_NAME  (default: CI_TOKEN_PROVIDER_PRIVATE_KEY)

set -euo pipefail

CTP_APP_ID_SECRET_NAME="${CTP_APP_ID_SECRET_NAME:-CI_TOKEN_PROVIDER_APP_ID}"
CTP_PRIVATE_KEY_SECRET_NAME="${CTP_PRIVATE_KEY_SECRET_NAME:-CI_TOKEN_PROVIDER_PRIVATE_KEY}"

ctp_require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ci-token-provider: required command '$cmd' is not on PATH" >&2
    return 1
  fi
}

ctp_require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "ci-token-provider: required env '$name' is not set" >&2
    return 1
  fi
}

# Decrypt the App private key from the age file and print the PEM to
# stdout. Run once and reuse to avoid repeated passphrase prompts.
ctp_decrypt_private_key() {
  ctp_require_command age
  ctp_require_env CTP_KEY_AGE
  ctp_require_env CTP_AGE_IDENTITY
  if [[ ! -f "$CTP_KEY_AGE" ]]; then
    echo "ci-token-provider: agenix file not found at: $CTP_KEY_AGE" >&2
    return 1
  fi
  if [[ ! -f "$CTP_AGE_IDENTITY" ]]; then
    echo "ci-token-provider: age identity not found at: $CTP_AGE_IDENTITY" >&2
    return 1
  fi
  age --decrypt -i "$CTP_AGE_IDENTITY" "$CTP_KEY_AGE"
}

# Set both secrets on a single repo. The PEM is piped in over stdin so it
# never lands in `ps` output, on disk, or in shell history.
#
#   $1    — owner/name of the repo
#   stdin — the App private key PEM
ctp_apply_to_repo() {
  local repo="$1"
  ctp_require_command gh
  ctp_require_env CTP_APP_ID

  if [[ ! "$repo" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
    echo "ci-token-provider: repo '$repo' must be in owner/name form" >&2
    return 2
  fi

  local pem
  pem=$(cat)
  if [[ -z "$pem" ]]; then
    echo "ci-token-provider: empty PEM piped in for $repo" >&2
    return 1
  fi

  echo "==> $repo"
  gh secret set "$CTP_APP_ID_SECRET_NAME" --body "$CTP_APP_ID" --repo "$repo"
  printf '%s' "$pem" | gh secret set "$CTP_PRIVATE_KEY_SECRET_NAME" --repo "$repo"
}
