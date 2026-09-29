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

# The legacy policy shape: no `requirePullRequest` anywhere, so every mainline
# must default to PR-only (backward compatibility).
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

# The current policy shape: an explicit per-class `requirePullRequest`, with
# spec `latest` opted out of PR-only (direct pushes accepted) and `agents` also
# false (it is not a mainline, so it must still never be targeted).
policyLatestDirect='{
  baseline = { allowForcePush = false; allowDeletion = false; };
  branchClasses = {
    stable = { repoClass = "product"; role = "default-release"; requirePullRequest = true; requirePullRequestReview = true; };
    dev = { repoClass = "product"; role = "mainline"; requirePullRequest = true; requirePullRequestReview = true; };
    agents = { repoClass = "product"; role = "integration"; requirePullRequest = false; };
    latest = { repoClass = "spec"; role = "mainline"; requirePullRequest = false; };
    live = { repoClass = "infra"; role = "mainline"; requirePullRequest = true; };
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

# $1 = extra helper arguments (Nix attrset body); $2 = policy (default: legacy)
helper_eval() {
  nix eval --json --impure --expr "
    import ${helper} ({ policy = ${2:-$policy}; repositories = ${repos}; } // { $1 })
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
  enforcementException = "test fixture: exercise the pass-through";
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
check "default bypass is EMPTY (the policy's noBypass rule: no admin bypass)" \
  '[.rulesets[].bypassActors] | all(. == [])' "$out"
check "default enforcement is active" \
  '[.rulesets[].enforcement] | all(. == "active")' "$(helper_eval 'excludeRepos = [ "fork" ];')"
check "absent requirePullRequest defaults to PR-only (latest keeps pull_request)" \
  '((.rulesets[] | select(.repository == "specs") | .rules.pullRequest) != null) and (.policyDirectPushRepos == []) and (.directPushClasses == [])' "$out"

# ── per-class requirePullRequest: spec `latest` accepts direct pushes ─────────
outLD="$(helper_eval "$args" "$policyLatestDirect")"
check "requirePullRequest=false class: same covered set (still protected)" \
  '(.protectedRepos | sort) == (["infra","manifests","product","public-dev","specs","stale"] | sort)' "$outLD"
check "requirePullRequest=false class keeps no-delete/no-force-push but no pull_request rule" \
  '(.rulesets[] | select(.repository == "specs") | .rules) == {deletion: true, nonFastForward: true}' "$outLD"
check "requirePullRequest=true classes (dev, live) stay PR-only" \
  '[.rulesets[] | select(.conditions.refNameInclude[0] | test("^refs/heads/(dev|live)$")) | .rules.pullRequest != null] | (length == 4 and all)' "$outLD"
check "coverage partitions: prOnly / caller direct-push / policy direct-push" \
  '((.prOnlyRepos | sort) == ["infra","product","public-dev","stale"]) and (.directPushRepos == ["manifests"]) and (.policyDirectPushRepos == ["specs"]) and (.directPushClasses == ["latest"]) and (((.prOnlyRepos + .directPushRepos + .policyDirectPushRepos) | sort) == (.protectedRepos | sort))' "$outLD"
check "a non-mainline class with requirePullRequest=false (agents) is still never targeted" \
  '[.rulesets[].conditions.refNameInclude[0]] | all(. != "refs/heads/agents")' "$outLD"

# `directPushRepos` is an OVERRIDE of the policy field, and a divergence between
# the two must be visible. Here `manifests` is on `latest`, which this policy
# already opts out of PR-only, so the entry grants nothing — the partition
# reports it under `directPushRepos` (caller-named wins), which on its own is
# indistinguishable from an override that is doing work. A repository must not
# appear to get direct pushes because somebody remembered to list it.
check "a directPushRepos entry the policy had already granted is reported as redundant" \
  '.redundantDirectPushRepos == ["manifests"]' "$outLD"
check "an override that actually loosens a PR-only class is NOT reported as redundant" \
  '.redundantDirectPushRepos == []' "$out"
check "nothing is reported redundant when the caller names no overrides" \
  '(.redundantDirectPushRepos == []) and ((.policyDirectPushRepos | sort) == ["manifests","specs"])' \
  "$(helper_eval 'excludeRepos = [ "fork" ]; overrides = { product = "dev"; stale = "live"; };' "$policyLatestDirect")"
# Negative control: the opt-out is per CLASS. Flipping it on `live` instead must
# move the `live` mainlines (infra, and stale via its override) — not specs — to
# direct push — the flag is actually read per class,
# not applied org-wide or keyed on the repository name.
outLive="$(helper_eval "$args" "(${policy}) // { branchClasses = (${policy}).branchClasses // { live = { repoClass = \"infra\"; role = \"mainline\"; requirePullRequest = false; }; }; }")"
check "negative control: opting out \`live\` drops PR on live mainlines only, specs stays PR-only" \
  '((.rulesets[] | select(.repository == "infra") | .rules) == {deletion: true, nonFastForward: true}) and ((.rulesets[] | select(.repository == "specs") | .rules.pullRequest) != null) and ((.policyDirectPushRepos | sort) == ["infra","stale"]) and (.directPushClasses == ["live"])' "$outLive"

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
if helper_eval "$args" "(${policy}) // { branchClasses = (${policy}).branchClasses // { latest = { role = \"mainline\"; requirePullRequest = \"no\"; }; }; }" >/dev/null 2>&1; then
  echo "FAIL: a non-boolean requirePullRequest was accepted"
  fail=1
else
  echo "ok: a non-boolean requirePullRequest is rejected"
fi

# The noBypass policy: a bypass or a non-active enforcement is an explicit,
# documented exception, never a silent argument.
if helper_eval 'bypassActors = [ { actorId = 0; actorType = "OrganizationAdmin"; bypassMode = "always"; } ];' >/dev/null 2>&1; then
  echo "FAIL: an OrganizationAdmin bypass without bypassException was accepted"
  fail=1
else
  echo "ok: a bypass without a documented bypassException is rejected"
fi
if helper_eval 'bypassActors = [ { actorId = 0; actorType = "OrganizationAdmin"; bypassMode = "always"; } ]; bypassException = "short";' >/dev/null 2>&1; then
  echo "FAIL: a bypass with an undocumented (too short) reason was accepted"
  fail=1
else
  echo "ok: a bypass with a too-short reason is rejected"
fi
if helper_eval 'enforcement = "evaluate";' >/dev/null 2>&1; then
  echo "FAIL: evaluate enforcement without enforcementException was accepted"
  fail=1
else
  echo "ok: a non-active enforcement without a documented enforcementException is rejected"
fi
outEx="$(helper_eval 'bypassActors = [ { actorId = 42; actorType = "Integration"; bypassMode = "always"; } ]; bypassException = "release App 42 tags releases on the mainline";')"
check "a documented bypassException is honoured (the actor is passed through)" \
  '[.rulesets[].bypassActors] | all(. == [{actorId: 42, actorType: "Integration", bypassMode: "always"}])' "$outEx"

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
check "rendered PR-only ruleset carries pull_request and NO bypass_actors" \
  '[.resource.github_repository_ruleset[] | select(.repository == "infra")][0] | (.rules[0].pull_request | length == 1) and (has("bypass_actors") | not) and (.enforcement == "evaluate") and (.conditions[0].ref_name[0].include == ["refs/heads/live"])' "$rendered"
check "rendered direct-push ruleset has no pull_request block" \
  '[.resource.github_repository_ruleset[] | select(.repository == "manifests")][0].rules[0] | has("pull_request") | not' "$rendered"

renderedLD="$(nix eval --json --impure --expr "
  let m = import ${helper} ({ policy = ${policyLatestDirect}; repositories = ${repos}; } // { ${args} });
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
check "rendered requirePullRequest=false ruleset: deletion + non_fast_forward, no pull_request" \
  '[.resource.github_repository_ruleset[] | select(.repository == "specs")][0].rules[0] | (has("pull_request") | not) and (.deletion == true) and (.non_fast_forward == true)' "$renderedLD"

# ── merge queue: opt-in per repository, settings from the policy class ───────
# The policy shape of 2026-09-29: PR-gated mainlines (dev, live) carry an
# enabled `mergeQueue`; spec `latest` has none.
policyMQ='{
  baseline = { allowForcePush = false; allowDeletion = false; };
  branchClasses = {
    stable = { repoClass = "product"; role = "default-release"; requirePullRequest = true; };
    dev = { repoClass = "product"; role = "mainline"; requirePullRequest = true; requirePullRequestReview = false;
      mergeQueue = { enabled = true; mergeMethod = "MERGE"; groupingStrategy = "ALLGREEN"; minEntriesToMerge = 1; maxEntriesToMerge = 5; minEntriesToMergeWaitMinutes = 5; maxEntriesToBuild = 2; checkResponseTimeoutMinutes = 360; strictRequiredStatusChecks = false; }; };
    agents = { repoClass = "product"; role = "integration"; requirePullRequest = false; };
    latest = { repoClass = "spec"; role = "mainline"; requirePullRequest = false; };
    live = { repoClass = "infra"; role = "mainline"; requirePullRequest = true;
      mergeQueue = { enabled = false; mergeMethod = "MERGE"; groupingStrategy = "ALLGREEN"; minEntriesToMerge = 1; maxEntriesToMerge = 5; minEntriesToMergeWaitMinutes = 5; maxEntriesToBuild = 2; checkResponseTimeoutMinutes = 360; strictRequiredStatusChecks = false; }; };
  };
}'
mqArgs='excludeRepos = [ "fork" ]; overrides = { product = "dev"; };'
outNoMQ="$(helper_eval "$mqArgs" "$policyMQ")"
check "a policy mergeQueue alone renders NO queue (the rollout gate is per repository)" \
  '([.rulesets[].rules | has("mergeQueue")] | any | not) and (.mergeQueues == {})' "$outNoMQ"
outMQ="$(helper_eval "$mqArgs mergeQueueRepos = [ \"product\" \"public-dev\" ]; mergeQueueOverrides = { product = { maxEntriesToBuild = 1; }; };" "$policyMQ")"
check "opted-in repositories get the policy's queue settings" \
  '(.rulesets[] | select(.repository == "public-dev") | .rules.mergeQueue) == {mergeMethod: "MERGE", groupingStrategy: "ALLGREEN", minEntriesToMerge: 1, maxEntriesToMerge: 5, minEntriesToMergeWaitMinutes: 5, maxEntriesToBuild: 2, checkResponseTimeoutMinutes: 360}' "$outMQ"
check "a per-repository override changes only that setting on that repository" \
  '(.rulesets[] | select(.repository == "product") | .rules.mergeQueue) as $q | $q.mergeMethod == "MERGE" and $q.maxEntriesToBuild == 1 and $q.maxEntriesToMerge == 5 and $q.checkResponseTimeoutMinutes == 360' "$outMQ"
check "repositories not opted in carry no queue" \
  '[.rulesets[] | select(.repository != "product" and .repository != "public-dev") | .rules | has("mergeQueue")] | any | not' "$outMQ"
check "mergeQueues reports settings, branch and strictRequiredStatusChecks=false" \
  '(.mergeQueues | keys) == ["product","public-dev"] and .mergeQueues.product.branch == "dev" and .mergeQueues.product.strictRequiredStatusChecks == false and .mergeQueues.product.mergeMethod == "MERGE"' "$outMQ"
for bad in \
  'mergeQueueRepos = [ "infra" ];|a class whose mergeQueue is disabled' \
  'mergeQueueRepos = [ "specs" ];|a class with no mergeQueue (spec latest)' \
  'mergeQueueRepos = [ "product" ]; directPushRepos = [ "product" ];|a direct-push (not PR-only) repository' \
  'mergeQueueRepos = [ "no-such-repo" ];|an unknown repository' \
  'mergeQueueRepos = [ "product" ]; mergeQueueOverrides = { public-dev = { maxEntriesToBuild = 1; }; };|an override for a repository without a queue' \
  'mergeQueueRepos = [ "product" ]; mergeQueueOverrides = { product = { mergeMethod = "REBASE"; }; };|a REBASE merge-method override (the method is not overridable)' \
  'mergeQueueRepos = [ "product" ]; mergeQueueOverrides = { product = { mergeMethod = "MERGE"; }; };|any merge-method override, even MERGE' \
  'mergeQueueRepos = [ "product" ]; mergeQueueOverrides = { product = { mergeMethd = "REBASE"; }; };|an override with an unknown key' \
  'mergeQueueRepos = [ "product" ]; mergeQueueOverrides = { product = { checkResponseTimeoutMinutes = 720; }; };|a check timeout beyond GitHub'"'"'s 360 minutes' \
  'mergeQueueRepos = [ "product" ]; mergeQueueOverrides = { product = { minEntriesToMerge = 6; }; };|a minimum group larger than the maximum'; do
  expr="${bad%%|*}"; what="${bad#*|}"
  if helper_eval "$mqArgs $expr" "$policyMQ" 2>/dev/null | jq -e '.rulesets | length' >/dev/null 2>&1; then
    echo "FAIL: a merge queue for $what was accepted"
    fail=1
  else
    echo "ok: a merge queue for $what is rejected"
  fi
done
renderedMQ="$(nix eval --json --impure --expr "
  let m = import ${helper} ({ policy = ${policyMQ}; repositories = ${repos}; } // { ${mqArgs} mergeQueueRepos = [ \"product\" ]; });
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
check "engine renders the provider merge_queue block, snake_case, on the queued ruleset only" \
  '([.resource.github_repository_ruleset[] | select(.repository == "product")][0].rules[0].merge_queue == [{merge_method: "MERGE", grouping_strategy: "ALLGREEN", min_entries_to_merge: 1, max_entries_to_merge: 5, min_entries_to_merge_wait_minutes: 5, max_entries_to_build: 2, check_response_timeout_minutes: 360}]) and ([.resource.github_repository_ruleset[] | select(.repository != "product") | .rules[0] | has("merge_queue")] | any | not)' "$renderedMQ"

# A policy class whose queue method is not MERGE is refused, even without an
# override: SQUASH collapses and REBASE rewrites the reviewed commits.
policyMQSquash="${policyMQ/mergeMethod = \"MERGE\"; groupingStrategy = \"ALLGREEN\"; minEntriesToMerge = 1; maxEntriesToMerge = 5; minEntriesToMergeWaitMinutes = 5; maxEntriesToBuild = 2; checkResponseTimeoutMinutes = 360; strictRequiredStatusChecks = false; }; };
    agents/mergeMethod = \"SQUASH\"; groupingStrategy = \"ALLGREEN\"; minEntriesToMerge = 1; maxEntriesToMerge = 5; minEntriesToMergeWaitMinutes = 5; maxEntriesToBuild = 2; checkResponseTimeoutMinutes = 360; strictRequiredStatusChecks = false; }; };
    agents}"
if [[ "$policyMQSquash" == "$policyMQ" ]]; then
  echo "FAIL: test setup: could not derive the SQUASH policy fixture"
  fail=1
elif helper_eval "$mqArgs mergeQueueRepos = [ \"product\" ];" "$policyMQSquash" 2>/dev/null | jq -e '.rulesets | length' >/dev/null 2>&1; then
  echo "FAIL: a policy queue method of SQUASH was accepted"
  fail=1
else
  echo "ok: a policy queue method other than MERGE is rejected"
fi

# ── allowed merge methods: PR-gated classes land merge commits only ──────────
# The policy shape of 2026-09-30: every PR-gated class carries
# `allowedMergeMethods = [ "merge" ]`; spec `latest` (direct push) does not.
policyAMM='{
  baseline = { allowForcePush = false; allowDeletion = false; };
  branchClasses = {
    stable = { repoClass = "product"; role = "default-release"; requirePullRequest = true; allowedMergeMethods = [ "merge" ]; };
    dev = { repoClass = "product"; role = "mainline"; requirePullRequest = true; requirePullRequestReview = false; allowedMergeMethods = [ "merge" ];
      mergeQueue = { enabled = true; mergeMethod = "MERGE"; groupingStrategy = "ALLGREEN"; minEntriesToMerge = 1; maxEntriesToMerge = 5; minEntriesToMergeWaitMinutes = 5; maxEntriesToBuild = 2; checkResponseTimeoutMinutes = 360; strictRequiredStatusChecks = false; }; };
    agents = { repoClass = "product"; role = "integration"; requirePullRequest = false; };
    latest = { repoClass = "spec"; role = "mainline"; requirePullRequest = false; };
    live = { repoClass = "infra"; role = "mainline"; requirePullRequest = true; allowedMergeMethods = [ "merge" ]; };
  };
}'
ammArgs='excludeRepos = [ "fork" ]; overrides = { product = "dev"; }; directPushRepos = [ "public-dev" ]; mergeQueueRepos = [ "product" ];'
outAMM="$(helper_eval "$ammArgs" "$policyAMM")"
check "every PR-gated ruleset allows exactly the merge method" \
  '[.rulesets[] | select(.rules.pullRequest != null) | .rules.pullRequest.allowedMergeMethods] as $m | ($m | length) == 2 and ($m | all(. == ["merge"]))' "$outAMM"
check "direct-push rulesets carry no pull_request rule, hence no merge methods" \
  '[.rulesets[] | select(.repository == "specs" or .repository == "manifests" or .repository == "public-dev") | .rules | has("pullRequest")] | any | not' "$outAMM"
check "repositoryMergeSettings: merge-only settings for exactly the PR-only repositories" \
  '(.repositoryMergeSettings | keys) == (.prOnlyRepos | sort) and ([.repositoryMergeSettings[]] | all(. == {allowMergeCommit: true, allowSquashMerge: false, allowRebaseMerge: false}))' "$outAMM"
check "the queue on a merge-only class merges with MERGE" \
  '.mergeQueues.product.mergeMethod == "MERGE"' "$outAMM"
check "a policy without allowedMergeMethods renders none and derives no repository settings" \
  '([.rulesets[].rules.pullRequest // {} | has("allowedMergeMethods")] | any | not) and (.repositoryMergeSettings == {})' "$(helper_eval "$args")"
for bad in \
  '[ ]|an empty list' \
  '[ "merge" "fastforward" ]|an unknown method' \
  '"merge"|a string instead of a list'; do
  val="${bad%%|*}"; what="${bad#*|}"
  if helper_eval "$ammArgs" "${policyAMM//allowedMergeMethods = \[ \"merge\" \]/allowedMergeMethods = $val}" 2>/dev/null | jq -e '.rulesets | length' >/dev/null 2>&1; then
    echo "FAIL: allowedMergeMethods as $what was accepted"
    fail=1
  else
    echo "ok: allowedMergeMethods as $what is rejected"
  fi
done
if helper_eval "$ammArgs" "${policyAMM//allowedMergeMethods = \[ \"merge\" \]/allowedMergeMethods = [ \"squash\" ]}" 2>/dev/null | jq -e '.rulesets | length' >/dev/null 2>&1; then
  echo "FAIL: a MERGE queue on a class that forbids merge commits was accepted"
  fail=1
else
  echo "ok: a MERGE queue on a class that forbids merge commits is rejected"
fi
renderedAMM="$(nix eval --json --impure --expr "
  let m = import ${helper} ({ policy = ${policyAMM}; repositories = ${repos}; } // { ${ammArgs} });
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
check "engine renders allowed_merge_methods = [merge] on every PR-gated pull_request rule" \
  '[.resource.github_repository_ruleset[] | .rules[0].pull_request // empty | .[0].allowed_merge_methods] as $m | ($m | length) == 2 and ($m | all(. == ["merge"]))' "$renderedAMM"
check "engine renders the queued ruleset with merge_method MERGE" \
  '[.resource.github_repository_ruleset[] | select(.repository == "product")][0].rules[0].merge_queue[0].merge_method == "MERGE"' "$renderedAMM"

exit "$fail"
