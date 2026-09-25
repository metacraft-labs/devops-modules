# Shared readers for the branch-protection policy's two pull-request fields.
#
# Both renderers in this directory must agree on what the shared policy means by
# "PR-only", or one policy file renders two different GitHub states:
#
#   * `branch-protection.nix`   -> raw `github_repository_ruleset` resources
#   * `mainline-protection.nix` -> `governance.repositoryRulesets` entries
#
# The policy keeps the two fields deliberately separate, and says so in its own
# notes:
#
#   requirePullRequest       — whether the branch class is PR-only (no direct
#                              push). THIS is the pull-request gate.
#   requirePullRequestReview — the required APPROVAL COUNT only.
#
# Reading the approval field to decide the gate conflates them, and the
# conflation is not benign in either direction. Required approvals are being
# removed org-wide, so every class now carries
# `requirePullRequestReview = false`: a renderer that gates on it drops the PR
# requirement from every class that should have one, while a renderer that
# instead derives PR-only from a hand-maintained repository list imposes one on
# every class that should not — which is how spec `latest` came to be PR-only
# against both the policy and the operator's stated intent.
{ }:
rec {
  # Is this branch class PR-only (no direct push)?
  #
  # `requirePullRequest` is explicit on every mainline and on `stable`. When it
  # is absent, the policy's own note fixes the default: "consumers treat an
  # absent value on a mainline as true, so a new mainline class is PR-only
  # unless the policy says otherwise". A repository's default branch is treated
  # the same way, so the fallback is never the lax one for the branch that
  # matters most. Every other class (deployment, integration, adaptation) is
  # governed by `restrictPushes` / `allowDirectPush` instead, and is not PR-only
  # unless it says so.
  #
  # `label` only names the class in the error message.
  requiresPullRequestNamed =
    label: cls:
    let
      v = cls.requirePullRequest or ((cls.role or "") == "mainline" || (cls.isDefaultBranch or false));
    in
    assert
      builtins.isBool v
      || throw "branch-policy: policy branch class `${label}` has a non-boolean requirePullRequest";
    v;

  requiresPullRequest = requiresPullRequestNamed "<unnamed>";

  # The required approving-review count for a class: `whenRequired` when the
  # class requires approvals, zero when it does not. `requirePullRequestReview
  # = false` means ZERO APPROVALS, not "no pull request" — a PR gate with a
  # count of 0 still forbids the direct push.
  approvalCount =
    cls: whenRequired: if cls.requirePullRequestReview or false then whenRequired else 0;
}
