# Company-agnostic standalone GitHub Actions **secrets** engine.
#
# Unlike the full governance engine (terraform/github/governance.nix, which maps
# an org inventory of repos/teams/branch-protection), this engine manages ONLY
# Actions secrets from rendered, GitHub-encrypted payloads. Two uses, following
# the principle that the bootstrap root holds only Layer 0 and everything else
# is normal:
#
#   * a NORMAL terraform/ root for ordinary per-repo application secrets, riding
#     the standard terraform-ci matrix (credential_mode = github-app) so any
#     secret change is plan-comment-apply like every other resource; and
#   * the small Layer-0 bootstrap/ root holding only the chicken-and-egg secrets
#     the pipeline itself authenticates with (the CI App credentials and the CI
#     agenix key), which the pipeline must not be able to rewrite.
#
# Consumers supply their reviewed manifest + rendered managedDoc/payloadDoc; this
# emits the github provider, the S3 backend, and one secret resource per managed,
# rendered payload: github_actions_secret for repository-scoped payloads and
# github_actions_organization_secret for organization-scoped ones. Attribute
# shape matches governance.nix exactly (key_id + value_encrypted, and for org
# secrets visibility + optional selected_repository_ids) so state is compatible.
#
# The AWS/GitHub deployment-fact params are OPTIONAL (null defaults) so existing
# callers that pass only githubOwner + stateKey keep evaluating unchanged. They
# exist so a secrets-only Layer-0 root can be planned/applied by `github-bootstrap`,
# which refuses any config whose outputs do not carry expected_aws_account_id,
# aws_region and github_access_check_repository (the "deployment facts"). Passing
# them makes this engine emit the same output block mkGovernance does.
{
  githubOwner,
  stateKey,
  githubProviderVersion ? "~> 6.0",
  awsAccountId ? null,
  awsRegion ? null,
  githubAccessCheckRepository ? null,
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
    attrValues
    elem
    filter
    listToAttrs
    map
    replaceStrings
    ;

  optionalAttrs = cond: attrs: if cond then attrs else { };

  resourceKey = value: "secret_${replaceStrings [ "/" ":" "." ] [ "_" "_" "_" ] value}";

  managedIds = managedDoc.providerIds or [ ];
  payloads = payloadDoc.payloads or { };

  # Enforced-managed payloads, split by provider resource. Repository-scoped
  # github_actions_secret and organization-scoped github_actions_organization_secret
  # are both handled here; environment/dependabot secrets and the Layer-0
  # bootstrap secrets stay with their respective roots.
  managedPayloads = filter (p: elem p.providerId managedIds) (attrValues payloads);

  wantedRepository = filter (
    p:
    (p.providerResource or "") == "github_actions_secret" && (p.scope or "repository") == "repository"
  ) managedPayloads;

  wantedOrganization = filter (
    p:
    (p.providerResource or "") == "github_actions_organization_secret"
    && (p.scope or "") == "organization"
  ) managedPayloads;

  repositorySecretResources = listToAttrs (
    map (p: {
      name = resourceKey p.providerId;
      value = {
        repository = p.repository;
        secret_name = p.name;
        key_id = p.keyId;
        value_encrypted = p.valueEncrypted;
      };
    }) wantedRepository
  );

  # visibility is required by the provider for organization secrets;
  # selected_repository_ids is only meaningful (and only emitted) when the
  # payload sets visibility = "selected" and carries the id list.
  organizationSecretResources = listToAttrs (
    map (p: {
      name = resourceKey p.providerId;
      value = {
        secret_name = p.name;
        key_id = p.keyId;
        value_encrypted = p.valueEncrypted;
        visibility = p.visibility;
      }
      // optionalAttrs (p ? selectedRepositoryIds) {
        selected_repository_ids = p.selectedRepositoryIds;
      };
    }) wantedOrganization
  );
in
{
  terraform = {
    required_version = ">= 1.8.0";
    backend.s3 = { };
    required_providers = {
      github = {
        source = "integrations/github";
        version = githubProviderVersion;
      };
    };
  };

  # Token comes from the github-app credential mode (GITHUB_TOKEN in the env),
  # minted per-run by the reusable-terraform-ci workflow. No token in config.
  provider.github = [ { owner = githubOwner; } ];

  resource.github_actions_secret = repositorySecretResources;
  resource.github_actions_organization_secret = organizationSecretResources;

  # Deployment facts required by `github-bootstrap` (plan/apply refuses a config
  # whose expected_aws_account_id / aws_region / github_access_check_repository
  # outputs are missing). Same attribute + description shape as mkGovernance so a
  # secrets-only root is a drop-in for the bootstrap tool.
  #
  # These three outputs are emitted ONLY when their param is non-null. terranix
  # strips `value = null` during serialization, which would render an output with
  # a `description` but no `value` key — a config OpenTofu rejects at plan time
  # ("Missing required argument: value"). So repo-only callers (githubOwner +
  # stateKey only) get NO fact outputs at all: the config stays valid and plans
  # cleanly, while `github-bootstrap` correctly sees the facts absent and rejects
  # such a root as not deployment-ready. github_owner and github_bootstrap_state_key
  # derive from required (always non-null) params and stay unconditional.
  output =
    optionalAttrs (awsAccountId != null) {
      expected_aws_account_id = {
        value = awsAccountId;
        description = "Expected AWS account ID for the S3 backend used by this bootstrap layer.";
      };
    }
    // optionalAttrs (awsRegion != null) {
      aws_region = {
        value = awsRegion;
        description = "AWS region for the S3 backend used by this bootstrap layer.";
      };
    }
    // optionalAttrs (githubAccessCheckRepository != null) {
      github_access_check_repository = {
        value = githubAccessCheckRepository;
        description = "Repository used by the bootstrap helper to validate GitHub token access.";
      };
    }
    // {
      github_owner = {
        value = githubOwner;
        description = "GitHub organization governed by this bootstrap layer.";
      };

      github_bootstrap_state_key = {
        value = stateKey;
        description = "S3 key for the manually applied GitHub Actions secrets Terraform state file.";
      };

      # managed_secret_count keeps its historical meaning — the number of
      # repository-scoped Actions secrets — so existing consumers and tftests that
      # assert `managed_secret_count == <repo count>` keep working. Organization
      # secrets are reported separately via managed_org_secret_count rather than
      # folded in, to avoid silently changing that established number.
      managed_secret_count = {
        value = builtins.length wantedRepository;
        description = "Number of repository Actions secrets managed by this root.";
      };

      managed_org_secret_count = {
        value = builtins.length wantedOrganization;
        description = "Number of organization Actions secrets managed by this root.";
      };
    };
}
