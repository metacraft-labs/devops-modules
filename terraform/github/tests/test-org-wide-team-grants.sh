#!/usr/bin/env bash
# Exercises governance.orgWideTeamRepositories: the "this team reaches every
# repository" rule, and specifically how it resolves against explicit
# governance.teamRepositories entries for the same (team, repo) pair.
#
# The resolution rule is max-by-permission, and both directions are asserted
# here because each protects a different promise. A weaker explicit grant must
# be RAISED (otherwise a repo left at `push` silently defeats a rule that says
# `maintain` everywhere), and a stronger explicit grant must be LEFT ALONE
# (otherwise adding a blanket rule silently strips a deliberate `admin`).
#
# Offline: Nix eval only, no credentials, no network, no mocks. The fixture is a
# literal governance model passed to the real engine, so what is asserted is the
# engine's actual resource output rather than a stand-in for it.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
engine="${here}/../governance.nix"
fail=0

render() {
  # $1 = extra governance attrs (Nix), merged over the base fixture.
  nix eval --json --impure --expr "
    import ${engine} {
      awsAccountId = \"000000000000\";
      awsRegion = \"us-east-1\";
      githubOwner = \"example-org\";
      githubBootstrapStateKey = \"x.tfstate\";
      manifest.secrets = [ ];
      governance = {
        snapshot.source = \"fixture\";
        organization.actionsPermissions = {
          enabledRepositories = \"all\";
          allowedActions = \"all\";
          shaPinningRequired = false;
        };
        repositories = map (n: {
          name = n;
          visibility = \"private\";
          hasIssues = true;
          hasProjects = false;
          hasWiki = false;
          hasDiscussions = false;
          allowForking = false;
          archived = false;
          isTemplate = false;
          webCommitSignoffRequired = false;
          defaultBranch = \"main\";
        }) [ \"alpha\" \"beta\" \"gamma\" \"delta\" ];
        memberships = [ ];
        outsideCollaborators = [ ];
        branchProtections = [ ];
        repositoryEnvironments = [ ];
        actionsRepositoryPermissions = [ ];
        actionsVariables = [ ];
        issueLabels = [ ];
        repositoryRulesets = [ ];
        deferredResources = [ ];
      } // ($1);
    }
  "
}

# permission granted to team 'ct' on a repo, read out of the rendered resources.
perm_for() { jq -r --arg r "$2" '.resource.github_team_repository | to_entries[] | select(.value.repository == $r and (.value.team_id | test("ct"))) | .value.permission' <<<"$1"; }

base='{
  teamRepositories = [
    { teamSlug = "ct"; repository = "alpha"; permission = "admin"; }
    { teamSlug = "ct"; repository = "beta"; permission = "push"; }
    { teamSlug = "ct"; repository = "gamma"; permission = "maintain"; }
  ];
  orgWideTeamRepositories = [ { teamSlug = "ct"; permission = "maintain"; } ];
}'

json="$(render "$base")"

# 1. Every repository in the model is covered exactly once.
n="$(jq '.resource.github_team_repository | length' <<<"$json")"
[[ "$n" == "4" ]] || { echo "FAIL: expected 4 team grants (one per repo), got $n"; fail=1; }

# 2. Stronger explicit grant is NOT downgraded by the blanket rule.
p="$(perm_for "$json" alpha)"
[[ "$p" == "admin" ]] || { echo "FAIL: alpha should stay admin, got '$p'"; fail=1; }

# 3. Weaker explicit grant IS raised to the rule level.
p="$(perm_for "$json" beta)"
[[ "$p" == "maintain" ]] || { echo "FAIL: beta should be raised to maintain, got '$p'"; fail=1; }

# 4. Equal explicit grant stays put and does not duplicate.
p="$(perm_for "$json" gamma)"
[[ "$p" == "maintain" ]] || { echo "FAIL: gamma should be maintain, got '$p'"; fail=1; }

# 5. A repo with no explicit grant is reached by the rule alone.
p="$(perm_for "$json" delta)"
[[ "$p" == "maintain" ]] || { echo "FAIL: delta should be maintain, got '$p'"; fail=1; }

# 6. The rule-referenced team still gets its data source (it is not a managed team here).
jq -e '.data.github_team | to_entries[] | select(.value.slug == "ct")' <<<"$json" >/dev/null \
  || { echo "FAIL: expected a github_team data source for the rule's team"; fail=1; }

# 7. The count output reflects the expanded set, not the explicit list.
c="$(jq '.output.github_governance_team_repository_count.value' <<<"$json")"
[[ "$c" == "4" ]] || { echo "FAIL: team_repository_count should be 4, got $c"; fail=1; }

# 8. No rule at all leaves the explicit list exactly as written.
json_norule="$(render '{
  teamRepositories = [ { teamSlug = "ct"; repository = "beta"; permission = "push"; } ];
}')"
n="$(jq '.resource.github_team_repository | length' <<<"$json_norule")"
p="$(perm_for "$json_norule" beta)"
[[ "$n" == "1" && "$p" == "push" ]] \
  || { echo "FAIL: without a rule expected 1 grant at push, got $n at '$p'"; fail=1; }

# 9. A rule naming an unrankable permission is rejected rather than half-applied.
if render '{
  teamRepositories = [ ];
  orgWideTeamRepositories = [ { teamSlug = "ct"; permission = "custom-role"; } ];
}' >/dev/null 2>&1; then
  echo "FAIL: expected an unrankable rule permission to throw"; fail=1
fi

# 10. Two rules for one team are rejected: the result would depend on list order.
if render '{
  teamRepositories = [ ];
  orgWideTeamRepositories = [
    { teamSlug = "ct"; permission = "maintain"; }
    { teamSlug = "ct"; permission = "push"; }
  ];
}' >/dev/null 2>&1; then
  echo "FAIL: expected duplicate rules for one team to throw"; fail=1
fi

# 11. An explicit CUSTOM role is left untouched: the engine cannot rank it, and
#     guessing could either strip privileges or invent them.
json_custom="$(render '{
  teamRepositories = [ { teamSlug = "ct"; repository = "beta"; permission = "custom-role"; } ];
  orgWideTeamRepositories = [ { teamSlug = "ct"; permission = "maintain"; } ];
}')"
p="$(perm_for "$json_custom" beta)"
[[ "$p" == "custom-role" ]] || { echo "FAIL: explicit custom role should be preserved, got '$p'"; fail=1; }

if [[ "$fail" == "0" ]]; then echo "PASS: org-wide team grant expansion and precedence"; fi
exit "$fail"
