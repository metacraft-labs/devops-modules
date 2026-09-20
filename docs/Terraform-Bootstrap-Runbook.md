# Terraform Layer-0 Bootstrap Runbook

The org-admin procedure for standing up a consumer repo's **Layer 0** — the
infrastructure the CI/CD pipeline depends on to run. Per the
[methodology](./Terraform-Agent-Development-Methodology.md#bootstrap-layer-separation),
Layer 0 (the remote-state bucket + lock table, the CI OIDC provider and
plan/apply/drift roles, the GitHub Environment / branch protection / CI
variables and secrets, and the break-glass role) is **applied manually by a
human admin, never through the pipeline it enables** — a faulty pipeline change
must never be able to destroy or weaken the pipeline's own foundation.

Both the AWS and GitHub sides are Layer 0. They live under `bootstrap/` (excluded
from CI triggers, CODEOWNERS-gated) and use the shared drivers in this repo:
`terraform/aws/aws-bootstrap` and `terraform/github/github-bootstrap`. Each
consumer repo wraps them in thin `just` targets.

Keep this layer **small**. Manual apply is the cost of being the root of trust,
not a general-purpose escape hatch, and every root parked here is a root that
never gets a plan comment, a drift check, or a reviewed diff. If a root would
not take the pipeline down when applied badly, it is Layer 1+ and belongs under
`terraform/` — see
[root layering](./Terraform-Root-Layering.md#which-layer-a-root-belongs-to).
GitHub **org governance** in particular is Layer 1+: only the Actions secrets
the pipeline authenticates with are Layer 0.

This runbook uses placeholders — substitute your repo's values:

- `<name>` — the bootstrap root name (e.g. the org-prefixed `…-prod`).
- `<repo>` — `owner/repo` of the infra repo.
- `<admin-profile>` — an AWS CLI profile with admin on the target account.

## Prerequisites

- The repo dev shell (`nix develop`) — provides `terranix`, `opentofu`, the AWS
  CLI, `gh`, and `jq` at pinned versions.
- An authenticated `<admin-profile>` for the **target AWS account** (the account
  the bootstrap is pinned to). `aws-bootstrap` refuses to run if
  `aws sts get-caller-identity` does not match the pinned `awsAccountId`.
- For the GitHub side: `gh` logged in (or `GITHUB_TOKEN`) with repository-admin
  and org permissions.

## 1. AWS Layer 0

1. **Pin the account and facts.** In `bootstrap/aws/<name>/default.nix`, set the
   real `awsAccountId`, `awsRegion`, and `budgetAlertEmails`, and commit. The
   account guard compares this tracked value against STS and refuses any other
   account.

2. **Offline check (no credentials):**

   ```bash
   just bootstrap-offline aws/<name>
   ```

   Renders the root and runs `tofu fmt`/`validate`/`test` with mock providers.

3. **Plan and apply (credentialed):**

   ```bash
   export AWS_PROFILE=<admin-profile>
   just aws-bootstrap-plan aws/<name>
   just aws-bootstrap-apply aws/<name>
   ```

   The **first** apply starts with **local state** (the S3 bucket does not exist
   yet). After the bucket and lock table exist, the apply step rewrites the
   non-secret backend files — one `backends/*.hcl` per managed root discovered
   under `terraform/`, plus the bootstrap root's own backend — then migrates the
   bootstrap state to `bootstrap/aws/<name>.tfstate`.

4. **Commit the generated backends** before expecting CI to plan/apply managed
   roots:

   ```bash
   git add backends/ && git commit -m "chore(bootstrap): generated backend configs"
   ```

Recovery:

- State migration interrupted → `just aws-bootstrap-migrate-state aws/<name>`.
- Review outputs (bucket, state keys, OIDC provider, role ARNs) →
  `just aws-bootstrap-outputs aws/<name>`.
- Verify the apply role's scoped managed-IAM policy is live →
  `just aws-bootstrap-managed-iam-status aws/<name>`.

Adding another managed root under `terraform/` does **not** require reapplying
the AWS IAM bootstrap — the OIDC roles are scoped to the `terraform/` state
prefix, and `sync-backend` regenerates its `backends/*.hcl`.

## 2. GitHub Layer 0

Run **after** the AWS bootstrap (GitHub state lives in the shared S3 backend).

1. **Plan and apply the CI-enabling repo settings** — the `production`
   Environment (the apply credential boundary), deploy-branch protection, the
   OIDC role-ARN Actions variables, CODEOWNERS, and safety labels:

   ```bash
   just github-bootstrap-plan github/<name>
   just github-bootstrap-apply github/<name>
   ```

2. **Governance-secrets root (if present).** The two `GH_GOVERNANCE_APP_*`
   secrets — and the CI agenix key alongside them — are bootstrapped with a
   targeted, confirmation-gated plan so normal governance CI can authenticate
   with the dedicated GitHub App. This root holds _only_ those credentials; the
   org governance model itself is a managed root under `terraform/github/` and
   is never applied from here:

   ```bash
   just github-governance-app-secrets-plan
   just github-governance-app-secrets-apply   # prompts for explicit confirmation
   ```

Only after this is `<branch>` protected and the `production` Environment allowed
to deploy from it. The AWS apply-role trust policy requires the `production`
Environment OIDC subject; keep the general deploy step disabled until the rest
of the pipeline is ready.

## Break-glass

Emergency manual applies require an authorized human with MFA (the break-glass
role, credentials in a vault — never in CI). Record: timestamp, actor, reason,
exact command, plan summary, follow-up PR URL. Open a reconciliation PR within
five business days so restored CI does not revert the manual change — recovery
is always roll-forward (Terraform has no native rollback).
