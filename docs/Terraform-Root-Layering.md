# Terraform Root Layering

Company-agnostic methodology for deciding when Terraform resources belong in one
root and when to split them into a new root. It pairs with the
[methodology](./Terraform-Agent-Development-Methodology.md) and
[testing](./Terraform-Testing.md) docs. Each infra repo adds a thin overlay
(`docs/runbooks/Terraform-Root-Layering.runbook.md`) that lists only its own
current roots, state prefixes, and apply-role boundaries.

## Which Layer a Root Belongs To

This is the first question, and it has a narrow answer. **Layer 0 (`bootstrap/`)
is only what the CI/CD pipeline depends on to run**: the remote-state bucket and
lock table, the OIDC provider and the plan/apply/drift roles, the CI agenix
keypair and the App credentials CI authenticates as, the deploy Environment and
the branch protection that gates apply, and the break-glass role. Those are
applied out-of-band by a human admin precisely because the pipeline cannot be
what provisions its own credentials — see
[Bootstrap layer separation](./Terraform-Agent-Development-Methodology.md#bootstrap-layer-separation).

**Everything else is Layer 1+ and runs through the PR workflow.** Manual apply
is a property of the root-of-trust, not a privilege that attaches to whatever
happens to be important, org-wide, or hard to review. Use this test:

> Would applying this root through CI make it possible for a faulty change to
> destroy the pipeline's ability to run and fix itself?

If no, it is Layer 1+, it lives under `terraform/`, it carries a
`metadata.json`, and it is plan-comment-applied like every other root. Blast
radius alone is not a Layer-0 criterion — a root can be large, org-wide, and
still belong on the PR path; that is what plan review, the sensitive-change
label, and the destroy/replace gates are for.

Two corollaries worth stating, because they are easy to get wrong:

- **GitHub org governance is Layer 1+.** Repositories, teams, memberships,
  team grants, branch protection, rulesets, Environments, Actions
  permissions/variables and labels are org policy, not pipeline plumbing. A
  governance root belongs under `terraform/github/<org>-governance-prod` with
  `credential_mode: "github-app"`. The one genuinely Layer-0 slice — the
  Actions secrets holding the CI App credentials and the CI agenix key — is a
  _separate_, small `bootstrap/` root, so that the pipeline's own credentials
  are never writable by the pipeline.
- **A root does not "graduate" out of `bootstrap/` on maturity.** There is no
  probation period. The only reason a root is ever excluded from the
  steady-state matrix is that it is mid-adoption, and that is expressed by
  `adoption_pending: true` in its `metadata.json` under `terraform/` — not by
  parking it in `bootstrap/`. See the
  [import phase](./Terraform-Import-Phase.md) (M5-M7).

## Root Metadata

Every managed root under `terraform/<provider>/<environment>` must include a
`metadata.json`. The shared `terraform/ci/terraform-ci-matrix` reads it and fails
closed if it is missing or inconsistent (schema:
[`terraform/ci/metadata.schema.json`](../terraform/ci/metadata.schema.json)).

Required fields:

- `state_key`: exact S3 backend key for the root.
- `state_sensitivity`: either `standard` or `sensitive`.
- `backend_config_file`: backend HCL file consumed by CI and operator commands.
- `provider_allowlist`: exact provider sources allowed after Terranix render.
- `credential_mode`: how CI obtains provider credentials.
- `backend_uses_aws_oidc`: optional boolean, defaulting to `false`, that requests
  the reviewed AWS OIDC role independently when the state backend needs it.
- `enable_checkov`: whether the reusable CI workflow should run Checkov.
- `split_boundary`: human-readable lifecycle and access-boundary rationale.

The metadata is deliberately redundant with the backend file. The backend file
drives OpenTofu; the metadata drives review and CI matrix generation.
Provider and backend authentication are separate: for example, a Cloudflare
root can use `credential_mode: "agenix-token"` for the provider and
`backend_uses_aws_oidc: true` for S3 state. The generated `uses_aws_oidc` field
is the combined workflow signal consumers use when selecting AWS plan, apply,
and drift roles. If required provider credential material is absent, the root
remains offline-only even when the backend would otherwise use AWS OIDC.

## State Classes

Standard roots use:

```text
terraform/<provider>/<environment>.tfstate
```

Sensitive roots use:

```text
terraform-sensitive/<provider>/<environment>.tfstate
```

Use `sensitive` when a root stores provider-returned or generated secret
material in state, even if the state bucket is encrypted at rest. S3 encryption
protects stored bytes, but any principal with `s3:GetObject` permission can
receive decrypted state. IAM and OIDC role scope are therefore the real access
boundary.

## Split Criteria

Do not split a root only to make files smaller. Split when at least one of these
is true:

- A component needs a distinct state access boundary.
- A component stores provider-returned or generated secret material in state.
- A component has an independent lifecycle, promotion cadence, or rollback path.
- A component needs different provider credentials or a different apply role.
- A component can be planned and applied independently without ambiguous
  cross-root ordering.

When those criteria are not true, prefer a single root so OpenTofu keeps one
dependency graph, one lock, and one plan.

## Future Split Procedure

Before any stateful resources are moved:

1. Add or update the target root's `metadata.json`.
2. Add the backend file and CI matrix support.
3. Add offline Terranix/OpenTofu tests for the new root.
4. Freeze applies for the affected roots.
5. Move state with reviewed `tofu state mv` or import into the new backend.
6. Confirm the old root does not plan to destroy moved resources.
7. Confirm the new root does not plan to recreate moved resources.
8. Merge only after the PR plan comments match the intended no-destroy migration.

If the split introduces a new sensitive state prefix or a narrower apply role,
the bootstrap IAM change must be reviewed and applied by a human before the
credentialed CI path is enabled (Layer 0 — see the
[bootstrap runbook](./Terraform-Bootstrap-Runbook.md)).
