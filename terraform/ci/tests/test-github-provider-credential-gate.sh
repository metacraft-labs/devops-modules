#!/usr/bin/env bash
# Contract tests for github-provider-credential-gate. No credentials, network
# or tofu: each case is a root directory holding the files the gate reads
# (metadata.json and rendered *.tf.json / *.tf), written by hand in the shapes
# terranix and the shared terraform-ci-matrix metadata schema produce.
#
# No mocks: the real script runs against real files on disk. The only stand-in
# is GITHUB_TOKEN, set to a dummy string or unset, which is exactly the input
# the gate inspects.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
gate="${GITHUB_PROVIDER_CREDENTIAL_GATE_SCRIPT:-${here}/../github-provider-credential-gate}"
python="${GITHUB_PROVIDER_CREDENTIAL_GATE_PYTHON:-python3}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

# root NAME — create an empty root directory.
root() { mkdir -p "$tmp/$1"; }
# file NAME PATH — write stdin to a file in a root.
file() { cat > "$tmp/$1/$2"; }

# expect NAME EXIT TOKEN [ARGS...] — run the gate with GITHUB_TOKEN=TOKEN
# ("-" leaves it unset) and check its exit status.
expect() {
  local name="$1" want="$2" token="$3"
  shift 3
  local got=0
  if [[ "$token" == "-" ]]; then
    env -u GITHUB_TOKEN "$python" "$gate" "$tmp/$name" "$@" > "$tmp/$name.out" 2>&1 || got=$?
  else
    GITHUB_TOKEN="$token" "$python" "$gate" "$tmp/$name" "$@" > "$tmp/$name.out" 2>&1 || got=$?
  fi
  if [[ "$got" != "$want" ]]; then
    fail "$name: exit $got, want $want"
    sed 's/^/    /' "$tmp/$name.out" >&2
  fi
}

contains() {
  grep -qF -- "$2" "$tmp/$1.out" || fail "$1: output lacks '$2'"
}

governance_metadata='{"credential_mode":"github-app","github_app_owner":"acme","backend_config_file":"b.hcl","state_key":"k","state_sensitivity":"standard","provider_allowlist":["integrations/github"]}'
github_provider='{"provider":{"github":{"owner":"acme"}},"resource":{}}'

# --- The 2026-09-24 incident: github-app root, caller dropped the owner --------
root incident
file incident metadata.json <<< "$governance_metadata"
file incident config.tf.json <<< "$github_provider"
expect incident 3 -
contains incident "empty github_app_owner"
contains incident "anonymous access"

# Owner passed but the token step produced nothing: still refused.
root owner-no-token
file owner-no-token metadata.json <<< "$governance_metadata"
file owner-no-token config.tf.json <<< "$github_provider"
expect owner-no-token 3 "" --github-app-owner acme
contains owner-no-token "GITHUB_TOKEN is empty"

# Correctly wired.
root wired
file wired metadata.json <<< "$governance_metadata"
file wired config.tf.json <<< "$github_provider"
expect wired 0 dummy-token --github-app-owner acme

# Owner mismatch: a token minted for the wrong installation.
root mismatch
file mismatch metadata.json <<< "$governance_metadata"
file mismatch config.tf.json <<< "$github_provider"
expect mismatch 3 dummy-token --github-app-owner other-org
contains mismatch "does not match"

# github-app metadata alone, token present but owner empty: wiring bug.
root no-owner-with-token
file no-owner-with-token metadata.json <<< "$governance_metadata"
file no-owner-with-token config.tf.json <<< "$github_provider"
expect no-owner-with-token 3 dummy-token
contains no-owner-with-token "empty github_app_owner"

# --- Roots that do not use the github provider are untouched -----------------
root aws-root
file aws-root metadata.json <<< '{"credential_mode":"aws-oidc"}'
file aws-root config.tf.json <<< '{"provider":{"aws":{"region":"us-east-1"}}}'
expect aws-root 0 -

root no-metadata
file no-metadata config.tf.json <<< '{"provider":{"cloudflare":{}}}'
expect no-metadata 0 -

# --- Inline credentials satisfy the provider check ---------------------------
root inline-app-auth
file inline-app-auth config.tf.json <<< '{"provider":{"github":[{"owner":"acme","app_auth":{"id":"1","installation_id":"2","pem_file":"x"}}]}}'
expect inline-app-auth 0 -

# Aliased providers: one block without a credential is enough to refuse.
root alias-missing
file alias-missing config.tf.json <<< '{"provider":[{"github":{"owner":"a","token":"t"}},{"github":{"alias":"b","owner":"b"}}]}'
expect alias-missing 3 -

# HCL roots.
root hcl-env
file hcl-env main.tf <<'HCL'
provider "github" {
  owner = "acme"
}
HCL
expect hcl-env 3 -
expect hcl-env 0 dummy-token

root hcl-inline
file hcl-inline main.tf <<'HCL'
provider "github" {
  owner = "acme"
  app_auth {}
}
HCL
expect hcl-inline 0 -

# --- Fail closed on unreadable inputs ----------------------------------------
root bad-json
printf 'not json' > "$tmp/bad-json/config.tf.json"
expect bad-json 2 -
expect missing-dir 2 -

if ((failures > 0)); then
  echo "github-provider-credential-gate tests: ${failures} failure(s)" >&2
  exit 1
fi
echo "github-provider-credential-gate tests: all passed"
