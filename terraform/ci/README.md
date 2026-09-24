# Shared Terraform CI groundwork

Company-agnostic tooling for the Terraform _operating layer_ every consumer
repo needs to drive infrastructure through the reusable CI workflow
(`.github/workflows/reusable-terraform-ci.yml`). Consumers supply their own
roots, backends, credentials, and identifiers; this directory ships only the
reusable discovery/validation machinery.

## `terraform-ci-matrix`

Discovers managed Terraform roots (any directory under `terraform/` holding a
`metadata.json`), validates each against the shared contract, and emits the
GitHub Actions matrix a repo's thin `terraform.yml` caller feeds into the
reusable workflow.

Unlike a company-specific generator, it hardcodes **no** provider names,
credential paths, or per-root smoke tests — everything comes from each root's
`metadata.json`. A root can be added before its CI keys exist: `agenix-token`
credentials are only emitted once the referenced encrypted secrets are present.

```bash
terraform-ci-matrix --root-dir . --pretty            # local troubleshooting
terraform-ci-matrix --github-output "$GITHUB_OUTPUT" # writes matrix=<json>
```

## `metadata.json` contract

Each managed root carries a `metadata.json` validated against
[`metadata.schema.json`](./metadata.schema.json). Required: `state_key`,
`state_sensitivity` (`standard` | `sensitive`), `backend_config_file`,
`credential_mode` (`aws-oidc` | `agenix-token` | `github-app` | `none`),
`enable_checkov`, `provider_allowlist`. `agenix-token` roots also require
`credentials_env_name` and `agenix_{plan,apply}_secret_path`; `github-app` roots
require `github_app_owner` (the org the per-run installation token is minted
for, exported as `GITHUB_TOKEN`). Optional: `smoke_test_command`,
`split_boundary` (prose; see the root-layering runbook),
`backend_uses_aws_oidc` (default `false`), and `adoption_pending` (default
`false`; while true the root is excluded from the steady-state matrix and
driven by the provider-specific import workflow — see the
[import phase](../../docs/Terraform-Import-Phase.md)). `credential_mode` describes provider
authentication only. Set `backend_uses_aws_oidc` when the state backend also
needs the caller's AWS OIDC role; this permits combinations such as a
Cloudflare provider token from agenix with an S3 state backend. The generated
`uses_aws_oidc` value is the combined workflow signal. If a required agenix
plan/apply key file is absent, the root remains offline-only and the matrix
emits neither provider credentials nor the AWS workflow switch.

The one fixed rule: the state key must match its sensitivity —
`terraform/<config>.tfstate` for `standard`, `terraform-sensitive/<config>.tfstate`
for `sensitive`, where `<config>` is the root path minus the leading
`terraform/`. This keeps sensitive state on an auditable key prefix.

## Apply-time destroy guard

The PR-time gates (`allow-destroy`, `sensitive-change`) judge the plan of the
pull request's own change. An apply on push judges nothing: it applies whatever
the root's plan is at that moment, including changes that landed earlier and
never applied because the pipeline was red or the root was skipped. That is how
a CI-only push re-applied a days-old Cloudflare change on 2026-09-23 and took
an SSO hostname down.

Set `destroy_guard: true` on the apply call. The apply job then runs
`plan-destroy-guard` on the saved plan it is about to execute and refuses any
destroy or replace unless one of these authorizes it:

- `allow_destroy: true` — wire it to an explicit `workflow_dispatch` input;
- a pull request that contains the pushed commit, targets the pushed branch,
  and carries `destroy_label` (default `allow-destroy`, the same label the
  PR-time gate asks for).

A refusal applies nothing, fails the job, and writes the destructive changes to
the step summary. Two shapes get a specific diagnosis, because each has a
zero-downtime fix that is not "approve the destroy":

- **`unmoved-address`** — the same object is destroyed at one address and
  created at another (a resource wrapped in `count`/`for_each`, or renamed).
  Add `moved { from = <old> to = <new> }`. Across resource types (for example
  `cloudflare_record` → `cloudflare_dns_record`), use
  `removed { from = <old> lifecycle { destroy = false } }` plus
  `import { to = <new> id = "<provider id>" }`, which adopts the live object
  without touching it.
- **`dns-replace`** — see the next section.

### Same-name DNS record replacement

`create_before_destroy` cannot help a DNS record: the provider refuses a second
record with the same name (and a CNAME cannot coexist with anything), so a
replace is always delete-then-create — a resolution gap — and if the create
fails the gap is permanent until someone notices. Never let one ride along with
an unrelated apply. Instead:

1. **Prefer not replacing at all.** If only the Terraform address changed, use
   `moved`; if the resource type changed, use `removed` (`destroy = false`) +
   `import`. Both are zero-change for the live record. Land that alone and
   confirm the next plan is empty for the record.
2. **If the provider genuinely forces a replacement** (for example an attribute
   that cannot be updated in place), do it as an attended, two-step change:
   (a) a first PR that only lowers the record's TTL (in-place update), applied
   and allowed to age past the old TTL; (b) a second PR that contains only the
   replacement, labelled `allow-destroy`, applied while someone watches it,
   with the old record's value written in the PR so a failed create can be
   restored by hand (`flarectl`/dashboard) within minutes. Verify resolution
   after the apply (`dig +short <name> @1.1.1.1`).

## Tests

`tests/test-matrix.sh` covers the provider/backend credential matrix and
negative validation directly, without credentials or network.
`tests/test-matrix-mutations.sh` proves that the suite rejects semantic
weakenings. The `terraform-ci-matrix` flake check runs both in a Nix sandbox on
every supported system. `tests/test-plan-destroy-guard.sh` exercises
`plan-destroy-guard` against `tofu show -json`-shaped fixtures, including a
replay of the 2026-09-23 incident; the same flake check runs it.
`tests/test-github-provider-credential-gate.sh` exercises
`github-provider-credential-gate`, including a replay of the 2026-09-24
incident; the same flake check runs it.

## GitHub provider credential gate

The `integrations/github` provider does not fail when it has no credential: it
tries `gh auth token`, then runs anonymously (60 requests/hour per source IP),
and answers every primary rate-limit 403 by sleeping until the reset and
retrying, logging only at WARN. A governance root refreshes hundreds of objects,
so an uncredentialed plan sleeps for hours with no output. On 2026-09-24 that
happened to a caller that forwarded its matrix row without `github_app_owner`
and the `GH_APP_*` secrets.

`github-provider-credential-gate` runs before init in the plan, apply and drift
jobs. It refuses a root whose `metadata.json` says `credential_mode: github-app`
when the caller passed no `github_app_owner`, and any root whose `github`
provider has neither `token` nor `app_auth` while `GITHUB_TOKEN` is empty.
Callers with a `github-app` root must pass:

```yaml
with:
  github_app_owner: ${{ matrix.github_app_owner }}
secrets:
  GH_APP_ID: ${{ secrets.GH_GOVERNANCE_APP_ID }}
  GH_APP_PRIVATE_KEY: ${{ secrets.GH_GOVERNANCE_APP_PRIVATE_KEY }}
```

The credentialed PR plan and the drift plan are also bounded by
`plan_timeout_minutes` (default 60), and the PR plan streams its stdout to the
job log, so any other stall fails visibly instead of holding a runner.
