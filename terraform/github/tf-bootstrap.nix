# Company-agnostic GitHub Layer-0 bootstrap module (CI-authentication plumbing).
#
# Renders ONLY the GitHub facts the Terraform workflow reads to authenticate:
# the three AWS OIDC role-ARN Actions variables and BACKEND_CONFIG_FILE. That is
# the whole of the GitHub side of Layer 0 ("the true bootstrap resources are the
# ones related to the infrastructure of running terraform plan and apply in CI,
# nothing else"); see metacraft-pm infrastructure/terraform-bootstrap-boundary.md.
#
# Everything this module used to render besides those four variables -- the
# reviewer team, its maintainers and repository grant, the Terraform safety
# labels, the deploy Environment and the deploy branch's classic protection --
# is ordinary org governance. It now lives in each consumer's CI-applied
# governance root (governance.nix), which imports it. For every such address
# this module emits a `removed` block with `destroy = false`, so a consumer that
# bumps its pin FORGETS those objects (GitHub is not touched). A `removed` block
# for an address that is not in state is a no-op.
#
# The retired arguments are still accepted so existing callers evaluate
# unchanged; only `reviewerTeam.additionalMaintainers` is read, to name the
# per-maintainer membership addresses that must be forgotten.
{
  awsAccountId,
  awsRegion ? "us-east-1",
  namePrefix,
  githubOwner,
  githubRepo ? "infra",
  githubEnvironment ? "production",
  protectedBranch ? "live",
  # Retired (governance-owned now). Accepted for caller compatibility;
  # `additionalMaintainers` names the membership addresses to forget.
  reviewerTeam ? { },
  enforceAdmins ? true,
  enforceAdminsException ? null,
  singleMaintainerBootstrap ? true,
  productionEnvironmentRequiresManualApproval ? false,
  productionEnvironmentUsesBranchPolicy ? true,
  requiredStatusCheckContexts ? [ ],
  backendConfigFile ? "backends/aws-${namePrefix}.hcl",
}:
let
  githubRepository = "${githubOwner}/${githubRepo}";
  githubBootstrapStateKey = "bootstrap/github/${namePrefix}.tfstate";
  terraformRoles = {
    AWS_TERRAFORM_PLAN_ROLE_ARN = "arn:aws:iam::${awsAccountId}:role/${namePrefix}-terraform-plan";
    AWS_TERRAFORM_APPLY_ROLE_ARN = "arn:aws:iam::${awsAccountId}:role/${namePrefix}-terraform-apply";
    AWS_TERRAFORM_DRIFT_ROLE_ARN = "arn:aws:iam::${awsAccountId}:role/${namePrefix}-terraform-drift";
  };
  # Retained until all existing workflow consumers have moved to per-root
  # backend config discovery.
  githubActionsVariables = terraformRoles // {
    BACKEND_CONFIG_FILE = backendConfigFile;
  };
  # Addresses this module rendered before the Layer-0 boundary was narrowed.
  # They are forgotten, never destroyed: each object is imported by the
  # consumer's governance root first (import-first ordering).
  retiredAddresses = [
    "github_team.infra"
    "github_team_membership.infra_initial_maintainer"
    "github_team_repository.infra"
    "github_issue_label.sensitive_change"
    "github_issue_label.allow_destroy"
    "github_repository_environment.production"
    "github_branch_protection.main"
  ]
  ++ map (
    login:
    "github_team_membership.infra_maintainer_${builtins.replaceStrings [ "-" "." ] [ "_" "_" ] login}"
  ) (reviewerTeam.additionalMaintainers or [ ]);
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

  resource = {
    github_actions_variable = {
      backend_config_file = {
        repository = githubRepo;
        variable_name = "BACKEND_CONFIG_FILE";
        value = githubActionsVariables.BACKEND_CONFIG_FILE;
      };

      aws_terraform_plan_role_arn = {
        repository = githubRepo;
        variable_name = "AWS_TERRAFORM_PLAN_ROLE_ARN";
        value = githubActionsVariables.AWS_TERRAFORM_PLAN_ROLE_ARN;
      };

      aws_terraform_apply_role_arn = {
        repository = githubRepo;
        variable_name = "AWS_TERRAFORM_APPLY_ROLE_ARN";
        value = githubActionsVariables.AWS_TERRAFORM_APPLY_ROLE_ARN;
      };

      aws_terraform_drift_role_arn = {
        repository = githubRepo;
        variable_name = "AWS_TERRAFORM_DRIFT_ROLE_ARN";
        value = githubActionsVariables.AWS_TERRAFORM_DRIFT_ROLE_ARN;
      };
    };
  };

  removed = map (from: {
    inherit from;
    lifecycle.destroy = false;
  }) retiredAddresses;

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
      description = "GitHub organization that owns the repository.";
    };

    github_repository = {
      value = githubRepository;
      description = "GitHub repository managed by this bootstrap layer.";
    };

    github_environment = {
      value = githubEnvironment;
      description = "GitHub Environment the apply role's OIDC trust is bound to (the Environment itself is governance-owned).";
    };

    protected_branch = {
      value = protectedBranch;
      description = "The deploy branch (its protection is governance-owned).";
    };

    github_bootstrap_state_key = {
      value = githubBootstrapStateKey;
      description = "S3 key for the manually applied GitHub bootstrap Terraform state file.";
    };

    github_actions_variables = {
      value = githubActionsVariables;
      description = "GitHub Actions repository variables managed by the GitHub provider.";
    };

    retired_addresses = {
      value = retiredAddresses;
      description = "Addresses this layer forgets (removed, destroy = false); their objects are governance-owned.";
    };
  };
}
