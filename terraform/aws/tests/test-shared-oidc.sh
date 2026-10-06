#!/usr/bin/env bash
# t_tf_bootstrap_shared_oidc
#
# Renders tf-bootstrap.nix BOTH ways and asserts the account-global GitHub
# Actions OIDC provider is either created (owning repo) or referenced (peer
# repo sharing the same AWS account), never both. Offline (Nix eval only);
# no AWS credentials.
#
# The GitHub Actions OIDC provider is account-global: only one repo may own it.
# A second repo sharing the account must REFERENCE it via a data source or the
# bootstrap fails with EntityAlreadyExists.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
module="${here}/../tf-bootstrap.nix"
fail=0

render() { # $1 = extra nix args merged into the caller
  nix eval --json --impure --expr "import ${module} {
    awsAccountId = \"000000000000\";
    awsRegion = \"us-east-1\";
    budgetAlertEmails = [ \"ops@example.com\" ];
    githubBranch = \"live\";
    githubEnvironment = \"production\";
    githubOwner = \"example-org\";
    githubRepo = \"infra\";
    lockTableName = \"example-prod-tofu-locks\";
    namePrefix = \"example-prod\";
    orgLabel = \"Example\";
    ${1}
  }"
}

resource_arn='${aws_iam_openid_connect_provider.github_actions.arn}'
data_arn='${data.aws_iam_openid_connect_provider.github_actions.arn}'
# The three IAM role trust policies that federate to the OIDC provider.
trust_docs=(github_plan_assume github_apply_assume github_drift_assume)

check_trust_refs() { # $1 = json, $2 = expected arn
  local json="$1" want="$2" doc got
  for doc in "${trust_docs[@]}"; do
    got="$(jq -r --arg d "$doc" \
      '.data.aws_iam_policy_document[$d].statement[0].principals[0].identifiers[0]' \
      <<<"$json")"
    [[ "$got" == "$want" ]] \
      || { echo "FAIL: $doc trust policy references '$got', expected '$want'"; fail=1; }
  done
}

# --- Mode 1: owning repo (default / manageGithubOidcProvider = true) --------
for args in "" "manageGithubOidcProvider = true;"; do
  json="$(render "$args")"
  label="${args:-<default>}"
  [[ "$(jq '.resource.aws_iam_openid_connect_provider.github_actions != null' <<<"$json")" == "true" ]] \
    || { echo "FAIL: [$label] expected resource.aws_iam_openid_connect_provider.github_actions"; fail=1; }
  [[ "$(jq '.data.aws_iam_openid_connect_provider // null' <<<"$json")" == "null" ]] \
    || { echo "FAIL: [$label] must NOT emit a data.aws_iam_openid_connect_provider"; fail=1; }
  check_trust_refs "$json" "$resource_arn"
done

# --- Mode 2: peer repo referencing the account-global provider (false) ------
json="$(render "manageGithubOidcProvider = false;")"
[[ "$(jq '.data.aws_iam_openid_connect_provider.github_actions != null' <<<"$json")" == "true" ]] \
  || { echo "FAIL: [false] expected data.aws_iam_openid_connect_provider.github_actions"; fail=1; }
[[ "$(jq -r '.data.aws_iam_openid_connect_provider.github_actions.url' <<<"$json")" \
    == "https://token.actions.githubusercontent.com" ]] \
  || { echo "FAIL: [false] data source must look up the GitHub Actions OIDC URL"; fail=1; }
[[ "$(jq '.resource.aws_iam_openid_connect_provider // null' <<<"$json")" == "null" ]] \
  || { echo "FAIL: [false] must NOT recreate resource.aws_iam_openid_connect_provider"; fail=1; }
check_trust_refs "$json" "$data_arn"

[[ "$fail" == 0 ]] \
  && echo "OK: t_tf_bootstrap_shared_oidc — OIDC provider created xor referenced, trust refs consistent" \
  || exit 1
