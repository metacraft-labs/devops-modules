# Fixture for tests/test-repository-seed.sh: an org with one existing
# repository (`infra`) and, when `withNewRepository`, one repository created by
# Terraform alone (`new-tool`, mainline `dev`, opt-in `seed`). Rendering it with
# and without the new repository is how the test proves that `infra`'s
# resources are byte-identical either way (no plan diff for existing repos).
#
# Org-agnostic placeholders only; nothing here is a real identity or secret.
{
  withNewRepository ? true,
  archived ? false,
  seed ? {
    authorName = "Example Operator";
    authorEmail = "operator@example.invalid";
  },
}:
let
  onlyIf = cond: values: if cond then values else [ ];
  repoBase = {
    hasIssues = true;
    hasProjects = false;
    hasWiki = false;
    hasDiscussions = false;
    allowForking = false;
    archived = false;
    isTemplate = false;
    webCommitSignoffRequired = false;
    visibility = "private";
  };
in
import ../../governance.nix {
  awsAccountId = "000000000000";
  awsRegion = "us-east-1";
  githubOwner = "example-org";
  githubBootstrapStateKey = "bootstrap/github/example-governance-prod.tfstate";
  governance = {
    snapshot.source = "repository-seed-fixture";
    organization.actionsPermissions = {
      enabledRepositories = "all";
      allowedActions = "selected";
      shaPinningRequired = true;
    };
    repositories = [
      (
        repoBase
        // {
          name = "infra";
          defaultBranch = "live";
          description = "Infrastructure as code.";
        }
      )
    ]
    ++ onlyIf withNewRepository [
      (
        repoBase
        // {
          name = "new-tool";
          defaultBranch = "dev";
          description = "A repository created by Terraform alone.";
          inherit archived seed;
        }
      )
    ];
    memberships = [ ];
    outsideCollaborators = [ ];
    vulnerabilityAlerts = [
      {
        repository = "infra";
        enabled = true;
      }
    ]
    ++ onlyIf withNewRepository [
      {
        repository = "new-tool";
        enabled = true;
      }
    ];
    dependabotSecurityUpdates = [ ];
    teamRepositories = [
      {
        teamSlug = "infra";
        repository = "infra";
        permission = "admin";
      }
    ]
    ++ onlyIf withNewRepository [
      {
        teamSlug = "infra";
        repository = "new-tool";
        permission = "push";
      }
    ];
    # Classic protection names its repository by node_id reference, the other
    # shape the seed ordering has to recognise.
    branchProtections = onlyIf withNewRepository [
      {
        repository = "new-tool";
        pattern = "dev";
        enforceAdmins = true;
        allowsDeletions = false;
        allowsForcePushes = false;
        requiredLinearHistory = false;
        requireConversationResolution = true;
        requireSignedCommits = false;
        lockBranch = false;
        requiredStatusChecks = {
          strict = true;
          contexts = [ "ci / build" ];
        };
      }
    ];
    repositoryRulesets = [
      {
        repository = "infra";
        name = "no-main-branch";
        target = "branch";
        enforcement = "active";
        conditions = {
          refNameInclude = [ "refs/heads/main" ];
          refNameExclude = [ ];
        };
        rules = {
          creation = true;
          update = true;
        };
      }
    ]
    ++ onlyIf withNewRepository [
      {
        repository = "new-tool";
        name = "no-main-branch";
        target = "branch";
        enforcement = "active";
        conditions = {
          refNameInclude = [ "refs/heads/main" ];
          refNameExclude = [ ];
        };
        rules = {
          creation = true;
          update = true;
        };
      }
    ];
    repositoryEnvironments = [ ];
    actionsRepositoryPermissions = [ ];
    actionsVariables = [ ];
    issueLabels = [ ];
    deferredResources = [ ];
  };
  manifest = {
    version = 1;
    owner = "example-org";
    secrets = [ ];
  };
}
