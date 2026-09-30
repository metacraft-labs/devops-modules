# Policy-driven FORBIDDEN-BRANCH rulesets, in the governance engine's
# `repositoryRulesets` schema.
#
# A branch class of the shared branch-protection policy (for Metacraft:
# `metacraft-dev-guidelines/policies/branch-protection-policy.json`) may carry
# `forbiddenBranches`: branch names or fnmatch patterns that may not exist in a
# repository of that class. For Metacraft that is `agents` and
# `agents-to-dev-*` on spec `latest`, infra `live` and `product-fork`: only
# product repositories have an agent landing branch, every other class lands
# agent work on its mainline. This helper renders one repository ruleset
# (default name `forbidden-branches`) per repository in scope.
#
# Usage (from a governance root, next to mainline-protection.nix):
#
#   let
#     policy = builtins.fromJSON (builtins.readFile ./branch-protection-policy.json);
#     mainline = import "${devops-modules}/terraform/github/mainline-protection.nix" { ... };
#     forbidden = import "${devops-modules}/terraform/github/forbidden-branches.nix" {
#       inherit policy;
#       repositories = inventory.repositories;
#       mainlines = mainline.mainlines;
#       excludeRepos = [ ... ];                 # the SAME list mainline-protection gets
#       forkRepos = { some-fork = "product"; }; # fork -> its product (default) branch
#     };
#   in mkGovernance {
#     governance = inventory // {
#       repositoryRulesets = inventory.repositoryRulesets ++ mainline.rulesets ++ forbidden.rulesets;
#     };
#   }
#
# SCOPE.
#
#   * Repositories on a policy MAINLINE (spec, infra, product) are DERIVED, not
#     listed: the caller passes the `mainlines` output of mainline-protection.nix
#     (repository -> mainline branch class, after overrides, exclusions and the
#     visibility filter), so class derivation lives in one place. A repository is
#     in scope when its mainline class carries a non-empty `forbiddenBranches`.
#     Product `dev` carries none, so product repositories are never in scope.
#   * PRODUCT-ADAPTED FORKS are LISTED (`forkRepos`), because a fork's product
#     branch (`codetracer`, `reprobuild`, ...) is not a policy mainline class and
#     cannot be derived from `defaultBranch`. Each entry names the product
#     branch, which must be the repository's default branch in the inventory.
#     Forks get the `forkClass` (default `product-fork`) class's list.
#
# WHAT A FORBIDDEN-BRANCHES RULESET DOES, and why it is expressed this way:
#
#   * `creation`        — the forbidden branch cannot be created (the point:
#     classic branch protection can only constrain a branch that exists).
#   * `update`          — a forbidden branch that already exists cannot be pushed to.
#   * `nonFastForward`  — nor force-pushed around either rule.
#   * NO `deletion`.    A stray branch must remain removable (after its content
#     is on the mainline); restricting deletion would pin it in place. The same
#     shape as the `no-main-branch` rulesets. A creation restriction does not
#     delete an existing branch; the caller removes those separately.
#   * `bypassActors = [ ]`, `enforcement = "active"` — the policy's `noBypass`
#     rule. A deviation needs `bypassException` / `enforcementException` (the
#     reason, >= 20 characters), exactly as mainline-protection.nix requires.
#
# VALIDATION. The evaluation throws, each with its own message, on:
#
#   * `forbiddenBranches` that is not a list of non-empty strings;
#   * a forbidden entry that matches a policy mainline key (`role = "mainline"`)
#     — "is a policy mainline";
#   * a forbidden entry that matches a branch class (its key or its `pattern`)
#     of the SAME `repoClass` as the forbidding class — it would block that
#     class's own branch. This is what makes forbidding `agents` on a product
#     repository impossible — "matches branch class";
#   * a forbidden entry that matches the repository's own mainline (for a fork:
#     its product branch) — "is the mainline of";
#   * a `mainlines` value that is not a policy branch class, or a `mainlines`
#     repository missing from the inventory;
#   * a `forkRepos` entry that is unknown, archived, in `excludeRepos`, already
#     derived through `mainlines`, whose product branch is a policy mainline key,
#     or whose product branch is not its default branch; or a non-empty
#     `forkRepos` with no `forkClass` in the policy;
#   * an undocumented bypass or non-active enforcement.
#
# "Matches" is an OVERLAP test between two fnmatch patterns: equal, or either
# one matches the other taken as a literal string. Patterns support literals,
# `*` (not across `/`), `**` and `?`; every other character is literal. That is
# exact when at least one side is a literal branch name and conservative for
# the prefix/suffix wildcards the policy uses (`agents-*` vs `agents-to-dev-*`
# overlap, and are reported).
#
# A policy with no `forbiddenBranches` anywhere renders nothing.
#
# This file imports nothing, so a governance root can vendor it verbatim.
{
  # policy: parsed branch-protection-policy.json (baseline + branchClasses).
  policy,
  # mainlines: the `mainlines` output of mainline-protection.nix,
  #   { <repoName> = "<mainline branch class key>"; }.
  mainlines,
  # repositories: the inventory `repositories` list (each { name; defaultBranch;
  #   archived ? false; ... }). Used to verify `forkRepos` and `mainlines`.
  repositories,
  # forkRepos: product-adapted forks, { <repoName> = "<productBranch>"; }. The
  #   product branch must be the repository's inventory `defaultBranch`.
  forkRepos ? { },
  # forkClass: the policy branch class whose `forbiddenBranches` applies to
  #   `forkRepos`.
  forkClass ? "product-fork",
  # excludeRepos: the caller's mainline-protection `excludeRepos`. Those
  #   repositories were deliberately left out of policy coverage, so naming one
  #   in `forkRepos` is a contradiction and is rejected.
  excludeRepos ? [ ],
  # name: the ruleset name (also part of the engine's resource key).
  name ? "forbidden-branches",
  # enforcement: "active" | "evaluate" | "disabled". Anything but "active"
  #   requires `enforcementException`.
  enforcement ? "active",
  # enforcementException: the documented reason for a non-"active" enforcement.
  enforcementException ? null,
  # bypassActors: the ruleset bypass list (engine schema). The policy forbids
  #   bypass, so a non-empty list requires `bypassException`.
  bypassActors ? [ ],
  # bypassException: the documented reason for a non-empty `bypassActors`.
  bypassException ? null,
}:
let
  inherit (builtins)
    all
    any
    attrNames
    concatStringsSep
    elem
    filter
    hasAttr
    isList
    isString
    listToAttrs
    stringLength
    ;

  branchClasses = policy.branchClasses;
  classNames = attrNames branchClasses;

  # fnmatch-style match of a branch name against a pattern: `**` any run,
  # `*` any run without `/`, `?` one character but `/`; everything else literal.
  globMatches =
    pattern: branch:
    pattern == branch
    ||
      builtins.match (builtins.replaceStrings
        [
          "\\"
          "."
          "+"
          "("
          ")"
          "|"
          "^"
          "$"
          "{"
          "}"
          "["
          "]"
          "**"
          "*"
          "?"
        ]
        [
          "\\\\"
          "\\."
          "\\+"
          "\\("
          "\\)"
          "\\|"
          "\\^"
          "\\$"
          "\\{"
          "\\}"
          "\\["
          "\\]"
          ".*"
          "[^/]*"
          "[^/]"
        ]
        pattern
      ) branch != null;
  # Two patterns overlap when either matches the other taken literally.
  overlaps = a: b: globMatches a b || globMatches b a;

  mainlineKeys = filter (k: (branchClasses.${k}.role or "") == "mainline") classNames;

  # The class's forbidden list, validated; [ ] when absent.
  forbiddenOf =
    cls:
    let
      fb = branchClasses.${cls}.forbiddenBranches or [ ];
    in
    assert
      (isList fb && all (e: isString e && e != "") fb)
      || throw "forbidden-branches: policy class `${cls}` forbiddenBranches ${builtins.toJSON fb} is not a list of non-empty branch names/patterns";
    fb;

  forbiddingClasses = filter (c: forbiddenOf c != [ ]) classNames;

  # The branch patterns a class stands for: its key and, when present, its
  # `pattern` (e.g. `agents-to-dev` covers `agents-to-dev-*`).
  classBranches =
    c: [ c ] ++ (if branchClasses.${c} ? pattern then [ branchClasses.${c}.pattern ] else [ ]);

  # Class-level validation, independent of which repositories are in scope, so
  # a bad policy fails even before any repository carries the class.
  checkClass =
    cls:
    let
      repoClass = branchClasses.${cls}.repoClass or null;
      sameRepoClass = filter (
        c: repoClass != null && (branchClasses.${c}.repoClass or null) == repoClass
      ) classNames;
      check =
        entry:
        let
          hitMainline = filter (k: overlaps entry k) mainlineKeys;
          hitSame = filter (c: any (b: overlaps entry b) (classBranches c)) sameRepoClass;
        in
        assert
          hitMainline == [ ]
          || throw "forbidden-branches: policy class `${cls}` forbids `${entry}`, which is a policy mainline (${concatStringsSep ", " hitMainline}); forbidding it would block a mainline";
        assert
          hitSame == [ ]
          || throw "forbidden-branches: policy class `${cls}` forbids `${entry}`, which matches branch class ${
            concatStringsSep ", " (map (c: "`${c}`") hitSame)
          } of the same repoClass `${toString repoClass}`; it would block that class's own branch";
        true;
    in
    all check (forbiddenOf cls);

  repoByName = listToAttrs (
    map (r: {
      name = r.name;
      value = r;
    }) repositories
  );

  # --- derived (mainline) repositories -------------------------------------
  unknownMainlineRepos = filter (n: !(hasAttr n repoByName)) (attrNames mainlines);
  badMainlineClasses = filter (n: !(hasAttr mainlines.${n} branchClasses)) (attrNames mainlines);

  derivedEntries = map (repo: {
    inherit repo;
    class = mainlines.${repo};
    branch = mainlines.${repo};
    source = "mainline";
  }) (filter (repo: forbiddenOf mainlines.${repo} != [ ]) (attrNames mainlines));

  # --- product-adapted forks ------------------------------------------------
  forkReason =
    repo:
    let
      productBranch = forkRepos.${repo};
      r = repoByName.${repo};
    in
    if !(hasAttr repo repoByName) then
      "is not in the inventory"
    else if r.archived or false then
      "is archived"
    else if elem repo excludeRepos then
      "is in excludeRepos (deliberately left out of policy coverage)"
    else if hasAttr repo mainlines then
      "is already derived through mainlines (mainline `${mainlines.${repo}}`); a repository on a policy mainline is not a product-adapted fork"
    else if elem productBranch mainlineKeys then
      "names `${productBranch}`, a policy mainline, as its product branch"
    else if (r.defaultBranch or null) != productBranch then
      "names product branch `${productBranch}`, but its default branch is `${
        toString (r.defaultBranch or null)
      }`"
    else
      null;
  badForks = filter (repo: forkReason repo != null) (attrNames forkRepos);

  forkEntries =
    if forbiddenOf forkClass == [ ] then
      [ ]
    else
      map (repo: {
        inherit repo;
        class = forkClass;
        branch = forkRepos.${repo};
        source = "fork";
      }) (attrNames forkRepos);

  # --- rendering --------------------------------------------------------------
  entries = derivedEntries ++ forkEntries;

  # Per-repository validation: no forbidden entry may match the repository's
  # own mainline (a fork's product branch).
  checkEntry =
    e:
    let
      hit = filter (f: overlaps f e.branch) (forbiddenOf e.class);
    in
    assert
      hit == [ ]
      || throw "forbidden-branches: policy class `${e.class}` forbids ${
        concatStringsSep ", " (map (f: "`${f}`") hit)
      }, which is the mainline of ${e.repo} (`${e.branch}`)";
    true;

  mkRuleset = e: {
    repository = e.repo;
    inherit name enforcement bypassActors;
    target = "branch";
    conditions = {
      refNameInclude = map (b: "refs/heads/${b}") (forbiddenOf e.class);
      refNameExclude = [ ];
    };
    # Deliberately NO `deletion`: a stray forbidden branch must stay removable.
    rules = {
      creation = true;
      update = true;
      nonFastForward = true;
    };
  };

  # The policy's `noBypass` rule: an exception must say why.
  documented = reason: isString reason && stringLength reason >= 20;
in
assert
  unknownMainlineRepos == [ ]
  || throw "forbidden-branches: mainlines names repositories not in the inventory: ${concatStringsSep ", " unknownMainlineRepos}";
assert
  badMainlineClasses == [ ]
  || throw "forbidden-branches: mainlines maps ${
    concatStringsSep ", " (map (n: "${n} -> `${mainlines.${n}}`") badMainlineClasses)
  }, which is not a policy branch class";
assert
  forkRepos == { }
  || hasAttr forkClass branchClasses
  || throw "forbidden-branches: forkRepos is non-empty but the policy has no `${forkClass}` branch class";
assert
  badForks == [ ]
  || throw "forbidden-branches: bad forkRepos entries: ${
    concatStringsSep "; " (map (repo: "${repo} ${forkReason repo}") badForks)
  }";
assert all checkClass forbiddingClasses;
assert all checkEntry entries;
assert
  bypassActors == [ ]
  || documented bypassException
  || throw "forbidden-branches: bypassActors ${builtins.toJSON bypassActors} without a documented `bypassException` — the branch-protection policy forbids bypass (agents act under their operator's identity)";
assert
  enforcement == "active"
  || documented enforcementException
  || throw "forbidden-branches: enforcement `${enforcement}` without a documented `enforcementException` — the branch-protection policy requires `active`";
{
  # Entries in the engine's `repositoryRulesets` schema. Append them to
  # `governance.repositoryRulesets`.
  rulesets = map mkRuleset entries;

  # The repositories that get a ruleset, sorted.
  coveredRepos = builtins.sort builtins.lessThan (map (e: e.repo) entries);

  # Per covered repository: the policy class, its mainline / product branch,
  # whether it was derived (`mainline`) or listed (`fork`), and the forbidden
  # patterns. For the caller's coverage checks.
  byRepo = listToAttrs (
    map (e: {
      name = e.repo;
      value = {
        inherit (e) class branch source;
        forbidden = forbiddenOf e.class;
      };
    }) entries
  );

  # The policy classes that forbid anything, with their lists.
  forbiddenByClass = listToAttrs (
    map (c: {
      name = c;
      value = forbiddenOf c;
    }) forbiddingClasses
  );
}
