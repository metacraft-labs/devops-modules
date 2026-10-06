# Offline mock-provider gate for milestone G3, backward-compatible path: a
# repo-only caller (githubOwner + stateKey only, no deployment-fact params) must
# still render a VALID config that plans cleanly. This is the exact scenario the
# review proved broken — unconditional `value = null` fact outputs terranix
# stripped down to value-less outputs OpenTofu rejects ("Missing required
# argument: value"). A clean plan here is the regression proof.
#
# The config under test is the terranix render of ./default.nix (produced into
# this directory as config.tf.json before `tofu test` runs). No credentials, no
# network: mock_provider + command = plan. Absence of the fact outputs from the
# rendered config is asserted separately (jq) by the gate script, since a tofu
# condition cannot reference an output that does not exist.
mock_provider "github" {}

run "t_actions_secrets_org_scope_repo_only" {
  command = plan

  # The repo secret still renders — the config is real, not empty.
  assert {
    condition     = github_actions_secret.secret_example-org_infra_REPO_SECRET.repository == "infra"
    error_message = "repository secret must still render for a repo-only caller"
  }

  # The always-present outputs survive even when the fact outputs are dropped.
  assert {
    condition     = output.managed_secret_count == 1
    error_message = "managed_secret_count must remain present and count the one repository secret"
  }
  assert {
    condition     = output.managed_org_secret_count == 0
    error_message = "managed_org_secret_count must remain present and be zero"
  }
  assert {
    condition     = output.github_owner == "example-org"
    error_message = "github_owner must remain present for a repo-only caller"
  }
  assert {
    condition     = output.github_bootstrap_state_key == "bootstrap/github/example-secrets.tfstate"
    error_message = "github_bootstrap_state_key must remain present for a repo-only caller"
  }
}
