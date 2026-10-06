# Runner capability-label taxonomy — derivation + linter (RC1 mechanism)

Runner-Fleet-Capability-Pools-And-Remote-Driving **RC1**, gate
`t_runner_label_taxonomy`.

This module is the **company-agnostic MECHANISM** that turns an RA6 signed
capability manifest (`GET /v1/manifest`, see
[`vm-harness/docs/serve-enrollment.md`](../../../vm-harness/docs/serve-enrollment.md))
into the GitHub runner label set a host may advertise, and **lints** that every
label a host advertises is a subset of what its manifest proves
(`advertised ⊆ derived`).

Per the campaign `:repo_layering:` the label **vocabulary** and the `runs-on`
**conventions** are POLICY and live in
[`metacraft-dev-guidelines/policies/ci-workflow-standards.md`](https://github.com/metacraft-labs/metacraft-dev-guidelines/blob/master/policies/ci-workflow-standards.md#capability-label-taxonomy-versioned).
This module bakes in **no** Metacraft host list, secret, or org — only the
mapping. The concrete per-host advertised sets live in `infra` and are validated
by this linter.

## The derivation (versioned)

`TAXONOMY_VERSION = "1"`, pinned to RA6 `manifestVersion = "1"`. A manifest
outside the supported set **fails closed** (no labels) rather than being
interpreted under the wrong schema.

| Manifest field                       | Derived label(s)                                                                                                                    |
| ------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------- |
| `os`                                 | `linux` / `windows` / `macos`                                                                                                       |
| `arch`                               | `x64` (x86_64/amd64) / `arm64` (aarch64)                                                                                            |
| `archLevel = x86-64-vN`              | `x86-64-v2 … x86-64-vN` — a host proving vN satisfies every lower level; `v1` baseline is not advertised (carries no routing value) |
| `gpu == true`                        | `gpu`                                                                                                                               |
| `nestedVirt == true`                 | `nested`                                                                                                                            |
| `docker == true`                     | `docker`                                                                                                                            |
| `podman == true`                     | `podman`                                                                                                                            |
| `rrHwCounters == true`               | `rr-hw-counters`                                                                                                                    |
| `hypervisors[].id` where `available` | `incus` / `libvirt` / `hyperv` / `tart`                                                                                             |
| (structural)                         | `self-hosted` — always, for any serve-host runner                                                                                   |

Only a proven `true` (or an `available` hypervisor) yields a label; a missing /
`false` field yields nothing — "not proven present", never a guess.

## The linter — `advertised ⊆ derived`

The manifest is authoritative only over the **manifest-governed vocabulary**
(the labels in the table above). The linter flags any advertised label that is
**in** that vocabulary yet **not** in the derived set. Labels **outside** the
vocabulary — POLICY / attested labels like `dev-env-ready`, `org:<name>`,
`ephemeral`, `benchmark`, `topology-host` — pass through: the hardware manifest
can neither prove nor disprove them, so a policy-owned check governs those, not
this one. That is the precise reading of `advertised ⊆ derived`: the manifest
only vetoes labels it owns.

## Signature boundary

This tool operates on an **already-verified** manifest. The RA6 controller
`verify()`s the HMAC/identity **before** calling `derive`; an unverifiable
manifest yields no labels. This tool does the field→label mapping only — it does
not re-implement the crypto. It DOES fail closed on an unsupported
`manifestVersion`.

## Usage

```console
# derive the labels a manifest proves (envelope or bare manifest, stdin or -m)
$ runner-label-tool derive -m manifest.json
docker
gpu
incus
…

# lint a host's advertised set against its manifest (exit 1 on a violation)
$ runner-label-tool lint -m manifest.json -a self-hosted,linux,x64,x86-64-v3,incus
[lint][PASS] advertised ⊆ derived

$ runner-label-tool --version
runner-label-taxonomy v1 (manifestVersion ['1'])
```

## Downstream consumers

- **RB2 / RC2** (central GARM + pools): run `derive` at JIT-registration time,
  after verifying the fetched manifest, to compute a classic runner's label
  array from proven hardware — replacing the hand-maintained `eph-<os>-<arch>`
  class name.
- **RC2 / infra CI**: run `lint` to prove every host's advertised set ⊆ what its
  manifest proves. Gate `t_runner_label_taxonomy` is that contract, hermetic.
- **RC4** (reusable-workflow `runs-on` migration): consumes the same vocabulary
  to rewrite class names into minimal capability label sets.
