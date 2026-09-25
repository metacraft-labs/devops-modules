# Agnostic branch-protection rulesets for GitHub repositories.
#
# Renders `github_repository_ruleset` resources from the shared branch-protection
# policy (the machine-readable `branch-protection-policy.json` maintained in
# metacraft-dev-guidelines) plus per-repository configuration. This library is
# company- and repository-agnostic: the caller supplies the parsed policy, the
# list of repositories, each repository's class, and its concrete required-check
# contexts. The policy fixes *which* branch classes gate on CI; the caller
# provides the *check names*.
#
# Usage (from a Terranix root):
#
#   let bp = import ./branch-protection.nix { inherit lib; };
#   in bp.mkRulesets {
#     policy = builtins.fromJSON (builtins.readFile "${inputs.dev-guidelines}/policies/branch-protection-policy.json");
#     repositories = {
#       "my-product" = {
#         repoClass = "product";
#         checks = { dev = [ "ci / build" "ci / test" ]; stable = [ "release" ]; };
#       };
#       "my-infra" = {
#         repoClass = "infra";
#         checks.live = [ "terraform / plan" "lint" ];
#       };
#     };
#   }
{ lib }:
let
  inherit (lib)
    filterAttrs
    concatMapAttrs
    foldlAttrs
    optionalAttrs
    replaceStrings
    ;

  # The one reading of the policy's two pull-request fields, shared with
  # `mainline-protection.nix` so the two renderers cannot drift apart.
  policyLib = import ./branch-policy-lib.nix { };

  # Sanitize a repo/branch identifier into a Terraform resource key.
  key =
    replaceStrings
      [
        "/"
        "."
        "*"
        "<"
        ">"
        "-"
        " "
      ]
      [
        "_"
        "_"
        "star"
        ""
        ""
        "_"
        "_"
      ];
in
{
  # policy: the parsed branch-protection-policy.json (baseline + branchClasses).
  # repositories: attrset keyed by repo name; each value is
  #   { repoClass;                         # "product" | "spec" | "infra" | "product-adapted-fork"
  #     checks ? { };                       # { <branchClassKey> = [ "context" ... ]; }
  #     reviewCount ? 1; }
  mkRulesets =
    { policy, repositories }:
    let
      inherit (policy) baseline branchClasses;

      # Baseline ruleset: every branch, no force push / no deletion.
      baselineRuleset = repoName: {
        name = "baseline-protect-all-branches";
        repository = repoName;
        target = "branch";
        enforcement = "active";
        conditions.ref_name = {
          include = [ "~ALL" ];
          exclude = [ ];
        };
        rules = {
          # A `true` rule blocks the operation.
          deletion = !(baseline.allowDeletion or false);
          non_fast_forward = !(baseline.allowForcePush or false);
        };
      };

      # Per-class rulesets for one repo: only classes whose repoClass matches.
      classRulesets =
        repoName: repoCfg:
        let
          applicable = filterAttrs (_: c: c.repoClass == repoCfg.repoClass) branchClasses;
        in
        concatMapAttrs (
          branchKey: cls:
          let
            # Which branch(es) this class targets.
            refInclude =
              if cls ? pattern then
                (
                  if cls.pattern == "<product-name>" then
                    [ "refs/heads/${repoName}" ]
                  else
                    [ "refs/heads/${cls.pattern}" ]
                )
              else
                [ "refs/heads/${branchKey}" ];
            contexts = repoCfg.checks.${branchKey} or [ ];
            rules =
              optionalAttrs (cls.requireStatusChecks or false) {
                required_status_checks = {
                  strict_required_status_checks_policy = true;
                  required_check = map (ctx: { context = ctx; }) contexts;
                };
              }
              # `requirePullRequest` — NOT `requirePullRequestReview` — decides
              # whether the branch is PR-only. The approval field only sets the
              # count, which may legitimately be 0 on a PR-only branch.
              // optionalAttrs (policyLib.requiresPullRequestNamed branchKey cls) {
                pull_request = {
                  required_approving_review_count = policyLib.approvalCount cls (repoCfg.reviewCount or 1);
                  dismiss_stale_reviews_on_push = true;
                  require_code_owner_review = false;
                };
              };
          in
          # Emit only when this class adds something beyond the baseline.
          optionalAttrs (rules != { }) {
            "ruleset_${key repoName}_${key branchKey}" = {
              name = "${branchKey}-policy";
              repository = repoName;
              target = "branch";
              enforcement = "active";
              conditions.ref_name = {
                include = refInclude;
                exclude = [ ];
              };
              inherit rules;
            };
          }
        ) applicable;

      allRulesets = foldlAttrs (
        acc: repoName: repoCfg:
        acc
        // {
          "ruleset_${key repoName}_baseline" = baselineRuleset repoName;
        }
        // classRulesets repoName repoCfg
      ) { } repositories;
    in
    {
      resource.github_repository_ruleset = allRulesets;
    };
}
