# GitHub Secret Rotation

Company-agnostic pattern for rotating the GitHub Actions secrets managed by the
[governance engine](../terraform/github/README.md). Each infra repo keeps its own
**source manifest** (`secrets/manifest.nix` — the concrete secret set) and a thin
overlay runbook; this doc is the reusable procedure they link to.

## Age file layout

Every managed secret has an agenix `.age` source, keyed by scope:

```text
secrets/actions/org/<NAME>.age                     # organization secret
secrets/actions/repos/<repo>/<NAME>.age            # repository secret
secrets/actions/repos/<repo>/environments/<env>/<NAME>.age   # environment secret
```

Recipients are defined in `secrets/secrets.nix` (the operator/host keys that may
decrypt). Plaintext values live only in these `.age` files — never in Terraform
state, never on the command line.

## Rotation order

1. **Intake** — place the new plaintext into the `.age` file with
   `github-secret-rotation-intake` (writes/verifies the encrypted file; never
   prints the value).
2. **Render** — regenerate the GitHub-encrypted payloads with
   `github-governance-secrets-render`, updating `secrets/payloads.generated.nix`
   and `secrets/managed.generated.nix`. The render seals each value against the
   target's public key via `gh secret set --no-store` (libsodium sealed-box) —
   the plaintext never enters the process table.
3. **Apply** — land the regenerated payloads through the normal governance
   PR/plan/apply path. The secret resource updates in place; the old value is
   overwritten atomically.

## Just target contract

Each repo exposes the same targets (thin wrappers over the shared tooling):

- `github-secret-rotation-plan` — read-only Markdown table grouped by
  `rotationGroup`.
- `github-secret-consumer-matrix` — which secret feeds which repo/workflow.
- `github-secret-rotation-intake` — create/verify the replacement `.age` file.
- `github-governance-secrets-render` — render the encrypted payloads.
- `github-secret-rotate` — issuer-aware dispatcher for credentials that must also
  be rotated at their source (the issuer handlers are per-repo data).

## Verification

After rotation, confirm:

- `github-secret-rotation-plan` shows the secret's `rotationStatus` cleared.
- The governance plan shows an in-place update (0 destroy/replace) for the secret
  resource, matching the [import-phase](./Terraform-Import-Phase.md) safety
  posture.
- Consumers still authenticate (trigger the dependent workflow or check its next
  scheduled run).
