# `services.garm` — GARM (GitHub Actions Runner Manager) control plane

Declarative NixOS module for the [cloudbase/garm](https://github.com/cloudbase/garm)
control plane, wired for the **Ephemeral-Windows-Runners-GARM** campaign: fresh
Windows-11 VMs boot from a golden image, JIT-register with GitHub, run exactly one
job, and are destroyed — orchestrated by GARM through the stateless
`garm-provider-vmharness` libvirt provider.

This document is the operator runbook and security posture reference (campaign
milestone **M6**). It covers: the hardened-but-provider-capable systemd unit and
each sandbox relaxation; declarative App / provider / scale-set / metrics wiring;
the security posture (fork-PR gating, network isolation, secret management);
observability (Prometheus); the eval-time resource guard; and known cosmetic log
noise.

---

## 1. Quick start (production shape)

```nix
services.garm = {
  enable = true;

  # API + guest-facing controller URLs. The metadata/callback base URLs must be
  # reachable BY THE GUEST — on the libvirt NAT network that is the host bridge
  # IP (virbr0 = 192.168.122.1), NEVER localhost.
  apiServer = { bind = "0.0.0.0"; port = 9997; };
  metadataURL = "http://192.168.122.1:9997/api/v1/metadata";
  callbackURL = "http://192.168.122.1:9997/api/v1/callbacks";

  # Prometheus /metrics on the same apiserver port.
  metrics = { enable = true; disableAuth = true; period = "60s"; };

  # GitHub App forge credentials, declarative. The PEM is staged at runtime via
  # LoadCredential (agenix) and NEVER enters the Nix store.
  github = {
    enable = true;
    appId = 123456;
    installationId = 7654321;
    appKeyFile = "/run/agenix/garm/github-app-key";
  };

  # The libvirt/KVM provider. Turning this on switches the unit to the
  # provider-capable posture (see §2).
  providers.vmharness = {
    enable = true;
    poolDir = "/var/lib/libvirt/images";
    memoryMb = 4096;
    vcpus = 4;
    images.golden.sourceImage = "/var/lib/garm/golden/windows-runner.qcow2";
  };

  # Declarative autoscale policy (applied at runtime via garm-cli — see §4).
  scaleSets.windows-ephemeral = {
    provider = "vmharness";
    image = "golden";
    osType = "windows";
    maxRunners = 2;      # concurrency cap
    minIdleRunners = 0;  # scale-to-zero (raise for a warm pool)
  };

  # Eval-time resource guard budget (see §6).
  hostBudget = { memoryMb = 65536; vcpus = 32; };
};
```

Orgs and scale sets carry GitHub-side state (a message-queue subscription, a
numeric id) and are therefore NOT part of `config.toml`; they are applied with
`garm-cli` against the live, App-authenticated org (see §4). They are still
declared here: `services.garm.scaleSets` (and the orgs those entries reference)
is rendered into a desired-state manifest that the `garm-reconcile` oneshot
converges idempotently once `services.garm.reconcile.enable` is set (default
`false`).

---

## 2. THE M6 CENTERPIECE — running the libvirt provider under a hardened unit

The M0 forge-less boot ran GARM under a `DynamicUser` with a **maximal** sandbox
(`ProtectSystem=strict`, `PrivateDevices`, `MemoryDenyWriteExecute`,
`DeviceAllow=[]`, `~@resources` syscall filter). That is ideal for a pure-Go API
daemon but **fatal** for the libvirt provider, which GARM execs as a child: the
provider shells to `virsh`/`qemu-img`/`genisoimage`, talks to the
`qemu:///system` libvirt socket, and ultimately drives `/dev/kvm`.

The module therefore uses a **provider-conditional posture**:

- **`providers.vmharness.enable = false`** (M0/boot-gate): the strict
  DynamicUser sandbox, **byte-for-byte unchanged**. The M0 boot gate still passes.
- **`providers.vmharness.enable = true`**: a dedicated `garm` system user in the
  `libvirtd`/`kvm` groups, with **only** the minimum relaxations below. Everything
  that does not block the provider stays on.

### Relaxations (provider posture) — each and why

| Change                     | M0 posture                                 | Provider posture                                   | Why the relaxation is required                                                                                                                                                                                                                                                                                                                                                                                                |
| -------------------------- | ------------------------------------------ | -------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **User**                   | `DynamicUser=true`                         | dedicated `garm` system user                       | A DynamicUser gets a fresh uid every boot and **cannot be a stable group member**. The provider needs a persistent uid in `libvirtd`+`kvm` to reach `qemu:///system` and `/dev/kvm`.                                                                                                                                                                                                                                          |
| **Groups**                 | none                                       | `SupplementaryGroups = [libvirtd kvm]`             | Group-gated access to the libvirt socket (`/run/libvirt/libvirt-sock`, `libvirtd`) and `/dev/kvm` (`kvm`).                                                                                                                                                                                                                                                                                                                    |
| **ProtectSystem**          | `strict`                                   | `full`                                             | `strict` makes the whole FS read-only except explicit `ReadWritePaths`; the provider writes per-job overlay + nvram + config-drive into the pool dir and touches the libvirt runtime. `full` keeps `/usr`,`/boot`,`/etc` read-only (the important protection) while allowing the granted paths below.                                                                                                                         |
| **ReadWritePaths**         | (n/a)                                      | pool dir, `/var/lib/libvirt`, `/run/libvirt`       | Explicit write grants for the VM pool artifacts + libvirt runtime socket. `StateDirectory` already grants the GARM state dir.                                                                                                                                                                                                                                                                                                 |
| **PrivateDevices**         | `true`                                     | **removed**                                        | `PrivateDevices=true` hides `/dev/kvm`; qemu cannot start a HW-accelerated guest without it. Scoped instead via `DeviceAllow` (below).                                                                                                                                                                                                                                                                                        |
| **DeviceAllow**            | (implicit deny-all)                        | `/dev/kvm rw` + null/zero/full/random/urandom/ptmx | Grant **exactly** the devices the provider/qemu path needs, nothing more.                                                                                                                                                                                                                                                                                                                                                     |
| **MemoryDenyWriteExecute** | `true`                                     | **removed**                                        | qemu (and some tool child processes) JIT / map W+X pages; MDWE breaks them. Dropped **only** in the provider posture.                                                                                                                                                                                                                                                                                                         |
| **SystemCallFilter**       | `@system-service ~@privileged ~@resources` | **removed**                                        | The provider execs a chain of VM tooling (qemu-img, virsh, cdrkit `mkisofs`); `mkisofs` is **killed by SIGSYS** under `@system-service` (verified: `status=31/SYS, core dumped`). Rather than chase a vendored tool's exact syscall (brittle), the filter is dropped for the provider path. Isolation stays strong via the non-root user, `NoNewPrivileges`, empty caps, device scoping, and namespace/realtime restrictions. |
| **PATH**                   | (none)                                     | cdrkit(genisoimage)+qemu+libvirt via unit `path`   | GARM does **not** forward its PATH to external providers; the provider resolves `genisoimage` via `LookPath`. The provider block sets `environment_variables = ["PATH"]` and the unit contributes a PATH containing `genisoimage`. `virsh`/`qemu-img` are absolute (from the provider config).                                                                                                                                |

### Filesystem access for the non-root `garm` user (M6 integration notes)

Running the provider as a **non-root** user (instead of root as the M4/M5
harnesses did) surfaces two real access requirements the root path masked:

1. **Golden readability.** The provider opens the golden as the qemu-img CoW
   backing file. The golden **and every parent directory** must be readable +
   traversable by the `garm` user. If the golden lives under a group-gated path
   (e.g. `/srv/goldens root:some-group 0770`), grant a POSIX ACL:
   ```
   setfacl -m u:garm:--x /srv
   setfacl -m u:garm:r-x /srv/goldens
   setfacl -m u:garm:r-- /srv/goldens/<golden>.qcow2
   ```
   or add `garm` to the owning group via `services.garm.extraGroups`.
2. **Pool-dir writability.** The provider writes the per-job overlay +
   config-drive + nvram into `providers.vmharness.poolDir`. The shared
   `/var/lib/libvirt/images` is root-only (`0711`), so the module defaults
   `poolDir` to a **garm-owned** `/var/lib/garm/pool` and provisions it via
   systemd-tmpfiles as `garm:libvirtd 0771`. qemu runs the domains as root on a
   stock NixOS libvirtd host, so it reads the overlays regardless. If you point
   `poolDir` at a shared pool, grant `garm` write access there yourself.

**Everything else stays hardened** in both postures: `NoNewPrivileges`,
`ProtectHome`, `PrivateTmp`, `ProtectKernel{Tunables,Modules,Logs}`,
`ProtectControlGroups`, `ProtectClock`, `ProtectHostname`, `ProtectProc=invisible`,
`ProcSubset=pid`, `RestrictNamespaces`, `RestrictRealtime`, `RestrictSUIDSGID`,
`LockPersonality`, `RemoveIPC`, `RestrictAddressFamilies` (INET/INET6/UNIX only),
`SystemCallArchitectures=native`, empty `CapabilityBoundingSet`/`AmbientCapabilities`,
`UMask=0077`. This is still a **superset** of the upstream `contrib/garm.service`
(which only sets `User=garm`).

---

## 2a. IM4 — the incus (Linux container) posture

Setting `providers.vmharness.backend = "incus"` drives the
**Ephemeral-Linux-Runners** path: per-job Linux **system containers** launched
from an incus runner image (e.g. `runner-linux`) instead of Windows VMs. Because
containers share the host kernel and need **no `/dev/kvm`, no writable host pool
dir, and no external-tool execs**, the incus posture is **strictly stronger**
than the libvirt one — it keeps _all_ the M0 strict knobs and relaxes **only**
the user/group:

| Change                               | M0 posture                                 | **Incus posture**                                                                               | Libvirt posture       |
| ------------------------------------ | ------------------------------------------ | ----------------------------------------------------------------------------------------------- | --------------------- |
| **User**                             | `DynamicUser`                              | dedicated `garm` user                                                                           | dedicated `garm` user |
| **Groups**                           | none                                       | **`incus-admin`** only (socket access)                                                          | `libvirtd`+`kvm`      |
| **ProtectSystem**                    | `strict`                                   | **`strict`** (kept)                                                                             | `full`                |
| **PrivateDevices**                   | `true`                                     | **`true`** (kept — no `/dev/kvm`)                                                               | removed               |
| **DeviceAllow**                      | deny-all                                   | **deny-all** (kept)                                                                             | `/dev/kvm` + std      |
| **MemoryDenyWriteExecute**           | `true`                                     | **`true`** (kept)                                                                               | removed               |
| **SystemCallFilter**                 | `@system-service ~@privileged ~@resources` | **kept** (the `incus` Go CLI passes it)                                                         | removed               |
| **PATH**                             | none                                       | `incus` client                                                                                  | cdrkit+qemu+libvirt   |
| **HOME (env forwarded to provider)** | n/a                                        | **`HOME`** (the `incus` CLI reads `$HOME/.config/incus/…`; HOME is the writable StateDirectory) | n/a                   |

Why each incus relaxation is required (and _only_ these):

- **Dedicated `garm` user in `incus-admin`.** The provider shells to the `incus`
  client, which reaches the incus daemon over the `incus-admin`-group-gated unix
  socket (`/var/lib/incus/unix.socket`). A `DynamicUser` cannot be a stable group
  member, so a persistent uid in `incus-admin` is needed. **No `libvirtd`/`kvm`,
  no `/dev/kvm`** — containers don't touch the KVM device.
- **`incus` on PATH + `HOME` forwarded.** `incus_path` is absolute, but the CLI
  reads its client config from `$HOME/.config/incus/`; without `HOME` (and with
  `ProtectHome` hiding `/root`) it fails _"Unable to read the configuration file …
  permission denied"_. The unit's `HOME` is the garm StateDirectory (writable via
  `StateDirectory=garm`), so forwarding `HOME` is sufficient. Verified on the
  Incus host: `incus list` runs green under exactly these knobs (strict +
  PrivateDevices + MDWE + the syscall filter).

Everything a container needs on disk is owned by the **incus daemon** (running
outside this sandbox); the provider itself writes nothing to the host FS, so
`ProtectSystem=strict` needs **no extra `ReadWritePaths`** and there is **no
tmpfiles pool dir** (libvirt-only).

### Static IPv4 + declarative egress (IM4)

- **DHCP.** `incusbr0`'s DHCP does not lease on this host (nixos-fw drops the DHCP
  path). The provider therefore injects a **static IPv4 per container** via
  `cloud-init.network-config`, allocated from
  `providers.vmharness.incusIPv4RangeStart..incusIPv4RangeEnd` on
  `incusIPv4CIDR`, routed via `incusIPv4Gateway`. This is the supported approach
  (no declarative DHCP needed); the range size is the true per-scale-set
  concurrency ceiling for the incus backend (one free IP per concurrent
  container), so keep it `>= maxRunners`.
- **Container → internet egress** needs **no host firewall change**: incus's own
  `inet incus` nftables table already masquerades + forwards `incusbr0`.
- **Container → host GARM** (metadata/callback on the apiserver port) is opened
  **declaratively** with `services.garm.openIncusBridgeFirewall = true`, which
  wires `networking.firewall.interfaces.<incusBridge>.allowedTCPPorts =
[ apiServer.port ]`. This replaces the runtime `nft insert … iifname incusbr0 …
dport <port> accept` rule the IM3 gate added by hand. It opens **only** the
  bridge interface for **only** that port — never the public firewall.

### Runner-image cache path (IM4)

GARM's Linux install template treats `/home/<RunnerUsername>/actions-runner`
(username defaults to `runner`) as the **cached** runner: when that directory
exists the bootstrap skips the ~200 MB download+extract. The runner image
(built by `vm-harness/guest-recipes/linux-x64-runner/build-runner-image.sh`)
therefore stages the runner at exactly `/home/runner/actions-runner` (owned
`runner:runner`), so each job reuses the baked copy instead of re-downloading.

### Metrics + declarative wiring

Prometheus `/metrics` (§6), the App/org/scale-set wiring (§3–§4), and the
eval-time resource guard (§7) work identically for the incus backend. The IM4
gate `checks/t_incus_linux_autoscale_and_harden.sh` runs the whole autoscale
suite (cap / scale-to-zero / warm-pool at a higher concurrency than the Windows
path) **through the module-built hardened incus unit**, and asserts the posture
above + `/metrics` served + the declarative egress option.

### Remote Incus capability grants

These two remote Incus capabilities are disabled by default. Opt-in booleans
under `services.garm.providers.<name>.remote` grant the fixed capabilities
implemented by the pinned `vm-harness` mainline:

- `incusSecurityNesting` maps only to `--incus-security-nesting`.
- `incusNestedKvm` maps only to `--incus-nested-kvm`, whose contract attaches
  host `/dev/kvm` at guest `/dev/kvm` with the fixed device type, verifies the
  exact guest mode `0666`, and actually opens it read-write before returning
  success so a device-policy denial cannot masquerade as usable KVM.

Both default to `false`; false values are omitted from the rendered provider
TOML, preserving the prior remote create command exactly. The module and provider
reject either grant unless `backend = "remote"` and
`remote.targetBackend = "incus"`. These are controller-operator settings, not
pool tools, workflow inputs, bootstrap/user-data, or guest settings. There is no
raw Incus config/device-path/mode escape hatch. A consumer must enable them only
for a host whose verified capability manifest and live runner probe establish
the corresponding capability.

The older permissive `extra_specs` schema still advertises similarly named
local-Incus keys for compatibility, although the provider does not currently
consume them. This milestone deliberately neither implements nor expands that
per-pool surface: remote grants come only from the provider's `[remote]` table,
and hostile pool `extra_specs` cannot change the remote create command.

---

## 3. Declarative App / provider wiring

- **App credentials** are emitted as a `[[github]]` block with `auth_type = "app"`.
  The App PEM is multi-line, so it cannot be inlined; the render hook copies it from
  the `LoadCredential`-staged path to a stable `0600` file under `stateDir` and the
  block's `private_key_path` points there. **The PEM never enters the store.**

  > **GARM constraint (important).** GARM imports config `[[github]]` credentials
  > into its DB only via the legacy one-shot `migrateCredentialsToDB`
  > (`cmd/garm/main.go`: `cfg.Database.MigrateCredentials = cfg.Github`), and only
  > (a) on the **first** DB open (before the credentials table exists) **and** (b)
  > if an **admin user already exists** at that instant. GARM's first-run flow
  > creates the admin via the API _after_ boot, so on a **fresh deploy the import is
  > always skipped** ("Admin user doesn't exist. This is a new deploy."). The
  > `[[github]]` block is therefore effective only for **upgrading** a pre-existing
  > single-user GARM, not for greenfield installs. For a fresh deploy, register the
  > credentials once with `garm-cli github credentials add ... --private-key-path
<stateDir>/app-key.pem` — using the App ID / installation ID from
  > `services.garm.github` and the **module-staged PEM**. Every input is still
  > declarative (module options + LoadCredential); only the final `garm-cli`
  > registration is a runtime step, exactly like org/scale-set creation. Setting
  > `services.garm.reconcile.enable` automates that step idempotently: the
  > `garm-reconcile` oneshot adds the credential when absent and updates it when
  > drifted, from the same declared App id / installation id / staged PEM.

- **Controller URLs** (`metadata_url`, `callback_url`) go in `[default]` and must be
  guest-reachable (host bridge IP).
- **Provider** is a `[[provider]]` external block pointing at the
  `garm-provider-vmharness` binary + a secret-free provider `config.toml` carrying
  `virsh_path`/`qemu_img_path`/`libvirt_uri`/`network`/`pool_dir`/`uefi_*`/
  `memory_mb`/`vcpus` (plus `current_memory_mb` when a balloon floor is set) +
  the golden `[images.*]` map (all from module options).
- **Dynamic memory** (`providers.<name>.currentMemoryMb`, libvirt only): when set,
  `memory_mb` becomes the guest's ceiling and `current_memory_mb` its virtio-balloon
  boot target, emitted as `<currentMemory>` plus an explicit
  `<memballoon model='virtio'/>`. It is a request the guest honours only while
  running the balloon driver (on Windows: `balloon.sys` + `BLNSVR`) — check with
  `virsh dommemstat <domain>`, which reports `unused`/`available` only when the
  guest is really ballooning. The resource guard below still budgets the ceiling.

---

## 4. Provisioning orgs + scale sets at runtime

Scale sets carry GitHub-side state, so they are applied after the daemon is up.
The `garm-reconcile` oneshot below does this for you; the equivalent by hand is:

```bash
# org (references the declarative App creds by name)
garm-cli organization add --name my-org --credentials my-app \
  --webhook-secret "$(openssl rand -hex 16)"   # scale sets ignore the webhook

# scale set (the runs-on: selector is the scale-set NAME)
garm-cli scaleset add --org <ORG_ID> --provider-name vmharness \
  --image golden --name windows-ephemeral --flavor default --enabled \
  --min-idle-runners 0 --max-runners 2 --os-type windows --os-arch amd64 \
  --runner-bootstrap-timeout 30
```

The `services.garm.scaleSets.<name>` option records the **intended** policy so a
host config documents its concurrency in one place, and `garm-reconcile` applies
it: with `services.garm.reconcile.enable = true` (default `false`) a oneshot runs
after `garm.service` and converges the forge endpoint, credentials, orgs, and
scale sets to the declared shape — creating what is missing, updating what has
drifted, and doing nothing on a second run. Undeclared entities are left alone
unless `reconcile.pruneUnmanaged` is also set. `garm-cli controller update
--minimum-job-age-backoff 0` makes scale-to-zero react eagerly.

---

## 4a. Capability POOLS + classic runners (RC2 / RB3)

Scale sets name **one** class and pin it to one host. **Pools** register
_classic_ runners advertising a **capability label set**, so
`runs-on: [self-hosted, linux, x64, x86-64-v3]` matches **any** runner that
proves all those labels. The reconcile applies pools via `garm-cli pool`
(id-tracked in `managed-pool-ids.json` — GARM pools have no name).

`services.garm.mode` (`scaleSets` | `pools`, default `scaleSets`) **declares**
which model a host is authoritative for; it gates nothing structurally — pools
and scale sets reconcile **additively** whenever declared, so they run in
parallel through the cutover (RC5 retires the scale sets).

**RC2 — explicit pools, labels DERIVED from the host manifest.** A
`services.garm.pools.<name>` binds a `provider` + label set + `minIdleRunners` +
`maxRunners` + `priority`. Give the backing provider a `manifestFile` (the
host's RA6-verified `/v1/manifest`, written by the controller's manifest-verify
step) and the reconcile **derives** the runner's tag set from it with the RC1
`runner-label-tool` — proven hardware, not a hand-kept class name. A declared
`labels` set is then **linted** `advertised ⊆ derived` (fail-closed: an
over-advertised pool is refused). `policyLabels` (e.g. `ephemeral`, `org:<name>`)
are the attested labels a hardware manifest cannot prove, appended after
derivation. With no `manifestFile`, `labels` is used verbatim (the escape hatch
for a guest OS the host manifest cannot describe — a Windows VM on a Linux host).

**RB3 — capability→host placement + balancing.** A
`services.garm.capabilityPools.<name>` is a **host-agnostic** declaration —
`requires` (the labels a host must prove), candidate `providers` (default: every
provider with a `manifestFile`), and a `balance` policy — that the reconcile
**expands into one concrete pool per qualifying host** (a candidate qualifies iff
its derived labels ⊇ `requires`). This is the structural fix for the "GPU hosts
idle while one host saturates" imbalance: a generic Linux pool expands across
**all** qualifying hosts, so a job is no longer pinned to one.

- `balance = "spread"` (default): every qualifying host's pool gets the same
  `basePriority`, distributing jobs across equivalent hosts.
- `balance = "pack"`: qualifying hosts get **descending, distinct** priorities in
  candidate order — one host fills before the next (bin-packing).

Give a more-specific capability (`requires = [ "gpu" ]`) a higher `basePriority`
than a generic pool so a specialised job prefers a specialised host. Both gates
are hermetic module checks: `t_garm_pools_labels` (RC2) and
`t_garm_capability_placement` (RB3).

#### What `priority` is — and, more importantly, what it is not

Read this before reaching for `priority` to make anything go **first**.

`priority` orders **pools**, never **jobs**. When several pools match a job's
labels, GARM sorts them **descending** by priority (`Order("priority desc")` in
`database/sql/pools.go`; `sort.Slice(… Priority > …)` in
`runner/pool/cache.go`) and walks that list to decide where to **create a
runner** — the sort is applied _inside_ a loop over jobs, at
`runner/pool/pool.go`. **Higher is tried first.** GARM has no job-priority
concept at any layer: the job iteration order is a `range` over the
`map[int64]params.Job` in `runner/pool/util.go`, i.e. randomised.

Two consequences worth stating plainly:

- **`priority` cannot make a job jump a queue.** GARM creates runners; **GitHub**
  decides which queued job lands on an idle one, and GARM's own code treats its
  choice being overridden as a normal outcome (it breaks the lock on the job
  that triggered the runner when GitHub gives that runner to a different job).
- **`priority` cannot reserve capacity.** Nor can a label: `runs-on` matches by
  **subset**, so a "reserved" pool on the same hardware advertises a superset of
  what ordinary jobs request and is eligible for them; and you cannot advertise
  _less_, because GitHub attaches `self-hosted`, the OS and the arch to every
  self-hosted runner itself. The only admission control that is not label-based
  is a **GitHub runner group** with `restricted_to_workflows` — set it with
  `pools.<name>.runnerGroup` / `capabilityPools.<name>.runnerGroup`, pair it with
  `minIdleRunners >= 1` so the reserved runner is actually there when wanted, and
  govern the group's admission list on the GitHub side (the
  `terraform/github/governance.nix` engine renders `selected_workflows`).

> [!IMPORTANT]
> Priority is only **fully** effective under the `pack` pool balancer, which
> GARM sets **per entity (org)**, not per pool — `garm-cli organization update
--pool-balancer-type pack`. GARM's default is `roundrobin`, and its round-robin
> cursor is not reset between jobs, so priority only fixes the starting point
> once. **This module does not configure the balancer type**, so on a default
> controller the `pack`-style spill described for `burstPools` below is not in
> force. Set it with `garm-cli` on the org, or treat priority as advisory.

**RC5 — cutover completion: alias classes + scale-set retirement.** The
migration off scale sets is phased class-by-class (no flag day), bridged by
`services.garm.pools.<name>.aliasClasses` — a list of **legacy scale-set class
names** the pool advertises **alongside** its derived capability labels. A
consumer still writing `runs-on: eph-linux-x64` matches the aliased pool by
GitHub's subset rule and keeps running while it migrates. An alias is a name, not
a hardware claim, so — like `policyLabels` — it is **never linted** against the
manifest. Keep the alias while any consumer still names the old class; then drop
it (empty `aliasClasses`) as the **final** step — after which a job still naming
the retired class matches no pool and stays queued (the deliberate, visible end
of the bridge).

Scale sets are **retired** by declaring the END state — `mode = "pools"`,
`scaleSets = { }`, and `reconcile.pruneUnmanaged = true` — so the reconcile keeps
the declared pools and **prunes** any live scale set no longer declared (it
disables then deletes each). **Rollback** is symmetric and additive: re-add the
`scaleSets.<name>` entries and the reconcile recreates them beside the pools (the
coexistence path RC2 already exercises). The hermetic gate
`t_pools_cutover_complete` (RC5) proves all three: the over-provision
recording-rule + alert (promtool), alias resolution + drop, and the
render-and-prune retirement. The live 48h no-regression soak is the operator's
post-cutover validation — see the runbook.

The **thundering-herd** signal that watches the cutover is the
`garm:overprovision_ratio` recording rule + `GarmFleetOverProvision` alert in
`modules/garm-fleet-alerts` (runners created ÷ jobs served over a window; ~1 in
the coordinated pool topology).

---

## 5. Security posture

### (a) Fork-PR / untrusted-code gating

**Self-hosted runners must never auto-run fork-PR jobs.** GitHub-hosted runners are
ephemeral and disposable; self-hosted runners — even ephemeral ones — expose the
host libvirt/KVM control plane to whatever code a job runs. Mitigations, in order
of strength:

1. **Org runner-group scoping** (primary): put the ephemeral scale set in a
   dedicated org runner group and restrict it to **selected private repositories**.
   Fork PRs from public repos then cannot target these runners at all.
2. **Require approval for outside collaborators / all outside contributors** in the
   org → Actions → _Fork pull request workflows_ settings (`Require approval for all
external contributors`). No workflow (hence no runner request) runs until a
   maintainer approves.
3. **Label discipline**: the `runs-on:` selector is the scale-set NAME. Do not put
   the ephemeral scale set on public repos whose workflows accept untrusted input.

The ephemeral model itself is a strong secondary control: each job runs in a fresh
VM destroyed afterward (no state bleed — proved by the M6 gate), so even a
malicious job cannot persist into the next.

### (b) Network isolation for runner VMs

The per-job VMs attach to the libvirt **NAT** `default` network (virbr0,
192.168.122.0/24). Posture:

- Guests reach the host's GARM metadata/callback endpoint (virbr0 = 192.168.122.1)
  and the public internet (GitHub, actions downloads) through NAT.
- Guests are **isolated from each other** at the workload level by being ephemeral
  and single-job; they share the NAT subnet, so for stronger tenant isolation use a
  per-tenant libvirt network or `<network><forward mode='nat'/><ip>` with
  `isolated` semantics, or nftables rules on virbr0 restricting guest→guest and
  guest→host-control-plane traffic to only the GARM port.
- The GARM API/metrics bind should be an **overlay/LAN or bridge** interface, never
  the public internet. On this host virbr0 is a trusted interface so guests reach
  the host on the GARM port without opening the host firewall to the world.
- **Do not** give runner VMs a route to the host management plane, the deploy
  agent, the binary cache signing keys, or other tenants. The default NAT already
  prevents inbound host→guest; restrict guest→host to the GARM port where feasible.

### (c) Secret management

All GARM secrets are runtime-rendered and **never** in the Nix store:

- **DB passphrase** + **JWT secret**: generated on first boot and persisted `0600`
  under `stateDir` (or supplied via `dbPassphraseFile`/`jwtSecretFile` +
  LoadCredential). The store holds only a template with `@SENTINEL@` placeholders.
- **GitHub App PEM**: staged via `LoadCredential` from the agenix path
  (`github.appKeyFile`) and copied to a `0600` file under `stateDir`; the store
  never sees it. Verify with `strings $(readlink /run/current-system) | grep -i
BEGIN.*PRIVATE` returning nothing garm-related, and the gate asserts no PEM in
  `/nix/store`.

---

## 6. Observability (Prometheus)

Set `metrics.enable = true`. GARM serves `/metrics` on the **same apiserver port**.
With `disableAuth = true` it is scrapeable without a JWT metrics-token (keep the
endpoint on a trusted interface). Otherwise mint a token with
`garm-cli metrics-token create` and scrape with an `Authorization` header.

Scrape config for the existing monitoring stack:

```yaml
scrape_configs:
  - job_name: 'garm'
    metrics_path: /metrics
    static_configs:
      - targets: ['<garm-host>:9997']
    # if disable_auth = false:
    # authorization: { credentials: "<metrics-token>" }
```

Key series (namespace `garm_`): `garm_health` (gauge, alert on `== 0`),
`garm_runner_status`, `garm_runner_operations_total` / `garm_runner_errors_total`
(by `operation`,`provider`), `garm_scaleset_desired_runner_count` /
`garm_scaleset_max_runners` / `garm_scaleset_min_idle_runners`,
`garm_github_rate_limit_remaining`. Minimal alerts:

- `garm_health == 0` for 5m → GARM unhealthy.
- `rate(garm_runner_errors_total[15m]) > 0` → provider create/delete failures.
- `garm_github_rate_limit_remaining < 100` → App rate-limit pressure.

You do not have to hand-roll these. `services.garm-fleet-alerts` (see
[`modules/garm-fleet-alerts/README.md`](../garm-fleet-alerts/README.md)) ships a
parametric alert-rule library covering the whole runner chain — controller
health, pool-manager status, provider error rates, GitHub rate limit, and fleet
starvation — and renders it into `services.prometheus.ruleFiles`. Enable it and
tune `thresholds` instead of writing the rules above by hand; the three bullets
here are just the smallest useful subset if you are not using the module.

---

## 6a. Central-GARM recovery + DB backup (RE2)

When the fleet collapses onto **one** central controller (the Runner-Fleet
campaign's Phase-B end state), that controller is a deliberate provisioning
**SPOF**. GARM is **DB-as-truth**: on start it reconciles desired-vs-actual
against GitHub, and GitHub re-queues any job whose runner disappeared — so a
crashed controller loses **no jobs** as long as it comes back fast over a
**surviving DB**. Two option blocks harden that, and they compose with the
`healthcheck` watchdog (which recovers a process-_alive_-but-API-_dead_ garm):

**`recovery`** — the fast declarative restart posture (default `enable = true`):

| option                  | default  | effect                                          |
| ----------------------- | -------- | ----------------------------------------------- |
| `restartSec`            | `"5s"`   | `RestartSec` — respawn delay after a crash      |
| `startLimitIntervalSec` | `"300s"` | widened `StartLimitIntervalSec`                 |
| `startLimitBurst`       | `50`     | `StartLimitBurst`                               |
| `targetRecoverySeconds` | `30`     | the documented RTO (informational + gate bound) |
| `warmStandby.enable`    | `false`  | see the trade-off below                         |
| `warmStandby.host`      | `null`   | informational standby host                      |

The start-limit widening is the load-bearing SPOF property: systemd's **default**
(5 restarts / 10s) would drop the crown-jewel controller into a permanent
`failed` state on a brief crash-loop. The widened window keeps it recovering;
only a garm that exceeds the generous burst is genuinely broken (bad config,
disk full) and is then **left failed on purpose**, so RE1's
`up==0`/`GarmControllerDown` pages a human instead of hiding a hard fault behind
an endless loop.

> **Warm-standby trade-off.** A _second live controller_ against the same forge
> would double-provision (split-brain), because both would reconcile the same
> desired state. So `warmStandby` here is **not** two live controllers — it is
> the DB backup continuously shipped to a standby host that can be **promoted**
> by restoring the DB and starting garm (a seconds-to-minutes runbook step).
> It is heavier than fast-restart and only pays off on **host** loss; most
> deploys should leave it off and rely on fast-restart + backup. Enabling it
> asserts `backup.enable` **and** a `backup.remoteCommand` (the ship-to-standby
> feed) are set — otherwise it would promise an HA that ships nothing.

**`backup`** — online SQLite snapshot + off-host hook (default `enable = false`):

| option          | default            | effect                                                                            |
| --------------- | ------------------ | --------------------------------------------------------------------------------- |
| `enable`        | `false`            | install `garm-db-backup` oneshot + timer                                          |
| `interval`      | `"15min"`          | snapshot cadence                                                                  |
| `dir`           | `/var/backup/garm` | local rotated snapshot dir (put it on a **different** filesystem than `stateDir`) |
| `retain`        | `24`               | snapshots kept                                                                    |
| `compress`      | `true`             | gzip each snapshot                                                                |
| `remoteCommand` | `null`             | operator hook: ship `$1` / `$GARM_DB_SNAPSHOT` off-host                           |

Snapshots use SQLite's own `.backup` (a consistent copy of committed pages under
a shared lock — **not** `cp`, which can catch a torn WAL write) and are
`PRAGMA integrity_check`-verified before publication. Restore with the installed
**`garm-db-restore <snapshot>`** tool: it stops garm, swaps the snapshot into
`stateDir`, and restarts — garm then reconciles the restored DB against the
forge. A **cross-host** restore requires the same `database.passphraseFile` the
snapshot was encrypted with (GARM field-encrypts the DB); the restore refuses a
snapshot that fails its integrity check.

The `remoteCommand` runs as the garm user from `garm-db-backup.service`, so any
transport credentials it needs must be reachable there (e.g. a `LoadCredential`
you add to that unit). The module ships **no transport** — only the hook — so it
stays company-agnostic.

The gate `t_central_garm_recovery` proves all of this hermetically: the RE1
down-signal alerts fire, a SIGKILL'd controller recovers within the RTO with a
new PID, the DB survives the crash, and a **destroyed** DB is recovered from a
backup (with a non-vacuity control that a wiped DB genuinely loses state).

---

## 7. Eval-time resource guard (M5 guard promoted to a module assertion)

The M5 autoscale gate enforced `MAX_RUNNERS * memory` against free RAM at **runtime**
(harness-only). M6 promotes this to a **module assertion** so a bad config fails to
**eval**:

```
sum over scaleSets (maxRunners * providers.vmharness.memoryMb) <= hostBudget.memoryMb
sum over scaleSets (maxRunners * providers.vmharness.vcpus)    <= hostBudget.vcpus
```

An over-committed config aborts `nixos-rebuild`/`nix flake check` with, e.g.:

> services.garm: worst-case ephemeral guest RAM (sum of maxRunners \*
> providers.vmharness.memoryMb = 81920 MiB) exceeds hostBudget.memoryMb (16384
> MiB). Lower maxRunners/memoryMb or raise hostBudget.memoryMb.

This is a _ceiling_, not a live free-RAM check — the autoscale gate's runtime guard
still applies on top for transient host load.

---

## 8. `%!s(<nil>)` in consolidate logs — a real bug, patched here

On an **unpatched** GARM, every consolidate cycle may log:

```
failed to consolidate runner state ... provider binary <path> returned error: %!s(<nil>)
```

This is a **GARM-side** bug, **not** a provider bug. In
`runner/providers/v0.1.1/external.go`, `ListInstances` guards the provider
exec with an inverted `if err == nil` — every sibling command in that file uses
`if err != nil`. On a **successful** provider run GARM therefore takes the
failure branch: it formats the nil error with `%s` (hence `%!s(<nil>)`) **and
returns an empty instance slice**, so scale-set runner-state consolidation never
sees the runners the provider actually reported. The message is not cosmetic —
it comes with genuine runner state drift.

The `garm-provider-vmharness` provider is correct: `ListInstances`/`List` return
`(nil, nil)` on the empty case (verified in `internal/backend/virsh.go`
`listFiltered` and `internal/provider/provider.go` `ListInstances`), and
`DeleteInstance` treats absence as success (idempotent).

The GARM package in this repo carries the one-line fix:
`packages/garm/default.nix` applies
`packages/garm/patches/fix-listinstances-inverted-error-check.patch`, and the
upstream submission material lives in
`upstream-patches/garm-listinstances-inverted-error-check/`. Operators who still
see the message are running an unpatched GARM.

---

## 9. Through-the-module e2e (M6 evidence)

The M6 gate `checks/t_ephemeral_runner_security_and_metrics.sh` runs a real one-job
ephemeral e2e **through the declarative `services.garm` module** (not a concrete
root config): the module-built hardened unit starts GARM, the provider clones a
fresh Windows VM, JIT-registers, runs one job, and destroys the VM. It additionally
asserts: no state bleed between jobs (a marker written in job 1 is absent in a fresh
job-2 VM), `/metrics` is served, no secret material in `/nix/store`, and — via a
sibling eval — the resource-guard assertion fires on a bad config.

**Prerequisites** (documented; the full run needs org+App+KVM+root):

- Run as root on the KVM host (`/dev/kvm`, `qemu:///system`, libvirt `default` net).
- The Windows golden (prefer the sysprepped variant) with cloudbase-init + the
  actions runner staged; UTC RTC. Path via env (`VMH_WIN_GOLDEN`).
- OVMF firmware under `/run/libvirt/nix-ovmf`.
- The GitHub App PEM readable at the App PEM path (`APP_PEM`), for the GitHub App
  ID / installation / org supplied via env, with `Self-hosted runners: R/W`.
- `gh` authenticated with `repo`+`admin:org`.

The gate is ISOLATED + SELF-CLEANING: a unique scale-set name + a throwaway repo it
creates and deletes; it uses ONLY `garm-*`/`m6-*` names and never touches
production runners or other concurrent workstreams.
