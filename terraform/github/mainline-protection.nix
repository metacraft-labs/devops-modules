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
#     drops the approval requirement. Emitted only when the mainline's policy
#     class says `requirePullRequest` (absent = true, so a mainline is PR-only
#     unless the policy explicitly opts it out — e.g. Metacraft's spec `latest`,
#     which accepts direct pushes) AND the caller did not name the repository in
#     `directPushRepos`. A class with `requirePullRequest = false` still gets
#     `deletion` + `nonFastForward`.
#   * `pullRequest.allowedMergeMethods` — the class's `allowedMergeMethods`
#     (Metacraft policy: `[ "merge" ]` on every PR-gated class), rendered as the
#     rule's `allowed_merge_methods`. Squash collapses the reviewed series and
#     rebase rewrites every SHA, so a PR-gated mainline lands merge commits only
#     (branching-policy.md, "Repository Merge-Method Settings"). A ruleset that
#     allows only merge commits on a repository whose settings disable them
#     leaves NO allowed method, so the helper also returns
#     `repositoryMergeSettings` (allow_merge_commit / allow_squash_merge /
#     allow_rebase_merge derived from the same field) for every PR-only covered
#     repository. The caller applies it to its `repositories` in the same change.
#   * `mergeQueue`                   — a GitHub merge queue (the ruleset
#     `merge_queue` rule), with the settings of the mainline class's policy
#     `mergeQueue` block (merge method, grouping strategy, group size, wait time,
#     build concurrency, check timeout). OPT-IN PER REPOSITORY via
#     `mergeQueueRepos`, because the policy's rollout gate forbids rendering the
#     queue before every workflow producing one of the branch's required checks
#     triggers on `merge_group` — otherwise the queue waits forever for checks
#     that never report, and the mainline freezes. Only a PR-only mainline can
#     carry a queue (a queue gates pull requests). `mergeQueueOverrides` adjusts
#     settings per repository, EXCEPT the merge method: the queue's method is
#     always `MERGE` (the queue pushes the merge commit it tested; SQUASH and
#     REBASE land something else), and it must be one of the class's
#     `allowedMergeMethods`. A `mergeMethod` override is rejected.
#     The policy's `strictRequiredStatusChecks = false` is reported per
#     repository in `mergeQueues`: the queue tests every group against the
#     latest mainline, so "require branches to be up to date" becomes redundant,
#     and the caller drops it on the same branch in the same change.
#   * NO `requiredStatusChecks`.     The engine's ruleset schema does not express
#     them, and pinning a check context that does not exist yet makes every PR
#     unmergeable. Concrete required checks are a later, per-repo layer.
#   * `bypassActors = [ ]`, `enforcement = "active"` — the policy's `noBypass`
#     rule (branch-protection-policy.json, branching-policy.md "No bypass").
#     Agents act under their operator's identity, so an OrganizationAdmin (or
#     any other) bypass the operator holds is a bypass every agent holds: the
#     ruleset would protect the mainline from everyone except the actors most
#     likely to push to it by mistake. Deviating from either default is an
#     explicit, documented exception: a non-empty `bypassActors` requires
#     `bypassException`, a non-`active` enforcement requires
#     `enforcementException` (each the reason, >= 20 characters), and the
#     render throws otherwise. (Until 2026-09-25 the default was
#     OrganizationAdmin/always — "protect the mainline, but NOT enforce_admins".)
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
  # directPushRepos: a per-repository OVERRIDE of the policy, not the source of
  #   truth for it. Whether a mainline is PR-only is decided by its branch
  #   class's `requirePullRequest` (spec `latest` is not; product `dev` and infra
  #   `live` are). This list names repositories whose class IS PR-only but which
  #   must nevertheless accept direct pushes, because legitimate tooling commits
  #   and pushes to the branch under the invoking user's own identity (so no
  #   narrower bypass actor exists). Each must be justified by the caller.
  #
  #   It can only LOOSEN the policy, and naming a repository whose class is
  #   already not PR-only is rejected rather than ignored — see
  #   `redundantDirectPush` below.
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
  #   Anything but "active" requires `enforcementException`.
  enforcement ? "active",
  # enforcementException: the documented reason for a non-"active" enforcement.
  enforcementException ? null,
  # requiredApprovingReviewCount: null derives it from the policy class
  #   (`requirePullRequestReview` -> 1, else 0); an integer forces it for every
  #   mainline.
  requiredApprovingReviewCount ? null,
  # bypassActors: the ruleset bypass list (engine schema). The policy forbids
  #   bypass, so a non-empty list requires `bypassException`.
  bypassActors ? [ ],
  # bypassException: the documented reason for a non-empty `bypassActors`.
  bypassException ? null,
  # mergeQueueRepos: repositories whose mainline gets a merge queue, from its
  #   policy class's `mergeQueue` block. The ROLLOUT GATE: list a repository only
  #   once every workflow producing one of its mainline's required checks
  #   triggers on `merge_group`. Each must be PR-only on a class whose policy
  #   has `mergeQueue.enabled = true`; anything else is rejected.
  mergeQueueRepos ? [ ],
  # mergeQueueOverrides: per-repository adjustments of the policy's queue
  #   settings, { <repoName> = { maxEntriesToBuild = 1; ... }; }, using the
  #   policy's camelCase keys. Every named repository must be in
  #   `mergeQueueRepos`. `mergeMethod` is NOT overridable: the queue always
  #   merges with MERGE (branching-policy.md, "Repository Merge-Method Settings").
  mergeQueueOverrides ? { },
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

  # The one reading of the policy's two pull-request fields, shared with
  # `branch-protection.nix` so the two renderers cannot drift apart.
  policyLib = import ./branch-policy-lib.nix { };

  # The mainline branch keys, straight from the policy: every branch class whose
  # role is "mainline" (for Metacraft: product `dev`, spec `latest`, infra
  # `live`). The attribute KEY is the concrete branch name.
  mainlineKeys = filter (k: (branchClasses.${k}.role or "") == "mainline") (attrNames branchClasses);

  # Whether a mainline class is PR-only, per the policy's explicit per-class
  # `requirePullRequest`. Absent means true: backward compatible with policies
  # that predate the field, and a new mainline class is PR-only by default.
  # (`requirePullRequestReview` is separate: it only sets the approval count.)
  #
  # Read through `branch-policy-lib.nix`, the single reader shared with
  # `branch-protection.nix`. The two renderers consume the same policy and must
  # not disagree about what it says: this one honoured `requirePullRequest`
  # while the other still gated its `pull_request` rule on the approval field,
  # so the same class came out PR-only in one and not in the other. Every branch
  # reaching here is in `mainlineKeys`, so the library's absent-value default
  # (PR-only on a mainline or a default branch) is the `or true` this used to
  # apply locally.
  classRequiresPullRequest =
    branch: policyLib.requiresPullRequestNamed branch (branchClasses.${branch} or { });

  # Mainline classes the policy opts out of PR-only (direct pushes accepted).
  directPushClasses = filter (k: !(classRequiresPullRequest k)) mainlineKeys;

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

  # The approval COUNT, which `requirePullRequestReview` governs and nothing
  # else does. Zero is a normal answer on a PR-only branch: it drops the
  # approval requirement while leaving the pull-request gate standing.
  reviewCountFor =
    branch:
    if requiredApprovingReviewCount != null then
      requiredApprovingReviewCount
    else
      policyLib.approvalCount (branchClasses.${branch} or { }) 1;

  # The merge-queue settings keys, as the policy spells them, mapped 1:1 onto
  # the ruleset `merge_queue` rule by governance.nix.
  mergeQueueKeys = [
    "mergeMethod"
    "groupingStrategy"
    "minEntriesToMerge"
    "maxEntriesToMerge"
    "minEntriesToMergeWaitMinutes"
    "maxEntriesToBuild"
    "checkResponseTimeoutMinutes"
  ];

  # The policy class's queue block, or null when the class has none (or it is
  # disabled): spec `latest`, `agents`, and other non-PR-gated classes.
  classMergeQueue =
    branch:
    let
      mq = (branchClasses.${branch} or { }).mergeQueue or null;
    in
    if mq != null && (mq.enabled or false) then mq else null;

  # The class's allowed pull-request merge methods, or null when the class
  # does not restrict them (GitHub's default: all three). Validated here, so a
  # typo in the policy fails the render instead of reaching the API.
  mergeMethodNames = [
    "merge"
    "squash"
    "rebase"
  ];
  classAllowedMergeMethods =
    branch:
    let
      m = (branchClasses.${branch} or { }).allowedMergeMethods or null;
    in
    assert
      m == null
      || (builtins.isList m && m != [ ] && builtins.all (x: elem x mergeMethodNames) m)
      || throw "mainline-protection: policy class `${branch}` allowedMergeMethods ${builtins.toJSON m} is not a non-empty subset of merge/squash/rebase";
    m;

  # The queue's merge method is fixed: MERGE, the one method that lands the
  # merge commit the queue tested with the reviewed commits unchanged beneath
  # it. Not in the overridable keys (an override is an unknown key).
  overridableMergeQueueKeys = filter (k: k != "mergeMethod") mergeQueueKeys;

  # The rendered settings for one repository: the class's policy block, with
  # the caller's per-repository overrides on top.
  mergeQueueFor =
    repo: branch:
    let
      base = classMergeQueue branch;
      ov = mergeQueueOverrides.${repo} or { };
      unknownKeys = filter (k: !(elem k overridableMergeQueueKeys)) (attrNames ov);
      allowed = classAllowedMergeMethods branch;
      merged = listToAttrs (
        map (k: {
          name = k;
          value = ov.${k} or base.${k};
        }) mergeQueueKeys
      );
      intIn =
        k: lo: hi:
        builtins.isInt merged.${k} && merged.${k} >= lo && merged.${k} <= hi;
    in
    assert
      base != null
      || throw "mainline-protection: mergeQueueRepos names ${repo}, but its mainline class `${branch}` has no enabled `mergeQueue` in the policy";
    assert
      unknownKeys == [ ]
      || throw "mainline-protection: mergeQueueOverrides.${repo} has unknown or non-overridable keys: ${builtins.concatStringsSep ", " unknownKeys} (the queue's mergeMethod is always MERGE)";
    assert
      merged.mergeMethod == "MERGE"
      || throw "mainline-protection: ${repo} merge queue mergeMethod `${toString merged.mergeMethod}` is not MERGE; squash collapses and rebase rewrites the reviewed commits (branching-policy.md, \"Repository Merge-Method Settings\")";
    assert
      allowed == null
      || elem "merge" allowed
      || throw "mainline-protection: ${repo} merge queue merges with MERGE, but class `${branch}` allowedMergeMethods ${builtins.toJSON allowed} does not include merge";
    assert
      elem merged.groupingStrategy [
        "ALLGREEN"
        "HEADGREEN"
      ]
      || throw "mainline-protection: ${repo} merge queue groupingStrategy `${toString merged.groupingStrategy}` is not ALLGREEN/HEADGREEN";
    assert
      (
        intIn "minEntriesToMerge" 0 100
        && intIn "maxEntriesToMerge" 0 100
        && intIn "maxEntriesToBuild" 0 100
        && intIn "minEntriesToMergeWaitMinutes" 0 360
        && intIn "checkResponseTimeoutMinutes" 1 360
        && merged.minEntriesToMerge <= merged.maxEntriesToMerge
      )
      || throw "mainline-protection: ${repo} merge queue settings out of range: ${builtins.toJSON merged}";
    merged;

  mkRuleset =
    repo:
    let
      branch = mainlineBranchFor repo;
      prOnly = !(elem repo.name directPushRepos) && classRequiresPullRequest branch;
      queued = elem repo.name mergeQueueRepos;
    in
    assert
      !queued
      || prOnly
      || throw "mainline-protection: mergeQueueRepos names ${repo.name}, whose mainline is not PR-only; a merge queue gates pull requests";
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
            }
            // (
              let
                allowed = classAllowedMergeMethods branch;
              in
              if allowed == null then { } else { allowedMergeMethods = allowed; }
            );
          }
        else
          { }
      )
      // (if queued then { mergeQueue = mergeQueueFor repo.name branch; } else { });
    };

  # Guard against typos in the caller's corrections: every name they list must
  # be a repository in the inventory, or the correction silently does nothing.
  inventoryNames = map (r: r.name) repositories;
  unknown = filter (n: !(elem n inventoryNames)) (
    excludeRepos ++ directPushRepos ++ attrNames overrides ++ mergeQueueRepos
  );
  # Overrides for a repository that gets no queue would silently do nothing.
  strayQueueOverrides = filter (n: !(elem n mergeQueueRepos)) (attrNames mergeQueueOverrides);

  # Divergence between the caller's list and the policy, named rather than left
  # implicit: a `directPushRepos` entry for a repository whose mainline class is
  # ALREADY not PR-only grants nothing, because the policy had granted the direct
  # push. Left unremarked it reads as though the direct push depended on the
  # list — the same shape as deriving PR-only from the list in the first place,
  # which is how a repository came to get direct pushes only if someone
  # remembered to add it. The partition outputs report such an entry under
  # `directPushRepos` (caller-named wins), so on its own it is indistinguishable
  # from an override that is doing work; this says which ones are not.
  #
  # A caller's coverage gate should assert this list is empty and delete what it
  # names. It is reported rather than thrown because an entry that is merely
  # redundant renders the correct ruleset — the misleading list is a maintenance
  # defect, not an incorrect deployment.
  repoByName = listToAttrs (
    map (r: {
      name = r.name;
      value = r;
    }) repositories
  );
  mainlineOfName = n: if hasAttr n repoByName then mainlineBranchFor repoByName.${n} else null;
  redundantDirectPush = filter (
    n:
    let
      branch = mainlineOfName n;
    in
    branch != null && elem branch mainlineKeys && !(classRequiresPullRequest branch)
  ) directPushRepos;
  # The policy's `noBypass` rule: an exception must say why.
  documented = reason: builtins.isString reason && builtins.stringLength reason >= 20;
in
assert
  unknown == [ ]
  || throw "mainline-protection: unknown repositories in excludeRepos/directPushRepos/overrides/mergeQueueRepos: ${builtins.concatStringsSep ", " unknown}";
assert
  strayQueueOverrides == [ ]
  || throw "mainline-protection: mergeQueueOverrides names repositories not in mergeQueueRepos: ${builtins.concatStringsSep ", " strayQueueOverrides}";
assert
  bypassActors == [ ]
  || documented bypassException
  || throw "mainline-protection: bypassActors ${builtins.toJSON bypassActors} without a documented `bypassException` — the branch-protection policy forbids bypass (agents act under their operator's identity)";
assert
  enforcement == "active"
  || documented enforcementException
  || throw "mainline-protection: enforcement `${enforcement}` without a documented `enforcementException` — the branch-protection policy requires `active`";
{
  # Entries in the engine's `repositoryRulesets` schema. Append them to
  # `governance.repositoryRulesets`.
  rulesets = map mkRuleset covered;

  # Coverage report, for the caller's README / gates.
  protectedRepos = map (r: r.name) covered;
  # protectedRepos = prOnlyRepos ++ directPushRepos ++ policyDirectPushRepos
  # (a partition; a caller-named repository on a direct-push class is reported
  # under directPushRepos).
  prOnlyRepos = map (r: r.name) (
    filter (r: !(elem r.name directPushRepos) && classRequiresPullRequest (mainlineBranchFor r)) covered
  );
  # Direct push because the CALLER named the repository.
  directPushRepos = map (r: r.name) (filter (r: elem r.name directPushRepos) covered);
  # Direct push because the POLICY class says `requirePullRequest = false`.
  policyDirectPushRepos = map (r: r.name) (
    filter (
      r: !(elem r.name directPushRepos) && !(classRequiresPullRequest (mainlineBranchFor r))
    ) covered
  );
  # The mainline classes whose policy opts out of PR-only.
  inherit directPushClasses;
  # `directPushRepos` entries the POLICY had already made direct-push: the
  # override grants nothing and only makes the list look load-bearing. A caller's
  # coverage gate should assert this is empty.
  redundantDirectPushRepos = redundantDirectPush;
  # Repository merge-method settings for every PR-only covered repository whose
  # mainline class restricts `allowedMergeMethods`, in the engine's repository
  # schema: { <repo> = { allowMergeCommit; allowSquashMerge; allowRebaseMerge; }; }.
  # The ruleset alone is not enough: a ruleset allowing only merge commits on a
  # repository whose settings disable them leaves no allowed method, and every
  # pull request becomes unmergeable. The caller merges these into its
  # `repositories` in the same change that lands the rulesets.
  repositoryMergeSettings = listToAttrs (
    map
      (r: {
        name = r.name;
        value =
          let
            allowed = classAllowedMergeMethods (mainlineBranchFor r);
          in
          {
            allowMergeCommit = elem "merge" allowed;
            allowSquashMerge = elem "squash" allowed;
            allowRebaseMerge = elem "rebase" allowed;
          };
      })
      (
        filter (
          r:
          !(elem r.name directPushRepos)
          && classRequiresPullRequest (mainlineBranchFor r)
          && classAllowedMergeMethods (mainlineBranchFor r) != null
        ) covered
      )
  );
  # Repositories whose mainline ruleset carries a merge queue, with the
  # rendered settings plus the policy's `strictRequiredStatusChecks` (false:
  # the caller drops "require branches to be up to date" on that branch, in
  # the same change that enables the queue).
  mergeQueues = listToAttrs (
    map (r: {
      name = r.name;
      value = mergeQueueFor r.name (mainlineBranchFor r) // {
        branch = mainlineBranchFor r;
        strictRequiredStatusChecks =
          (classMergeQueue (mainlineBranchFor r)).strictRequiredStatusChecks or false;
      };
    }) (filter (r: elem r.name mergeQueueRepos) covered)
  );
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
