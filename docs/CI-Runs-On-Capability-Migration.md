# Migrating `runs-on` to Capability Label Sets (RC4)

Campaign: **Runner-Fleet-Capability-Pools-And-Remote-Driving**, milestone **RC4**
(gate `t_ci_runs_on_capability`). This guide is for **consumer repos** moving
their CI off the legacy single-name `eph-<os>-<arch>` runner classes and onto the
RC1 **capability label sets**.

## Why

The single-name class scheme (`runs-on: eph-linux-x64`) pins a job to one
hand-maintained class — effectively one machine — even when any number of hosts
could serve it. That is the **starvation-amplifier**: a job queues behind its
one class while the rest of the fleet sits idle.

Under the [capability-label taxonomy](../../metacraft-dev-guidelines/policies/ci-workflow-standards.md#capability-label-taxonomy-versioned)
a job requests the **minimum capabilities it needs** as a label set, and **any**
runner advertising a superset serves it:

```yaml
# generic Linux — served by any self-hosted Linux x64 host in the fleet
runs-on: [self-hosted, linux, x64]
```

A runner's advertised labels are **derived from real hardware** (the RA6 signed
capability manifest), not from a name a human keeps in sync.

## The migration table

Each retired class maps to a **minimum** label set. Add a micro-arch level or a
capability **only if the job genuinely needs it** (see
[Justifying a narrowing capability](#justifying-a-narrowing-capability)):

| Retired class (`runs-on: <name>`) | Capability label set (`runs-on: [ … ]`) | Notes                                                                                         |
| --------------------------------- | --------------------------------------- | --------------------------------------------------------------------------------------------- |
| `eph-linux-x64`                   | `[self-hosted, linux, x64]`             | add `x86-64-v3` only if the job needs AVX2/v3                                                 |
| `eph-linux-x64-gpu` / `-gpu-2`    | `[self-hosted, linux, x64, gpu]`        | genuine GPU jobs keep `gpu` and stay pinned to the 2-slot GPU fleet                           |
| `eph-linux-x64-g1` / `-g2`        | `[self-hosted, linux, x64]`             | general-purpose scale sets on the GPU hosts; jobs don't need a GPU, so they move off (op #50) |
| `eph-linux-x64-nested`            | `[self-hosted, linux, x64]`             | container runtimes and nested VMs are universal across the fleet — no extra label (see below) |
| `eph-linux-arm64`                 | `[self-hosted, linux, arm64]`           |                                                                                               |
| `eph-macos-arm64`                 | `[self-hosted, macos, arm64]`           |                                                                                               |
| `eph-win-x64`                     | `[self-hosted, windows, x64]`           |                                                                                               |
| `eph-win-arm64`                   | `[self-hosted, windows, arm64]`         |                                                                                               |

During RC5 the old class names stay live as **aliases**, so an unmigrated repo
keeps working; they are withdrawn once the fleet runs entirely on pool+label
runners. A `runs-on` label that matches no runner **queues forever** rather than
failing, so migrate before the aliases are withdrawn.

## How to migrate a consumer repo

### 1. Run the codemod (mechanical rewrite)

From a clone of `nixos-modules`, point the codemod at the consumer repo's
workflows. It is dry-run by default:

```bash
python3 scripts/ci/codemod_runs_on_labels.py <consumer>/.github/workflows
# review the diff, then apply:
python3 scripts/ci/codemod_runs_on_labels.py --write <consumer>/.github/workflows
```

It rewrites every `eph-*` class token — a `runs-on:` scalar, a quoted JSON
matrix default, or a bare list item — to its migration-table label set. It never
**adds** a narrowing capability, so a job that truly needs `gpu`/`x86-64-v3`
still needs that label added by hand (next step).

### 2. Add + justify any genuinely-needed capability

If a job really needs a narrowing capability, add the label **and** declare why
with a file-scoped `# cap-justify:` comment (mirroring the `ci-mainline-exempt`
precedent in the policy):

```yaml
# cap-justify: gpu (Vulkan visual-replay tests need a real GPU)
# cap-justify: x86-64-v3 (AVX2 codepath under test)
jobs:
  visual-replay:
    runs-on: [self-hosted, linux, x64, gpu]
```

The narrowing labels are: `gpu`, `rr-hw-counters`, `benchmark`, `x86-64-v2/v3/v4`,
and the hypervisor labels `incus`/`libvirt`/`hyperv`/`tart`. Prefer requesting
the **capability** (`gpu`), not the **mechanism** that provides it (`incus`).

**Container and nested-VM support are universal, not routing labels.** Every
runner in the fleet can run Docker/Podman containers and boot nested VMs, so
`docker`, `podman`, and `nested` are **not** targetable capability labels — do
not add them to a `runs-on` array. A job needing a container runtime or a nested
VM simply targets the OS/arch it needs and uses containers/nested virt directly.
(They were narrowing labels in an earlier draft of the taxonomy and were removed
once every runner image gained universal container + nested-VM support.)

Provider-admin controls that make these universal guest capabilities available
are deployment plumbing, not runner-selection labels. For a pool backed by a
remote Incus provider, the fleet operator must opt that provider into
`remote.incusNestedKvm`; the shared provider then passes only vm-harness's fixed
`--incus-nested-kvm` contract. Without that operator setting the guest receives
no `/dev/kvm`. Nested Docker similarly requires the separate
`remote.incusSecurityNesting` operator grant. Workflows cannot set either value.

### 3. Lint (the over-constrained checker)

Fail CI on any over-constrained `runs-on` — a bare class name that should be a
label set, or an unjustified narrowing capability:

```bash
python3 scripts/ci/check_over_constrained_runs_on.py .github/workflows
```

Wire it into the consumer repo as a cheap lint job (its `runs-on` resolution is
shared with the RD2 public-runner guard, so the two never disagree). It skips
parameterised `runs-on` (`fromJSON(inputs.*)`, `fromJson(needs.choose…)`), which
is exactly the reusable-workflow / RD3-preflight shape.

## Reusable workflows already migrated

The `nixos-modules` reusable workflows now default their `runs-on` inputs to
capability label sets, so a consumer that just calls them inherits the migration:

| Reusable workflow                     | Input                                           | New default                                                                                                            |
| ------------------------------------- | ----------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `reusable-lint.yml`                   | `runner`                                        | `["self-hosted","linux","x64"]`                                                                                        |
| `reusable-merge.yml`                  | `runner`                                        | `["self-hosted","linux","x64"]`                                                                                        |
| `reusable-nix-diff.yml`               | `runner`                                        | `["self-hosted","linux","x64"]`                                                                                        |
| `reusable-flake-checks-ci-matrix.yml` | `runners` / `non-nix-runner` / `results-runner` | label sets per Nix system (`x86_64-linux` → `[self-hosted,linux,x64]`, `aarch64-darwin` → `[self-hosted,macos,arm64]`) |
| `reusable-recorder-ci.yml`            | `runners`                                       | `[[self-hosted,linux,x64],[self-hosted,linux,arm64],[self-hosted,macos,arm64]]`                                        |

The RD3 `reusable-choose-runner.yml` preflight already emits its self-hosted
target as a capability label set (`fallback` default
`["self-hosted","linux","x64"]`) — its hosted↔self-hosted fallback and this
migration compose cleanly.

`reusable-terraform-ci.yml` and `reusable-cloudflare-import.yml` keep their
persistent-runner label arrays (`[self-hosted, Linux, x86-64-v2]`) as a
documented infra exemption; they run on the persistent NixOS runners, not the
ephemeral pool.

## Coordination

There are many consumer repos. Roll out **class-by-class**, keeping the alias
classes live (RC5) so nothing flag-days. A pilot lands first (as RD2/RD3 piloted
on `codetracer-test-mirror`); the checker + codemod let each repo migrate on its
own schedule, and the over-constrained lint keeps them from regressing.
