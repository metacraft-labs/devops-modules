#!/usr/bin/env bash
# Exercises terraform/github/mainline-protection.nix: which repositories get a
# mainline ruleset, what that ruleset contains, and that its entries render into
# real `github_repository_ruleset` resources through governance.nix.
#
# Offline: Nix eval only, no credentials, no network, no mocks. The policy is
# the literal shape of branch-protection-policy.json (mainline classes only are
# load-bearing here) and the inventory is a literal repository list, both passed
# to the real helper and the real engine.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
helper="${here}/../mainline-protection.nix"
engine="${here}/../governance.nix"
fail=0

policy='{
  baseline = { allowForcePush = false; allowDeletion = false; };
  branchClasses = {
    stable = { repoClass = "product"; role = "default-release"; requirePullRequestReview = true; };
    dev = { repoClass = "product"; role = "mainline"; requirePullRequestReview = true; };
    agents = { repoClass = "product"; role = "integration"; };
    latest = { repoClass = "spec"; role = "mainline"; };
    live = { repoClass = "infra"; role = "mainline"; };
  };
}'

repos='map (x: { name = builtins.elemAt x 0; visibility = builtins.elemAt x 1; defaultBranch = builtins.elemAt x 2; archived = builtins.elemAt x 3; }) [
  [ "product" "private" "stable" false ]
  [ "specs" "internal" "latest" false ]
  [ "infra" "private" "live" false ]
  [ "public-dev" "public" "dev" false ]
  [ "legacy" "public" "main" false ]
  [ "old" "public" "dev" true ]
  [ "fork" "public" "dev" false ]
  [ "manifests" "private" "latest" false ]
  [ "stale" "private" "main" false ]
]'

# $1 = extra helper arguments (Nix attrset body)
helper_eval() {
  nix eval --json --impure --expr "
    import ${helper} ({ policy = ${policy}; repositories = ${repos}; } // { $1 })
  "
}

check() { # $1 = description, $2 = jq expr that must be true, $3 = json
  if [[ "$(jq -r "$2" <<<"$3")" != "true" ]]; then
    echo "FAIL: $1"
    fail=1
  else
    echo "ok: $1"
  fi
}

args='
  excludeRepos = [ "fork" ];
  overrides = { product = "dev"; stale = "live"; };
  directPushRepos = [ "manifests" ];
  enforcement = "evaluate";
'
out="$(helper_eval "$args")"

check "covered set: overrides + mainline defaults, minus archived/excluded/legacy" \
  '(.protectedRepos | sort) == (["infra","manifests","product","public-dev","specs","stale"] | sort)' "$out"
check "legacy default branch is reported uncovered with a reason" \
  '.uncovered.legacy | test("not a policy mainline")' "$out"
check "archived and excluded are reported uncovered" \
  '(.uncovered.old == "archived") and (.uncovered.fork == "excluded by caller")' "$out"
check "override wins over the inventory default branch" \
  '.mainlines.product == "dev" and .mainlines.stale == "live"' "$out"
check "every ruleset targets exactly its mainline ref, never agents" \
  '[.rulesets[] | .conditions.refNameInclude] | all(length == 1 and (.[0] | test("^refs/heads/(dev|latest|live)$")))' "$out"
check "enforcement is passed through" \
  '[.rulesets[].enforcement] | all(. == "evaluate")' "$out"
check "PR-only repos carry pull_request + no-delete + no-force-push" \
  '[.rulesets[] | select(.repository != "manifests") | .rules | (.pullRequest != null and .deletion and .nonFastForward)] | all' "$out"
check "direct-push repo keeps no-delete/no-force-push but no pull_request rule" \
  '(.rulesets[] | select(.repository == "manifests") | .rules) == {deletion: true, nonFastForward: true}' "$out"
check "approval count derives from the policy class (dev=1, latest/live=0)" \
  '([.rulesets[] | select(.conditions.refNameInclude[0] == "refs/heads/dev") | .rules.pullRequest.requiredApprovingReviewCount] | all(. == 1)) and ([.rulesets[] | select(.repository == "infra") | .rules.pullRequest.requiredApprovingReviewCount] == [0])' "$out"
check "default bypass is OrganizationAdmin only (not enforce_admins)" \
  '[.rulesets[].bypassActors] | all(. == [{actorId: 0, actorType: "OrganizationAdmin", bypassMode: "always"}])' "$out"

out0="$(helper_eval "$args requiredApprovingReviewCount = 0;")"
check "requiredApprovingReviewCount override applies to every mainline" \
  '[.rulesets[].rules.pullRequest // empty | .requiredApprovingReviewCount] | all(. == 0)' "$out0"

outPub="$(helper_eval 'visibilities = [ "public" ];')"
check "free-plan visibility filter keeps only public repositories" \
  '((.protectedRepos | sort) == ["fork","public-dev"]) and (.uncovered.infra | test("visibility private"))' "$outPub"

# Caller typos must fail loudly rather than silently protect nothing.
if helper_eval 'excludeRepos = [ "no-such-repo" ];' >/dev/null 2>&1; then
  echo "FAIL: unknown repository in excludeRepos was accepted"
  fail=1
else
  echo "ok: unknown repository in excludeRepos is rejected"
fi
if helper_eval 'overrides = { legacy = "main"; };' >/dev/null 2>&1; then
  echo "FAIL: override to a non-mainline branch was accepted"
  fail=1
else
  echo "ok: override to a non-mainline branch is rejected"
fi

# Round-trip through the real engine: the entries are valid repositoryRulesets.
rendered="$(nix eval --json --impure --expr "
  let m = import ${helper} ({ policy = ${policy}; repositories = ${repos}; } // { ${args} });
  in import ${engine} {
    awsAccountId = \"000000000000\";
    awsRegion = \"us-east-1\";
    githubOwner = \"example-org\";
    githubBootstrapStateKey = \"x.tfstate\";
    manifest.secrets = [ ];
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
      repositoryRulesets = m.rulesets;
      deferredResources = [ ];
    };
  }
")"
check "engine renders one github_repository_ruleset per covered repository" \
  '(.resource.github_repository_ruleset | length) == 6' "$rendered"
check "rendered PR-only ruleset carries pull_request and the admin bypass" \
  '[.resource.github_repository_ruleset[] | select(.repository == "infra")][0] | (.rules[0].pull_request | length == 1) and (.bypass_actors[0].actor_type == "OrganizationAdmin") and (.enforcement == "evaluate") and (.conditions[0].ref_name[0].include == ["refs/heads/live"])' "$rendered"
check "rendered direct-push ruleset has no pull_request block" \
  '[.resource.github_repository_ruleset[] | select(.repository == "manifests")][0].rules[0] | has("pull_request") | not' "$rendered"

exit "$fail"
