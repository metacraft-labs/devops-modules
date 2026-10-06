#!/usr/bin/env bash
# Renders the CI-enabling GitHub bootstrap example and checks it produces only
# the Layer-0 CI-authentication plumbing (the four Actions variables), and that
# every address it used to render is forgotten (removed, destroy = false) rather
# than destroyed. Offline (Nix eval only); no creds.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
json="$(nix eval --json --impure --expr "import ${here}/../tf-bootstrap.example.nix")"
fail=0

# Only the Actions variables remain Layer 0.
[[ "$(jq -c '.resource | keys' <<<"$json")" == '["github_actions_variable"]' ]] \
  || { echo "FAIL: expected only github_actions_variable resources, got $(jq -c '.resource | keys' <<<"$json")"; fail=1; }
# The three AWS OIDC role-ARN variables plus the backend-config variable.
[[ "$(jq -c '.resource.github_actions_variable | [.[].variable_name] | sort' <<<"$json")" \
  == '["AWS_TERRAFORM_APPLY_ROLE_ARN","AWS_TERRAFORM_DRIFT_ROLE_ARN","AWS_TERRAFORM_PLAN_ROLE_ARN","BACKEND_CONFIG_FILE"]' ]] \
  || { echo "FAIL: expected the 4 CI-auth Actions variables"; fail=1; }

# Every retired address is forgotten, never destroyed.
retired=(
  github_team.infra
  github_team_membership.infra_initial_maintainer
  github_team_repository.infra
  github_issue_label.sensitive_change
  github_issue_label.allow_destroy
  github_repository_environment.production
  github_branch_protection.main
)
for a in "${retired[@]}"; do
  jq -e --arg a "$a" '.removed[] | select(.from == $a and .lifecycle.destroy == false)' <<<"$json" >/dev/null \
    || { echo "FAIL: expected removed { from = $a, destroy = false }"; fail=1; }
done
[[ "$(jq '[.removed[] | select(.lifecycle.destroy != false)] | length' <<<"$json")" == "0" ]] \
  || { echo "FAIL: a removed block would destroy"; fail=1; }

# Extra team maintainers name their own membership addresses; those are
# forgotten too, and the retired arguments are still accepted.
args='{
  awsAccountId = "000000000000"; awsRegion = "us-east-1"; namePrefix = "example-prod";
  githubOwner = "example-org"; githubRepo = "infra"; protectedBranch = "live";
  reviewerTeam = { name = "infra"; slug = "infra"; description = "x"; initialMaintainer = "example-admin"; additionalMaintainers = [ "second-admin" ]; };
  requiredStatusCheckContexts = [ "ci" ]; enforceAdmins = true;
}'
extra="$(nix eval --json --impure --expr "(import ${here}/../tf-bootstrap.nix ${args}).removed")"
jq -e '.[] | select(.from == "github_team_membership.infra_maintainer_second_admin")' <<<"$extra" >/dev/null \
  || { echo "FAIL: additional maintainer membership address not forgotten"; fail=1; }

# No company literals leak from the example.
# The example must render only placeholder identifiers — flag any 12-digit AWS
# account id other than the 000000000000 placeholder (no real value embedded here).
if jq -e '.. | strings | select(test("[0-9]{12}") and (contains("000000000000") | not))' <<<"$json" >/dev/null 2>&1; then
  echo "FAIL: example rendered company-specific literals"; fail=1
fi

[[ "$fail" == 0 ]] && echo "OK: github tf-bootstrap renders only the Layer-0 CI-auth variables and forgets the rest" || exit 1
