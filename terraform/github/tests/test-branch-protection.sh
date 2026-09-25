#!/usr/bin/env bash
# Exercises terraform/github/branch-protection.nix: which branch classes produce
# a ruleset for which repository class, and — the part that had no coverage at
# all — WHICH POLICY FIELD decides that a branch is PR-only.
#
# Offline: Nix eval only, no credentials, no network, no mocks. The policy is the
# real `example/policy.fixture.json` (so the fixture that consumers copy is the
# thing under test), plus two small literal policies for the two ways the two
# pull-request fields can disagree.
#
# The distinction the policy draws, and that this test pins:
#
#   requirePullRequest       -> the branch is PR-only (emit `pull_request`)
#   requirePullRequestReview -> the required approval COUNT only
#
# Gating the rule on the approval field is wrong in both directions: with
# approvals removed org-wide (`requirePullRequestReview = false` everywhere) it
# drops the PR gate from `stable`, `dev` and `live`, and it would impose one on
# any class that kept an approval count while declaring itself not PR-only.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
helper="${here}/../branch-protection.nix"
fixture="${here}/../example/policy.fixture.json"
fail=0

# $1 = a Nix expression for the policy. One repository per repoClass, so every
# class in the policy is reachable.
render() {
  nix eval --json --impure --expr "
    let
      pkgs = import <nixpkgs> { };
      bp = import ${helper} { inherit (pkgs) lib; };
    in (bp.mkRulesets {
      policy = $1;
      repositories = {
        r-product = { repoClass = \"product\"; checks.dev = [ \"ci\" ]; };
        r-spec = { repoClass = \"spec\"; };
        r-infra = { repoClass = \"infra\"; };
        r-fork = { repoClass = \"product-adapted-fork\"; };
      };
    }).resource.github_repository_ruleset
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

# `pull_request` presence, keyed by branch class, as an object.
pr_by_class='
  [ to_entries[] | select(.value.name != "baseline-protect-all-branches")
    | { key: (.value.name | sub("-policy$"; "")),
        value: (if (.value.rules | has("pull_request"))
                then .value.rules.pull_request.required_approving_review_count
                else null end) } ]
  | from_entries'

# ---------------------------------------------------------------------------
# The shipped fixture.
out="$(render "builtins.fromJSON (builtins.readFile ${fixture})")"

check "one baseline ~ALL ruleset per repository, blocking deletion + force-push" \
  '[to_entries[] | select(.value.name == "baseline-protect-all-branches")]
   | (length == 4) and all(.value.conditions.ref_name.include == ["~ALL"]
                          and .value.rules.deletion and .value.rules.non_fast_forward)' "$out"

check "PR-only classes get pull_request; latest and agents do not" \
  "(${pr_by_class}) as \$p
   | (\$p.stable != null) and (\$p.dev != null) and (\$p.live != null)
     and (\$p.latest == null) and (\$p | has(\"agents\") | not)" "$out"

# This is the assertion that is RED on a renderer gating the rule on
# `requirePullRequestReview`: `live` declares requirePullRequest = true and
# carries no review field at all, so the gate must be present with a count of 0.
check "a PR-only class with no approval requirement gets the gate with count 0 (live)" \
  "(${pr_by_class}).live == 0" "$out"

check "the approval count still comes from requirePullRequestReview (stable/dev = 1)" \
  "(${pr_by_class}) as \$p | (\$p.stable == 1) and (\$p.dev == 1)" "$out"

check "spec latest still gates on CI while accepting direct pushes" \
  '[to_entries[] | select(.value.name == "latest-policy")][0].value.rules
   | has("required_status_checks") and (has("pull_request") | not)' "$out"

check "the caller's concrete check contexts are carried through" \
  '[to_entries[] | select(.value.name == "dev-policy")][0].value.rules.required_status_checks.required_check
   == [{context: "ci"}]' "$out"

# ---------------------------------------------------------------------------
# Field independence, both directions. These are the two shapes a renderer that
# conflates the fields gets wrong, and neither is reachable from the fixture
# alone.
noPrWithReview='{
  baseline = { allowForcePush = false; allowDeletion = false; };
  branchClasses = {
    latest = { repoClass = "spec"; role = "mainline"; requireStatusChecks = true;
               requirePullRequest = false; requirePullRequestReview = true; };
  };
}'
out2="$(render "$noPrWithReview")"
check "requirePullRequest = false wins over requirePullRequestReview = true (no PR gate)" \
  "(${pr_by_class}).latest == null" "$out2"

prWithoutReview='{
  baseline = { allowForcePush = false; allowDeletion = false; };
  branchClasses = {
    latest = { repoClass = "spec"; role = "mainline"; requireStatusChecks = false;
               requirePullRequest = true; requirePullRequestReview = false; };
  };
}'
out3="$(render "$prWithoutReview")"
check "requirePullRequest = true alone emits a ruleset with the PR gate and 0 approvals" \
  "(${pr_by_class}).latest == 0" "$out3"

# An absent requirePullRequest on a MAINLINE defaults to true — the policy's own
# note ("consumers treat an absent value on a mainline as true"). A class that is
# not a mainline defaults to false.
absentField='{
  baseline = { allowForcePush = false; allowDeletion = false; };
  branchClasses = {
    dev = { repoClass = "product"; role = "mainline"; requireStatusChecks = true; };
    staging = { repoClass = "product"; role = "deployment"; pattern = "staging"; requireStatusChecks = true; };
  };
}'
out4="$(render "$absentField")"
check "absent requirePullRequest defaults to PR-only on a mainline, not on a deployment branch" \
  "(${pr_by_class}) as \$p | (\$p.dev == 0) and (\$p.staging == null)" "$out4"

# The policy's noBypass rule: every ruleset this renderer emits is `active` and
# carries NO bypass actors (agents act under their operator's identity, so an
# operator's bypass is every agent's bypass).
for o in "$out" "$out2" "$out3" "$out4"; do
  check "every rendered ruleset is active with no bypass_actors" \
    '[.[] | (.enforcement == "active") and ((.bypass_actors // []) == [])] | all' "$o"
done

exit "$fail"
