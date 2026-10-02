# Shared AWS Terraform bootstrap

Company-agnostic **Layer-0** bootstrap for an AWS-backed Terraform operating
layer. Human-applied once per account, out-of-band, and never part of the
CI-managed state. Extracted verbatim from a production bootstrap;
only the identifiers are parameters now.

## `tf-bootstrap.nix`

A Terranix module that provisions the foundation the reusable CI workflow
depends on:

- the remote state **S3 bucket** (versioned, encrypted, public-access-blocked,
  with a bucket policy scoping the managed/sensitive state prefixes),
- the **DynamoDB lock table**,
- the GitHub **OIDC provider** and the `PLAN` / `APPLY` / `DRIFT` **IAM roles**
  (trust scoped to the repo/branch/environment), plus their policies,
- the MFA-gated **break-glass** administrator role. It is not CI machinery, but
  CI must not be able to write it: a CI-writable role holding
  `AdministratorAccess` would let CI make itself administrator.

That is all of Layer 0: the infrastructure of running `plan` and `apply` in CI.
The monthly budget, the cost-allocation tags and the cost categories used to be
rendered here too. They are account governance, so each consumer now declares
them in its CI-applied account root (`terraform/aws/<namePrefix>`). Their old
addresses are emitted as `removed` blocks (`destroy = false`), so bumping a
consumer's pin forgets them without touching AWS. Import them into the account
root **first**, then bump. See metacraft-pm
`infrastructure/terraform-bootstrap-boundary.md`.

### Parameters

All identifiers are per-repo — two repos may point at the same AWS account
today yet each keeps its own variables, so either can move to a separate
account later without touching the other.

| Param                                | Example                                                                    |
| ------------------------------------ | -------------------------------------------------------------------------- |
| `awsAccountId`                       | `"000000000000"`                                                           |
| `awsRegion`                          | `"us-east-1"`                                                              |
| `budgetAlertEmails`                  | retired; accepted and ignored                                              |
| `githubOwner` / `githubRepo`         | `"example-org"` / `"infra"`                                                |
| `githubBranch` / `githubEnvironment` | `"live"` / `"production"`                                                  |
| `lockTableName`                      | `"example-prod-tofu-locks"`                                                |
| `namePrefix`                         | `"example-prod"` (state keys, role/ARN patterns)                           |
| `orgLabel`                           | `"Example"` (PascalCase infix for Sids and the break-glass role)          |

### Usage

A consumer's `bootstrap/aws/<name>/default.nix` becomes a thin caller:

```nix
import "${inputs.nixos-modules}/terraform/aws/tf-bootstrap.nix" {
  awsAccountId = "…";
  awsRegion = "us-east-1";
  githubOwner = "…";
  githubRepo = "infra";
  githubBranch = "live";
  githubEnvironment = "production";
  lockTableName = "…-tofu-locks";
  namePrefix = "…-prod";
  orgLabel = "…";
}
```

See [`example.nix`](./example.nix).

### Verifying an extraction is a no-op

When repointing an existing bootstrap at this module, prove the rendered
Terraform is unchanged before applying — the module is value-independent, so
identical inputs yield identical output:

```bash
# before: render the original default.nix
nix eval --json --impure --expr '(import ./default.nix) {}' | jq -S . > before.json
# after: render the module with the same values
nix eval --json --impure --expr 'import "${nixos-modules}/terraform/aws/tf-bootstrap.nix" { … }' | jq -S . > after.json
diff before.json after.json   # empty == zero plan diff == safe
```

`tests/test-render.sh` renders the example offline and checks the Layer-0
resources are present with no company-specific leakage.
