# Current Cachix Deployment Flow

The current production-capable deploy path is the reusable GitHub Actions
workflow documented in [current-flow-inventory.json](current-flow-inventory.json).
As of c056211 the in-CI Cachix Deploy activation was removed: the
`run-cachix-deploy` gate, the `mcl-devops deploy-spec` activation step, and all
`CACHIX_*` workflow inputs no longer exist. A single `push-deployment-caches`
gate now controls deployment-closure publication to the Attic deployment cache
backend, and activation is performed out-of-band by an operator via
`mcl-devops deploy-ssh` / `mcl-devops deploy-reconcile`.

## CI Flow

1. `compute-mcl-ref` computes the reusable workflow revision and exposes an
   `mcl-devops` command such as `nix run ...#mcl-devops`.
2. `shard-matrix` runs `mcl-devops shard-matrix` to discover systems and shard work.
3. `eval-matrix` runs `mcl-devops ci-matrix --flake-attribute-path ... --is-initial`
   for each evaluation shard and uploads matrix artifacts.
4. `merge-matrices` runs `mcl-devops merge-ci-matrices` and publishes the merged
   package table.
5. `build` runs `nix build -L --no-link --keep-going --show-trace
'.#${{ matrix.attrPath }}'` for each matrix item.
6. When `inputs.push-deployment-caches` is true, `build` runs
   `mcl-devops cache push-closure` for each deployment target and the configured
   `deployment-cache-push-backends` (`attic` by default, with `none` as the
   only non-Attic option), using the Attic CI transport (`--transport
attic-ci`).
7. `results` runs on the JSON-encoded `results-runner` input, which defaults
   to self-hosted Linux fleet runner labels. It prints the final matrix and
   updates the pull request comment.
8. There is no longer an in-CI activation step. The removed `run-cachix-deploy`
   gate and `mcl-devops deploy-spec` step have no replacement in the workflow;
   activation happens out-of-band via `mcl-devops deploy-ssh` / `mcl-devops deploy-reconcile`.

## Target Activation Flow

In-CI activation was removed in c056211. The workflow no longer evaluates a
deploy spec, no longer writes a `cachix-deploy-spec.json`, and no longer runs
`cachix deploy activate`. The reusable workflow now stops at building and (when
`push-deployment-caches` is enabled) publishing deployment closures to the Attic
deployment cache.

Activation is performed out-of-band by an operator after CI publishes the
closure. The supported activation paths are:

- `mcl-devops deploy-ssh` for a supervised, signed, forced-command SSH push to a
  single target; and
- `mcl-devops deploy-reconcile` for the state-directory reconciler / pull-agent path.

A manual `cachix deploy activate` fallback remains available to operators only
as an explicit rollback window during the operational retirement; it is not part
of the CI workflow. The new paths emit a deployment event stream so target-side
restore, switch, generation number, health-check, and rollback status are
captured — gaps the previous Cachix Deploy path left outside the workflow.

## Deployment Inputs

| Input                | Current source                                                                                      | Notes                                                                                       |
| -------------------- | --------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| Flake attr           | Build matrix `matrix.attrPath`                                                                      | Out-of-band activation selects the desired system path explicitly.                          |
| Target machine       | Build matrix `matrix.name` (deployment target name)                                                 | Must match the target-side reconciler / SSH apply identity.                                 |
| Store path           | Build matrix `matrix.output`                                                                        | Expected to be a NixOS system toplevel.                                                     |
| Closure size         | Not recorded by the workflow today                                                                  | M1+ event emission should record closure count and bytes.                                   |
| Attic cache          | GitHub variables `ATTIC_CACHE`, `ATTIC_SUBSTITUTER`, `ATTIC_TRUSTED_PUBLIC_KEY`                     | Used when `deployment-cache-push-backends` includes `attic`.                                |
| Substituters         | GitHub variable `SUBSTITUTERS` plus default cache URLs supplied to `mcl-devops`                     | Used for Nix setup and cache-status checks.                                                 |
| Trusted public keys  | GitHub variable `TRUSTED_PUBLIC_KEYS`                                                               | Required for substituter trust on runners.                                                  |
| Results runner       | Workflow input `results-runner`, JSON default `["self-hosted", "nixos", "x86-64-v2", "bare-metal"]` | Keeps deploy orchestration on self-hosted runners by default.                               |
| Deploy token         | Removed in c056211 (`CACHIX_ACTIVATE_TOKEN` no longer passed to CI)                                 | There is no in-CI activation step; activation is out-of-band.                               |
| Cache push token     | Secret `ATTIC_TOKEN`                                                                                | Used by Attic cache pushes and cache-status checks; `CACHIX_AUTH_TOKEN` removed in c056211. |
| Source access tokens | `NIX_GITHUB_TOKEN`, `NIX_GITLAB_TOKEN`, `NIX_GITLAB_DOMAIN`                                         | Used by Nix access-token setup.                                                             |
| Health checks        | Not modeled in the reusable workflow                                                                | Future events should model check command, timeout, attempts, and result.                    |

## Current Cachix Deploy Monitoring Path

The existing monitoring path is implemented by the following sources:

- `metacraft-labs/infra/services/monitoring/cachix-deploy-metrics/default.nix`
- `modules/cachix-deploy-metrics/default.nix`
- `packages/cachix-deploy-metrics/default.nix`
- `packages/cachix-deploy-metrics/main.d`

The infrastructure service imports the shared NixOS module and enables
`services.cachix-deploy-metrics`. Its current configuration binds the exporter
on all addresses, reads the Cachix API token through `auth-token-path`, passes a
Cachix Deploy `workspace`, and derives `agent-names` from the server machine
directories under the infrastructure tree. Concrete private workspace and host
names are kept in the private infrastructure repository, not in this shared repo.

The shared NixOS module turns that configuration into the
`cachix-deploy-metrics` systemd service. The service is a Prometheus exporter:
it runs the packaged binary with `--port`, `--bind-addresses`,
`--scrape-interval`, `--auth-token-path`, `--workspace`, and `--agent-names`,
then serves Prometheus text format at `/metrics`. The module default port is
`9160`; the observed infrastructure service inherits that port and sets a
one-second scrape interval through the module default.

The package builds the D exporter from `packages/cachix-deploy-metrics/main.d`.
The exporter reads the token either from `--auth-token` or `--auth-token-path`,
then polls the Cachix Deploy API endpoint
`https://app.cachix.org/api/v1/deploy/agent/<workspace>/<agent>`. It maps the
API `lastDeployment` state into these metrics:

- `cachix_deploy_status`
- `cachix_deploy_counter`
- `cachix_deploy_last_started_time`
- `cachix_deploy_last_finished_time`
- `cachix_deploy_in_progress_duration_seconds`

This path observes Cachix Deploy API state for the last deployment per agent.
It does not consume the new M0 deployment event stream, target journald,
switch-to-configuration logs, health-check output, rollback evidence, or a
cross-system correlation id. Those gaps are why later milestones need event and
desired-state status artifacts rather than relying on the current exporter
alone.

## Observability Gaps

- The current workflow reports build and cache-push status but not target
  restoration, switch, generation number, health-check, or rollback state.
- `cachix deploy activate --async` returns before target activation completes.
- Target-side failure details remain outside the workflow unless an operator
  separately checks agent logs.
- The current Cachix Deploy metrics exporter observes Cachix Deploy API status
  only; it is not fed by the new event stream.
- There is no deployment correlation id propagated through the workflow,
  `mcl-devops`, target logs, metrics, and status artifacts.
