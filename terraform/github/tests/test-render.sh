#!/usr/bin/env bash
# Renders the governance example and checks the engine produces the expected
# github_* resources and outputs. Offline (Nix eval only); no credentials.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
json="$(nix eval --json --impure --expr "import ${here}/../governance.example.nix")"
fail=0

# Core governance resources the example models.
need=(
  github_actions_organization_permissions
  github_repository
  github_branch_default
  github_team_repository
  github_branch_protection
  github_repository_environment
  github_actions_repository_permissions
  github_actions_variable
  github_issue_label
  github_membership
  github_repository_vulnerability_alerts
  github_repository_dependabot_security_updates
)
for t in "${need[@]}"; do
  n="$(jq --arg t "$t" '.resource[$t] | length' <<<"$json")"
  [[ "$n" -ge 1 ]] || { echo "FAIL: expected resource $t"; fail=1; }
done

# The team data source is emitted for the granted team.
[[ "$(jq '.data.github_team | length' <<<"$json")" -ge 1 ]] || { echo "FAIL: expected github_team data source"; fail=1; }

# Manifest counting output is wired through.
[[ "$(jq '.output.secret_manifest_count.value' <<<"$json")" == "1" ]] || { echo "FAIL: secret_manifest_count"; fail=1; }
# The declared-but-unmanaged secret renders no secret resource and needs no payload.
[[ "$(jq 'has("github_actions_organization_secret") | not' <<<"$(jq .resource <<<"$json")")" == "true" ]] \
  || { echo "FAIL: unexpected managed secret resource without payload"; fail=1; }

# security_and_analysis carries exactly the two sub-blocks the provider both
# writes and reads back. The other four are schema-only or renamed upstream, so
# emitting them would produce a permanent, unappliable diff. This is the
# assertion that keeps a well-meaning addition from reintroducing one.
sa='.resource.github_repository.repo_docs.security_and_analysis[0]'
[[ "$(jq -r "$sa | keys | join(\",\")" <<<"$json")" == "secret_scanning,secret_scanning_push_protection" ]] \
  || { echo "FAIL: security_and_analysis must emit exactly secret_scanning + secret_scanning_push_protection"; fail=1; }
[[ "$(jq -r "$sa.secret_scanning[0].status" <<<"$json")" == "enabled" ]] \
  || { echo "FAIL: security_and_analysis status not carried through"; fail=1; }

# A repository without the inventory field emits no block at all, so the
# attribute stays Computed rather than being asserted to a default.
[[ "$(jq '.resource.github_repository.repo_infra | has("security_and_analysis") | not' <<<"$json")" == "true" ]] \
  || { echo "FAIL: security_and_analysis emitted for a repository that does not declare it"; fail=1; }

# Negative control: the sub-blocks provider 6.12.1 cannot round-trip must be
# rejected loudly at eval time rather than rendered into an unappliable plan.
bad_expr="$(cat <<NIX
let
  engine = import ${here}/../governance.nix;
in
engine {
  awsAccountId = "000000000000";
  awsRegion = "us-east-1";
  githubOwner = "example-org";
  githubBootstrapStateKey = "k";
  manifest.secrets = [ ];
  governance = {
    snapshot.source = "s";
    organization.actionsPermissions = {
      enabledRepositories = "all";
      allowedActions = "all";
      shaPinningRequired = true;
    };
    repositories = [
      {
        name = "docs";
        visibility = "public";
        hasIssues = true;
        hasProjects = false;
        hasWiki = false;
        hasDiscussions = false;
        allowForking = true;
        archived = false;
        isTemplate = false;
        webCommitSignoffRequired = false;
        defaultBranch = "main";
        securityAndAnalysis = {
          secretScanning = "enabled";
          secretScanningPushProtection = "enabled";
          advancedSecurity = "enabled";
        };
      }
    ];
    memberships = [ ];
    outsideCollaborators = [ ];
    teamRepositories = [ ];
    branchProtections = [ ];
    repositoryEnvironments = [ ];
    actionsRepositoryPermissions = [ ];
    actionsVariables = [ ];
    issueLabels = [ ];
    deferredResources = [ ];
  };
}
NIX
)"
if nix eval --json --impure --expr "$bad_expr" >/dev/null 2>&1; then
  echo "FAIL: advancedSecurity must be rejected — the provider sends a field GitHub renamed, so it diffs forever"
  fail=1
fi

# ---------------------------------------------------------------------------
# Runner groups, and in particular the WORKFLOW-RESTRICTED shape.
#
# `restricted_to_workflows` was emitted for a long time while `selected_workflows`
# was not, and that pairing is not merely incomplete — GitHub reads a true
# restriction with an empty list as "admit NOTHING", so a group emitted that way
# takes its runners offline for every workflow in the org. These assertions are
# what keep the two fields from drifting apart again.
rg='.resource.github_actions_runner_group'
n_rg="$(jq "$rg | length" <<<"$json")"
[[ "$n_rg" == "2" ]] || { echo "FAIL: expected 2 runner groups, rendered $n_rg — the assertions below would be vacuous"; fail=1; }

# The unrestricted group carries no admission list at all: a group that does not
# restrict must not emit `selected_workflows`, or the attribute is asserted to a
# default the provider then diffs against.
unrestricted="$(jq -r "$rg | to_entries[] | select(.value.restricted_to_workflows == false) | .key" <<<"$json")"
[[ -n "$unrestricted" ]] || { echo "FAIL: no unrestricted runner group rendered"; fail=1; }
[[ "$(jq "${rg}[\"$unrestricted\"] | has(\"selected_workflows\") | not" <<<"$json")" == "true" ]] \
  || { echo "FAIL: an unrestricted runner group emitted selected_workflows"; fail=1; }

# The restricted group carries a NON-EMPTY list, and each entry is fully
# qualified — GitHub accepts no wildcards, and an entry it cannot parse does not
# error, it simply never matches, so the reservation silently shrinks.
restricted="$(jq -r "$rg | to_entries[] | select(.value.restricted_to_workflows == true) | .key" <<<"$json")"
[[ -n "$restricted" ]] || { echo "FAIL: no workflow-restricted runner group rendered"; fail=1; }
n_wf="$(jq "${rg}[\"$restricted\"].selected_workflows | length" <<<"$json")"
[[ "${n_wf:-0}" -ge 1 ]] \
  || { echo "FAIL: a restricted runner group rendered $n_wf selected_workflows — GitHub reads that as admitting NOTHING"; fail=1; }
bad_wf="$(jq -r "(${rg}[\"$restricted\"].selected_workflows // [])[] | select(test(\"^[^/]+/[^/]+/\\\\.github/workflows/[^@]+@(refs/(heads|tags)/.+|[0-9a-f]{40})$\") | not)" <<<"$json")"
[[ -z "$bad_wf" ]] \
  || { echo "FAIL: selected_workflows entries are not OWNER/REPO/.github/workflows/FILE@<fully-qualified-ref>: $bad_wf"; fail=1; }

# No company literals leak from the example.
# The example must render only placeholder identifiers — flag any 12-digit AWS
# account id other than the 000000000000 placeholder (no real value embedded here).
if jq -e '.. | strings | select(test("[0-9]{12}") and (contains("000000000000") | not))' <<<"$json" >/dev/null 2>&1; then
  echo "FAIL: example rendered company-specific literals"; fail=1
fi

[[ "$fail" == 0 ]] && echo "OK: governance example renders expected github_* resources" || exit 1
