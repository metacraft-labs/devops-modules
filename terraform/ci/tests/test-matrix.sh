#!/usr/bin/env bash
# Direct contract tests for terraform-ci-matrix. No credentials or network are
# required. Environment overrides let the Nix check and mutation suite exercise
# the exact same assertions with sandboxed or deliberately altered inputs.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
matrix="${TERRAFORM_CI_MATRIX_SCRIPT:-${here}/../terraform-ci-matrix}"
schema="${TERRAFORM_CI_MATRIX_SCHEMA:-${here}/../metadata.schema.json}"
matrix_bash="${TERRAFORM_CI_MATRIX_BASH:-}"
tmp="$(mktemp -d)"
badtmp=""
github_output="${tmp}/github-output"
failures=0

cleanup() {
  rm -rf "$tmp"
  if [[ -n "$badtmp" ]]; then
    rm -rf "$badtmp"
  fi
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

mkroot() {
  mkdir -p "$tmp/$1"
  cat > "$tmp/$1/metadata.json"
}

run_matrix() {
  if [[ -n "$matrix_bash" ]]; then
    "$matrix_bash" "$matrix" "$@"
  else
    "$matrix" "$@"
  fi
}

expect_row() {
  local root="$1"
  local expression="$2"
  if ! jq -e --arg root "$root" \
    ".include[] | select(.root == \$root) | ${expression}" <<<"$out" >/dev/null; then
    fail "unexpected matrix contract for ${root}: ${expression}"
  fi
}

expect_invalid_backend_flag() {
  local invalid_backend_flag="$1"
  badtmp="$(mktemp -d)"
  mkdir -p "$badtmp/terraform/x/y"
  jq -n --argjson backend_flag "$invalid_backend_flag" '{
    state_key: "terraform/x/y.tfstate",
    state_sensitivity: "standard",
    backend_config_file: "b.hcl",
    credential_mode: "none",
    backend_uses_aws_oidc: $backend_flag,
    enable_checkov: false,
    provider_allowlist: ["hashicorp/archive"]
  }' > "$badtmp/terraform/x/y/metadata.json"
  if run_matrix --root-dir "$badtmp" >/dev/null 2>&1; then
    fail "non-boolean backend_uses_aws_oidc=${invalid_backend_flag} was accepted"
  fi
  rm -rf "$badtmp"
  badtmp=""
}

# The published JSON Schema must expose the optional, false-defaulted backend
# axis and retain the agenix provider requirements.
if ! jq -e '
  .properties.backend_uses_aws_oidc.type == "boolean"
  and .properties.backend_uses_aws_oidc.default == false
  and ((.required | index("backend_uses_aws_oidc")) == null)
  and any(.allOf[];
    .if.properties.credential_mode.const == "agenix-token"
    and (.then.required | sort) == ([
      "agenix_apply_secret_path",
      "agenix_plan_secret_path",
      "credentials_env_name"
    ] | sort)
  )
' "$schema" >/dev/null; then
  fail "metadata schema does not publish the independent backend credential axis"
fi

mkdir -p "$tmp/secrets"
touch \
  "$tmp/secrets/github-plan.age" \
  "$tmp/secrets/github-apply.age" \
  "$tmp/secrets/cloudflare-plan.age" \
  "$tmp/secrets/cloudflare-apply.age" \
  "$tmp/secrets/partial-plan.age"

# Mixed provider/backend credentials.
mkroot terraform/github/governance <<'JSON'
{
  "state_key": "terraform/github/governance.tfstate",
  "state_sensitivity": "standard",
  "backend_config_file": "backends/github.hcl",
  "credential_mode": "agenix-token",
  "backend_uses_aws_oidc": true,
  "credentials_env_name": "GITHUB_TOKEN",
  "agenix_plan_secret_path": "secrets/github-plan.age",
  "agenix_apply_secret_path": "secrets/github-apply.age",
  "enable_checkov": false,
  "provider_allowlist": ["integrations/github"]
}
JSON

# Provider credentials without AWS backend credentials; omission proves the
# compatibility default rather than relying only on an explicit false value.
mkroot terraform/cloudflare/prod <<'JSON'
{
  "state_key": "terraform/cloudflare/prod.tfstate",
  "state_sensitivity": "standard",
  "backend_config_file": "backends/cloudflare.hcl",
  "credential_mode": "agenix-token",
  "credentials_env_name": "CLOUDFLARE_API_TOKEN",
  "agenix_plan_secret_path": "secrets/cloudflare-plan.age",
  "agenix_apply_secret_path": "secrets/cloudflare-apply.age",
  "enable_checkov": false,
  "provider_allowlist": ["cloudflare/cloudflare"]
}
JSON

# Legacy AWS provider behavior remains valid without the new backend field.
mkroot terraform/aws/prod <<'JSON'
{
  "state_key": "terraform/aws/prod.tfstate",
  "state_sensitivity": "standard",
  "backend_config_file": "backends/aws.hcl",
  "credential_mode": "aws-oidc",
  "enable_checkov": true,
  "provider_allowlist": ["hashicorp/aws"]
}
JSON

# Backend-only and wholly credential-free roots prove both sides of the new
# axis for providers that need no runtime credential material.
mkroot terraform/archive/state-backed <<'JSON'
{
  "state_key": "terraform/archive/state-backed.tfstate",
  "state_sensitivity": "standard",
  "backend_config_file": "backends/archive.hcl",
  "credential_mode": "none",
  "backend_uses_aws_oidc": true,
  "enable_checkov": false,
  "provider_allowlist": ["hashicorp/archive"]
}
JSON
mkroot terraform/archive/local <<'JSON'
{
  "state_key": "terraform/archive/local.tfstate",
  "state_sensitivity": "standard",
  "backend_config_file": "backends/local.hcl",
  "credential_mode": "none",
  "backend_uses_aws_oidc": false,
  "enable_checkov": false,
  "provider_allowlist": ["hashicorp/archive"]
}
JSON

# Missing either or both agenix files must suppress provider fields and the
# combined workflow switch, including when the backend requests AWS OIDC.
mkroot terraform/github/pending <<'JSON'
{
  "state_key": "terraform/github/pending.tfstate",
  "state_sensitivity": "standard",
  "backend_config_file": "backends/pending.hcl",
  "credential_mode": "agenix-token",
  "backend_uses_aws_oidc": true,
  "credentials_env_name": "GITHUB_TOKEN",
  "agenix_plan_secret_path": "secrets/missing-plan.age",
  "agenix_apply_secret_path": "secrets/missing-apply.age",
  "enable_checkov": false,
  "provider_allowlist": ["integrations/github"]
}
JSON
mkroot terraform/github/partial <<'JSON'
{
  "state_key": "terraform/github/partial.tfstate",
  "state_sensitivity": "standard",
  "backend_config_file": "backends/partial.hcl",
  "credential_mode": "agenix-token",
  "backend_uses_aws_oidc": true,
  "credentials_env_name": "GITHUB_TOKEN",
  "agenix_plan_secret_path": "secrets/partial-plan.age",
  "agenix_apply_secret_path": "secrets/missing-apply.age",
  "enable_checkov": false,
  "provider_allowlist": ["integrations/github"]
}
JSON

out="$(run_matrix --root-dir "$tmp")"
if [[ "$(jq '.include | length' <<<"$out")" != 7 ]]; then
  fail "expected seven credential-axis roots"
fi

expect_row terraform/github/governance '
  .credential_mode == "agenix-token"
  and .backend_uses_aws_oidc == true
  and .uses_aws_oidc == true
  and .credentials_env_name == "GITHUB_TOKEN"
  and .agenix_plan_secret_path == "secrets/github-plan.age"
  and .agenix_apply_secret_path == "secrets/github-apply.age"'
expect_row terraform/cloudflare/prod '
  .credential_mode == "agenix-token"
  and .backend_uses_aws_oidc == false
  and .uses_aws_oidc == false
  and .credentials_env_name == "CLOUDFLARE_API_TOKEN"
  and .agenix_plan_secret_path == "secrets/cloudflare-plan.age"
  and .agenix_apply_secret_path == "secrets/cloudflare-apply.age"'
expect_row terraform/aws/prod '
  .credential_mode == "aws-oidc"
  and .backend_uses_aws_oidc == false
  and .uses_aws_oidc == true
  and .credentials_env_name == ""'
expect_row terraform/archive/state-backed '
  .credential_mode == "none"
  and .backend_uses_aws_oidc == true
  and .uses_aws_oidc == true
  and .credentials_env_name == ""'
expect_row terraform/archive/local '
  .credential_mode == "none"
  and .backend_uses_aws_oidc == false
  and .uses_aws_oidc == false
  and .credentials_env_name == ""'
for pending_root in terraform/github/pending terraform/github/partial; do
  expect_row "$pending_root" '
    .credential_mode == "agenix-token"
    and .backend_uses_aws_oidc == true
    and .uses_aws_oidc == false
    and .credentials_env_name == ""
    and .agenix_plan_secret_path == ""
    and .agenix_apply_secret_path == ""'
done

# GitHub-output and pretty modes must preserve the exact matrix contract.
run_matrix --root-dir "$tmp" --github-output "$github_output" >/dev/null
if ! jq -Rse --argjson expected "$out" '
  (sub("^matrix="; "") | fromjson) == $expected
' "$github_output" >/dev/null; then
  fail "GitHub output did not preserve the matrix"
fi
if ! run_matrix --root-dir "$tmp" --pretty | jq -e . >/dev/null; then
  fail "pretty output was not valid JSON"
fi

# The new field is strictly boolean. Explicit null is rejected rather than
# silently inheriting the default.
for invalid_backend_flag in '"true"' null 0 '[]' '{}'; do
  expect_invalid_backend_flag "$invalid_backend_flag"
done

# Existing fail-closed validation remains part of the contract.
badtmp="$(mktemp -d)"
mkdir -p "$badtmp/terraform/x/y"
cat > "$badtmp/terraform/x/y/metadata.json" <<'JSON'
{
  "state_key": "wrong.tfstate",
  "state_sensitivity": "standard",
  "backend_config_file": "b.hcl",
  "credential_mode": "none",
  "enable_checkov": false,
  "provider_allowlist": ["hashicorp/archive"]
}
JSON
if run_matrix --root-dir "$badtmp" >/dev/null 2>&1; then
  fail "invalid state key was accepted"
fi
rm -rf "$badtmp"
badtmp=""

badtmp="$(mktemp -d)"
mkdir -p "$badtmp/terraform/x/y"
cat > "$badtmp/terraform/x/y/metadata.json" <<'JSON'
{
  "state_key": "terraform/x/y.tfstate",
  "state_sensitivity": "standard",
  "backend_config_file": "b.hcl",
  "credential_mode": "agenix-token",
  "backend_uses_aws_oidc": true,
  "enable_checkov": false,
  "provider_allowlist": ["integrations/github"]
}
JSON
if run_matrix --root-dir "$badtmp" >/dev/null 2>&1; then
  fail "agenix mode without provider metadata was accepted"
fi
rm -rf "$badtmp"
badtmp=""

if ((failures > 0)); then
  echo "${failures} terraform-ci-matrix contract assertion(s) failed." >&2
  exit 1
fi

echo "OK: terraform-ci-matrix direct contract tests passed"
