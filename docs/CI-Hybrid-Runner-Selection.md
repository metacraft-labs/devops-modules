# Hybrid free/self-hosted CI — runner selection (RD2 + RD3)

Part of the **Runner-Fleet-Capability-Pools-And-Remote-Driving** campaign,
Phase D (hybrid free/self-hosted CI + $0 budget). This document covers the two
GENERAL, company-agnostic pieces that live in `nixos-modules`, and the rollout
to consumer repos.

## Billing model (why this exists)

- **Public repos**: standard GitHub-hosted runners (`ubuntu-latest`,
  `windows-latest`, `macos-latest` + pinned versions) are **free and
  unlimited**. Self-hosted is free too. The **only** way a public repo incurs
  charges is a **larger or GPU** hosted runner — those bill from minute 0, and
  under the $0 org budget (RD1) they are _blocked_, not billed.
- **Private/internal repos**: a fixed monthly _included-minutes_ pool (Team
  org = 3,000; Enterprise = 50,000, **pooled across every org of the
  enterprise**). Since GitHub's enhanced-billing platform the pool is a
  **dollar** allowance — included minutes × the Linux 2-core price ($0.006) —
  drawn down by each SKU's gross price (Windows ≈1.67×, macOS ≈10.3× a Linux
  minute), not by the old 1×/2×/10× multipliers. Measured on live data
  2026-09: the schelling-point-labs pool stopped jobs at $300.87 gross after
  34,005 raw minutes (a 2× Windows multiplier would have exhausted it two days
  earlier), and metacraft-labs stopped at exactly $18.00. Past the pool, the
  **$0 budget hard-stops** hosted jobs — they _fail to start_ ("The job was
  not started because … your spending limit needs to be increased"), never a
  bill.
- **Reading it**: the classic `GET /orgs/{org}/settings/billing/actions`
  endpoint returns **HTTP 410** since the migration. The workflows below read
  the enhanced usage report (`GET /organizations/{org}/settings/billing/usage`,
  or `/enterprises/{ent}/…` for a pooled enterprise) and derive the remaining
  pool as `included − Σ gross(minutes rows not in a public repo) / $0.006` —
  the report's discount column mixes free public-repo usage with pool usage,
  so public repos are excluded by name. The logic is one shared
  `billing_remaining` shell function, kept byte-identical across the three
  workflows (gated by `t_runner_mode_manager`).

The two mechanisms below turn those facts into policy that cannot be violated by
accident.

## RD2 — the billed-runner guard (`t_public_repo_free_ci`)

`scripts/ci/check_public_repo_runners.py` scans a repo's workflows and, on a
**public** repo, **fails** any `runs-on` that names a larger/GPU GitHub-hosted
runner. Standard hosted runners and self-hosted classes pass; on a private repo
it only warns. It resolves `${{ matrix.<key> }}` against `strategy.matrix`, and
treats other `${{ … }}` expressions (e.g. the RD3 `fromJson(...)` chooser
output) as trusted/dynamic.

Wire it into a consumer repo:

```yaml
jobs:
  runner-policy:
    uses: metacraft-labs/devops-modules/.github/workflows/reusable-public-runner-guard.yml@dev
```

The reusable workflow derives visibility from `github.event.repository.private`
and fails **closed** (assumes public) if that is ever unset.

## RD3 — the hybrid preflight (`t_private_repo_hybrid_fallback`)

GitHub has **no** native hosted↔self-hosted fallback, so
`reusable-choose-runner.yml` runs a cheap **preflight** that emits `runs_on`:

1. **Public repo** → always the preferred hosted runner (free).
2. **Private repo, `vars.GH_HOSTED_OK`** (written by the cron below):
   `true` → hosted, `false` → self-hosted. _This is the production default_
   — no per-run billing API call, no admin token in every workflow.
3. **Private repo, `GH_HOSTED_OK` unset + a `billing_token` secret** → a live
   enhanced-billing usage check (`billing_remaining`, see above) against a
   `min_minutes_remaining` buffer; any read failure → self-hosted, never a
   failed preflight. Bootstrap / belt-and-braces.

**Where the preflight runs.** A private repo's hosted job cannot start once the
pool is exhausted, and a preflight that never starts skips every downstream
`needs: choose` job. So `decide` runs on free `ubuntu-latest` only when hosted is
already known affordable from job-level contexts (public repo,
`CI_RUNNER_MODE=github-hosted`, or `CI_RUNNER_MODE` unset with
`GH_HOSTED_OK=true`); otherwise it runs on the self-hosted `preflight_runner`
(default `["self-hosted","linux","x64"]`). The two cron workflows below apply
the same rule to themselves via a `runner` input. 4. **No signal** → self-hosted (fail-safe; never risk a blocked/paid job).

Consumer pattern (with the reactive safety net):

```yaml
jobs:
  choose:
    uses: metacraft-labs/devops-modules/.github/workflows/reusable-choose-runner.yml@dev
    with:
      preferred: ubuntu-latest
      fallback: '["self-hosted","linux","x64"]'

  build:
    needs: choose
    continue-on-error: ${{ fromJson(needs.choose.outputs.hosted) }}
    runs-on: ${{ fromJson(needs.choose.outputs.runs_on) }}
    steps: […]

  build-retry: # RD3 reactive safety net
    needs: [choose, build]
    if: ${{ failure() && fromJson(needs.choose.outputs.hosted) }}
    runs-on: [self-hosted, linux, x64]
    steps: […] # same steps, self-hosted
```

### The cron that writes `GH_HOSTED_OK`

`reusable-sync-hosted-minutes.yml` computes remaining minutes and writes the
`GH_HOSTED_OK` org variable. It is a _reusable_ workflow (`workflow_call`); a
`schedule:` trigger must live in the repo that runs it, so an ops repo wraps it
**once per org**:

```yaml
# ops-repo/.github/workflows/sync-hosted-minutes.yml
name: sync-hosted-minutes
on:
  schedule: [{ cron: '*/30 * * * *' }]
  workflow_dispatch:
jobs:
  sync:
    uses: metacraft-labs/devops-modules/.github/workflows/reusable-sync-hosted-minutes.yml@dev
    with:
      {
        org: metacraft-labs,
        min_minutes_remaining: 300,
        included_minutes: 3000,
      }
    # enterprise-plan org: add `enterprise: schelling-point-labs` and
    # `included_minutes: 50000` (and an enterprise-billing token)
    secrets:
      billing_token: ${{ secrets.ORG_BILLING_READ_TOKEN }}
      variables_token: ${{ secrets.ORG_VARIABLES_WRITE_TOKEN }}
```

## Operator prerequisites

| Item                        | What                                                                                                                                                                                                                                                                                                          | Scope   |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- |
| `ORG_BILLING_READ_TOKEN`    | Reads the enhanced usage report (`/organizations/{org}/settings/billing/usage`) + the org's public-repo list. Classic PAT `admin:org`, or a GitHub App install token with org **billing: read**. Enterprise-plan orgs need the **enterprise** report instead: a classic PAT with `manage_billing:enterprise`. | per org |
| `ORG_VARIABLES_WRITE_TOKEN` | Writes the `GH_HOSTED_OK` org variable. Fine-grained token with org **Variables: read/write** (may equal the billing token if it has both).                                                                                                                                                                   | per org |
| Cron wrapper                | One `sync-hosted-minutes.yml` per org (`metacraft-labs`, `blocksense-network`, `agent-harbor`) in an ops repo, on a ~30-min schedule.                                                                                                                                                                         | per org |
| `GH_HOSTED_OK` seed         | Optional: set it to `true` initially so private repos start on hosted before the first cron run.                                                                                                                                                                                                              | per org |
| Verify allowance            | Pass the pool size as `included_minutes`: Team org 3,000; Enterprise 50,000 (pooled — set `enterprise` too); Free 2,000.                                                                                                                                                                                      | per org |
| `$0` budget (RD1)           | The hard guarantee that a wrong estimate can only ever _fail_ a hosted job, never bill. Must be live for all three orgs.                                                                                                                                                                                      | per org |

`GITHUB_TOKEN` **cannot** read billing or write org variables — both dedicated
tokens are required.

## Rollout to the rest of the fleet

Pilot: **`codetracer-test-mirror`** (private, small) — wired end to end
(`choose` + guard + `continue-on-error`/`if: failure()` retry; macOS routed
straight to self-hosted — a macOS minute draws ~10.3× a Linux minute from the pool).

Staged rollout, safest-first — **do not flag-day**:

1. **Land the cron + tokens** for all three orgs and seed `GH_HOSTED_OK=true`.
   Until this exists, the chooser fail-safes every private repo to self-hosted
   (correct, just not yet cost-optimal).
2. **Public repos**: add the `runner-policy` guard job (RD2). It is a pure lint —
   no runner change — so it can land everywhere first. Then move any
   standard-fit public-repo jobs from self-hosted to `ubuntu-latest`; keep on
   self-hosted only the public-repo workflows RD4 fit-monitoring shows do **not**
   fit ubuntu-latest (2–4 vCPU / 14 GB disk).
3. **Private repos**: convert the primary job to the `choose` + `runs-on:
fromJson(...)` + retry pattern, repo by repo, watching RD4 duration/limit
   signals. Route Windows/macOS jobs (2×/10×) straight to self-hosted.
4. **Phase C interaction**: the self-hosted `fallback` labels here are the
   existing single-name classes (`self-hosted, linux, x64` / `eph-*`). When
   Phase C lands capability label sets, update the `fallback` default in
   `reusable-choose-runner.yml` and the consumers to the new label sets.

## Gates

Both live in `nixos-modules/checks/hybrid-ci-runner.nix` and run in the repo's
normal `nix flake check` with **no** infra repo and **no** real GitHub API:

- `t_public_repo_free_ci` — the guard fails billed/GPU public runners, passes
  `ubuntu-latest` (incl. inside a mixed matrix), warns-only on private, honours
  `--billed-label`, and confirms the repo's own reusable workflows are clean.
- `t_private_repo_hybrid_fallback` — extracts the **real** preflight from
  `reusable-choose-runner.yml` and drives all six branches (public; org-variable
  true/false; no-signal; live-check ok/exhausted). The only mock is a stub `gh`
  for the live-billing branch.
