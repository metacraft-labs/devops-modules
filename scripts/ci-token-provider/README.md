# ci-token-provider

Org-agnostic tooling for the "CI token provider" GitHub App pattern: a
GitHub App whose **non-expiring** private key mints **short-lived**
installation tokens on demand, replacing long-lived PATs.

Two halves:

- **Consumption** (in CI): the [`create-app-token`](../../.github/create-app-token/action.yml)
  composite action mints a scoped token from the App ID + private key.
- **Provisioning** (this dir): `configure-github-repo.sh` writes the
  `CI_TOKEN_PROVIDER_APP_ID` / `CI_TOKEN_PROVIDER_PRIVATE_KEY` secrets onto
  a repo, decrypting the key from agenix.

This code carries **no company-specific values**. Each infra repo passes
its own `CTP_APP_ID`, `CTP_KEY_AGE`, `CTP_AGE_IDENTITY`, and repo list
(e.g. via its flake devshell / Justfile, with `nixos-modules` as a flake
input). Terraform-managed infra repos should instead declare the two
secrets via `github_actions_secret` sourced from the same agenix key.
