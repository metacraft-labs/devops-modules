#!/usr/bin/env bash
# Exercises governance.nix's merge-method consistency gate. A ruleset that
# restricts `allowedMergeMethods` (the branch-protection policy: merge commits
# only on PR-gated mainlines) can combine with other settings into a branch
# nothing can be merged into, although GitHub accepts every piece on its own:
#
#   * repository settings that disable every method the ruleset allows;
#   * a merge-only ruleset on a branch that also requires linear history (a
#     ruleset or a classic protection), which forbids merge commits;
#   * a merge queue whose method the ruleset or repository does not allow.
#
# The render THROWS on each, and a model that does not restrict merge methods
# renders exactly as before.
#
# Offline: Nix eval of the real engine over a literal inventory. No mocks.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
engine="${here}/../governance.nix"
fail=0

# $1 = repository settings overrides (Nix attrset body), $2 = extra governance fields
render() {
  nix eval --json --impure --expr "
    let
      repo = {
        name = \"repo\"; visibility = \"private\"; hasIssues = true; hasProjects = false;
        hasWiki = false; hasDiscussions = false; allowForking = false; archived = false;
        isTemplate = false; webCommitSignoffRequired = false; defaultBranch = \"dev\";
      } // { $1 };
      rs = name: include: rules: {
        repository = \"repo\"; inherit name; target = \"branch\"; enforcement = \"active\";
        conditions = { refNameInclude = [ include ]; refNameExclude = [ ]; };
        rules = { deletion = true; nonFastForward = true; } // rules;
        bypassActors = [ ];
      };
      pr = methods: {
        requiredApprovingReviewCount = 0; dismissStaleReviewsOnPush = false;
        requireCodeOwnerReview = false; requireLastPushApproval = false;
        requiredReviewThreadResolution = false;
      } // (if methods == null then { } else { allowedMergeMethods = methods; });
      queue = method: {
        mergeMethod = method; groupingStrategy = \"ALLGREEN\"; minEntriesToMerge = 1;
        maxEntriesToMerge = 5; minEntriesToMergeWaitMinutes = 5; maxEntriesToBuild = 2;
        checkResponseTimeoutMinutes = 360;
      };
      bp = pattern: linear: {
        repository = \"repo\"; inherit pattern; enforceAdmins = true;
        allowsDeletions = false; allowsForcePushes = false; requiredLinearHistory = linear;
        requireConversationResolution = false; requireSignedCommits = false; lockBranch = false;
      };
    in (import ${engine} {
      awsAccountId = \"000000000000\";
      awsRegion = \"us-east-1\";
      githubOwner = \"example-org\";
      githubBootstrapStateKey = \"x.tfstate\";
      manifest.secrets = [ ];
      governance = {
        snapshot.source = \"fixture\";
        organization.actionsPermissions = { enabledRepositories = \"all\"; allowedActions = \"all\"; shaPinningRequired = false; };
        repositories = [ repo ];
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
      } // { $2 };
    }).resource.github_repository_ruleset
  "
}

expect_ok() { # $1 desc, $2 repo settings, $3 fields
  if out="$(render "$2" "$3" 2>&1)"; then echo "ok: $1"; else echo "FAIL: $1 (${out: -400})"; fail=1; fi
}
expect_reject() { # $1 desc, $2 repo settings, $3 fields, $4 expected message fragment
  if out="$(render "$2" "$3" 2>&1)"; then
    echo "FAIL: $1 (was accepted)"; fail=1
  elif grep -qF -- "$4" <<<"$out"; then
    echo "ok: $1"
  else
    echo "FAIL: $1 (rejected, but not with \"$4\": ${out: -400})"; fail=1
  fi
}

mergeOnly='allowMergeCommit = true; allowSquashMerge = false; allowRebaseMerge = false;'
rebaseOnly='allowMergeCommit = false; allowSquashMerge = false; allowRebaseMerge = true;'
mainline='(rs "mainline-protect" "refs/heads/dev" { pullRequest = pr [ "merge" ]; })'

expect_ok "a merge-only ruleset on a merge-only repository renders" \
  "$mergeOnly" "repositoryRulesets = [ ${mainline} ];"
expect_ok "GitHub's default repository settings (all methods) also admit it" \
  "" "repositoryRulesets = [ ${mainline} ];"
expect_reject "a merge-only ruleset on a rebase-only repository is rejected" \
  "$rebaseOnly" "repositoryRulesets = [ ${mainline} ];" \
  "repository-ruleset:repo:mainline-protect: allows [\"merge\"], but the repository settings allow [\"rebase\"]"
expect_reject "a merge-only ruleset plus a linear-history ruleset on the default branch is rejected" \
  "$mergeOnly" "repositoryRulesets = [ ${mainline} (rs \"linear\" \"~DEFAULT_BRANCH\" { requiredLinearHistory = true; }) ];" \
  "merge-only, but ruleset \`linear\` requires linear history"
expect_reject "a merge-only ruleset plus a linear-history ruleset on ~ALL is rejected" \
  "$mergeOnly" "repositoryRulesets = [ ${mainline} (rs \"all\" \"~ALL\" { requiredLinearHistory = true; }) ];" \
  "merge-only, but ruleset \`all\` requires linear history"
expect_reject "a merge-only ruleset plus a linear-history classic protection is rejected" \
  "$mergeOnly" "repositoryRulesets = [ ${mainline} ]; branchProtections = [ (bp \"dev\" true) ];" \
  "merge-only, but classic protection \`dev\` requires linear history"
expect_reject "a merge-only ruleset on the default branch plus a linear classic glob is rejected" \
  "$mergeOnly" "repositoryRulesets = [ (rs \"protect\" \"~DEFAULT_BRANCH\" { pullRequest = pr [ \"merge\" ]; }) ]; branchProtections = [ (bp \"d*\" true) ];" \
  "merge-only, but classic protection \`d*\` requires linear history"
expect_ok "linear history on a different branch is fine" \
  "$mergeOnly" "repositoryRulesets = [ ${mainline} (rs \"legacy\" \"refs/heads/main\" { requiredLinearHistory = true; }) ]; branchProtections = [ (bp \"main\" true) (bp \"dev\" false) ];"
expect_ok "a disabled linear-history ruleset is ignored" \
  "$mergeOnly" "repositoryRulesets = [ ${mainline} ((rs \"linear\" \"refs/heads/dev\" { requiredLinearHistory = true; }) // { enforcement = \"disabled\"; }) ];"
expect_ok "a MERGE queue on a merge-only branch renders" \
  "$mergeOnly" "repositoryRulesets = [ (rs \"mainline-protect\" \"refs/heads/dev\" { pullRequest = pr [ \"merge\" ]; mergeQueue = queue \"MERGE\"; }) ];"
expect_reject "a REBASE queue on a merge-only branch is rejected" \
  "$mergeOnly" "repositoryRulesets = [ (rs \"mainline-protect\" \"refs/heads/dev\" { pullRequest = pr [ \"merge\" ]; mergeQueue = queue \"REBASE\"; }) ];" \
  "the merge queue merges with REBASE"
expect_ok "without allowedMergeMethods nothing is checked (a legacy model renders as before)" \
  "$rebaseOnly" "repositoryRulesets = [ (rs \"mainline-protect\" \"refs/heads/dev\" { pullRequest = pr null; requiredLinearHistory = true; mergeQueue = queue \"REBASE\"; }) ]; branchProtections = [ (bp \"dev\" true) ];"

exit "$fail"
