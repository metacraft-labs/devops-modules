#!/usr/bin/env bash
# Renders the example caller and checks the bootstrap produces the expected
# Layer-0 resources. Offline (Nix eval only); no AWS credentials.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
json="$(nix eval --json --impure --expr "import ${here}/../example.nix")"
need=(aws_s3_bucket aws_dynamodb_table aws_iam_openid_connect_provider aws_iam_role)
fail=0
for t in "${need[@]}"; do
  n="$(jq --arg t "$t" '.resource[$t] | length' <<<"$json")"
  [[ "$n" -ge 1 ]] || { echo "FAIL: expected resource $t"; fail=1; }
done
# The apply role must be able to DESTROY the roles it manages: the AWS
# provider's aws_iam_role delete calls ListInstanceProfilesForRole (and the
# inline/attached policy listings) before DeleteRole. Missing any of these makes
# a role destroy fail with AccessDenied (observed on a consumer's managed root).
roles_actions="$(jq -r '.resource.aws_iam_role_policy.terraform_apply_managed_iam.policy
  | fromjson | .Statement[] | select(.Sid | test("^Manage.*Roles$")) | .Action[]' <<<"$json")"
for a in iam:DeleteRole iam:ListInstanceProfilesForRole iam:ListRolePolicies iam:ListAttachedRolePolicies iam:DeleteRolePolicy; do
  grep -qxF "$a" <<<"$roles_actions" || { echo "FAIL: managed-IAM roles statement lacks $a"; fail=1; }
done
profile_actions="$(jq -r '.resource.aws_iam_role_policy.terraform_apply_managed_iam.policy
  | fromjson | .Statement[] | select(.Sid | test("^Manage.*InstanceProfiles$")) | .Action[]' <<<"$json")"
grep -qxF "iam:RemoveRoleFromInstanceProfile" <<<"$profile_actions" \
  || { echo "FAIL: managed-IAM instance-profile statement lacks iam:RemoveRoleFromInstanceProfile"; fail=1; }
# Layer 0 is the CI machinery only: the budget and cost-allocation settings are
# account governance, owned by the consumer's CI-applied account root. They must
# not render here, and their old addresses must be forgotten, never destroyed.
for t in aws_budgets_budget aws_ce_cost_allocation_tag aws_ce_cost_category; do
  [[ "$(jq --arg t "$t" '.resource[$t] // {} | length' <<<"$json")" == "0" ]] \
    || { echo "FAIL: $t is not Layer 0 and must not render"; fail=1; }
done
for a in aws_budgets_budget.monthly_cost aws_ce_cost_allocation_tag.project aws_ce_cost_category.agent_harbor_cost_layer; do
  jq -e --arg a "$a" '.removed[] | select(.from == $a and .lifecycle.destroy == false)' <<<"$json" >/dev/null \
    || { echo "FAIL: expected removed { from = $a, destroy = false }"; fail=1; }
done
# No real-account leakage from the example.
# The example must render only placeholder identifiers — flag any 12-digit AWS
# account id other than the 000000000000 placeholder (no real value embedded here).
if jq -e '.. | strings | select(test("[0-9]{12}") and (contains("000000000000") | not))' <<<"$json" >/dev/null 2>&1; then
  echo "FAIL: example rendered company-specific literals"; fail=1
fi
[[ "$fail" == 0 ]] && echo "OK: tf-bootstrap example renders expected Layer-0 resources" || exit 1
