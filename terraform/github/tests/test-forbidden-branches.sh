#!/usr/bin/env bash
# Exercises terraform/github/forbidden-branches.nix: which repositories get a
# `forbidden-branches` ruleset, what that ruleset contains, that its entries
# render into real `github_repository_ruleset` resources through governance.nix,
# and that every validation the helper performs refuses its input with its own
# message.
#
# DESIGN. Offline: Nix eval only, no credentials, no network. NO MOCKS: the real
# helper, the real mainline-protection.nix (which supplies `mainlines`, exactly
# as a governance root wires it) and the real governance.nix engine are
# evaluated. The only inputs are fixtures, which are test data, not stand-ins
# for any component:
#
#   * `policy` — the literal shape of branch-protection-policy.json as of
#     2026-09-30, reduced to the fields the two helpers read: `forbiddenBranches
#     = [ "agents" "agents-to-dev-*" ]` on spec `latest`, infra `live` and
#     `product-fork`, none on the product classes. The product `agents` class
#     and the `agents-to-dev` pattern class are present because they are what
#     the same-repoClass guard protects.
#   * `legacyPolicy` — the same policy without `forbiddenBranches` anywhere.
#   * `repos` — a literal inventory: a spec, an infra and two product
#     repositories (one on `stable`, overridden to `dev`), two product-adapted
#     forks, an archived fork, a repository excluded from mainline coverage and a
#     legacy `main` repository.
#
# SCENARIOS.
#
#   Positive: spec + infra repositories get exactly one ruleset each, with the
#   forbidden refs, creation + update + nonFastForward, NO deletion, active, no
#   bypass; product repositories get none; listed forks get one; the coverage
#   outputs agree; a legacy policy renders nothing; a round trip through the
#   engine (with its noBypassPolicy gate on) yields github_repository_ruleset
#   resources with `creation` and without `deletion`.
#
#   Negative: one NAMED mutation per throw, each asserted to fail with its own
#   message. Every mutation has a positive control — the same input with the
#   offending value replaced by a benign one — that must evaluate, so a mutation
#   cannot "fail" for an unrelated reason (a typo in the fixture, an eval error).
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
helper="${here}/../forbidden-branches.nix"
mainline="${here}/../mainline-protection.nix"
engine="${here}/../governance.nix"
fail=0

policy='{
  baseline = { allowForcePush = false; allowDeletion = false; };
  branchClasses = {
    stable = { repoClass = "product"; role = "default-release"; isDefaultBranch = true; requirePullRequest = true; };
    dev = { repoClass = "product"; role = "mainline"; requirePullRequest = true; };
    staging-wildcard = { repoClass = "product"; role = "deployment"; pattern = "staging-*"; };
    agents = { repoClass = "product"; role = "integration"; requirePullRequest = false; };
    agents-to-dev = { repoClass = "product"; role = "stabilization"; pattern = "agents-to-dev-*"; requirePullRequest = false; };
    latest = { repoClass = "spec"; role = "mainline"; requirePullRequest = false; forbiddenBranches = [ "agents" "agents-to-dev-*" ]; };
    live = { repoClass = "infra"; role = "mainline"; requirePullRequest = true; forbiddenBranches = [ "agents" "agents-to-dev-*" ]; };
    product-fork = { repoClass = "product-adapted-fork"; role = "adaptation"; pattern = "<product-name>"; forbiddenBranches = [ "agents" "agents-to-dev-*" ]; };
  };
}'

# Every class as above, with `forbiddenBranches` removed.
legacyPolicy="(${policy}) // { branchClasses = builtins.mapAttrs (_: c: removeAttrs c [ \"forbiddenBranches\" ]) (${policy}).branchClasses; }"

repos='map (x: { name = builtins.elemAt x 0; visibility = "public"; defaultBranch = builtins.elemAt x 1; archived = builtins.elemAt x 2; }) [
  [ "specs" "latest" false ]
  [ "infra" "live" false ]
  [ "product" "dev" false ]
  [ "product-stable" "stable" false ]
  [ "fork-a" "codetracer" false ]
  [ "fork-b" "reprobuild" false ]
  [ "fork-old" "codetracer" true ]
  [ "rebased" "dev" false ]
  [ "legacy" "main" false ]
]'

# The mainline-protection arguments a governance root would pass; its
# `mainlines` output feeds the helper, and its excludeRepos is shared with it.
mainlineArgs='excludeRepos = [ "rebased" ]; overrides = { product-stable = "dev"; };'
baseArgs='forkRepos = { fork-a = "codetracer"; fork-b = "reprobuild"; }; excludeRepos = [ "rebased" ];'

# $1 = extra helper arguments (Nix attrset body, overriding the base ones);
# $2 = policy (default: current). Prints the helper's result as JSON.
helper_eval() {
  local pol="${2:-$policy}"
  nix eval --json --impure --expr "
    let
      pol = ${pol};
      repositories = ${repos};
      m = import ${mainline} { policy = pol; inherit repositories; ${mainlineArgs} };
    in import ${helper} ({ policy = pol; inherit repositories; mainlines = m.mainlines; ${baseArgs} } // { $1 })
  "
}

# The current policy with one class's attributes replaced: $1 = class, $2 = attrset body.
policy_with() {
  echo "(${policy}) // { branchClasses = (${policy}).branchClasses // { $1 = (${policy}).branchClasses.$1 // { $2 }; }; }"
}

check() { # $1 = description, $2 = jq expr that must be true, $3 = json
  if [[ "$(jq -r "$2" <<<"$3")" != "true" ]]; then
    echo "FAIL: $1"
    fail=1
  else
    echo "ok: $1"
  fi
}

# ── positive shape ──────────────────────────────────────────────────────────
out="$(helper_eval "")"
check "covered set: spec + infra (derived) and the two listed forks, nothing else" \
  '.coveredRepos == ["fork-a","fork-b","infra","specs"]' "$out"
check "exactly one ruleset per covered repository" \
  '(.rulesets | length) == 4 and ([.rulesets[].repository] | sort) == .coveredRepos' "$out"
check "product repositories (dev, stable->dev) get no ruleset" \
  '[.rulesets[].repository] | (index("product") == null and index("product-stable") == null)' "$out"
check "archived, excluded and legacy repositories get no ruleset" \
  '[.rulesets[].repository] | (index("fork-old") == null and index("rebased") == null and index("legacy") == null)' "$out"
check "every ruleset has the exact forbidden-branches shape" \
  '[.rulesets[] | del(.repository)] | all(. == {name: "forbidden-branches", target: "branch", enforcement: "active", bypassActors: [], conditions: {refNameInclude: ["refs/heads/agents","refs/heads/agents-to-dev-*"], refNameExclude: []}, rules: {creation: true, update: true, nonFastForward: true}})' "$out"
check "no ruleset restricts deletion (a stray branch must stay removable)" \
  '[.rulesets[].rules | has("deletion")] | any | not' "$out"
check "byRepo reports class, branch and source per covered repository" \
  '.byRepo == {specs: {class: "latest", branch: "latest", source: "mainline", forbidden: ["agents","agents-to-dev-*"]}, infra: {class: "live", branch: "live", source: "mainline", forbidden: ["agents","agents-to-dev-*"]}, "fork-a": {class: "product-fork", branch: "codetracer", source: "fork", forbidden: ["agents","agents-to-dev-*"]}, "fork-b": {class: "product-fork", branch: "reprobuild", source: "fork", forbidden: ["agents","agents-to-dev-*"]}}' "$out"
check "forbiddenByClass names exactly the three forbidding classes" \
  '(.forbiddenByClass | keys) == ["latest","live","product-fork"]' "$out"
check "the ruleset name is configurable" \
  '[.rulesets[].name] | all(. == "no-agents")' "$(helper_eval 'name = "no-agents";')"
check "no forkRepos: only the derived spec + infra repositories" \
  '.coveredRepos == ["infra","specs"]' "$(helper_eval 'forkRepos = { };')"

# ── legacy policy: no forbiddenBranches anywhere renders nothing ────────────
outLegacy="$(helper_eval "" "$legacyPolicy")"
check "legacy policy without forbiddenBranches renders nothing (forks listed too)" \
  '.rulesets == [] and .coveredRepos == [] and .byRepo == {} and .forbiddenByClass == {}' "$outLegacy"

# ── documented exceptions are honoured ──────────────────────────────────────
outEx="$(helper_eval 'bypassActors = [ { actorId = 42; actorType = "Integration"; bypassMode = "always"; } ]; bypassException = "release App 42 must be able to push these refs"; enforcement = "evaluate"; enforcementException = "dry-run one cycle before enforcing";')"
check "a documented bypassException / enforcementException is honoured" \
  '[.rulesets[] | (.bypassActors == [{actorId: 42, actorType: "Integration", bypassMode: "always"}] and .enforcement == "evaluate")] | (length == 4 and all)' "$outEx"

# ── round trip through the real engine, with the no-bypass gate on ──────────
rendered="$(nix eval --json --impure --expr "
  let
    pol = ${policy};
    repositories = ${repos};
    m = import ${mainline} { policy = pol; inherit repositories; ${mainlineArgs} };
    f = import ${helper} { policy = pol; inherit repositories; mainlines = m.mainlines; ${baseArgs} };
  in import ${engine} {
    awsAccountId = \"000000000000\";
    awsRegion = \"us-east-1\";
    githubOwner = \"example-org\";
    githubBootstrapStateKey = \"x.tfstate\";
    manifest.secrets = [ ];
    noBypassPolicy = { };
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
      repositoryRulesets = m.rulesets ++ f.rulesets;
      deferredResources = [ ];
    };
  }
")"
check "engine renders one forbidden-branches github_repository_ruleset per covered repository, beside the mainline ones" \
  '([.resource.github_repository_ruleset[] | select(.name == "forbidden-branches") | .repository] | sort) == ["fork-a","fork-b","infra","specs"] and ([.resource.github_repository_ruleset[] | select(.name == "mainline-protect")] | length) == 4' "$rendered"
check "rendered forbidden-branches rules: creation + update + non_fast_forward, NO deletion" \
  '[.resource.github_repository_ruleset[] | select(.name == "forbidden-branches") | .rules] | all(. == [{creation: true, update: true, non_fast_forward: true}])' "$rendered"
check "rendered forbidden-branches refs, active, no bypass_actors" \
  '[.resource.github_repository_ruleset[] | select(.name == "forbidden-branches") | (.conditions == [{ref_name: [{include: ["refs/heads/agents","refs/heads/agents-to-dev-*"], exclude: []}]}] and .enforcement == "active" and .target == "branch" and (has("bypass_actors") | not))] | (length == 4 and all)' "$rendered"

# ── negative mutations: one per throw, each with a positive control ─────────
# $1 = name; $2/$3 = control args/policy (must evaluate); $4/$5 = mutated
# args/policy (must fail); $6 = regex the failure message must match.
mutation() {
  local name="$1" okArgs="$2" okPol="$3" badArgs="$4" badPol="$5" msg="$6" err
  if ! helper_eval "$okArgs" "$okPol" 2>/dev/null | jq -e '.rulesets | type == "array"' >/dev/null 2>&1; then
    echo "FAIL: [$name] positive control does not evaluate"
    fail=1
    return
  fi
  if err="$(helper_eval "$badArgs" "$badPol" 2>&1 >/dev/null)"; then
    echo "FAIL: [$name] mutation was accepted"
    fail=1
  elif ! grep -Eq -- "$msg" <<<"$err"; then
    echo "FAIL: [$name] mutation failed, but not with /$msg/:"
    grep -E 'error' <<<"$err" | tail -3 | sed 's/^/    /'
    fail=1
  else
    echo "ok: [$name] rejected with its own message"
  fi
}

mutation "forbids-policy-mainline" \
  "" "$(policy_with live 'forbiddenBranches = [ "agents" ];')" \
  "" "$(policy_with live 'forbiddenBranches = [ "agents" "dev" ];')" \
  'class `live` forbids `dev`, which is a policy mainline'
mutation "forbids-policy-mainline-by-glob" \
  "" "$(policy_with latest 'forbiddenBranches = [ "agents-*" ];')" \
  "" "$(policy_with latest 'forbiddenBranches = [ "l*" ];')" \
  'class `latest` forbids `l\*`, which is a policy mainline \(latest, live\)'
mutation "forbids-same-repoclass-branch (agents on product dev)" \
  "" "$(policy_with dev 'forbiddenBranches = [ ];')" \
  "" "$(policy_with dev 'forbiddenBranches = [ "agents" ];')" \
  'class `dev` forbids `agents`, which matches branch class `agents` of the same repoClass `product`'
mutation "forbids-same-repoclass-pattern (agents-to-dev-* on product stable)" \
  "" "$(policy_with stable 'forbiddenBranches = [ ];')" \
  "" "$(policy_with stable 'forbiddenBranches = [ "agents-to-dev-*" ];')" \
  'class `stable` forbids `agents-to-dev-\*`, which matches branch class `agents-to-dev` of the same repoClass `product`'
mutation "forbids-own-mainline (a fork's product branch)" \
  "" "$(policy_with product-fork 'forbiddenBranches = [ "agents" "reprobuild-*" ];')" \
  "" "$(policy_with product-fork 'forbiddenBranches = [ "agents" "codetracer" ];')" \
  'forbids `codetracer`, which is the mainline of fork-a \(`codetracer`\)'
mutation "forbiddenBranches-not-a-list" \
  "" "$(policy_with latest 'forbiddenBranches = [ "agents" ];')" \
  "" "$(policy_with latest 'forbiddenBranches = "agents";')" \
  'class `latest` forbiddenBranches "agents" is not a list of non-empty branch names'
mutation "forbiddenBranches-empty-entry" \
  "" "$(policy_with latest 'forbiddenBranches = [ "agents" ];')" \
  "" "$(policy_with latest 'forbiddenBranches = [ "agents" "" ];')" \
  'class `latest` forbiddenBranches .* is not a list of non-empty branch names'
mutation "fork-unknown" \
  'forkRepos = { fork-a = "codetracer"; };' "$policy" \
  'forkRepos = { fork-a = "codetracer"; no-such-repo = "codetracer"; };' "$policy" \
  'bad forkRepos entries: no-such-repo is not in the inventory'
mutation "fork-archived" \
  'forkRepos = { fork-a = "codetracer"; };' "$policy" \
  'forkRepos = { fork-a = "codetracer"; fork-old = "codetracer"; };' "$policy" \
  'bad forkRepos entries: fork-old is archived'
mutation "fork-excluded" \
  'forkRepos = { fork-a = "codetracer"; };' "$policy" \
  'forkRepos = { fork-a = "codetracer"; rebased = "dev"; };' "$policy" \
  'bad forkRepos entries: rebased is in excludeRepos'
mutation "fork-already-derived" \
  'forkRepos = { fork-a = "codetracer"; };' "$policy" \
  'forkRepos = { fork-a = "codetracer"; specs = "latest"; };' "$policy" \
  'bad forkRepos entries: specs is already derived through mainlines'
mutation "fork-product-branch-is-policy-mainline" \
  'forkRepos = { fork-a = "codetracer"; };' "$policy" \
  'forkRepos = { fork-a = "codetracer"; legacy = "live"; };' "$policy" \
  'bad forkRepos entries: legacy names `live`, a policy mainline, as its product branch'
mutation "fork-product-branch-not-default" \
  'forkRepos = { fork-a = "codetracer"; };' "$policy" \
  'forkRepos = { fork-a = "reprobuild"; };' "$policy" \
  'bad forkRepos entries: fork-a names product branch `reprobuild`, but its default branch is `codetracer`'
mutation "fork-class-missing" \
  'forkRepos = { };' "(${policy}) // { branchClasses = removeAttrs (${policy}).branchClasses [ \"product-fork\" ]; }" \
  '' "(${policy}) // { branchClasses = removeAttrs (${policy}).branchClasses [ \"product-fork\" ]; }" \
  'forkRepos is non-empty but the policy has no `product-fork` branch class'
mutation "mainlines-unknown-repo" \
  'mainlines = { specs = "latest"; };' "$policy" \
  'mainlines = { specs = "latest"; ghost = "latest"; };' "$policy" \
  'mainlines names repositories not in the inventory: ghost'
mutation "mainlines-not-a-class" \
  'mainlines = { specs = "latest"; };' "$policy" \
  'mainlines = { specs = "main"; };' "$policy" \
  'mainlines maps specs -> `main`, which is not a policy branch class'
mutation "bypass-undocumented" \
  'bypassActors = [ { actorId = 0; actorType = "OrganizationAdmin"; bypassMode = "always"; } ]; bypassException = "a documented reason, twenty+ chars";' "$policy" \
  'bypassActors = [ { actorId = 0; actorType = "OrganizationAdmin"; bypassMode = "always"; } ];' "$policy" \
  'bypassActors .* without a documented `bypassException`'
mutation "bypass-reason-too-short" \
  'bypassActors = [ { actorId = 0; actorType = "OrganizationAdmin"; bypassMode = "always"; } ]; bypassException = "a documented reason, twenty+ chars";' "$policy" \
  'bypassActors = [ { actorId = 0; actorType = "OrganizationAdmin"; bypassMode = "always"; } ]; bypassException = "short";' "$policy" \
  'bypassActors .* without a documented `bypassException`'
mutation "enforcement-undocumented" \
  'enforcement = "evaluate"; enforcementException = "a documented reason, twenty+ chars";' "$policy" \
  'enforcement = "evaluate";' "$policy" \
  'enforcement `evaluate` without a documented `enforcementException`'

exit "$fail"
