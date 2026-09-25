#!/usr/bin/env bash
# Renders the CI-enabling GitHub bootstrap example and checks it produces the
# expected Layer-0 resources and outputs. Offline (Nix eval only); no creds.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
json="$(nix eval --json --impure --expr "import ${here}/../tf-bootstrap.example.nix")"
fail=0

need=(
  github_team
  github_team_membership
  github_team_repository
  github_actions_variable
  github_issue_label
  github_repository_environment
  github_branch_protection
)
for t in "${need[@]}"; do
  n="$(jq --arg t "$t" '.resource[$t] | length' <<<"$json")"
  [[ "$n" -ge 1 ]] || { echo "FAIL: expected resource $t"; fail=1; }
done

# The three AWS OIDC role-ARN variables plus the backend-config variable.
[[ "$(jq '.resource.github_actions_variable | length' <<<"$json")" == "4" ]] \
  || { echo "FAIL: expected 4 github_actions_variable"; fail=1; }
# Single-maintainer bootstrap default relaxes PR-review gates but keeps checks.
[[ "$(jq '.output.branch_protection_requires_pull_request_reviews.value' <<<"$json")" == "false" ]] \
  || { echo "FAIL: expected relaxed PR reviews under single-maintainer bootstrap"; fail=1; }
[[ "$(jq '.resource.github_branch_protection.main.required_status_checks[0].contexts | length' <<<"$json")" -ge 1 ]] \
  || { echo "FAIL: expected required status checks"; fail=1; }

# The policy's noBypass rule: classic protection binds admins by default, and
# opting out needs a documented enforceAdminsException.
[[ "$(jq '.resource.github_branch_protection.main.enforce_admins' <<<"$json")" == "true" ]] \
  || { echo "FAIL: expected enforce_admins = true by default"; fail=1; }
args='{
  awsAccountId = "000000000000"; awsRegion = "us-east-1"; namePrefix = "example-prod";
  githubOwner = "example-org"; githubRepo = "infra"; protectedBranch = "live";
  reviewerTeam = { name = "infra"; slug = "infra"; description = "x"; initialMaintainer = "example-admin"; };
  requiredStatusCheckContexts = [ ];
}'
bs() { nix eval --json --impure --expr "(import ${here}/../tf-bootstrap.nix (${args} // { $1 })).resource.github_branch_protection" 2>/dev/null; }
if bs 'enforceAdmins = false;' >/dev/null; then
  echo "FAIL: enforceAdmins = false without enforceAdminsException was accepted"; fail=1
fi
[[ "$(bs 'enforceAdmins = false; enforceAdminsException = "documented test exception for the gate";' | jq '.main.enforce_admins')" == "false" ]] \
  || { echo "FAIL: a documented enforceAdminsException was not honoured"; fail=1; }

# No company literals leak from the example.
# The example must render only placeholder identifiers — flag any 12-digit AWS
# account id other than the 000000000000 placeholder (no real value embedded here).
if jq -e '.. | strings | select(test("[0-9]{12}") and (contains("000000000000") | not))' <<<"$json" >/dev/null 2>&1; then
  echo "FAIL: example rendered company-specific literals"; fail=1
fi

[[ "$fail" == 0 ]] && echo "OK: github tf-bootstrap example renders expected Layer-0 resources" || exit 1
