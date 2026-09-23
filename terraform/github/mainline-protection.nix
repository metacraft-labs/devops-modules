# Policy-driven MAINLINE branch-protection rulesets, in the governance engine's
# `repositoryRulesets` schema.
#
# Renders one repository ruleset (default name `mainline-protect`) per repository
# whose MAINLINE branch is protectable, straight from the shared branch-protection
# policy (for Metacraft: `metacraft-dev-guidelines/policies/branch-protection-policy.json`)
# plus the caller's repository inventory. It is company-agnostic: the caller
# supplies the parsed policy, the inventory `repositories` list, and its own
# org-specific corrections (exclusions, default-branch overrides, direct-push
# repositories, plan constraints). The policy fixes WHICH branch classes are
# mainlines; the inventory says which concrete repositories exist and on what
# branch.
#
# Unlike `branch-protection.nix` (which emits raw `github_repository_ruleset`
# resources for a hand-written repository map), this helper returns plain
# entries for `governance.repositoryRulesets`, so they flow through
# `governance.nix` with every other ruleset the org models — and through
# whatever filter the caller applies around it (e.g. an import-only adoption
# window that must hold creates back).
#
# Usage (from a governance root):
#
#   let
#     mainline = import "${devops-modules}/terraform/github/mainline-protection.nix" {
#       policy = builtins.fromJSON (builtins.readFile ./branch-protection-policy.json);
#       repositories = inventory.repositories;
#       overrides = { my-product = "dev"; };      # default branch is `stable`
#       directPushRepos = [ "workspace" ];        # tool-driven direct pushes
#       enforcement = "evaluate";                 # Enterprise: dry-run first
#     };
#   in mkGovernance {
#     governance = inventory // {
#       repositoryRulesets = inventory.repositoryRulesets ++ mainline.rulesets;
#     };
#     ...
#   }
#
# WHAT A MAINLINE RULESET DOES, and why it is expressed this way:
#
#   * `deletion` + `nonFastForward`  — the all-branches baseline (no deletion, no
#     force-push) restated on the mainline.
#   * `pullRequest`                  — THIS is "no direct push / PR-only": the
#     ruleset `pull_request` rule requires a pull request to update the branch.
#     A required approving-review count of 0 still enforces the PR gate; it only
#     drops the approval requirement.
#   * NO `requiredStatusChecks`.     The engine's ruleset schema does not express
#     them, and pinning a check context that does not exist yet makes every PR
#     unmergeable. Concrete required checks are a later, per-repo layer.
#   * `bypassActors`                 — default: OrganizationAdmin/always, i.e.
#     "protect the mainline, but NOT enforce_admins". Callers may add narrowly
#     scoped actors (e.g. a release App by its Integration id).
#
# The `agents` integration branch is INTENTIONALLY never targeted: agents push to
# it directly and reach the mainline only through a pull request.
{
  # policy: parsed branch-protection-policy.json (baseline + branchClasses).
  policy,
  # repositories: the inventory `repositories` list (each { name; visibility;
  #   defaultBranch; archived ? false; ... }).
  repositories,
  # excludeRepos: repositories that derive as protectable but must NOT be, e.g.
  #   forks whose mainline is rebased onto upstream (a force-push that
  #   `nonFastForward` would break).
  excludeRepos ? [ ],
  # overrides: repositories whose real mainline differs from the inventory's
  #   `defaultBranch`. Attrset { <repoName> = "<mainlineBranch>"; }. The branch
  #   must itself be a policy mainline key.
  overrides ? { },
  # directPushRepos: repositories whose mainline is protected from deletion and
  #   force-push but NOT made PR-only, because legitimate tooling commits and
  #   pushes to it directly under the invoking user's own identity (so no
  #   narrower bypass actor exists). Each must be justified by the caller.
  directPushRepos ? [ ],
  # visibilities: repository visibilities the org's plan can carry rulesets on.
  #   GitHub Free refuses rulesets on private repositories (403) — such a caller
  #   passes [ "public" ]. Team/Enterprise can protect all three.
  visibilities ? [
    "public"
    "private"
    "internal"
  ],
  # enforcement: "active" | "evaluate" | "disabled". `evaluate` (Enterprise
  #   only) records what WOULD be blocked in rule insights without blocking.
  enforcement ? "active",
  # requiredApprovingReviewCount: null derives it from the policy class
  #   (`requirePullRequestReview` -> 1, else 0); an integer forces it for every
  #   mainline.
  requiredApprovingReviewCount ? null,
  # bypassActors: the ruleset bypass list (engine schema).
  bypassActors ? [
    {
      actorId = 0;
      actorType = "OrganizationAdmin";
      bypassMode = "always";
    }
  ],
  # name: the ruleset name (also part of the engine's resource key).
  name ? "mainline-protect",
}:
let
  inherit (builtins)
    attrNames
    elem
    filter
    hasAttr
    listToAttrs
    ;

  branchClasses = policy.branchClasses;
  baseline = policy.baseline or { };

  # The mainline branch keys, straight from the policy: every branch class whose
  # role is "mainline" (for Metacraft: product `dev`, spec `latest`, infra
  # `live`). The attribute KEY is the concrete branch name.
  mainlineKeys = filter (k: (branchClasses.${k}.role or "") == "mainline") (attrNames branchClasses);

  # Resolve a repository to the mainline branch it should protect, or null.
  mainlineBranchFor =
    repo:
    if hasAttr repo.name overrides then
      overrides.${repo.name}
    else if elem (repo.defaultBranch or "") mainlineKeys then
      repo.defaultBranch
    else
      null;

  # Why a repository is NOT covered, or null when it is. Ordered so the most
  # fundamental reason is reported.
  uncoveredReason =
    repo:
    if repo.archived or false then
      "archived"
    else if elem repo.name excludeRepos then
      "excluded by caller"
    else if !(elem (repo.visibility or "private") visibilities) then
      "visibility ${repo.visibility or "private"} cannot carry rulesets on this plan"
    else if mainlineBranchFor repo == null then
      "default branch `${repo.defaultBranch or "?"}` is not a policy mainline (${builtins.concatStringsSep "/" mainlineKeys}) and no override is given"
    else
      null;

  protectable = repo: uncoveredReason repo == null;
  covered = filter protectable repositories;

  reviewCountFor =
    branch:
    if requiredApprovingReviewCount != null then
      requiredApprovingReviewCount
    else if (branchClasses.${branch}.requirePullRequestReview or false) then
      1
    else
      0;

  mkRuleset =
    repo:
    let
      branch = mainlineBranchFor repo;
      prOnly = !(elem repo.name directPushRepos);
    in
    assert
      (elem branch mainlineKeys)
      || throw "mainline-protection: override for ${repo.name} names `${branch}`, which is not a policy mainline branch";
    {
      repository = repo.name;
      inherit name enforcement bypassActors;
      target = "branch";
      conditions = {
        refNameInclude = [ "refs/heads/${branch}" ];
        refNameExclude = [ ];
      };
      rules = {
        deletion = !(baseline.allowDeletion or false);
        nonFastForward = !(baseline.allowForcePush or false);
      }
      // (
        if prOnly then
          {
            # PR-only. The presence of this rule is what forbids direct pushes.
            pullRequest = {
              requiredApprovingReviewCount = reviewCountFor branch;
              dismissStaleReviewsOnPush = false;
              requireCodeOwnerReview = false;
              requireLastPushApproval = false;
              requiredReviewThreadResolution = false;
            };
          }
        else
          { }
      );
    };

  # Guard against typos in the caller's corrections: every name they list must
  # be a repository in the inventory, or the correction silently does nothing.
  inventoryNames = map (r: r.name) repositories;
  unknown = filter (n: !(elem n inventoryNames)) (
    excludeRepos ++ directPushRepos ++ attrNames overrides
  );
in
assert
  unknown == [ ]
  || throw "mainline-protection: unknown repositories in excludeRepos/directPushRepos/overrides: ${builtins.concatStringsSep ", " unknown}";
{
  # Entries in the engine's `repositoryRulesets` schema. Append them to
  # `governance.repositoryRulesets`.
  rulesets = map mkRuleset covered;

  # Coverage report, for the caller's README / gates.
  protectedRepos = map (r: r.name) covered;
  prOnlyRepos = map (r: r.name) (filter (r: !(elem r.name directPushRepos)) covered);
  directPushRepos = map (r: r.name) (filter (r: elem r.name directPushRepos) covered);
  mainlines = listToAttrs (
    map (r: {
      name = r.name;
      value = mainlineBranchFor r;
    }) covered
  );
  uncovered = listToAttrs (
    map (r: {
      name = r.name;
      value = uncoveredReason r;
    }) (filter (r: !(protectable r)) repositories)
  );
}
