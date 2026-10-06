# Example caller for governance.nix. A real consumer's governance root
# (bootstrap/github/<name>-governance-prod/root.nix) imports this engine and
# passes its own `governance` inventory model and secret `manifest`, plus the
# resolved managed/payload documents rendered by github-governance-secrets-render.
# This fixture supplies a tiny, org-agnostic model so the engine can be rendered
# offline (Nix eval only) with no credentials and no company literals.
import ./governance.nix {
  awsAccountId = "000000000000";
  awsRegion = "us-east-1";
  githubOwner = "example-org";
  githubBootstrapStateKey = "bootstrap/github/example-governance-prod.tfstate";

  governance = {
    snapshot.source = "example-inventory-snapshot";
    organization.actionsPermissions = {
      enabledRepositories = "all";
      allowedActions = "selected";
      shaPinningRequired = true;
    };
    repositories = [
      {
        name = "infra";
        visibility = "private";
        hasIssues = true;
        hasProjects = false;
        hasWiki = false;
        hasDiscussions = false;
        allowForking = false;
        archived = false;
        isTemplate = false;
        webCommitSignoffRequired = false;
        defaultBranch = "live";
        description = "Infrastructure as code.";
        topics = [ "terraform" ];
      }
      {
        name = "docs";
        visibility = "public";
        hasIssues = true;
        hasProjects = false;
        hasWiki = false;
        hasDiscussions = false;
        allowForking = true;
        archived = false;
        isTemplate = false;
        webCommitSignoffRequired = false;
        defaultBranch = "main";
        description = "Public documentation.";
        # Recorded at the OBSERVED value, never the desired one: the block rides
        # the existing github_repository import, so a declared value that does
        # not match live turns the import into an update.
        securityAndAnalysis = {
          secretScanning = "enabled";
          secretScanningPushProtection = "disabled";
        };
      }
    ];
    memberships = [
      {
        username = "example-admin";
        role = "admin";
      }
    ];
    # `github_repository_collaborator` rows are DIRECT grants only
    # (`collaborators?affiliation=direct`). Team-derived access belongs in
    # teamRepositories; recording it here would survive removal from the team.
    outsideCollaborators = [ ];
    # Dependabot alerts and security updates: free on every plan and both
    # visibilities, one row per repository including the disabled ones.
    vulnerabilityAlerts = [
      {
        repository = "infra";
        enabled = true;
      }
      {
        repository = "docs";
        enabled = false;
      }
    ];
    dependabotSecurityUpdates = [
      {
        repository = "infra";
        enabled = false;
      }
      {
        repository = "docs";
        enabled = false;
      }
    ];
    teamRepositories = [
      {
        teamSlug = "infra";
        repository = "infra";
        permission = "admin";
      }
    ];
    branchProtections = [
      {
        repository = "infra";
        pattern = "live";
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
    repositoryEnvironments = [
      {
        repository = "infra";
        environment = "production";
        canAdminsBypass = true;
        waitTimer = 0;
      }
    ];
    actionsRepositoryPermissions = [
      {
        repository = "infra";
        enabled = true;
        allowedActions = "selected";
        shaPinningRequired = true;
      }
    ];
    actionsVariables = [
      {
        repository = "infra";
        name = "BACKEND_CONFIG_FILE";
        value = "backends/aws-example-prod.hcl";
      }
    ];
    issueLabels = [
      {
        repository = "infra";
        name = "sensitive-change";
        color = "b60205";
        description = "Touches Layer-0 or secrets.";
      }
    ];
    # Two runner groups, chosen to exercise BOTH shapes of the emitter: an
    # ordinary unrestricted group, and one that reserves capacity by refusing
    # every workflow not on its admission list.
    #
    # The restricted shape is the load-bearing one. Under GitHub's capability
    # matching you cannot reserve runners with a label — `runs-on` matches by
    # SUBSET, so a reserved pool on the same hardware advertises a superset of
    # what ordinary jobs ask for and is eligible for them — and you cannot
    # advertise less, because GitHub attaches `self-hosted`/OS/arch to every
    # self-hosted runner itself. `restricted_to_workflows` + `selected_workflows`
    # is the only admission control in the system that is not label-based, which
    # makes it the only way to express a reserved release lane.
    runnerGroups = [
      {
        name = "example-shared";
        visibility = "all";
        allowsPublicRepositories = true;
        restrictedToWorkflows = false;
      }
      {
        name = "example-release-lane";
        visibility = "all";
        allowsPublicRepositories = true;
        restrictedToWorkflows = true;
        # Fully-qualified refs, no wildcards, and the CALLED workflow for a
        # reusable pair — see the emitter's note in governance.nix.
        selectedWorkflows = [
          "example-org/infra/.github/workflows/release.yml@refs/heads/live"
        ];
      }
    ];
    deferredResources = [ ];
  };

  # One org secret declared but not yet promoted to Terraform management (absent
  # from managedDoc), so the engine renders manifest counts without needing any
  # GitHub-encrypted payloads.
  manifest = {
    version = 1;
    owner = "example-org";
    secrets = [
      {
        providerResource = "github_actions_organization_secret";
        scope = "organization";
        name = "GH_GOVERNANCE_APP_ID";
        providerId = "example-org/GH_GOVERNANCE_APP_ID";
        visibility = "all";
        ageFile = "secrets/actions/org/GH_GOVERNANCE_APP_ID.age";
        manageWithTerraform = true;
      }
    ];
  };
}
