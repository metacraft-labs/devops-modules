#!/usr/bin/env bash
# Exercises governance.nix `noBypassPolicy`: the shared branch-protection
# policy's `noBypass` rule (branching-policy.md "No bypass"). With the policy
# on, every rendered ruleset must be `active` with no bypass actors and every
# classic branch protection must set enforce_admins and name no pull-request
# bypassers — unless the resource carries a documented exception. The render
# THROWS otherwise, so a violating plan cannot be produced at all.
#
# Offline: Nix eval of the real engine over a literal inventory. No mocks.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
engine="${here}/../governance.nix"
fail=0

# $1 = extra governance fields (Nix attrset body), $2 = noBypassPolicy expr
render() {
  nix eval --json --impure --expr "
    let
      rs = name: extra: {
        repository = \"repo\"; inherit name; target = \"branch\"; enforcement = \"active\";
        conditions = { refNameInclude = [ \"refs/heads/dev\" ]; refNameExclude = [ ]; };
        rules = { deletion = true; nonFastForward = true; };
        bypassActors = [ ];
      } // extra;
      bp = extra: {
        repository = \"repo\"; pattern = \"dev\"; enforceAdmins = true;
        allowsDeletions = false; allowsForcePushes = false; requiredLinearHistory = false;
        requireConversationResolution = false; requireSignedCommits = false; lockBranch = false;
      } // extra;
    in import ${engine} {
      awsAccountId = \"000000000000\";
      awsRegion = \"us-east-1\";
      githubOwner = \"example-org\";
      githubBootstrapStateKey = \"x.tfstate\";
      manifest.secrets = [ ];
      noBypassPolicy = $2;
      governance = {
        snapshot.source = \"fixture\";
        organization.actionsPermissions = { enabledRepositories = \"all\"; allowedActions = \"all\"; shaPinningRequired = false; };
        repositories = [ ];
        memberships = [ ];
        teamRepositories = [ ];
        outsideCollaborators = [ ];
        branchProtections = [ ];
        repositoryEnvironments = [ ];
        actionsRepositoryPermissions = [ ];
        actionsVariables = [ ];
        issueLabels = [ ];
        repositoryRulesets = [ ];
        organizationRulesets = [ ];
        deferredResources = [ ];
      } // { $1 };
    }
  "
}

expect_ok() { # $1 desc, $2 fields, $3 policy
  if out="$(render "$2" "$3" 2>&1)"; then echo "ok: $1"; else echo "FAIL: $1 (${out: -300})"; fail=1; fi
}
expect_reject() { # $1 desc, $2 fields, $3 policy, $4 expected message fragment
  if out="$(render "$2" "$3" 2>&1)"; then
    echo "FAIL: $1 (was accepted)"; fail=1
  elif grep -qF -- "$4" <<<"$out"; then
    echo "ok: $1"
  else
    echo "FAIL: $1 (rejected, but not with \"$4\": ${out: -300})"; fail=1
  fi
}

admin='[ { actorId = 0; actorType = "OrganizationAdmin"; bypassMode = "always"; } ]'
on='{ }'

expect_ok "a clean inventory renders with the policy on" \
  "repositoryRulesets = [ (rs \"mainline-protect\" { }) ]; branchProtections = [ (bp { }) ];" "$on"
expect_ok "the policy is opt-in: null accepts a bypass (backward compatible)" \
  "repositoryRulesets = [ (rs \"mainline-protect\" { bypassActors = ${admin}; }) ];" "null"
expect_reject "a repository ruleset with an OrganizationAdmin bypass is rejected" \
  "repositoryRulesets = [ (rs \"mainline-protect\" { bypassActors = ${admin}; }) ];" "$on" \
  "repository-ruleset:repo:mainline-protect: has bypass actors"
expect_reject "an organization ruleset with a RepositoryRole bypass is rejected" \
  "organizationRulesets = [ ((builtins.removeAttrs (rs \"Standard ruleset\" { }) [ \"repository\" ]) // { conditions = { refNameInclude = [ \"~DEFAULT_BRANCH\" ]; refNameExclude = [ ]; repositoryNameInclude = [ \"~ALL\" ]; repositoryNameExclude = [ ]; }; bypassActors = [ { actorId = 5; actorType = \"RepositoryRole\"; bypassMode = \"always\"; } ]; }) ];" "$on" \
  "organization-ruleset:Standard ruleset: has bypass actors"
expect_reject "an evaluate-mode ruleset is rejected" \
  "repositoryRulesets = [ (rs \"mainline-protect\" { enforcement = \"evaluate\"; }) ];" "$on" \
  "enforcement is \`evaluate\`, not \`active\`"
expect_reject "classic protection with enforce_admins = false is rejected" \
  "branchProtections = [ (bp { enforceAdmins = false; }) ];" "$on" \
  "branch-protection:repo:dev: enforce_admins is false"
expect_reject "classic protection naming pull-request bypassers is rejected" \
  "branchProtections = [ (bp { requiredPullRequestReviews = { dismissStaleReviews = false; requireCodeOwnerReviews = false; requireLastPushApproval = false; requiredApprovingReviewCount = 0; pullRequestBypassers = [ \"/someone\" ]; }; }) ];" "$on" \
  "names pull-request bypassers"
expect_ok "a documented ruleset exception is honoured" \
  "repositoryRulesets = [ (rs \"legacy\" { enforcement = \"disabled\"; }) ];" \
  '{ rulesetExceptions."repository-ruleset:repo:legacy" = "disabled legacy ruleset, enforces nothing"; }'
expect_ok "a documented branch-protection exception is honoured" \
  "branchProtections = [ (bp { enforceAdmins = false; }) ];" \
  '{ branchProtectionExceptions."branch-protection:repo:dev" = "coordinated upstream rebase window, see PR"; }'
expect_reject "an exception without a real reason is rejected" \
  "repositoryRulesets = [ (rs \"legacy\" { enforcement = \"disabled\"; }) ];" \
  '{ rulesetExceptions."repository-ruleset:repo:legacy" = "legacy"; }' \
  "has no documented reason"
expect_reject "a stale exception (no such resource) is rejected" \
  "repositoryRulesets = [ (rs \"mainline-protect\" { }) ];" \
  '{ rulesetExceptions."repository-ruleset:repo:gone" = "retired ruleset that no longer exists"; }' \
  "names no rendered resource"

counts="$(render "repositoryRulesets = [ (rs \"a\" { bypassActors = ${admin}; enforcement = \"evaluate\"; }) (rs \"b\" { }) ]; branchProtections = [ (bp { enforceAdmins = false; }) ];" null)"
[[ "$(jq -c '[.output.github_governance_ruleset_bypass_actor_count.value, .output.github_governance_ruleset_non_active_count.value, .output.github_governance_branch_protection_admin_bypass_count.value]' <<<"$counts")" == "[1,1,1]" ]] \
  && echo "ok: the bypass / non-active / admin-bypass counters are exported" \
  || { echo "FAIL: counters wrong: $(jq -c '.output | with_entries(select(.key | test("bypass|non_active")))' <<<"$counts")"; fail=1; }

exit "$fail"
