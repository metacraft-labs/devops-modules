# Deployment Pull Agent

This module provides the opt-in target-side deployment path for NixOS and
nix-darwin. It is production-capable, but importing the generic module never
enables deployment by itself: the consuming infrastructure repository owns
target selection, manifest publication, trust roots, credentials, lifecycle
hooks, health policy, and rollout approval. Metacraft's production enablement
and operator runbook live in the `metacraft-labs/infra` repository.

## Architecture

The selected shape is publisher plus pull agent:

- CI or another publisher remains responsible for building closures, pushing
  them to an authenticated binary cache, creating signed desired-state
  manifests, and publishing only the manifests a target is allowed to read.
- The target-side `mcl-deploy-agent` service polls configured manifest files,
  directories, or HTTP(S) URLs and applies the latest signed manifest for its
  own target.
- No persistent central controller is required. A persistent service
  can still be added later if full-topology rehearsals prove that the simpler
  publisher plus pull-agent model is insufficient.

This keeps the target-side behavior small and preserves the signed manifest and
`deploy-apply` format. The agent does not define a second desired
state protocol. Cache selection is intentionally consumer-owned; the Metacraft
production integration uses private Attic and has no Cachix Deploy fallback.

## Target Rules

The agent is intentionally strict:

- Every manifest loaded from its configured sources must target the agent's
  configured `targetName`; a manifest for any other target is non-retryable.
- Every manifest must verify against the configured OpenSSH allowed-signers
  file or trusted public key before any state change or apply attempt.
- A target's sequence is its monotonic high-water mark, independently of
  `deploymentId`. A lower sequence is a mutation-free superseded no-op. At an
  equal sequence, only the exact same trusted signed manifest bytes are
  idempotent; any different payload (including one that reuses the same
  `deploymentId`) is a non-retryable `manifest_sequence_conflict`.
- A higher sequence is accepted even when it legitimately reuses the same
  `deploymentId`. Retry accounting and convergence evidence include the
  sequence and desired system path, so evidence from the older sequence cannot
  satisfy or exhaust the newer one.
- Only the highest valid sequence is applied.

Publishers should therefore expose per-target manifest paths or pre-filtered
directories. A shared mixed-target directory is rejected by design.

## State And Reporting

The pull agent reuses the M4 deployment state directory and event stream:

- Desired/current/failed/superseded/converged state stays under
  `/var/lib/mcl/deployments` on NixOS or the canonical
  `/private/var/lib/mcl/deployments` path on Darwin.
- Agent status is written only to
  `<stateDir>/agent-status/<target>.json`.
- `targets/<target>.json` is the complete signed desired-state manifest and is
  replaced atomically with mode `0640`. Before its deployment identity or
  sequence is used as a high-water mark, the agent binds the exact durable
  bytes in memory, validates required identity fields, confirms the target,
  and verifies the full payload against the configured manifest trust roots.
  The bound bytes and values are carried into `deploy-apply`; they are not
  reread for a later high-water or supersession decision. A path replacement
  between validation and recording fails closed before desired/current state,
  events, attempts, lifecycle hooks, activation, or rollback can change.
  Malformed, mismatched, unsigned, or tampered durable state likewise fails as
  `invalid_durable_state` without consuming an attempt or entering
  `deploy-apply`.
- Sequence refusal is decided before desired/current/superseded state or
  deployment events are written. A stale or equal-sequence conflicting
  manifest therefore cannot regress the durable target bytes, convergence
  evidence, agent status/attempts, lifecycle hooks, profile, or activation.
  The direct apply command returns `76` for an equal-sequence conflict; the
  pull agent reports the stable non-retryable error code
  `manifest_sequence_conflict` on stdout without overwriting durable status.
- Target-side deployment events are emitted by the existing `deploy-apply`
  path with `target.transport = "pull-agent"` and
  `backend.controller = "mcl-deploy-agent"`.

The current reporter coverage is the M4 event stream: restore, switch,
healthcheck, rollback, and complete events. Dedicated journald extraction and
more detailed switch progress capture are deferred until the full-topology
rehearsal defines the operator artifact format.

## Locking And Retries

The NixOS and nix-darwin modules wrap scheduled polls in `flock -n` using a
per-target runtime lock file, so an overlapping timer invocation exits without
starting another poll. Independently of those wrappers, `mcl-devops deploy-agent`,
`mcl-devops deploy-apply`, and desired-state recording take a shared internal
per-target state lock under `stateDir/locks`. The internal lock is held from
durable snapshot validation through the state transition, activation, events,
and final status. Direct CLI callers therefore cannot bypass serialization,
and a stale signed writer that began first but acquires the lock after a newer
writer is reclassified against the newer signed high-water state instead of
overwriting it.

The application-owned `stateDir/locks` directory must be owned by the
effective deployment user with exact mode `0700`; existing `0750`, `0500`, or
otherwise mismatched directories are rejected rather than silently accepted
or repaired. Lock leaves must be regular, singly-linked, same-owner files with
exact mode `0600`.

Before a direct CLI invocation creates a missing state directory, it walks and
pins every ancestor with no-follow directory descriptors. Ancestors must be
owned by root or the effective deployment user and must not be group- or
world-writable; root-owned sticky shared directories such as `/tmp` are the
only exception. Darwin's fixed `/var` and `/tmp` aliases are normalized to
their `/private` paths before the walk. Any other symlink or unsafe ancestor
fails before the filesystem is mutated.

On NixOS, the service's `ExecStartPre` is the sole upgrade migration boundary:
inside the declaratively protected root-owned state directory it creates an
absent `locks` child as `root:root` mode `0700`, or narrows a legitimate
root-owned legacy `0750`/`0755` directory to `0700`. It binds the child with
no-follow directory descriptors, refuses symlinks, non-directories, unexpected
owners/groups or modes, and revalidates the inode after migration before `mcl-devops`
can execute. Generic CLI callers remain fail-closed and never repair unsafe
existing state.

Retry handling is bounded:

- Source read or fetch failures are retryable.
- Apply failures are retryable until `maxAttempts` is reached.
- A pre-switch readiness hook that exits with status 75 records `deferred`,
  remains retryable, and does not increment `attempts`. Other hook failures are
  ordinary apply failures and consume an attempt.
- A higher authenticated sequence whose desired system path is already the
  selected current generation is durably accepted with zero new transaction
  attempts. A lifecycle-enabled deployment must first run its dedicated
  `--already-current-recovery-hook`: exit zero certifies clean lifecycle state
  or completes retained recovery, while failure remains retryable without
  falsely recording convergence or consuming another activation attempt. Only
  then is the identity marked `succeeded`. Closure restore, ordinary pre/post
  hooks, profile selection, activation, health checks, and rollback are all
  skipped. This recovery-only path remains available when the transaction
  retry budget is exhausted, but only after an authenticated, lock-held check
  proves that the selected generation exactly equals the desired generation.
  The apply engine repeats that equality check at the final boundary before
  restore and ordinary lifecycle/activation work, so a concurrent profile
  change cannot turn the recovery exception into another transaction. Exact
  replay then uses the ordinary byte-identical convergence shortcut.
- Wrong target, invalid manifest signature, invalid durable state, ambiguous
  source sequence, conflicting durable sequence identity, and exhausted retry
  budget are explicit non-retryable states.
- Already converged deployments short-circuit without another apply attempt.

## Platform Activation And Lifecycle Hooks

`mcl-devops deploy-apply` and `mcl-devops deploy-agent` default to
`--activation-mode nixos`. That mode retains the existing detached
`systemd-run` invocation of `switch-to-configuration`; existing callers do not
need new arguments.

`--activation-mode nix-darwin` uses the native nix-darwin transaction:

1. After authenticating and durably accepting the monotonic manifest identity,
   resolve the generation currently selected by `--system-profile` (default
   `/nix/var/nix/profiles/system`).
2. If it already equals the desired generation, invoke only the configured
   recovery probe and require it to certify clean or recovered lifecycle state.
   Lifecycle-enabled callers that omit this hook fail closed. A successful
   probe marks the new identity converged without restore, ordinary pre/post
   hooks, profile mutation, activation, health checks, or rollback.
3. Otherwise, restore the desired closure and atomically select it with
   `nix-env --profile ... --set`.
4. Execute the desired generation's `activate` directly, without
   `systemd-run`.
5. If activation fails, atomically restore the previous profile and execute
   the previous generation's `activate` before reporting failure. Automatic
   health-check rollback uses the same pair of operations.

This ordering was hardened after an m3 incident where a newly published
revision and sequence retained the exact current system store path. Entering
the pre-switch hook for that non-transaction stopped CI resources even though
there was no generation to activate. The equality decision therefore remains
before closure restore and the pre-switch hook, while signature validation and
durable high-water acceptance remain before the equality decision.

A second m3 incident exposed the inverse edge: activation had selected the
desired generation, but post-switch CI restoration failed and retained its
authenticated recovery journal. An identical retry therefore observed the
desired path as current even though host lifecycle state was not clean. The
generic engine cannot infer a host's recovery format, so
`--already-current-recovery-hook` is a separate executable contract called only
on equality, with `DESIRED_GENERATION CURRENT_GENERATION`. It must validate or
complete retained state without beginning a new deployment transaction. It is
not the pre-switch hook: invoking normal preparation on a clean equality would
recreate the first incident.

This repository provides the engine and nix-darwin option, not m3's
host-specific recovery implementation. The infra consumer must provide a
dedicated `m3-phase deploy-recover` executable (or an equivalent recovery-only
command) and set `alreadyCurrentRecoveryHook` to it before enabling m3's
lifecycle hooks; the module assertion deliberately rejects that configuration
when the recovery hook is missing.

The optional lifecycle hooks are executable paths, not shell fragments. The
agent invokes them with separate arguments so generation values cannot be
reinterpreted as shell syntax:

```text
PRE_SWITCH_HOOK  DESIRED_GENERATION PREVIOUS_GENERATION
POST_SWITCH_HOOK DESIRED_GENERATION PREVIOUS_GENERATION OUTCOME
ALREADY_CURRENT_RECOVERY_HOOK DESIRED_GENERATION CURRENT_GENERATION
```

The pre-switch hook runs after closure restoration and generation discovery,
but before any profile or system switch. Exit 75 means “not ready yet” and is
the only deferred result. Once readiness succeeds, the post-switch hook runs
after success, activation failure, health-check failure, and rollback. Its
`OUTCOME` is one of `succeeded`, `switch-failed`, `healthcheck-failed`, or
`rolled-back`. A failed post-switch hook prevents a successful deployment from
being marked converged.

Lifecycle events remain within the checked-in deployment event schema: hook
execution uses the existing `switch` phase and distinguishes `pre-switch` from
`post-switch` with `metadata.lifecycleStage`. Readiness deferral uses command
status `skipped`, exit code 75, error code `deployment_deferred`, and
`error.retryable = true`; it does not introduce a new phase or status value.
Darwin activation events report target kind `darwin`.

## NixOS Module

The generic module is `flake.modules.nixos.deployment-pull-agent` and exposes
`services.mcl-deploy-agent`.

Example:

```nix
{
  imports = [ inputs.nixos-modules.modules.nixos.deployment-pull-agent ];

  services.mcl-deploy-agent = {
    enable = true;
    targetName = config.networking.hostName;
    manifestPublicKeys = [ "ssh-ed25519 ..." ];
    manifestSources = [ "https://example.invalid/deployments/${config.networking.hostName}/latest.json" ];
    interval = "15min";
    jitter = "5min";
    maxAttempts = 3;
  };
}
```

Production integrations should wire private source URLs, trust material, target
selection, and any approval policy in the infrastructure repository. The
generic module should remain opt-in.

## nix-darwin Module

The opt-in Darwin module is
`flake.modules.darwin.deployment-pull-agent`. It uses the same
`services.mcl-deploy-agent` target, manifest trust, source, state, event,
timeout, and retry options where their platform semantics match. Darwin uses
`intervalSeconds` for launchd's integer `StartInterval`, and adds
`systemProfile`, `preSwitchHook`, `postSwitchHook`, `standardOutLog`, and
`standardErrorLog`. An optional `runtimePrerequisite` executable runs before
each poll and fails closed before manifest retrieval or closure restoration;
infrastructure integrations can use it to require runtime-only credentials
without embedding those credentials in the Nix store.

The module installs a root LaunchDaemon with `RunAtLoad` and periodic polling.
Its plist executes a small immutable Nix-store launcher whose derivation is
independent of the configured agent package and host arguments. On a true first
enable, nix-darwin may load the job before advancing `/run/current-system`; the
launcher waits up to 120 seconds for
`/run/current-system/sw/bin/mcl-deploy-agent`, reports a diagnostic, and exits
75 if that bounded activation window expires. Once available, that stable
wrapper resolves the current generation's `mcl-devops`, trust file, and lifecycle
hooks. Agent-package changes therefore leave the plist and launcher identical,
so an agent can activate its own replacement without launchd unloading it.

Every invocation takes a non-blocking `flock` supplied by the wrapper's Darwin
runtime closure and applies umask `0027`. Darwin uses canonical
`/private/var/lib/mcl/deployments`, `/private/var/log/mcl/deployments`, and a
nested `/private/var/run/mcl/deployments/<target>.lock` by default; spelling
these paths through `/var` would traverse macOS's `/var` symlink and is rejected.
Launchd stdout and stderr use durable files beside the event log.

The pre-activation fragment invokes a dedicated path-preparation executable
before launchd loads the daemon. It rejects non-normalized or non-dedicated
configuration, refuses every symlink component and linked/non-regular log,
never chmods or chowns `/private/var`, `/private/var/{lib,log,run}`, or another
shared root, and post-verifies exact root:wheel ownership with 0750 directories
and 0640 logs. Preparation is transactional: after validating the complete
existing set, it records each pre-existing inode's identity and original mode
and separately records every inode it creates. A later create, ownership,
revalidation, or chmod failure restores original modes and removes only
identity-stable invocation-created objects, child-first. A replaced, linked,
remoded, or otherwise raced object is preserved and makes rollback explicitly
incomplete and nonzero. Production roots and UID/GID are fixed by module
assertions; deterministic failure seams are selected only while evaluating the
module's test configuration and their variable names are absent from production
scripts. No `sudo` or passwordless privilege rule is involved: launchd runs the
system daemon directly as `root:wheel`.

Example:

```nix
{
  imports = [ inputs.nixos-modules.modules.darwin.deployment-pull-agent ];

  services.mcl-deploy-agent = {
    enable = true;
    targetName = config.networking.hostName;
    manifestPublicKeys = [ "ssh-ed25519 ..." ];
    manifestSources = [ "https://example.invalid/deployments/m3/latest.json" ];
    intervalSeconds = 15 * 60;
    maxAttempts = 3;
    preSwitchHook = pkgs.writeShellScript "deployment-ready" ''
      # Exit 75 to defer without spending an attempt.
    '';
    postSwitchHook = pkgs.writeShellScript "deployment-cleanup" ''
      # Receives DESIRED PREVIOUS OUTCOME.
    '';
  };
}
```

Like the NixOS module, importing the Darwin module does not enable it.

## Verification

Current automated coverage:

- Focused D unit tests for latest-only selection, wrong-target rejection,
  retry budget behavior, authenticated durable high-water validation, and
  dry-run isolation from every activation lifecycle surface.
- Static NixOS module rendering check for service, timer, source, lock,
  pre-execution lock migration, and retry options.
- NixOS VM test proving the agent applies only the latest signed manifest for
  its own host.
- NixOS VM test proving wrong-target and invalid-signature manifests are
  rejected without restore or switch.
- NixOS VM test proving the service-held lock rejects a concurrent contender
  and releases after the service exits.
- NixOS VM test proving absent and legitimate legacy lock directories become
  exact `root:root` `0700` before `mcl-devops`, while symlink, non-directory,
  hardlinked, wrong-owner, and wrong-group objects fail closed without mutation
  or deployment.
- Darwin activation integration populates every restore, generation, lifecycle
  hook, profile/activation, health, and rollback surface with fatal markers and
  proves `deploy-apply --dry-run` reaches none of them; the equivalent non-dry
  override configuration fails before creating state or events.
- Darwin module contract checks for its root LaunchDaemon, immutable bounded
  launcher, delayed first-enable entrypoint availability and timeout, stable
  self-update semantics,
  polling interval, canonical dedicated paths, root:wheel preparation commands,
  transactional late-failure rollback, exact original-mode restoration,
  invocation-created cleanup, rollback-time race preservation, mode repair,
  wrong-owner rejection, symlink refusal, shared-root invariance, real
  activation arguments, and retry bound.
- Darwin public-entrypoint integration coverage for a trusted activation,
  unavailable desired state, wrong-target and invalid-signature rejection,
  parse/type/shape/target/signature durable-state corruption, recovery of a
  later authentic deployment, a higher revision/sequence that is already the
  selected profile, injected recovery-only failure without false convergence,
  successful retained-state recovery, a separate clean-state probe, zero
  restore/ordinary-hook/profile/activation/health mutations and zero new
  attempts, exact replay, JSON-schema-valid events, and non-destructive lock
  contention.

## Consumer Integration Boundary

Before enabling a new production target, the consumer must test the complete
publisher/cache/target topology, including an unreachable target, reconnection,
latest-only selection, activation failure and rollback. Sensitive-target
approval belongs at manifest publication; the generic target agent cannot
infer organizational policy. A consumer must also provide monitoring for both
the agent's durable desired/actual state and its structured event log—a healthy
binary-cache request is not proof that the target activated the closure.
