#!/usr/bin/env bash
# Regression test for the github-bootstrap driver: plain `plan` / `apply` /
# `outputs` must work for a Layer-0 root that has NO governance secret manifest
# (a repo-settings root such as bootstrap/github/<org>-prod).
#
# 335db9dd checked for "github-governance-app secrets" at the top level, so every
# action refused every non-governance root with "No github-governance-app secrets
# found". 0b9e93d8 moved the check into the governance-app-secrets action; this
# test pins that.
#
# Mocks, justified: the driver's collaborators are credentialed network tools
# (aws STS, gh, tofu against an S3 backend) and terranix. The behaviour under test
# is the driver's own argument/precondition flow, so each tool is replaced by a
# PATH stub that records its arguments and returns a canned success. No real
# Terraform, AWS or GitHub call is made or needed.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
driver="${here}/../github-bootstrap"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

mkdir -p "$work/bin" "$work/root/bootstrap/github/example-prod" "$work/root/backends"
echo '{ ... }: { }' >"$work/root/bootstrap/github/example-prod/default.nix"
echo 'key = "bootstrap/github/example-prod.tfstate"' >"$work/root/backends/github-example-prod.hcl"
log="$work/calls.log"

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" >"$work/bin/$1"; chmod +x "$work/bin/$1"; }
stub terranix 'echo "{\"output\":{\"expected_aws_account_id\":{\"value\":\"000000000000\"},\"aws_region\":{\"value\":\"us-east-1\"},\"github_repository\":{\"value\":\"example-org/infra\"}}}"'
stub aws "echo \"aws \$*\" >>'$log'; if [[ \"\$*\" == *sts* ]]; then echo '{\"Account\":\"000000000000\"}'; fi"
stub gh "echo \"gh \$*\" >>'$log'; [[ \"\$1\" == auth && \"\$2\" == token ]] && echo stub-token; exit 0"
stub tofu "echo \"tofu \$*\" >>'$log'"
# No secrets manifest exists, so the manifest read fails, as it does for a real
# repo-settings root.
stub nix 'exit 1'

run() { (cd "$work/root" && PATH="$work/bin:$PATH" AWS_PROFILE=stub-profile GITHUB_TOKEN=stub "$driver" "$@"); }

for action in plan apply outputs; do
  : >"$log"
  if ! out="$(run "$action" github/example-prod 2>&1)"; then
    echo "FAIL: '$action' on a root without a governance secret manifest exited non-zero:"
    echo "$out" | sed 's/^/    /'
    fail=1
    continue
  fi
  if grep -q 'No github-governance-app secrets found' <<<"$out"; then
    echo "FAIL: '$action' still runs the governance-app secrets check"; fail=1
  fi
  case "$action" in
    plan) grep -qx 'tofu plan -out=github-bootstrap.tfplan' "$log" || { echo "FAIL: plan did not reach tofu plan"; fail=1; } ;;
    apply) grep -qx 'tofu apply github-bootstrap.tfplan' "$log" || { echo "FAIL: apply did not reach tofu apply"; fail=1; } ;;
    outputs) grep -qx 'tofu output' "$log" || { echo "FAIL: outputs did not reach tofu output"; fail=1; } ;;
  esac
done

# The governance-app secrets action still refuses a non-governance root.
if run governance-app-secrets-plan github/example-prod >/dev/null 2>&1; then
  echo "FAIL: governance-app-secrets-plan accepted a non-governance root"; fail=1
fi

[[ "$fail" == 0 ]] && echo "OK: github-bootstrap plan/apply/outputs work for a root without a governance secret manifest" || exit 1
