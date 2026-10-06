#!/usr/bin/env bash
# Prove that the direct suite detects semantic weakenings of the independent
# provider/backend credential contract.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
matrix="${TERRAFORM_CI_MATRIX_SCRIPT:-${here}/../terraform-ci-matrix}"
schema="${TERRAFORM_CI_MATRIX_SCHEMA:-${here}/../metadata.schema.json}"
matrix_bash="${TERRAFORM_CI_MATRIX_BASH:-}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

expect_rejected() {
  local name="$1"
  local old="$2"
  local new="$3"
  local mutated="${tmp}/${name}"
  local log="${tmp}/${name}.log"

  python3 - "$matrix" "$mutated" "$old" "$new" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
old = sys.argv[3]
count = source.count(old)
if count != 1:
    raise SystemExit(f"mutation anchor occurs {count} times, expected exactly once: {old!r}")
pathlib.Path(sys.argv[2]).write_text(source.replace(old, sys.argv[4], 1))
PY
  chmod +x "$mutated"

  if TERRAFORM_CI_MATRIX_SCRIPT="$mutated" \
    TERRAFORM_CI_MATRIX_SCHEMA="$schema" \
    TERRAFORM_CI_MATRIX_BASH="$matrix_bash" \
    bash "${here}/test-matrix.sh" >"$log" 2>&1; then
    echo "FAIL: semantic mutation '${name}' escaped the direct suite" >&2
    cat "$log" >&2
    return 1
  fi
}

expect_rejected \
  remove-backend-composition \
  '|| "$backend_uses_aws_oidc" == true' \
  '|| false == true'
expect_rejected \
  bypass-provider-readiness \
  '"$provider_credentials_ready" == true' \
  'true == true'
expect_rejected \
  invert-backend-default \
  ".backend_uses_aws_oidc // false" \
  ".backend_uses_aws_oidc // true"
expect_rejected \
  weaken-backend-type-validation \
  'or (.backend_uses_aws_oidc | type == "boolean")' \
  'or true'
expect_rejected \
  omit-backend-axis-from-output \
  'backend_uses_aws_oidc: $backend_uses_aws_oidc,' \
  'backend_uses_aws_oidc: false,'

echo "OK: terraform-ci-matrix semantic mutations were rejected"
