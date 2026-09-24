# Nixos-Modules

This repository contains a collection of Nix packages and NixOS modules, commonly used by the Metacraft Labs development team.

## Documentation

- [Shard Splitting Architecture](docs/shard-splitting-architecture.md) — Distributed CI/CD evaluation with the `shardSplit` flake module

## GitHub Workflows

### CI Workflow

To use this repo's CI workflow, add the following to your repository:

```yml
jobs:
  call-ci:
    uses: metacraft-labs/devops-modules/.github/workflows/ci.yml@dev
    secrets: inherit
```

### Reusable Workflows

The following reusable workflows are available in `.github/workflows/`:

#### [`reusable-flake-checks-ci-matrix.yml`](.github/workflows/reusable-flake-checks-ci-matrix.yml)

Runs flake checks with shard-based parallelization. See [Shard Splitting Architecture](docs/shard-splitting-architecture.md).

```yml
jobs:
  ci:
    uses: metacraft-labs/devops-modules/.github/workflows/reusable-flake-checks-ci-matrix.yml@dev
    secrets:
      ATTIC_TOKEN: ${{ secrets.ATTIC_TOKEN }}
    with:
      runners: | # json
        {
          "x86_64-linux": ["self-hosted", "nixos", "x86-64-v3", "bare-metal"],
          "aarch64-darwin": ["self-hosted", "macOS", "aarch64-darwin"]
        }
      # JSON-encoded runner for Final Results and deploy orchestration.
      # Defaults to the off-target GitHub-hosted runner "ubuntu-latest".
      results-runner: '"ubuntu-latest"'
```

#### [`reusable-lint.yml`](.github/workflows/reusable-lint.yml)

Runs pre-commit hooks for linting and formatting checks. Before the hooks run
it initializes git submodules (`submodules: auto`) and materializes the repo's
reprobuild develop set — the sibling repos its committed `repro.lock` pins, at
the pinned revisions, placed where `repro develop` would place them
(`develop-set: auto`). Set either input to `off` to skip it.

```yml
jobs:
  lint:
    uses: metacraft-labs/devops-modules/.github/workflows/reusable-lint.yml@dev
    secrets:
      NIX_GITHUB_TOKEN: ${{ secrets.NIX_GITHUB_TOKEN }}
```

#### [`reusable-merge.yml`](.github/workflows/reusable-merge.yml)

Merges a source branch into a target branch with `--no-ff` and pushes the result.

```yml
jobs:
  promote:
    uses: metacraft-labs/devops-modules/.github/workflows/reusable-merge.yml@dev
    with:
      source_branch: main
      target_branch: testnet
```

#### [`reusable-nix-diff.yml`](.github/workflows/reusable-nix-diff.yml)

On pull requests, builds every machine under a flake attribute on both the PR and a synthetic base branch and comments the derivation diff.

```yml
jobs:
  nix-diff:
    uses: metacraft-labs/devops-modules/.github/workflows/reusable-nix-diff.yml@dev
    secrets:
      NIX_GITHUB_TOKEN: ${{ secrets.NIX_GITHUB_TOKEN }}
    with:
      # Flake attribute to enumerate machines (must be an attrset of derivations)
      machines-attr: legacyPackages.x86_64-linux.bareMetalMachines
```

#### [`reusable-recorder-ci.yml`](.github/workflows/reusable-recorder-ci.yml)

Shared lint-and-test CI for the CodeTracer recorder fleet: `setup-dev-env`, an optional recorder-specific `just` prep recipe (`prepare-recipe`), then `just lint` / `just test`, with failure logs uploaded to GitHub and mirrored to the S3 artifact store.

```yml
jobs:
  ci:
    uses: metacraft-labs/devops-modules/.github/workflows/reusable-recorder-ci.yml@dev
    secrets: inherit
```

#### [`reusable-terraform-ci.yml`](.github/workflows/reusable-terraform-ci.yml)

Terraform/OpenTofu CI for a single root, in one of three modes: `pr` (offline checks + plan), `apply` (apply on merge), `drift` (scheduled drift check). It has a large input surface (backends, credential modes, Checkov, smoke tests); see [`terraform/ci/README.md`](terraform/ci/README.md) for the root `metadata.json` contract and the `terraform-ci-matrix` generator that feeds it.

```yml
jobs:
  terraform:
    uses: metacraft-labs/devops-modules/.github/workflows/reusable-terraform-ci.yml@dev
    secrets:
      AGENIX_CI_PRIVATE_KEY: ${{ secrets.AGENIX_CI_PRIVATE_KEY }}
      NIX_GITHUB_TOKEN: ${{ secrets.NIX_GITHUB_TOKEN }}
    with:
      mode: pr
      working_directory: cloudflare
```

Large Nix closures can opt into `reclaim_hosted_runner_disk: true` when the
selected runner is standard GitHub-hosted Linux. Before installing or invoking
Nix, Setup Nix removes only its fixed preinstalled-tool allowlist and fails if
the runner identity is different or less than 20 GiB remains. The input
defaults to `false`; do not enable it for self-hosted or non-Linux runners.

#### [`reusable-update-flake-lock.yml`](.github/workflows/reusable-update-flake-lock.yml)

Updates `flake.lock` and creates a PR. Supports GPG-signed commits.

```yml
jobs:
  update-flake-lock:
    uses: metacraft-labs/devops-modules/.github/workflows/reusable-update-flake-lock.yml@dev
    secrets:
      CREATE_PR_APP_ID: ${{ secrets.APP_ID }}
      CREATE_PR_APP_PRIVATE_KEY: ${{ secrets.APP_PRIVATE_KEY }}
      NIX_GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
      GIT_GPG_SIGNING_SECRET_KEY: ${{ secrets.GIT_GPG_SIGNING_SECRET_KEY }}
    with:
      runner: '["self-hosted", "Linux", "x86-64-v2"]'
      sign-commits: true
```

#### [`reusable-update-flake-packages.yml`](.github/workflows/reusable-update-flake-packages.yml)

Updates individual flake packages using [`nix-update-action`](https://github.com/metacraft-labs/nix-update-action) and creates PRs.

```yml
jobs:
  update-packages:
    uses: metacraft-labs/devops-modules/.github/workflows/reusable-update-flake-packages.yml@dev
    secrets:
      CREATE_PR_APP_ID: ${{ secrets.APP_ID }}
      CREATE_PR_APP_PRIVATE_KEY: ${{ secrets.APP_PRIVATE_KEY }}
```

## MCL CLI Tool

The `mcl-devops` tool is a Swiss-knife CLI for managing NixOS deployments. For development best practices, see [packages/mcl-devops/AGENTS.md](packages/mcl-devops/AGENTS.md).

### Available Commands

| Command             | Description                                                                                                              |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `host-info`         | Returns system information (OS, BIOS, CPU, GPU, RAM, disks) as JSON                                                      |
| `hosts`             | Remote host management and network scanning                                                                              |
| `ci`                | Evaluates packages and compares to cached versions                                                                       |
| `ci-matrix`         | Print a table of the cache status of each package                                                                        |
| `print-table`       | Print a table of the cache status of each package                                                                        |
| `merge-ci-matrices` | Merge downloaded `matrix-pre.json` artifacts and emit GitHub outputs                                                     |
| `shard-matrix`      | Splits packages into shards for distributed CI. See [Shard Splitting Architecture](docs/shard-splitting-architecture.md) |
| `cache`             | Operate on deployment cache backends                                                                                     |
| `deploy-spec`       | Deploys machine specs to Cachix                                                                                          |
| `deploy-plan`       | Create a signed desired-state deployment manifest                                                                        |
| `deploy-apply`      | Target-side signed deployment apply wrapper                                                                              |
| `deploy-agent`      | Target-side pull agent for signed desired-state manifests                                                                |
| `deploy-reconcile`  | Converge signed desired-state deployments with latest-only semantics                                                     |
| `deploy-ssh`        | Direct one-target SSH deployment backed by `deploy-reconcile`                                                            |
| `deploy-status`     | Inspect deployment event logs                                                                                            |
| `machine`           | Create and manage NixOS machine configurations                                                                           |
| `config`            | Manage NixOS machine configurations (system, home, VM)                                                                   |
| `secret`            | Manage age-encrypted secrets for NixOS machines                                                                          |

Run `mcl-devops --help` or `mcl-devops <command> --help` for usage details, subcommands, and environment variables.
