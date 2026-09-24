# Company-agnostic GitHub Layer-0 bootstrap module (CI-enabling repo settings).
#
# Renders the minimal GitHub facts the CI/CD pipeline depends on to run: the
# reviewer team, the deploy Environment, the AWS OIDC role-ARN Actions variables,
# the Terraform safety labels, and branch protection for the deploy branch. This
# is the GitHub counterpart of tf-bootstrap.nix on the AWS side — a value-
# independent module; each consumer's bootstrap/github/<name>/default.nix thin-
# calls it with its own identifiers. Broader org governance (repos, memberships,
# org secrets) lives in the separate governance engine (governance.nix).
{
  awsAccountId,
  awsRegion ? "us-east-1",
  namePrefix,
  githubOwner,
  githubRepo ? "infra",
  githubEnvironment ? "production",
  protectedBranch ? "live",
  # { name, slug, description, initialMaintainer, additionalMaintainers ? [ ] }
  # `additionalMaintainers` are further GitHub logins made team maintainers;
  # `initialMaintainer` keeps its own resource address so existing state is
  # unaffected.
  reviewerTeam,
  # Whether classic branch protection binds org/repo admins too. The Phase P
  # model is "protect the mainline, but NOT enforce_admins" (admins keep the
  # escape hatch; see mainline-protection.nix). Defaults to true only so that
  # existing callers render unchanged; new callers should pass false.
  enforceAdmins ? true,
  # During single-maintainer bootstrap, mandatory PR-review gates would block
  # every PR. Required checks stay enforced regardless; flip to false once the
  # reviewer team has at least two admins.
  singleMaintainerBootstrap ? true,
  productionEnvironmentRequiresManualApproval ? false,
  productionEnvironmentUsesBranchPolicy ? true,
  requiredStatusCheckContexts,
  backendConfigFile ? "backends/aws-${namePrefix}.hcl",
}:
let
  githubRepository = "${githubOwner}/${githubRepo}";
  githubBootstrapStateKey = "bootstrap/github/${namePrefix}.tfstate";
  requirePullRequestReviews = !singleMaintainerBootstrap;
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
    github_team.infra = {
      name = reviewerTeam.name;
      description = reviewerTeam.description;
      privacy = "closed";
    };

    github_team_membership = {
      infra_initial_maintainer = {
        team_id = "\${github_team.infra.id}";
        username = reviewerTeam.initialMaintainer;
        role = "maintainer";
      };
    }
    // builtins.listToAttrs (
      map (login: {
        name = "infra_maintainer_${builtins.replaceStrings [ "-" "." ] [ "_" "_" ] login}";
        value = {
          team_id = "\${github_team.infra.id}";
          username = login;
          role = "maintainer";
        };
      }) (reviewerTeam.additionalMaintainers or [ ])
    );

    github_team_repository.infra = {
      team_id = "\${github_team.infra.id}";
      repository = githubRepo;
      permission = "maintain";
    };

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

    github_issue_label = {
      sensitive_change = {
        repository = githubRepo;
        name = "sensitive-change";
        color = "D93F0B";
        description = "Terraform safety gate";
      };

      allow_destroy = {
        repository = githubRepo;
        name = "allow-destroy";
        color = "D93F0B";
        description = "Terraform safety gate";
      };
    };

    github_repository_environment.production = {
      repository = githubRepo;
      environment = githubEnvironment;
      wait_timer = 0;
      can_admins_bypass = false;
      deployment_branch_policy = [
        {
          protected_branches = productionEnvironmentUsesBranchPolicy;
          custom_branch_policies = false;
        }
      ];
    };

    github_branch_protection.main = {
      repository_id = githubRepo;
      pattern = protectedBranch;
      enforce_admins = enforceAdmins;
      allows_deletions = false;
      allows_force_pushes = false;
      require_conversation_resolution = true;
      required_linear_history = true;

      required_status_checks = [
        {
          strict = true;
          contexts = requiredStatusCheckContexts;
        }
      ];
    }
    // (
      if requirePullRequestReviews then
        {
          required_pull_request_reviews = [
            {
              dismiss_stale_reviews = true;
              require_code_owner_reviews = true;
              require_last_push_approval = true;
              required_approving_review_count = 1;
            }
          ];
        }
      else
        { }
    );
  };

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
      description = "GitHub Environment used by Terraform apply jobs.";
    };

    github_reviewer_team_slug = {
      value = reviewerTeam.slug;
      description = "GitHub team slug used for CODEOWNERS and future PR review rules.";
    };

    github_reviewer_team_name = {
      value = "\${github_team.infra.name}";
      description = "GitHub team name managed by this bootstrap layer.";
    };

    github_reviewer_team_initial_maintainer = {
      value = reviewerTeam.initialMaintainer;
      description = "Initial maintainer for the Terraform-managed infrastructure reviewer team.";
    };

    single_maintainer_bootstrap = {
      value = singleMaintainerBootstrap;
      description = "Whether GitHub PR review gates are relaxed for a single-maintainer bootstrap phase.";
    };

    production_environment_requires_manual_approval = {
      value = productionEnvironmentRequiresManualApproval;
      description = "Whether production Environment requires a separate post-merge deployment approval.";
    };

    production_environment_uses_branch_policy = {
      value = productionEnvironmentUsesBranchPolicy;
      description = "Whether production Environment deployments are limited to protected branches.";
    };

    branch_protection_requires_pull_request_reviews = {
      value = requirePullRequestReviews;
      description = "Whether branch protection requires pull request reviews.";
    };

    protected_branch = {
      value = protectedBranch;
      description = "GitHub branch protected by this bootstrap layer.";
    };

    required_status_check_contexts = {
      value = requiredStatusCheckContexts;
      description = "Required GitHub status check contexts for the protected branch.";
    };

    github_bootstrap_state_key = {
      value = githubBootstrapStateKey;
      description = "S3 key for the manually applied GitHub bootstrap Terraform state file.";
    };

    github_actions_variables = {
      value = githubActionsVariables;
      description = "GitHub Actions repository variables managed by the GitHub provider.";
    };
  };
}
