# Mock-provider gate for Terraform-only repository creation (`seed`).
#
# Mock justification: the github provider is mocked because the real one needs
# GitHub credentials and a live organization; the test must run offline. Only
# the provider is mocked. terraform_data and its local-exec provisioner are
# OpenTofu built-ins and run for real: on apply the seed script performs a real
# `git push` into the local bare repository named by GOVERNANCE_SEED_REMOTE,
# which test-repository-seed.sh creates and inspects afterwards.
mock_provider "github" {}

run "plan_seeds_new_repository" {
  command = plan

  assert {
    condition     = github_branch_default.branch_default_new_tool.branch == "dev"
    error_message = "the seeded repository's default branch must be its mainline"
  }
  assert {
    condition     = github_repository.repo_new_tool.auto_init == null && length(github_repository.repo_new_tool.template) == 0
    error_message = "a seeded repository must not use auto_init or template (both create the provider's default branch)"
  }
  assert {
    condition     = terraform_data.seed_new_tool.triggers_replace[1] == "dev"
    error_message = "the seed must be keyed on the mainline name"
  }
  assert {
    condition     = github_branch_default.branch_default_infra.branch == "live"
    error_message = "the existing repository's default branch must be untouched"
  }
}

run "apply_pushes_the_mainline" {
  command = apply

  assert {
    condition     = github_branch_default.branch_default_new_tool.branch == "dev"
    error_message = "apply must reach the default-branch resource after the seed"
  }
}
