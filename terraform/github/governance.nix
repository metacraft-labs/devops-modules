# Company-agnostic GitHub governance engine.
#
# Maps a declarative governance model (repositories, teams, memberships, branch
# protection, Actions variables, issue labels) plus a secret manifest and the
# GitHub-encrypted payloads rendered by `github-governance-secrets-render` into
# `github_*` Terraform resources, and exposes the same rich `output` block the
# bootstrap helper reads. Nothing company-specific is hardcoded: the consumer
# supplies its own `governance` / `manifest` data and the resolved managed and
# payload documents. See `terraform/github/README.md` for the thin-caller shape.
{
  awsAccountId,
  awsRegion,
  githubOwner,
  githubAccessCheckRepository ? "${githubOwner}/infra",
  githubBootstrapStateKey,
  governance,
  manifest,
  managedDoc ? {
    version = 1;
    providerIds = [ ];
  },
  payloadDoc ? {
    version = 1;
    payloads = { };
  },
}:
let
  inherit (builtins)
    attrNames
    concatMap
    concatStringsSep
    elem
    filter
    foldl'
    hasAttr
    head
    length
    listToAttrs
    map
    replaceStrings
    sort
    throw
    ;

  optionalAttrs = cond: attrs: if cond then attrs else { };
  optionalField = attrs: name: if hasAttr name attrs then { ${name} = attrs.${name}; } else { };
  resourceKey = value: "secret_${replaceStrings [ "/" ":" "." ] [ "_" "_" "_" ] value}";
  governanceResourceKey =
    value:
    replaceStrings
      [
        "/"
        ":"
        "."
        "-"
        " "
        "|"
        "("
        ")"
        ","
      ]
      [
        "_"
        "_"
        "_"
        "_"
        "_"
        "_"
        "_"
        "_"
        "_"
      ]
      value;
  repositoryResourceName = repository: governanceResourceKey "repo:${repository}";
  teamDataName = teamSlug: governanceResourceKey "team:${teamSlug}";
  terraformRef = ref: "\${${ref}}";
  listToResourceAttrs =
    values: keyFn: valueFn:
    listToAttrs (
      map (value: {
        name = governanceResourceKey (keyFn value);
        value = valueFn value;
      }) values
    );

  requestedPayloads = payloadDoc.payloads or { };

  eligibleSecrets = filter (secret: secret.manageWithTerraform or false) manifest.secrets;
  manifestProviderIds = map (secret: secret.providerId) eligibleSecrets;
  managedProviderIds = managedDoc.providerIds or [ ];
  unknownManagedIds = filter (providerId: !(elem providerId manifestProviderIds)) managedProviderIds;
  unknownPayloadIds = filter (providerId: !(elem providerId manifestProviderIds)) (
    attrNames requestedPayloads
  );
  missingPayloadIds = filter (providerId: !(hasAttr providerId requestedPayloads)) managedProviderIds;
  manifestOrganizationSecrets = filter (secret: secret.scope == "organization") eligibleSecrets;
  manifestRepositorySecrets = filter (secret: secret.scope == "repository") eligibleSecrets;
  manifestEnvironmentSecrets = filter (secret: secret.scope == "environment") eligibleSecrets;
  managedSecrets =
    if unknownManagedIds != [ ] then
      throw "unknown managed GitHub secret ids: ${concatStringsSep ", " unknownManagedIds}"
    else
      filter (secret: elem secret.providerId managedProviderIds) eligibleSecrets;
  secretPayloads =
    if unknownPayloadIds != [ ] then
      throw "unknown GitHub secret payload ids: ${concatStringsSep ", " unknownPayloadIds}"
    else if missingPayloadIds != [ ] then
      throw "missing GitHub secret payload ids: ${concatStringsSep ", " missingPayloadIds}"
    else
      requestedPayloads;

  organizationSecrets = filter (secret: secret.scope == "organization") managedSecrets;
  repositorySecrets = filter (secret: secret.scope == "repository") managedSecrets;
  environmentSecrets = filter (secret: secret.scope == "environment") managedSecrets;

  # Resource emission is keyed on providerResource so Actions and Dependabot
  # secrets map to their own resource types (both use scope "organization" /
  # "repository"). Consumers with only github_actions_* secrets are unaffected.
  byProviderResource = res: filter (secret: (secret.providerResource or "") == res) managedSecrets;
  actionsOrganizationSecrets = byProviderResource "github_actions_organization_secret";
  actionsRepositorySecrets = byProviderResource "github_actions_secret";
  actionsEnvironmentSecrets = byProviderResource "github_actions_environment_secret";
  dependabotRepositorySecrets = byProviderResource "github_dependabot_secret";
  dependabotOrganizationSecrets = byProviderResource "github_dependabot_organization_secret";

  withPayload =
    secret: attrs:
    let
      payload = secretPayloads.${secret.providerId};
    in
    attrs
    // {
      key_id = payload.keyId;
      value_encrypted = payload.valueEncrypted;
    };

  organizationSecretResources = listToAttrs (
    map (secret: {
      name = resourceKey secret.providerId;
      value = withPayload secret (
        {
          secret_name = secret.name;
          visibility = secret.visibility;
        }
        // optionalAttrs (secret ? selectedRepositoryIds) {
          selected_repository_ids = secret.selectedRepositoryIds;
        }
      );
    }) actionsOrganizationSecrets
  );

  repositorySecretResources = listToAttrs (
    map (secret: {
      name = resourceKey secret.providerId;
      value = withPayload secret {
        repository = secret.repository;
        secret_name = secret.name;
      };
    }) actionsRepositorySecrets
  );

  environmentSecretResources = listToAttrs (
    map (secret: {
      name = resourceKey secret.providerId;
      value = withPayload secret {
        repository = secret.repository;
        environment = secret.environment;
        secret_name = secret.name;
      };
    }) actionsEnvironmentSecrets
  );

  dependabotRepositorySecretResources = listToAttrs (
    map (secret: {
      name = resourceKey secret.providerId;
      value = withPayload secret {
        repository = secret.repository;
        secret_name = secret.name;
      };
    }) dependabotRepositorySecrets
  );

  dependabotOrganizationSecretResources = listToAttrs (
    map (secret: {
      name = resourceKey secret.providerId;
      value = withPayload secret (
        {
          secret_name = secret.name;
          visibility = secret.visibility;
        }
        // optionalAttrs (secret ? selectedRepositoryIds) {
          selected_repository_ids = secret.selectedRepositoryIds;
        }
      );
    }) dependabotOrganizationSecrets
  );

  sortedRepoNames = sort (a: b: a < b) (map (repo: repo.name) governance.repositories);

  # `security_and_analysis` carries exactly the two sub-blocks that provider
  # 6.12.1 both writes and reads back, and that GitHub still returns under the
  # same names: secret_scanning and secret_scanning_push_protection.
  #
  # Everything else in the provider's schema is deliberately not expressible
  # here, because declaring it produces a permanent, unappliable diff:
  #
  #   * `advanced_security` — GitHub renamed it to `code_security` in the API
  #     response. The provider still SENDS advanced_security and still READS
  #     advanced_security, so the read path can never populate what the
  #     configuration declares. It is also the paid Code Security product on
  #     private repositories, which is a second reason not to hand consumers a
  #     knob for it here.
  #   * `code_security`, `secret_scanning_ai_detection`,
  #     `secret_scanning_non_provider_patterns` — schema-only in the provider:
  #     `calculateSecurityAndAnalysis` never sends them and
  #     `flattenSecurityAndAnalysis` never reads them.
  #
  # Whether a repository SHOULD carry the block at all is the consumer's
  # decision, recorded in its inventory. Omitting it leaves the attribute
  # Computed, which is the correct state for a repository whose security
  # settings are not governed here (e.g. private repositories on a plan that
  # does not include Secret Protection).
  securityAndAnalysisStatuses = [
    "enabled"
    "disabled"
  ];
  securityAndAnalysisFields = [
    "secretScanning"
    "secretScanningPushProtection"
  ];
  securityAndAnalysisBlock =
    repo:
    let
      sa = repo.securityAndAnalysis;
      unsupported = filter (field: !(elem field securityAndAnalysisFields)) (attrNames sa);
      missing = filter (field: !(hasAttr field sa)) securityAndAnalysisFields;
      badStatuses = filter (field: !(elem sa.${field} securityAndAnalysisStatuses)) (
        filter (field: hasAttr field sa) securityAndAnalysisFields
      );
    in
    if unsupported != [ ] then
      throw (
        "unsupported securityAndAnalysis fields on ${repo.name}: "
        + "${concatStringsSep ", " unsupported} "
        + "(only ${concatStringsSep ", " securityAndAnalysisFields} round-trip through provider 6.12.1)"
      )
    else if missing != [ ] then
      throw (
        "missing securityAndAnalysis fields on ${repo.name}: ${concatStringsSep ", " missing} "
        + "(an omitted sub-block is left Computed and drifts silently, so all of them are required together)"
      )
    else if badStatuses != [ ] then
      throw (
        "securityAndAnalysis fields on ${repo.name} must be \"enabled\" or \"disabled\": "
        + concatStringsSep ", " badStatuses
      )
    else
      {
        secret_scanning = [ { status = sa.secretScanning; } ];
        secret_scanning_push_protection = [ { status = sa.secretScanningPushProtection; } ];
      };

  repositoryResources = listToResourceAttrs governance.repositories (repo: "repo:${repo.name}") (
    repo:
    {
      name = repo.name;
      visibility = repo.visibility;
      has_issues = repo.hasIssues;
      has_projects = repo.hasProjects;
      has_wiki = repo.hasWiki;
      has_discussions = repo.hasDiscussions;
      allow_forking = repo.allowForking;
      archived = repo.archived;
      is_template = repo.isTemplate;
      web_commit_signoff_required = repo.webCommitSignoffRequired;
      lifecycle = {
        ignore_changes = [
          # GitHub no longer uses this provider field, but imported state can
          # still contain the historical value.
          "has_downloads"
          # Read-only/deprecated; the API returns null, so it can't be matched.
          "ignore_vulnerability_alerts_during_read"
        ]
        ++ (
          # Archived repos freeze their settings: the API returns null for the
          # mutable options, so any managed value is a spurious, unappliable
          # diff (you can't modify an archived repo). Ignore them there.
          if (repo.archived or false) then
            [
              "allow_auto_merge"
              "allow_forking"
              "allow_merge_commit"
              "allow_rebase_merge"
              "allow_squash_merge"
              "allow_update_branch"
              "delete_branch_on_merge"
              "merge_commit_message"
              "merge_commit_title"
              "squash_merge_commit_message"
              "squash_merge_commit_title"
              "web_commit_signoff_required"
            ]
          else
            [ ]
        );
      };
    }
    // optionalField repo "description"
    // optionalField repo "topics"
    // optionalAttrs (repo ? homepageUrl) { homepage_url = repo.homepageUrl; }
    // optionalAttrs (repo ? allowAutoMerge) { allow_auto_merge = repo.allowAutoMerge; }
    // optionalAttrs (repo ? allowMergeCommit) { allow_merge_commit = repo.allowMergeCommit; }
    // optionalAttrs (repo ? allowSquashMerge) { allow_squash_merge = repo.allowSquashMerge; }
    // optionalAttrs (repo ? allowUpdateBranch) { allow_update_branch = repo.allowUpdateBranch; }
    // optionalAttrs (repo ? deleteBranchOnMerge) { delete_branch_on_merge = repo.deleteBranchOnMerge; }
    // optionalAttrs (repo ? allowRebaseMerge) { allow_rebase_merge = repo.allowRebaseMerge; }
    // optionalAttrs (repo ? mergeCommitTitle) { merge_commit_title = repo.mergeCommitTitle; }
    // optionalAttrs (repo ? mergeCommitMessage) { merge_commit_message = repo.mergeCommitMessage; }
    // optionalAttrs (repo ? squashMergeCommitTitle) {
      squash_merge_commit_title = repo.squashMergeCommitTitle;
    }
    // optionalAttrs (repo ? squashMergeCommitMessage) {
      squash_merge_commit_message = repo.squashMergeCommitMessage;
    }
    // optionalAttrs (repo ? securityAndAnalysis) {
      security_and_analysis = [ (securityAndAnalysisBlock repo) ];
    }
  );

  # Dependabot alerts and Dependabot security updates are free on every GitHub
  # plan and both visibilities, and each is its own importable resource keyed by
  # bare repository name. The deprecated `github_repository.vulnerability_alerts`
  # field is deliberately not used: it is scheduled for removal, and its read
  # path sits behind the provider's `security_and_analysis != nil` guard, so it
  # stops refreshing (silently) for any token that is less than admin on a repo.
  #
  # Model every repository, not only the enabled ones — a disabled feature
  # imports cleanly as `enabled = false`, whereas an unmodelled repository is a
  # creation waiting to happen.
  vulnerabilityAlertResources =
    listToResourceAttrs (governance.vulnerabilityAlerts or [ ])
      (row: "vulnerability-alerts:${row.repository}")
      (row: {
        repository = row.repository;
        enabled = row.enabled;
      });

  dependabotSecurityUpdateResources =
    listToResourceAttrs (governance.dependabotSecurityUpdates or [ ])
      (row: "dependabot-security-updates:${row.repository}")
      (row: {
        repository = row.repository;
        enabled = row.enabled;
      });

  countEnabled = rows: length (filter (row: row.enabled) rows);
  repositoriesWithSecurityAndAnalysis = filter (
    repo: repo ? securityAndAnalysis
  ) governance.repositories;
  countSecurityAndAnalysis =
    field:
    length (
      filter (repo: repo.securityAndAnalysis.${field} == "enabled") repositoriesWithSecurityAndAnalysis
    );

  branchDefaultResources =
    listToResourceAttrs governance.repositories (repo: "branch-default:${repo.name}")
      (repo: {
        repository = repo.name;
        branch = repo.defaultBranch;
      });

  # Teams are managed as resources when governance.teams is provided; otherwise
  # they are referenced as data sources (backward-compatible with consumers that
  # only grant to pre-existing teams).
  managedTeams = governance.teams or [ ];
  managedTeamSlugs = listToAttrs (
    map (team: {
      name = team.slug;
      value = true;
    }) managedTeams
  );
  teamKey = teamSlug: governanceResourceKey "team:${teamSlug}";
  teamRef =
    teamSlug:
    if managedTeamSlugs ? ${teamSlug} then
      terraformRef "github_team.${teamKey teamSlug}.id"
    else
      terraformRef "data.github_team.${teamDataName teamSlug}.id";

  # Org-wide team grants: "this team reaches every repository in the model".
  #
  # `governance.orgWideTeamRepositories` is a list of { teamSlug, permission }
  # rules, each expanded here over `governance.repositories` rather than
  # enumerated by the consumer. The expansion is the point: a repository added to
  # the model later inherits the grant without anyone remembering to extend the
  # rule. Enumerating instead would turn every new repo into a silent hole in an
  # access policy whose whole content is the word "all".
  #
  # Where a rule and an explicit `governance.teamRepositories` entry cover the
  # same (team, repo) pair, the STRONGER permission wins — not whichever list it
  # came from. Both directions of that matter, and picking a side breaks one of
  # them. Letting the explicit entry always win means a repo left at `push`
  # quietly defeats a rule promising `maintain` everywhere. Letting the rule
  # always win means a deliberate `admin` grant is silently downgraded the day
  # someone adds a blanket rule. Taking the max is the only reading under which
  # "the team reaches every repo at >= this level" and "a deliberate stronger
  # grant is never weakened by a blanket rule" are both true.
  permissionRank = {
    pull = 1;
    read = 1;
    triage = 2;
    push = 3;
    write = 3;
    maintain = 4;
    admin = 5;
  };
  rankOf = permission: permissionRank.${permission} or null;

  orgWideTeamRepositories = governance.orgWideTeamRepositories or [ ];

  # A rule's own permission must be rankable. A custom repository role cannot be
  # compared against the built-in ladder, so a rule naming one could be honoured
  # on repos with no explicit grant and silently skipped on repos that have one —
  # a rule that is true in some places and not others is worse than no rule.
  unrankableRules = filter (rule: rankOf rule.permission == null) orgWideTeamRepositories;
  duplicateRuleSlugs =
    filter (slug: length (filter (rule: rule.teamSlug == slug) orgWideTeamRepositories) > 1)
      (
        attrNames (
          listToAttrs (
            map (rule: {
              name = rule.teamSlug;
              value = true;
            }) orgWideTeamRepositories
          )
        )
      );

  checkedOrgWideRules =
    if unrankableRules != [ ] then
      throw (
        "orgWideTeamRepositories: permission must be one of "
        + concatStringsSep ", " (sort (a: b: a < b) (attrNames permissionRank))
        + "; got "
        + concatStringsSep ", " (map (rule: "${rule.teamSlug}=${rule.permission}") unrankableRules)
      )
    else if duplicateRuleSlugs != [ ] then
      throw (
        "orgWideTeamRepositories: more than one rule for team(s) "
        + concatStringsSep ", " duplicateRuleSlugs
      )
    else
      orgWideTeamRepositories;

  orgWideRulePermission =
    teamSlug:
    let
      matches = filter (rule: rule.teamSlug == teamSlug) checkedOrgWideRules;
    in
    if matches == [ ] then null else (head matches).permission;

  # Repository names and team slugs cannot contain ":", so this key is unambiguous.
  teamGrantKey = teamSlug: repository: "${teamSlug}:${repository}";
  explicitTeamGrants = listToAttrs (
    map (grant: {
      name = teamGrantKey grant.teamSlug grant.repository;
      value = true;
    }) governance.teamRepositories
  );

  # Explicit grants, raised to the rule level where the rule is stronger. An
  # unrankable EXPLICIT permission (a custom role) is left exactly as written:
  # the engine cannot know whether a custom role outranks `maintain`, and
  # guessing could either strip privileges or invent them.
  resolvedExplicitGrants = map (
    grant:
    let
      rulePermission = orgWideRulePermission grant.teamSlug;
      explicitRank = rankOf grant.permission;
    in
    if rulePermission == null || explicitRank == null then
      grant
    else if explicitRank >= rankOf rulePermission then
      grant
    else
      grant // { permission = rulePermission; }
  ) governance.teamRepositories;

  # Every repo a rule covers that has no explicit grant for that team.
  orgWideOnlyGrants = concatMap (
    rule:
    map
      (repo: {
        inherit (rule) teamSlug permission;
        repository = repo.name;
      })
      (
        filter (
          repo: !(explicitTeamGrants ? ${teamGrantKey rule.teamSlug repo.name})
        ) governance.repositories
      )
  ) checkedOrgWideRules;

  effectiveTeamRepositories = resolvedExplicitGrants ++ orgWideOnlyGrants;

  teamResources = listToAttrs (
    map (team: {
      name = teamKey team.slug;
      value = {
        name = team.name;
        privacy = team.privacy;
      }
      // optionalField team "description"
      // optionalAttrs (team ? notificationSetting) { notification_setting = team.notificationSetting; }
      // optionalAttrs (team ? parentTeamSlug) { parent_team_id = teamRef team.parentTeamSlug; };
    }) managedTeams
  );

  teamMembershipResources =
    listToResourceAttrs (governance.teamMemberships or [ ])
      (m: "team-membership:${m.teamSlug}:${m.username}")
      (m: {
        team_id = teamRef m.teamSlug;
        username = m.username;
        role = m.role;
      });

  runnerGroupResources =
    listToResourceAttrs (governance.runnerGroups or [ ]) (rg: "runner-group:${rg.name}")
      (
        rg:
        {
          name = rg.name;
          visibility = rg.visibility;
        }
        // optionalAttrs (rg ? selectedRepositoryIds) {
          selected_repository_ids = rg.selectedRepositoryIds;
        }
        // optionalAttrs (rg ? allowsPublicRepositories) {
          allows_public_repositories = rg.allowsPublicRepositories;
        }
        // optionalAttrs (rg ? restrictedToWorkflows) {
          restricted_to_workflows = rg.restrictedToWorkflows;
        }
        # `selected_workflows` is the ONLY admission control GitHub offers that
        # is not label-based, and without it `restrictedToWorkflows = true` is
        # not merely incomplete — it is an OUTAGE: GitHub reads a true
        # restriction with an empty list as "admit nothing", so the group's
        # runners become unusable by every workflow in the org. Emitting one
        # without the other was therefore never a safe state to leave expressible.
        #
        # Format, per GitHub: `OWNER/REPO/.github/workflows/FILE@REF`, with the
        # ref fully qualified (`refs/heads/…`, `refs/tags/…`, or a 40-hex SHA).
        # NO WILDCARDS — a tag-glob release trigger cannot be expressed. And
        # "only jobs DIRECTLY DEFINED within the selected workflows will have
        # access", so for a caller -> reusable-workflow pair it is the CALLED
        # file, where the job carrying `runs-on` lives, that must be listed.
        // optionalAttrs (rg ? selectedWorkflows) {
          selected_workflows = rg.selectedWorkflows;
        }
      );

  customRoleResources =
    listToResourceAttrs (governance.customRepositoryRoles or [ ]) (role: "custom-role:${role.name}")
      (
        role:
        {
          name = role.name;
          base_role = role.baseRole;
          permissions = role.permissions;
        }
        // optionalField role "description"
      );

  # Referenced team slugs that are not managed still need a data source.
  referencedTeamSlugs = attrNames (
    listToAttrs (
      map
        (slug: {
          name = slug;
          value = true;
        })
        (
          (map (grant: grant.teamSlug) effectiveTeamRepositories)
          ++ (map (m: m.teamSlug) (governance.teamMemberships or [ ]))
        )
    )
  );
  teamDataSources = listToAttrs (
    map (teamSlug: {
      name = teamDataName teamSlug;
      value = {
        slug = teamSlug;
      };
    }) (filter (slug: !(managedTeamSlugs ? ${slug})) referencedTeamSlugs)
  );

  membershipResources =
    listToResourceAttrs governance.memberships (member: "member:${member.username}")
      (member: {
        username = member.username;
        role = member.role;
      });

  repositoryCollaboratorResources =
    listToResourceAttrs governance.outsideCollaborators
      (collaborator: "repo-collaborator:${collaborator.repository}:${collaborator.username}")
      (collaborator: {
        repository = collaborator.repository;
        username = collaborator.username;
        permission = collaborator.permission;
      });

  teamRepositoryResources =
    listToResourceAttrs effectiveTeamRepositories
      (grant: "team-repository:${grant.teamSlug}:${grant.repository}")
      (grant: {
        team_id = teamRef grant.teamSlug;
        repository = grant.repository;
        permission = grant.permission;
      });

  branchProtectionResources =
    listToResourceAttrs governance.branchProtections
      (branch: "branch-protection:${branch.repository}:${branch.pattern}")
      (
        branch:
        {
          repository_id = terraformRef "github_repository.${repositoryResourceName branch.repository}.node_id";
          pattern = branch.pattern;
          enforce_admins = branch.enforceAdmins;
          allows_deletions = branch.allowsDeletions;
          allows_force_pushes = branch.allowsForcePushes;
          required_linear_history = branch.requiredLinearHistory;
          require_conversation_resolution = branch.requireConversationResolution;
          require_signed_commits = branch.requireSignedCommits;
          lock_branch = branch.lockBranch;
        }
        // optionalAttrs (branch ? requiredStatusChecks) {
          required_status_checks = [
            {
              strict = branch.requiredStatusChecks.strict;
              contexts = branch.requiredStatusChecks.contexts;
            }
          ];
        }
        // optionalAttrs (branch ? requiredPullRequestReviews) {
          required_pull_request_reviews = [
            (
              {
                dismiss_stale_reviews = branch.requiredPullRequestReviews.dismissStaleReviews;
                require_code_owner_reviews = branch.requiredPullRequestReviews.requireCodeOwnerReviews;
                require_last_push_approval = branch.requiredPullRequestReviews.requireLastPushApproval;
                required_approving_review_count = branch.requiredPullRequestReviews.requiredApprovingReviewCount;
              }
              // optionalAttrs (branch.requiredPullRequestReviews ? pullRequestBypassers) {
                pull_request_bypassers = branch.requiredPullRequestReviews.pullRequestBypassers;
              }
            )
          ];
        }
      );

  repositoryEnvironmentResources =
    listToResourceAttrs governance.repositoryEnvironments
      (environment: "environment:${environment.repository}:${environment.environment}")
      (
        environment:
        {
          repository = environment.repository;
          environment = environment.environment;
          can_admins_bypass = environment.canAdminsBypass;
          wait_timer = environment.waitTimer;
        }
        // optionalAttrs (environment ? deploymentBranchPolicy) {
          deployment_branch_policy = [
            {
              protected_branches = environment.deploymentBranchPolicy.protectedBranches;
              custom_branch_policies = environment.deploymentBranchPolicy.customBranchPolicies;
            }
          ];
        }
      );

  actionsRepositoryPermissionResources =
    listToResourceAttrs governance.actionsRepositoryPermissions
      (permissions: "actions-repository-permissions:${permissions.repository}")
      (
        permissions:
        {
          repository = permissions.repository;
          enabled = permissions.enabled;
          sha_pinning_required = permissions.shaPinningRequired;
        }
        // optionalAttrs (permissions ? allowedActions) {
          allowed_actions = permissions.allowedActions;
        }
      );

  actionsVariableResources =
    listToResourceAttrs governance.actionsVariables
      (variable: "actions-variable:${variable.repository}:${variable.name}")
      (variable: {
        repository = variable.repository;
        variable_name = variable.name;
        value = variable.value;
      });

  issueLabelResources =
    listToResourceAttrs governance.issueLabels (label: "label:${label.repository}:${label.name}")
      (
        label:
        {
          repository = label.repository;
          name = label.name;
          color = label.color;
        }
        // optionalField label "description"
      );

  # --- rulesets (repository + organization) ---
  rulesetRules =
    rules:
    optionalAttrs (rules ? creation) { creation = rules.creation; }
    // optionalAttrs (rules ? deletion) { deletion = rules.deletion; }
    // optionalAttrs (rules ? update) { update = rules.update; }
    // optionalAttrs (rules ? nonFastForward) { non_fast_forward = rules.nonFastForward; }
    // optionalAttrs (rules ? requiredLinearHistory) {
      required_linear_history = rules.requiredLinearHistory;
    }
    // optionalAttrs (rules ? requiredSignatures) { required_signatures = rules.requiredSignatures; }
    // optionalAttrs (rules ? pullRequest) {
      pull_request = [
        {
          required_approving_review_count = rules.pullRequest.requiredApprovingReviewCount;
          dismiss_stale_reviews_on_push = rules.pullRequest.dismissStaleReviewsOnPush;
          require_code_owner_review = rules.pullRequest.requireCodeOwnerReview;
          require_last_push_approval = rules.pullRequest.requireLastPushApproval;
          required_review_thread_resolution = rules.pullRequest.requiredReviewThreadResolution;
        }
      ];
    };

  rulesetConditions = cond: [
    (
      {
        ref_name = [
          {
            include = cond.refNameInclude;
            exclude = cond.refNameExclude;
          }
        ];
      }
      // optionalAttrs (cond ? repositoryNameInclude) {
        repository_name = [
          {
            include = cond.repositoryNameInclude;
            exclude = cond.repositoryNameExclude;
          }
        ];
      }
    )
  ];

  rulesetBypassActors =
    actors:
    map (a: {
      actor_id = a.actorId;
      actor_type = a.actorType;
      bypass_mode = a.bypassMode;
    }) actors;

  repositoryRulesetResources =
    listToResourceAttrs (governance.repositoryRulesets or [ ])
      (rs: "repository-ruleset:${rs.repository}:${rs.name}")
      (
        rs:
        {
          repository = rs.repository;
          name = rs.name;
          target = rs.target;
          enforcement = rs.enforcement;
          conditions = rulesetConditions rs.conditions;
          rules = [ (rulesetRules rs.rules) ];
        }
        // optionalAttrs ((rs.bypassActors or [ ]) != [ ]) {
          bypass_actors = rulesetBypassActors rs.bypassActors;
        }
      );

  organizationRulesetResources =
    listToResourceAttrs (governance.organizationRulesets or [ ]) (rs: "organization-ruleset:${rs.name}")
      (
        rs:
        {
          name = rs.name;
          target = rs.target;
          enforcement = rs.enforcement;
          conditions = rulesetConditions rs.conditions;
          rules = [ (rulesetRules rs.rules) ];
        }
        // optionalAttrs ((rs.bypassActors or [ ]) != [ ]) {
          bypass_actors = rulesetBypassActors rs.bypassActors;
        }
      );

  organizationResources = {
    github_actions_organization_permissions.default = {
      enabled_repositories = governance.organization.actionsPermissions.enabledRepositories;
      allowed_actions = governance.organization.actionsPermissions.allowedActions;
      sha_pinning_required = governance.organization.actionsPermissions.shaPinningRequired;
    };
  };

  governanceResources =
    organizationResources
    // optionalAttrs (membershipResources != { }) { github_membership = membershipResources; }
    // optionalAttrs (repositoryResources != { }) { github_repository = repositoryResources; }
    // optionalAttrs (branchDefaultResources != { }) { github_branch_default = branchDefaultResources; }
    // optionalAttrs (repositoryCollaboratorResources != { }) {
      github_repository_collaborator = repositoryCollaboratorResources;
    }
    // optionalAttrs (vulnerabilityAlertResources != { }) {
      github_repository_vulnerability_alerts = vulnerabilityAlertResources;
    }
    // optionalAttrs (dependabotSecurityUpdateResources != { }) {
      github_repository_dependabot_security_updates = dependabotSecurityUpdateResources;
    }
    // optionalAttrs (teamResources != { }) { github_team = teamResources; }
    // optionalAttrs (teamMembershipResources != { }) {
      github_team_membership = teamMembershipResources;
    }
    // optionalAttrs (teamRepositoryResources != { }) {
      github_team_repository = teamRepositoryResources;
    }
    // optionalAttrs (runnerGroupResources != { }) {
      github_actions_runner_group = runnerGroupResources;
    }
    // optionalAttrs (customRoleResources != { }) {
      github_organization_custom_role = customRoleResources;
    }
    // optionalAttrs (branchProtectionResources != { }) {
      github_branch_protection = branchProtectionResources;
    }
    // optionalAttrs (repositoryEnvironmentResources != { }) {
      github_repository_environment = repositoryEnvironmentResources;
    }
    // optionalAttrs (actionsRepositoryPermissionResources != { }) {
      github_actions_repository_permissions = actionsRepositoryPermissionResources;
    }
    // optionalAttrs (actionsVariableResources != { }) {
      github_actions_variable = actionsVariableResources;
    }
    // optionalAttrs (issueLabelResources != { }) { github_issue_label = issueLabelResources; }
    // optionalAttrs (repositoryRulesetResources != { }) {
      github_repository_ruleset = repositoryRulesetResources;
    }
    // optionalAttrs (organizationRulesetResources != { }) {
      github_organization_ruleset = organizationRulesetResources;
    };

  countAttrs = attrs: length (attrNames attrs);
  countTopics = foldl' (sum: repo: sum + length (repo.topics or [ ])) 0 governance.repositories;

  resources =
    governanceResources
    // optionalAttrs (organizationSecretResources != { }) {
      github_actions_organization_secret = organizationSecretResources;
    }
    // optionalAttrs (repositorySecretResources != { }) {
      github_actions_secret = repositorySecretResources;
    }
    // optionalAttrs (environmentSecretResources != { }) {
      github_actions_environment_secret = environmentSecretResources;
    }
    // optionalAttrs (dependabotRepositorySecretResources != { }) {
      github_dependabot_secret = dependabotRepositorySecretResources;
    }
    // optionalAttrs (dependabotOrganizationSecretResources != { }) {
      github_dependabot_organization_secret = dependabotOrganizationSecretResources;
    };
in
{
  terraform = {
    required_version = ">= 1.8.0";
    backend.s3 = { };
    required_providers.github = {
      source = "integrations/github";
      version = "~> 6.0";
    };
  };

  provider.github = {
    owner = githubOwner;
  };

  resource = resources;

  output = {
    expected_aws_account_id = {
      value = awsAccountId;
      description = "Expected AWS account ID for the S3 backend used by this bootstrap layer.";
    };

    aws_region = {
      value = awsRegion;
      description = "AWS region for the S3 backend used by this bootstrap layer.";
    };

    github_owner = {
      value = githubOwner;
      description = "GitHub organization governed by this bootstrap layer.";
    };

    github_access_check_repository = {
      value = githubAccessCheckRepository;
      description = "Repository used by the bootstrap helper to validate GitHub token access.";
    };

    github_bootstrap_state_key = {
      value = githubBootstrapStateKey;
      description = "S3 key for the manually applied GitHub governance Terraform state file.";
    };

    governance_inventory_source = {
      value = governance.snapshot.source;
      description = "Reviewed inventory snapshot used to seed the non-secret GitHub governance model.";
    };

    github_governance_repository_count = {
      value = length governance.repositories;
      description = "GitHub repositories emitted by the governance model.";
    };

    github_governance_repository_names = {
      value = sortedRepoNames;
      description = "GitHub repositories emitted by the governance model.";
    };

    github_governance_membership_count = {
      value = countAttrs membershipResources;
      description = "Organization membership resources emitted by the governance model.";
    };

    github_governance_branch_default_count = {
      value = countAttrs branchDefaultResources;
      description = "Default branch resources emitted by the governance model.";
    };

    github_governance_outside_collaborator_count = {
      value = countAttrs repositoryCollaboratorResources;
      description = ''
        Direct repository collaborator grants emitted by the governance model.
        These are grants held on the repository itself, from
        `collaborators?affiliation=direct`. Team-derived access (`affiliation=all`)
        is NOT a collaborator grant and must never be recorded as one: it would
        survive removal from the team and defeat team-based revocation.
      '';
    };

    github_governance_vulnerability_alerts_count = {
      value = countAttrs vulnerabilityAlertResources;
      description = "Repositories whose Dependabot alerts state is governed by this model.";
    };

    github_governance_vulnerability_alerts_enabled_count = {
      value = countEnabled (governance.vulnerabilityAlerts or [ ]);
      description = "Governed repositories with Dependabot alerts enabled.";
    };

    github_governance_dependabot_security_updates_count = {
      value = countAttrs dependabotSecurityUpdateResources;
      description = "Repositories whose Dependabot security updates state is governed by this model.";
    };

    github_governance_dependabot_security_updates_enabled_count = {
      value = countEnabled (governance.dependabotSecurityUpdates or [ ]);
      description = "Governed repositories with Dependabot security updates enabled.";
    };

    github_governance_security_and_analysis_count = {
      value = length repositoriesWithSecurityAndAnalysis;
      description = "Repositories carrying a governed security_and_analysis block.";
    };

    github_governance_secret_scanning_enabled_count = {
      value = countSecurityAndAnalysis "secretScanning";
      description = "Governed repositories with secret scanning enabled.";
    };

    github_governance_secret_scanning_push_protection_enabled_count = {
      value = countSecurityAndAnalysis "secretScanningPushProtection";
      description = "Governed repositories with secret scanning push protection enabled.";
    };

    github_governance_team_repository_count = {
      value = countAttrs teamRepositoryResources;
      description = "Team repository grant resources emitted by the governance model.";
    };

    github_governance_branch_protection_count = {
      value = countAttrs branchProtectionResources;
      description = "Branch protection resources emitted by the governance model.";
    };

    github_governance_environment_count = {
      value = countAttrs repositoryEnvironmentResources;
      description = "Repository Environment resources emitted by the governance model.";
    };

    github_governance_actions_repository_permissions_count = {
      value = countAttrs actionsRepositoryPermissionResources;
      description = "Repository Actions permission resources emitted by the governance model.";
    };

    github_governance_actions_variable_count = {
      value = countAttrs actionsVariableResources;
      description = "Repository Actions variable resources emitted by the governance model.";
    };

    github_governance_issue_label_count = {
      value = countAttrs issueLabelResources;
      description = "Issue label resources emitted by the governance model.";
    };

    github_governance_repository_topic_count = {
      value = countTopics;
      description = "Repository topics modeled through github_repository.topics.";
    };

    github_governance_deferred_resource_count = {
      value = length governance.deferredResources;
      description = "Inventory rows intentionally not emitted by this root yet.";
    };

    github_governance_deferred_resource_names = {
      value = map (resource: "${resource.type}:${resource.name}") governance.deferredResources;
      description = "Deferred inventory rows that need explicit follow-up before Terraform management.";
    };

    secret_manifest_count = {
      value = length eligibleSecrets;
      description = "Total GitHub Actions secrets declared in the governance manifest.";
    };

    secret_manifest_organization_secret_count = {
      value = length manifestOrganizationSecrets;
      description = "Organization-scoped GitHub Actions secrets declared in the governance manifest.";
    };

    secret_manifest_repository_secret_count = {
      value = length manifestRepositorySecrets;
      description = "Repository-scoped GitHub Actions secrets declared in the governance manifest.";
    };

    secret_manifest_environment_secret_count = {
      value = length manifestEnvironmentSecrets;
      description = "Environment-scoped GitHub Actions secrets declared in the governance manifest.";
    };

    secret_manifest_ids = {
      value = manifestProviderIds;
      description = "Provider ids for every GitHub Actions secret declared in the manifest.";
    };

    github_secret_managed_candidate_count = {
      value = length managedProviderIds;
      description = "GitHub Actions secret provider ids requested for Terraform management.";
    };

    github_secret_managed_candidate_ids = {
      value = managedProviderIds;
      description = "Provider ids requested for Terraform-managed GitHub Actions secret resources.";
    };

    github_secret_payload_count = {
      value = length (attrNames secretPayloads);
      description = "GitHub-encrypted secret payloads currently available to Terraform.";
    };

    github_secret_payload_ids = {
      value = attrNames secretPayloads;
      description = "Provider ids that currently have GitHub-encrypted payloads.";
    };

    github_secret_managed_count = {
      value = length managedSecrets;
      description = "GitHub Actions secret resources emitted by Terraform from the governance manifest.";
    };

    github_secret_managed_ids = {
      value = map (secret: secret.providerId) managedSecrets;
      description = "Provider ids emitted as GitHub Actions secret resources.";
    };

    github_organization_secret_count = {
      value = length organizationSecrets;
      description = "Organization GitHub Actions secret resources emitted by Terraform.";
    };

    github_repository_secret_count = {
      value = length repositorySecrets;
      description = "Repository GitHub Actions secret resources emitted by Terraform.";
    };

    github_environment_secret_count = {
      value = length environmentSecrets;
      description = "Environment GitHub Actions secret resources emitted by Terraform.";
    };
  };
}
# Only emit the `data` block when there are team data sources; an empty
# `data = { }` is invalid Terraform JSON (relevant to a pre-inventory skeleton).
// optionalAttrs (teamDataSources != { }) {
  data.github_team = teamDataSources;
}
