# Offline mock-provider gate for milestone G3: the standalone Actions-secrets
# engine must emit organization-scoped secrets (not just repository-scoped ones)
# and must carry the deployment-fact outputs a secrets-only Layer-0 root needs to
# be planned/applied by `github-bootstrap`.
#
# The config under test is the terranix render of ./default.nix (produced into
# this directory as config.tf.json by test-actions-secrets-org-scope.sh before
# `tofu test` runs). No credentials, no network: mock_provider + command = plan.
mock_provider "github" {}

run "t_actions_secrets_org_scope" {
  command = plan

  # (1) an org-scoped secret with visibility "all" produces a
  # github_actions_organization_secret with the right visibility.
  assert {
    condition     = github_actions_organization_secret.secret_example-org_ORG_SECRET_ALL.visibility == "all"
    error_message = "org secret ORG_SECRET_ALL must render github_actions_organization_secret with visibility = all"
  }
  assert {
    condition     = github_actions_organization_secret.secret_example-org_ORG_SECRET_ALL.secret_name == "ORG_SECRET_ALL"
    error_message = "org secret ORG_SECRET_ALL must carry its secret_name"
  }
  assert {
    condition     = github_actions_organization_secret.secret_example-org_ORG_SECRET_ALL.key_id == "2222222222222222222"
    error_message = "org secret must carry key_id from the rendered payload"
  }

  # (1b) a "selected"-visibility org secret carries selected_repository_ids.
  assert {
    condition     = github_actions_organization_secret.secret_example-org_ORG_SECRET_SELECTED.visibility == "selected"
    error_message = "org secret ORG_SECRET_SELECTED must render visibility = selected"
  }
  assert {
    condition     = length(github_actions_organization_secret.secret_example-org_ORG_SECRET_SELECTED.selected_repository_ids) == 2
    error_message = "a selected-visibility org secret must carry selected_repository_ids"
  }

  # (2) a repo-scoped secret still produces a github_actions_secret.
  assert {
    condition     = github_actions_secret.secret_example-org_infra_REPO_SECRET.repository == "infra"
    error_message = "repository secret must still render github_actions_secret bound to its repository"
  }

  # (3) the count outputs reflect both scopes.
  assert {
    condition     = output.managed_secret_count == 1
    error_message = "managed_secret_count must count exactly the one repository secret"
  }
  assert {
    condition     = output.managed_org_secret_count == 2
    error_message = "managed_org_secret_count must count exactly the two organization secrets"
  }

  # (4) deployment facts required by github-bootstrap are present and equal the
  # inputs, so a secrets-only root now produces a bootstrap-tool-acceptable config.
  assert {
    condition     = output.expected_aws_account_id == "000000000000"
    error_message = "expected_aws_account_id deployment fact must equal awsAccountId"
  }
  assert {
    condition     = output.aws_region == "us-east-1"
    error_message = "aws_region deployment fact must equal awsRegion"
  }
  assert {
    condition     = output.github_access_check_repository == "infra"
    error_message = "github_access_check_repository deployment fact must equal githubAccessCheckRepository"
  }
  assert {
    condition     = output.github_owner == "example-org"
    error_message = "github_owner deployment fact must equal githubOwner"
  }
  assert {
    condition     = output.github_bootstrap_state_key == "bootstrap/github/example-secrets.tfstate"
    error_message = "github_bootstrap_state_key deployment fact must equal stateKey"
  }
}
