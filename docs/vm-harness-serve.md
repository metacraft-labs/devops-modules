# `services.gosti-serve` — declarative `gosti serve` deployment

> **Renamed (GOSTI1b).** The option path is `services.gosti-serve`; the old
> `services.vm-harness-serve` path still works and prints a deprecation
> warning. The default package is `packages.gosti` (`bin/gosti`, with
> `bin/vm-harness` as a symlink; `packages.vm-harness` is an alias). The units
> are `gosti-serve.service` (with `vm-harness-serve.service` as an alias, so
> `systemctl … vm-harness-serve` keeps working), `gosti-serve-healthcheck.*`
> and `gosti-serve-inventory.*`; on darwin the launchd jobs are
> `launchd.daemons.gosti-serve*` with label `org.metacraft-labs.gosti-serve`.
> Setting `systemd.services.vm-harness-serve*` or
> `launchd.daemons.vm-harness-serve*` is an evaluation error. The user, group,
> credential names, log paths and state directory (`/var/lib/vm-harness-serve`;
> `/var/lib/gosti-serve` is a symlink to it) are deliberately UNCHANGED: they
> carry the enrollment keyId and the agenix secret ownership. Journal queries
> must name the real unit: `journalctl -u gosti-serve`.
> Units export `GOSTI_EPHEMERAL_LABEL_DIR` (the legacy `VMH_` name was dropped in
> GOSTI1b step 6; gosti still reads it as a fallback).
> Gates: `t_gosti_serve_rename`, `t_gosti_serve_unit_rename_switch`.

Campaign: _CI Runner Fleet — vm-harness Remoting, Central GARM, Capability
Pools_ · milestone **RA2** (Linux/incus serve deployment).

`services.vm-harness-serve` runs the RA1 [`vm-harness
serve`](https://github.com/metacraft-labs/gosti/blob/dev/docs/serve.md)
remoting daemon as a hardened systemd service. It is the **uniform network
access point** that lets ONE central GARM's incus providers drive every Linux
host's containers remotely (campaign Phase B) — replacing the per-host GARM and
the `eph-linux-x64` capacity band-aid.

This is the GENERAL, company-agnostic machinery: it bakes in no host list, IPs,
or credentials. The concrete Metacraft instantiation (which hosts, which overlay
IPs, the agenix token ciphertext) lives in the private `infra` repo and only
consumes these options.

## What it provides

- A `gosti-serve.service` systemd unit running `gosti serve` as a
  dedicated system user (`vm-harness-serve`), in the `incus-admin` group so it
  can reach the incus socket, under the same hardening profile as the
  `services.garm` incus-strict posture (`ProtectSystem=strict`,
  `NoNewPrivileges`, empty capability bounding set, a `@system-service` syscall
  filter, `AF_INET`/`AF_INET6`/`AF_UNIX` only, …).
- The bearer token delivered out of the world-readable Nix store via systemd
  `LoadCredential` (`--auth-token-file %d/token`), sourced from an
  agenix-decrypted file.
- **Overlay-only reachability, enforced two ways at once:**
  1. the listener binds a single overlay (NetBird) address — never `0.0.0.0`
     (an assertion rejects the wildcard); and
  2. the port is opened on the overlay interface's firewall zone ONLY
     (`networking.firewall.interfaces.<iface>`), never the global firewall.
- Idle-cheap / scale-to-zero-friendly: one acceptor thread plus a small bounded
  pool of request handlers, all parked in a blocking wait when idle — an idle
  daemon costs ~nothing.
- **A listener health watchdog (MA12), enabled by default.** A periodic probe
  restarts the daemon when it stops ANSWERING, which is a state nothing else on
  either platform can observe: the process is alive, every thread is present,
  the port is `LISTEN`ing, and `systemctl is-active` reports no problem. That
  is exactly how the daemon went silently deaf twice in production
  (high-mem-server, gpu-server-001), once for nineteen hours, with `ss -lnt`
  showing a full accept backlog (`Recv-Q 4097` against `Send-Q 4096`) and
  callers timing out rather than being refused.

  On Linux it is a `systemd.timer` + oneshot that `systemctl restart`s the
  unit; on darwin a launchd `StartInterval` job that `launchctl kickstart -k`s
  it, because launchd's `KeepAlive` reacts only to the process EXITING and has
  no `WatchdogSec` equivalent. Both restart only after
  `healthcheck.failureThreshold` CONSECUTIVE failures and never more often than
  `healthcheck.minRestartInterval`, so a busy daemon is never restarted and a
  systemically wedged one is never restart-stormed.

  The probe is an UNAUTHENTICATED `GET /v1/info`, whose healthy answer is
  `401` — producing it still requires accept → dispatch → read → respond, but
  costs the daemon nothing, and needs no bearer token in a root-run unit. A
  `503` (every handler busy) and a timeout both count as failures. Probing the
  endpoint AUTHENTICATED would be the wrong instrument: it sweeps every
  registered hypervisor backend synchronously — measured 2026-09-18 at 16.7 s
  authenticated versus 5 ms unauthenticated.

- **Surviving a dependency blip.** The daemon needs incus only per request (it
  shells out to the CLI), so it depends on `incus.service` with `Wants=`, not
  `Requires=`. A failed incus start therefore can't fail the serve start job
  ("Dependency failed"), and an incus restart doesn't stop the daemon. The unit
  restarts on failure with no start limit (`StartLimitIntervalSec=0`,
  `RestartSec=5`). The GARM incus convergence oneshots
  (`garm-incus-storage-network`, `garm-incus-image-import`) do the same: they
  `Want` incus and retry every 10 s until it is back.

  The watchdog is the second layer. When the listener does not answer and the
  unit is inactive, the watchdog starts the unit if its latest start failed on
  a dependency. It does NOT rely on `Result=dependency`, which systemd doesn't
  record for a failed start job: the Result field keeps its previous value. It
  checks the unit's journal for a `Dependency failed for` line since the unit
  last went inactive. A deliberate `systemctl stop` is still left alone. The
  watchdog's state-file writes are best-effort, so a write failure is logged
  and can't abort the run.

  Incidents behind this: gpu-server-002 (serve down 17 h after incus
  core-dumped and restarted) and gpu-server-001 on 2026-10-14 (a deploy stopped
  serve at 21:04, the restart at 21:14 hit a 3 s incus blip, and serve stayed
  down until restarted by hand at 01:41). Gate:
  `t_gosti_serve_survives_incus_blip`.

- **Ownership records for kept GARM instances.** The remote GARM provider
  records which pool owns each instance it creates (`vm-harness
ephemeral-label`) and lists a pool's instances with `ephemeral-list --label
garm-pool=<id>`. The records live in `GOSTI_EPHEMERAL_LABEL_DIR`, which the
  unit sets to `/var/lib/vm-harness-serve/ephemeral-labels` (inside its
  StateDirectory, the only writable state under `ProtectSystem=strict`; the
  darwin module uses `<stateDir>/ephemeral-labels`). A pool must see only its
  own instances: GARM's scale-set reconciler deletes any listed instance it has
  no record of.
- **An opt-in kept-instance inventory exporter** (`inventoryExporter.enable`,
  `inventoryExporter.backends = [ "incus" ]` / `[ "libvirt" ]`). A timer runs
  `ephemeral-list` as the serve user and writes node-exporter textfile metrics
  `vmh_ephemeral_instances{backend,state,attributed}` and
  `vmh_ephemeral_list_success{backend}`. The snapshot is rendered into the
  serve user's own `0750` state directory and installed into
  `inventoryExporter.textfileDir` (default
  `/var/lib/prometheus-node-exporter/textfile`, which must match node-exporter's
  `--collector.textfile.directory`) by a privileged `ExecStartPost`, so that
  directory stays `root:root 0755`. The host is the only party that can
  see an orphan — an instance GARM has forgotten is absent from GARM — so the
  `garm-fleet-alerts` library alerts from these on sustained STOPPED instances
  (`VmhEphemeralStoppedOrphans`), runner-named instances no pool owns
  (`VmhEphemeralUnattributedInstances`) and a host that cannot enumerate
  (`VmhEphemeralInventoryFailing`).

The daemon's single `vm-harness` binary already contains `serve`; the module
defaults `package` to this flake's vendored `vm-harness` package
(`packages/vm-harness`).

## Minimal use

```nix
{ config, ... }:
{
  imports = [ inputs.nixos-modules.modules.nixos.vm-harness-serve ];

  services.vm-harness-serve = {
    enable = true;
    listenAddress = "100.83.180.254";                        # this host's overlay IP
    authTokenFile = config.age.secrets."vm-harness-serve/token".path;
    backend = "incus";
    # overlayInterface defaults to "nb-default"; extraPackages/extraGroups
    # default to the incus package + incus-admin when incus is enabled.
  };
}
```

The host also needs a converged incus (bridge, storage pool, default profile,
the runner base image) — use `services.garm-incus-runner-host` for that.

## Minting the bearer token (agenix)

The token is a per-host agenix secret (same $TOKEN the central GARM's per-host
provider config uses). On the Metacraft hosts the declaration is
`mcl.secrets.services.vm-harness-serve.secrets.token`, whose ciphertext path
auto-derives to `machines/server/<host>/secrets/vm-harness-serve/token.age`:

```sh
nix eval --json --apply 'c: c.mcl.secrets.services.vm-harness-serve.recipients' \
  ".#nixosConfigurations.<host>.config" | jq -r '.[]' > recipients.txt
printf '%s' "$TOKEN" | age -R recipients.txt \
  -o machines/server/<host>/secrets/vm-harness-serve/token.age
```

Recipients are the host key plus the `devops` group (`mcl.secrets.extraKeys`),
so the ciphertext must be minted once per host.

## Gate

`checks/vmharness-serve-linux-deploy.nix` builds the nixosTest
**`t_vmharness_serve_linux_deploy`**: it boots a host with the module + in-guest
incus and a second controller node, then proves the deployment end to end — a
remote controller drives a real ephemeral incus container roundtrip
(launch → probe → destroy, no residue) over the authenticated endpoint; a
wrong/missing token is rejected; and the port is bound to the overlay address
only and is unreachable on the host's second (non-overlay) network.

```sh
nix build .#checks.x86_64-linux.t_vmharness_serve_linux_deploy   # no infra repo needed
```
