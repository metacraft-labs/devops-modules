{
  awsAccountId,
  awsRegion,
  budgetAlertEmails,
  githubBranch,
  githubEnvironment,
  githubOwner,
  githubRepo,
  lockTableName,
  namePrefix,
  orgLabel,
  # Cost-allocation tags and Cost Categories can only be managed from the AWS
  # Organizations management/payer account. Set false for member-account
  # bootstraps (e.g. a dedicated per-org prod account) to skip them.
  manageCostAllocation ? true,
  # The GitHub Actions OIDC provider is account-global: only one owner may
  # create it. When two repos share an AWS account, the owning repo keeps
  # `true` (creates the `aws_iam_openid_connect_provider`) and every other repo
  # sets `false` to look it up as a `data` source and reference the same ARN
  # instead of recreating it (which would fail with EntityAlreadyExists).
  manageGithubOidcProvider ? true,
  ...
}:
let
  githubTokenHost = "token.actions.githubusercontent.com";
  githubApplyOidcSubject = "repo:${repo}:environment:${githubEnvironment}";
  githubApplyAssumeConditions = [
    {
      test = "StringEquals";
      variable = "${githubTokenHost}:aud";
      values = [ "sts.amazonaws.com" ];
    }
    {
      test = "StringEquals";
      variable = "${githubTokenHost}:repository";
      values = [ repo ];
    }
    # Jobs that reference a GitHub Environment use an environment-shaped OIDC
    # subject. Keep live-branch scoping in the GitHub Environment deployment
    # branch policy instead of requiring a separate ref claim.
    {
      test = "StringLike";
      variable = "${githubTokenHost}:sub";
      values = [ githubApplyOidcSubject ];
    }
  ];
  monthlyBudgetLimitUsd = 100;
  costAllocationTags = {
    project = "Project";
    environment = "Environment";
    managed_by = "ManagedBy";
    repository = "Repository";
    bootstrap = "Bootstrap";
    cost_layer = "CostLayer";
    workload = "Workload";
    platform = "Platform";
    platform_layer = "PlatformLayer";
    component = "Component";
    cell = "Cell";
    role = "Role";
    tier = "Tier";
  };
  costAllocationTagResourceRefs = builtins.map (
    allocationTagName: "aws_ce_cost_allocation_tag.${allocationTagName}"
  ) (builtins.attrNames costAllocationTags);
  mkInheritedCostCategory = name: tagKey: {
    inherit name;
    rule_version = "CostCategoryExpression.v1";
    default_value = "unallocated";
    depends_on = costAllocationTagResourceRefs;
    rule = [
      {
        type = "INHERITED_VALUE";
        inherited_value = [
          {
            dimension_name = "TAG";
            dimension_key = tagKey;
          }
        ];
      }
    ];
  };
  repo = "${githubOwner}/${githubRepo}";
  bootstrapStateKey = "bootstrap/aws/${namePrefix}.tfstate";
  managedStatePrefix = "terraform/";
  sensitiveManagedStatePrefix = "terraform-sensitive/";
  managedStatePrefixes = [
    managedStatePrefix
    sensitiveManagedStatePrefix
  ];
  managedStateListPrefixes = builtins.concatMap (prefix: [
    prefix
    "${prefix}*"
  ]) managedStatePrefixes;
  managedStateObjectArns = builtins.map (
    prefix: "\${aws_s3_bucket.tf_state.arn}/${prefix}*"
  ) managedStatePrefixes;
  awsStateKey = "${managedStatePrefix}aws/${namePrefix}.tfstate";
  stripeSensitiveStateKey = "${sensitiveManagedStatePrefix}stripe/${namePrefix}.tfstate";
  managedIamRoleArnPattern = "arn:aws:iam::${awsAccountId}:role/${namePrefix}-*";
  managedIamInstanceProfileArnPattern = "arn:aws:iam::${awsAccountId}:instance-profile/${namePrefix}-*";
  managedIamUserArnPattern = "arn:aws:iam::${awsAccountId}:user/${namePrefix}-*";
  managedIamGroupArnPattern = "arn:aws:iam::${awsAccountId}:group/${namePrefix}-*";
  managedIamPassRoleServices = [
    "vpc-flow-logs.amazonaws.com"
    "backup.amazonaws.com"
    "ec2.amazonaws.com"
    "lambda.amazonaws.com"
  ];
  managedIamPolicyAttachmentArns = [
    "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  ];
  terraformApplyManagedIamPolicy = builtins.toJSON {
    Version = "2012-10-17";
    Statement = [
      {
        Sid = "Manage${orgLabel}Roles";
        Effect = "Allow";
        Action = [
          "iam:CreateRole"
          "iam:DeleteRole"
          "iam:GetRole"
          "iam:ListRolePolicies"
          "iam:ListAttachedRolePolicies"
          # Authorized against the ROLE arn, not the instance-profile arn, which
          # is why it belongs in this statement and not the instance-profile one
          # below. The AWS provider calls ListInstanceProfilesForRole as a
          # pre-step of every aws_iam_role delete (to detach the role from any
          # profile first), so without it a destroy fails mid-apply with
          # `AccessDenied ... on resource: role <name>` -- after earlier
          # resources in the same apply have already been destroyed.
          "iam:ListInstanceProfilesForRole"
          "iam:PutRolePolicy"
          "iam:GetRolePolicy"
          "iam:DeleteRolePolicy"
          "iam:TagRole"
          "iam:UntagRole"
          "iam:UpdateAssumeRolePolicy"
        ];
        Resource = managedIamRoleArnPattern;
      }
      {
        Sid = "Manage${orgLabel}InstanceProfiles";
        Effect = "Allow";
        Action = [
          "iam:CreateInstanceProfile"
          "iam:DeleteInstanceProfile"
          "iam:GetInstanceProfile"
          "iam:AddRoleToInstanceProfile"
          "iam:RemoveRoleFromInstanceProfile"
          "iam:TagInstanceProfile"
          "iam:UntagInstanceProfile"
        ];
        Resource = managedIamInstanceProfileArnPattern;
      }
      {
        Sid = "Manage${orgLabel}Users";
        Effect = "Allow";
        Action = [
          "iam:CreateUser"
          "iam:DeleteUser"
          "iam:GetUser"
          "iam:ListGroupsForUser"
          "iam:TagUser"
          "iam:UntagUser"
        ];
        Resource = managedIamUserArnPattern;
      }
      {
        Sid = "Manage${orgLabel}Groups";
        Effect = "Allow";
        Action = [
          "iam:CreateGroup"
          "iam:DeleteGroup"
          "iam:GetGroup"
          "iam:ListGroupPolicies"
          "iam:PutGroupPolicy"
          "iam:GetGroupPolicy"
          "iam:DeleteGroupPolicy"
          "iam:AddUserToGroup"
          "iam:RemoveUserFromGroup"
        ];
        Resource = managedIamGroupArnPattern;
      }
      {
        Sid = "AttachApprovedManagedPoliciesTo${orgLabel}Roles";
        Effect = "Allow";
        Action = [
          "iam:AttachRolePolicy"
          "iam:DetachRolePolicy"
        ];
        Resource = managedIamRoleArnPattern;
        Condition.ArnEquals."iam:PolicyARN" = managedIamPolicyAttachmentArns;
      }
      {
        Sid = "ReadApprovedManagedPolicies";
        Effect = "Allow";
        Action = [
          "iam:GetPolicy"
          "iam:GetPolicyVersion"
        ];
        Resource = managedIamPolicyAttachmentArns;
      }
      {
        Sid = "Pass${orgLabel}RolesToAwsServices";
        Effect = "Allow";
        Action = "iam:PassRole";
        Resource = managedIamRoleArnPattern;
        Condition.StringEquals."iam:PassedToService" = managedIamPassRoleServices;
      }
    ];
  };
  breakGlassRoleName = "${namePrefix}-break-glass-admin";
  breakGlassMaxSessionDurationSeconds = 3600;
  terraformApplyMaxSessionDurationSeconds = 7200;
  breakGlassAdministratorAccessPolicyArn = "arn:aws:iam::aws:policy/AdministratorAccess";
  # These patterns intentionally constrain the account-root trust principal to
  # named human operator identities in the production account. Update them in
  # code before applying if the real human-admin identity names differ.
  #
  # AWS condition key references:
  # https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_condition-keys.html#condition-keys-multifactorauthpresent
  # https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_condition-keys.html#condition-keys-principalarn
  breakGlassPrincipalArnPatterns = [
    "arn:aws:iam::${awsAccountId}:user/break-glass/*"
    "arn:aws:iam::${awsAccountId}:role/${orgLabel}BreakGlassOperator"
    "arn:aws:iam::${awsAccountId}:role/aws-reserved/sso.amazonaws.com/*/AWSReservedSSO_AdministratorAccess_*"
  ];
  # Account-global OIDC provider ARN, whether this bootstrap owns the provider
  # (resource) or references a peer-owned one (data source).
  githubOidcProviderArn =
    if manageGithubOidcProvider then
      "\${aws_iam_openid_connect_provider.github_actions.arn}"
    else
      "\${data.aws_iam_openid_connect_provider.github_actions.arn}";
  breakGlassAssumeRolePolicy = builtins.toJSON {
    Version = "2012-10-17";
    Statement = [
      {
        Sid = "AllowSameAccountHumanBreakGlassWithMfa";
        Effect = "Allow";
        Action = "sts:AssumeRole";
        Principal.AWS = "arn:aws:iam::${awsAccountId}:root";
        Condition = {
          Bool."aws:MultiFactorAuthPresent" = "true";
          StringLike."aws:PrincipalArn" = breakGlassPrincipalArnPatterns;
        };
      }
    ];
  };
in
{
  terraform = {
    required_version = ">= 1.8.0";
    backend.s3 = { };
    required_providers = {
      aws = {
        source = "hashicorp/aws";
        version = "~> 5.0";
      };
      tls = {
        source = "hashicorp/tls";
        version = "~> 4.0";
      };
    };
  };

  locals = {
    state_bucket_name = "\${format(\"${namePrefix}-tofu-state-%s\", data.aws_caller_identity.current.account_id)}";
    github_repository = repo;
    common_tags = {
      Project = githubOwner;
      Environment = "prod";
      ManagedBy = "opentofu";
      Repository = repo;
      Bootstrap = "true";
      CostLayer = "terraform-control-plane";
      Workload = "terraform-state";
      Component = "terraform-bootstrap";
    };
  };

  provider.aws = {
    region = awsRegion;
    default_tags.tags = "\${local.common_tags}";
  };

  resource = {
    aws_s3_bucket.tf_state = {
      bucket = "\${local.state_bucket_name}";
    };

    aws_s3_bucket_public_access_block.tf_state = {
      bucket = "\${aws_s3_bucket.tf_state.id}";

      block_public_acls = true;
      block_public_policy = true;
      ignore_public_acls = true;
      restrict_public_buckets = true;
    };

    aws_s3_bucket_versioning.tf_state = {
      bucket = "\${aws_s3_bucket.tf_state.id}";

      versioning_configuration.status = "Enabled";
    };

    aws_s3_bucket_server_side_encryption_configuration.tf_state = {
      bucket = "\${aws_s3_bucket.tf_state.id}";

      rule.apply_server_side_encryption_by_default.sse_algorithm = "AES256";
    };

    aws_s3_bucket_policy.tf_state = {
      bucket = "\${aws_s3_bucket.tf_state.id}";
      policy = "\${data.aws_iam_policy_document.state_bucket_tls.json}";
    };

    aws_dynamodb_table.tf_locks = {
      name = lockTableName;
      billing_mode = "PAY_PER_REQUEST";
      hash_key = "LockID";

      attribute = [
        {
          name = "LockID";
          type = "S";
        }
      ];

      point_in_time_recovery.enabled = true;
      server_side_encryption.enabled = true;
    };

    aws_iam_role.terraform_plan = {
      name = "${namePrefix}-terraform-plan";
      description = "Read-only Terraform plan role for ${repo}.";
      assume_role_policy = "\${data.aws_iam_policy_document.github_plan_assume.json}";
    };

    aws_iam_role.terraform_apply = {
      name = "${namePrefix}-terraform-apply";
      description = "Terraform apply role for ${repo}, scoped to the production GitHub Environment.";
      assume_role_policy = "\${data.aws_iam_policy_document.github_apply_assume.json}";
      max_session_duration = terraformApplyMaxSessionDurationSeconds;
    };

    aws_iam_role.terraform_drift = {
      name = "${namePrefix}-terraform-drift";
      description = "Read-only scheduled Terraform drift role for ${repo}.";
      assume_role_policy = "\${data.aws_iam_policy_document.github_drift_assume.json}";
    };

    aws_iam_role.break_glass_admin = {
      name = breakGlassRoleName;
      description = "Emergency human administrator role for Agent Harbor production. Requires MFA and constrained same-account principals.";
      assume_role_policy = breakGlassAssumeRolePolicy;
      max_session_duration = breakGlassMaxSessionDurationSeconds;
    };

    aws_iam_role_policy.terraform_plan_backend = {
      name = "${namePrefix}-terraform-plan-backend";
      role = "\${aws_iam_role.terraform_plan.id}";
      policy = "\${data.aws_iam_policy_document.backend_read_lock.json}";
    };

    aws_iam_role_policy.terraform_apply_backend = {
      name = "${namePrefix}-terraform-apply-backend";
      role = "\${aws_iam_role.terraform_apply.id}";
      policy = "\${data.aws_iam_policy_document.backend_read_write_lock.json}";
    };

    aws_iam_role_policy.terraform_apply_managed_iam = {
      name = "${namePrefix}-terraform-apply-managed-iam";
      role = "\${aws_iam_role.terraform_apply.id}";
      policy = terraformApplyManagedIamPolicy;
    };

    aws_iam_role_policy.terraform_drift_backend = {
      name = "${namePrefix}-terraform-drift-backend";
      role = "\${aws_iam_role.terraform_drift.id}";
      policy = "\${data.aws_iam_policy_document.backend_read_lock.json}";
    };

    aws_iam_role_policy_attachment.terraform_plan_readonly = {
      role = "\${aws_iam_role.terraform_plan.name}";
      policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess";
    };

    aws_iam_role_policy_attachment.terraform_apply_poweruser = {
      role = "\${aws_iam_role.terraform_apply.name}";
      policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess";
    };

    aws_iam_role_policy_attachment.terraform_drift_readonly = {
      role = "\${aws_iam_role.terraform_drift.name}";
      policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess";
    };

    aws_iam_role_policy_attachment.break_glass_admin = {
      role = "\${aws_iam_role.break_glass_admin.name}";
      policy_arn = breakGlassAdministratorAccessPolicyArn;
    };

    aws_budgets_budget.monthly_cost = {
      name = "${namePrefix}-monthly-cost";
      budget_type = "COST";
      limit_amount = toString monthlyBudgetLimitUsd;
      limit_unit = "USD";
      time_unit = "MONTHLY";

      notification = [
        {
          comparison_operator = "GREATER_THAN";
          threshold = 80;
          threshold_type = "PERCENTAGE";
          notification_type = "ACTUAL";
          subscriber_email_addresses = budgetAlertEmails;
        }
        {
          comparison_operator = "GREATER_THAN";
          threshold = 100;
          threshold_type = "PERCENTAGE";
          notification_type = "FORECASTED";
          subscriber_email_addresses = budgetAlertEmails;
        }
      ];
    };
  }
  // (
    # Account-global: only the owning repo creates it (see manageGithubOidcProvider).
    if manageGithubOidcProvider then
      {
        aws_iam_openid_connect_provider.github_actions = {
          url = "https://${githubTokenHost}";
          client_id_list = [ "sts.amazonaws.com" ];
          thumbprint_list = [ "\${data.tls_certificate.github_actions.certificates[0].sha1_fingerprint}" ];
        };
      }
    else
      { }
  )
  // (
    if manageCostAllocation then
      {
        aws_ce_cost_allocation_tag = builtins.mapAttrs (_name: tagKey: {
          tag_key = tagKey;
          status = "Active";
        }) costAllocationTags;

        aws_ce_cost_category = {
          agent_harbor_cost_layer = mkInheritedCostCategory "${orgLabel}CostLayer" "CostLayer";
          agent_harbor_workload = mkInheritedCostCategory "${orgLabel}Workload" "Workload";
          agent_harbor_platform_layer = mkInheritedCostCategory "${orgLabel}PlatformLayer" "PlatformLayer";
          agent_harbor_component = mkInheritedCostCategory "${orgLabel}Component" "Component";
        };
      }
    else
      { }
  );

  data = {
    aws_caller_identity.current = { };
    tls_certificate.github_actions = {
      url = "https://${githubTokenHost}";
    };

    aws_iam_policy_document = {
      state_bucket_tls.statement = [
        {
          sid = "DenyInsecureTransport";
          effect = "Deny";
          actions = [ "s3:*" ];
          resources = [
            "\${aws_s3_bucket.tf_state.arn}"
            "\${aws_s3_bucket.tf_state.arn}/*"
          ];
          principals = [
            {
              type = "*";
              identifiers = [ "*" ];
            }
          ];
          condition = [
            {
              test = "Bool";
              variable = "aws:SecureTransport";
              values = [ "false" ];
            }
          ];
        }
      ];

      backend_read_lock.statement = [
        {
          sid = "ListStateBucket";
          effect = "Allow";
          actions = [ "s3:ListBucket" ];
          resources = [ "\${aws_s3_bucket.tf_state.arn}" ];
          condition = [
            {
              test = "StringLike";
              variable = "s3:prefix";
              values = managedStateListPrefixes;
            }
          ];
        }
        {
          sid = "ReadStateObject";
          effect = "Allow";
          actions = [ "s3:GetObject" ];
          resources = managedStateObjectArns;
        }
        {
          sid = "UseStateLock";
          effect = "Allow";
          actions = [
            "dynamodb:DeleteItem"
            "dynamodb:GetItem"
            "dynamodb:PutItem"
            "dynamodb:UpdateItem"
          ];
          resources = [ "\${aws_dynamodb_table.tf_locks.arn}" ];
        }
      ];

      backend_read_write_lock.statement = [
        {
          sid = "ListStateBucket";
          effect = "Allow";
          actions = [ "s3:ListBucket" ];
          resources = [ "\${aws_s3_bucket.tf_state.arn}" ];
          condition = [
            {
              test = "StringLike";
              variable = "s3:prefix";
              values = managedStateListPrefixes;
            }
          ];
        }
        {
          sid = "WriteStateObject";
          effect = "Allow";
          actions = [
            "s3:DeleteObject"
            "s3:GetObject"
            "s3:PutObject"
          ];
          resources = managedStateObjectArns;
        }
        {
          sid = "UseStateLock";
          effect = "Allow";
          actions = [
            "dynamodb:DeleteItem"
            "dynamodb:GetItem"
            "dynamodb:PutItem"
            "dynamodb:UpdateItem"
          ];
          resources = [ "\${aws_dynamodb_table.tf_locks.arn}" ];
        }
      ];

      github_plan_assume.statement = [
        {
          effect = "Allow";
          actions = [ "sts:AssumeRoleWithWebIdentity" ];
          principals = [
            {
              type = "Federated";
              identifiers = [ githubOidcProviderArn ];
            }
          ];
          condition = [
            {
              test = "StringEquals";
              variable = "${githubTokenHost}:aud";
              values = [ "sts.amazonaws.com" ];
            }
            {
              test = "StringEquals";
              variable = "${githubTokenHost}:repository";
              values = [ "\${local.github_repository}" ];
            }
            {
              test = "StringLike";
              variable = "${githubTokenHost}:sub";
              values = [ "repo:\${local.github_repository}:pull_request" ];
            }
          ];
        }
      ];

      github_apply_assume.statement = [
        {
          effect = "Allow";
          actions = [ "sts:AssumeRoleWithWebIdentity" ];
          principals = [
            {
              type = "Federated";
              identifiers = [ githubOidcProviderArn ];
            }
          ];
          condition = githubApplyAssumeConditions;
        }
      ];

      github_drift_assume.statement = [
        {
          effect = "Allow";
          actions = [ "sts:AssumeRoleWithWebIdentity" ];
          principals = [
            {
              type = "Federated";
              identifiers = [ githubOidcProviderArn ];
            }
          ];
          condition = [
            {
              test = "StringEquals";
              variable = "${githubTokenHost}:aud";
              values = [ "sts.amazonaws.com" ];
            }
            {
              test = "StringEquals";
              variable = "${githubTokenHost}:repository";
              values = [ "\${local.github_repository}" ];
            }
            {
              test = "StringLike";
              variable = "${githubTokenHost}:sub";
              values = [ "repo:\${local.github_repository}:ref:refs/heads/${githubBranch}" ];
            }
          ];
        }
      ];

    };
  }
  // (
    # Peer-owned account-global OIDC provider: look it up instead of creating it.
    if manageGithubOidcProvider then
      { }
    else
      {
        aws_iam_openid_connect_provider.github_actions = {
          url = "https://${githubTokenHost}";
        };
      }
  );

  output = {
    expected_aws_account_id = {
      value = awsAccountId;
      description = "Expected production AWS account ID for credentialed bootstrap guard.";
    };

    aws_region = {
      value = awsRegion;
      description = "AWS region used by the production environment.";
    };

    state_bucket_name = {
      value = "\${aws_s3_bucket.tf_state.bucket}";
      description = "S3 bucket for managed Terraform state.";
    };

    state_key = {
      value = awsStateKey;
      description = "S3 key for the managed Terraform state file.";
    };

    managed_state_prefix = {
      value = managedStatePrefix;
      description = "Default S3 key prefix for ordinary managed Terraform state.";
    };

    sensitive_managed_state_prefix = {
      value = sensitiveManagedStatePrefix;
      description = "S3 key prefix for Terraform state that is expected to contain provider-returned or generated secret material.";
    };

    managed_state_prefixes = {
      value = managedStatePrefixes;
      description = "S3 key prefixes that GitHub OIDC Terraform roles may read or write.";
    };

    stripe_sensitive_state_key = {
      value = stripeSensitiveStateKey;
      description = "S3 key for the Stripe Terraform root; this state contains the webhook signing secret after endpoint creation.";
    };

    bootstrap_state_key = {
      value = bootstrapStateKey;
      description = "S3 key for the manually applied bootstrap Terraform state file.";
    };

    lock_table_name = {
      value = "\${aws_dynamodb_table.tf_locks.name}";
      description = "DynamoDB table for OpenTofu state locking.";
    };

    common_tags = {
      value = "\${local.common_tags}";
      description = "Common cost-allocation and ownership tags applied to bootstrap AWS resources.";
    };

    cost_allocation_tag_keys = {
      value = if manageCostAllocation then costAllocationTags else { };
      description = "User-defined AWS cost allocation tag keys activated by the bootstrap root.";
    };

    cost_category_names = {
      value =
        if manageCostAllocation then
          [
            "\${aws_ce_cost_category.agent_harbor_cost_layer.name}"
            "\${aws_ce_cost_category.agent_harbor_workload.name}"
            "\${aws_ce_cost_category.agent_harbor_platform_layer.name}"
            "\${aws_ce_cost_category.agent_harbor_component.name}"
          ]
        else
          [ ];
      description = "AWS Cost Categories managed by the bootstrap root for Agent Harbor cost reporting.";
    };

    terraform_plan_role_arn = {
      value = "\${aws_iam_role.terraform_plan.arn}";
      description = "GitHub OIDC role ARN for PR plans.";
    };

    terraform_apply_role_arn = {
      value = "\${aws_iam_role.terraform_apply.arn}";
      description = "GitHub OIDC role ARN for applies.";
    };

    terraform_apply_role_max_session_duration = {
      value = "\${aws_iam_role.terraform_apply.max_session_duration}";
      description = "Maximum session duration, in seconds, for production apply and long-running DR workflows.";
    };

    terraform_drift_role_arn = {
      value = "\${aws_iam_role.terraform_drift.arn}";
      description = "GitHub OIDC role ARN for drift checks.";
    };

    managed_iam_role_arn_pattern = {
      value = managedIamRoleArnPattern;
      description = "Scoped IAM role ARN pattern managed Terraform roots may create and pass.";
    };

    managed_iam_instance_profile_arn_pattern = {
      value = managedIamInstanceProfileArnPattern;
      description = "Scoped IAM instance-profile ARN pattern managed Terraform roots may create for EC2 hosts.";
    };

    managed_iam_user_arn_pattern = {
      value = managedIamUserArnPattern;
      description = "Scoped IAM user ARN pattern managed Terraform roots may create for provider-issued credentials such as SES SMTP.";
    };

    managed_iam_group_arn_pattern = {
      value = managedIamGroupArnPattern;
      description = "Scoped IAM group ARN pattern managed Terraform roots may create for non-human service identities.";
    };

    managed_iam_pass_role_services = {
      value = managedIamPassRoleServices;
      description = "AWS services that managed Terraform roots may receive scoped Agent Harbor IAM roles for.";
    };

    managed_iam_policy_attachment_arns = {
      value = managedIamPolicyAttachmentArns;
      description = "AWS managed policies that the Terraform apply role may attach to scoped Agent Harbor roles.";
    };

    break_glass_role_name = {
      value = "\${aws_iam_role.break_glass_admin.name}";
      description = "Name of the emergency human administrator role defined by bootstrap Terraform.";
    };

    break_glass_role_arn = {
      value = "arn:aws:iam::${awsAccountId}:role/${breakGlassRoleName}";
      description = "Expected ARN of the emergency human administrator role defined by bootstrap Terraform.";
    };

    break_glass_role_max_session_duration = {
      value = "\${aws_iam_role.break_glass_admin.max_session_duration}";
      description = "Maximum session duration, in seconds, for the break-glass administrator role.";
    };

    break_glass_allowed_principal_arn_patterns = {
      value = "\${jsondecode(aws_iam_role.break_glass_admin.assume_role_policy).Statement[0].Condition.StringLike[\"aws:PrincipalArn\"]}";
      description = "Same-account human operator IAM principal ARN patterns allowed to assume the break-glass role when MFA is present.";
    };

    break_glass_mfa_required = {
      value = "\${jsondecode(aws_iam_role.break_glass_admin.assume_role_policy).Statement[0].Condition.Bool[\"aws:MultiFactorAuthPresent\"] == \"true\"}";
      description = "Whether the break-glass trust policy requires aws:MultiFactorAuthPresent.";
    };

    break_glass_policy_attachment_arn = {
      value = "\${aws_iam_role_policy_attachment.break_glass_admin.policy_arn}";
      description = "Managed policy ARN attached to the break-glass administrator role.";
    };

    github_actions_variables = {
      value = {
        AWS_TERRAFORM_PLAN_ROLE_ARN = "\${aws_iam_role.terraform_plan.arn}";
        AWS_TERRAFORM_APPLY_ROLE_ARN = "\${aws_iam_role.terraform_apply.arn}";
        AWS_TERRAFORM_DRIFT_ROLE_ARN = "\${aws_iam_role.terraform_drift.arn}";
        BACKEND_CONFIG_FILE = "backends/aws-${namePrefix}.hcl";
      };
      description = "GitHub Actions repository variables surfaced for the GitHub bootstrap layer.";
    };

    budget_alert_emails = {
      value = budgetAlertEmails;
      description = "Email addresses subscribed to budget alerts.";
    };

    github_branch = {
      value = githubBranch;
      description = "GitHub branch allowed by the production Environment branch policy and drift role.";
    };

    github_apply_oidc_subject = {
      value = githubApplyOidcSubject;
      description = "GitHub OIDC subject accepted by the production apply role.";
    };

    github_apply_oidc_condition_variables = {
      value = builtins.map (condition: condition.variable) githubApplyAssumeConditions;
      description = "OIDC condition keys used by the production apply role trust policy.";
    };
  };
}
