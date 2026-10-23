#!/usr/bin/env bash
# Gate for milestone G3 (Sovereign-CI-Fleet): proves the standalone
# Actions-secrets engine (../actions-secrets.nix) emits organization-scoped
# secrets and the deployment-fact outputs a secrets-only Layer-0 root needs, AND
# that the backward-compatible repo-only path (no fact params) still renders a
# valid config that plans cleanly.
#
# Two cases, both terranix -> config.tf.json -> `tofu test`, fully offline:
#   * facts-set  (actions-secrets-org-scope/)          org secrets + fact outputs
#   * facts-unset (actions-secrets-org-scope/repo-only/) no fact outputs present;
#     reproduces the exact regression the review found (terranix strips
#     `value = null`, leaving value-less outputs OpenTofu rejects at plan time)
#     and proves it is fixed by asserting the fact outputs are absent and the
#     config plans cleanly.
#
# No credentials, no network. Mirrors the terranix -> config.tf.json -> `tofu
# test` flow github-bootstrap uses for the real roots.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
src="${here}/actions-secrets-org-scope"

# --- Case 1: facts set (org-scoped secrets + deployment-fact outputs) ---------
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

terranix "${src}/default.nix" > "${work}/config.tf.json"
jq . "${work}/config.tf.json" >/dev/null

# Package selection belongs to the owning shell, not an inherited host alias.
# Exercise the real renderer: poisoning that alias must not change its bytes.
poison_pkgs="${work}/missing-nixpkgs"
NIX_PATH="nixpkgs=${poison_pkgs}" terranix "${src}/default.nix" > "${work}/poisoned-path.json"
cmp "${work}/config.tf.json" "${work}/poisoned-path.json"

# An explicit public --pkgs override still wins. Require its actual missing-path
# error, so an unrelated provider or parsing failure cannot satisfy this arm.
if NIX_PATH='' terranix --pkgs "$poison_pkgs" "${src}/default.nix" \
  > "${work}/override.json" 2> "${work}/override.stderr"; then
  echo "FAIL: explicit missing --pkgs override was ignored" >&2
  exit 1
fi
grep -F -- "$poison_pkgs" "${work}/override.stderr"
grep -Eq 'does not exist|No such file or directory' "${work}/override.stderr"
cp "${src}"/*.tftest.hcl "${work}/"

( cd "$work" && tofu init -input=false -backend=false >/dev/null && tofu test )

# --- Case 2: facts unset (repo-only backward-compatible path) -----------------
# Reproduces the regression: with null fact params, the fact outputs must be
# ABSENT from the rendered config (not present-but-value-less) so the config is
# valid and plans cleanly.
repo_only_src="${src}/repo-only"
repo_only_work="$(mktemp -d)"
trap 'rm -rf "$work" "$repo_only_work"' EXIT

terranix "${repo_only_src}/default.nix" > "${repo_only_work}/config.tf.json"
jq . "${repo_only_work}/config.tf.json" >/dev/null

# Direct regression assertions on the rendered config: none of the three fact
# outputs may be present, and each present output MUST carry a `value` key (the
# precise defect: terranix strips `value = null`, leaving a value-less output).
for fact in expected_aws_account_id aws_region github_access_check_repository; do
  if jq -e --arg k "$fact" '.output | has($k)' "${repo_only_work}/config.tf.json" >/dev/null; then
    echo "FAIL: fact output '${fact}' must be absent for a repo-only (facts-unset) caller" >&2
    exit 1
  fi
done

missing_value="$(jq -r '.output | to_entries[] | select(.value | has("value") | not) | .key' "${repo_only_work}/config.tf.json")"
if [ -n "$missing_value" ]; then
  echo "FAIL: rendered output(s) missing required 'value' key: ${missing_value}" >&2
  exit 1
fi

cp "${repo_only_src}"/*.tftest.hcl "${repo_only_work}/"
( cd "$repo_only_work" && tofu init -input=false -backend=false >/dev/null && tofu test )
