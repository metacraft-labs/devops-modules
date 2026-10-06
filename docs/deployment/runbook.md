# Deployment Operator Runbook

This runbook is for human operators who are not using Codex skills. It covers
the Attic/deployment migration operation surface in generic terms. Private
target groups, URLs, and escalation paths belong in the infrastructure
repository.

## Normal Investigation

Start with the deployment event artifact when it exists:

```sh
gh run view "$RUN_ID" --log
gh run download "$RUN_ID" --dir .result/deployment-artifacts
mcl-devops deploy-status summarize .result/deployment-artifacts/events.jsonl \
  --output .result/deployment-summary.md \
  --json-output .result/deployment-summary.json
```

Classify the final phase. `evaluate`, `build`, and `cache-push` are
controller-side. `activate-requested` is transport or reconciler-side.
`agent-restore`, `switch`, `healthcheck`, `rollback`, and `complete` are
target-side and require target journals:

```sh
ssh "$TARGET" 'sudo journalctl -u mcl-deploy-agent.service -u mcl-deployment-reconciler.service -b --no-pager -n 200'
```

For cache suspicion, verify the exact desired system path:

```sh
nix path-info --store "$SUBSTITUTER" --recursive "$SYSTEM_PATH" \
  --option trusted-public-keys "$TRUSTED_PUBLIC_KEY"
```

Evidence to preserve: GitHub run URL, event JSONL, deployment summary, target
journal excerpt, desired manifest, cache query result, and health-check output.

## Normal Deployment

Use the repository wrapper where available:

```sh
just deploy-machine "$TARGET"
just deploy-machine-direct-ssh "$TARGET" "$SSH_HOST" deploy
```

The direct SSH path expands to:

```sh
mcl-devops cache push-closure --backend attic --cache "$CACHE" --target "$TARGET" \
  --transport ssh --substituter "$ATTIC_SUBSTITUTER" \
  --trusted-public-key "$ATTIC_TRUSTED_PUBLIC_KEY" --require-substitute "$SYSTEM_PATH"
mcl-devops deploy-plan --target "$TARGET" --desired-system-path "$SYSTEM_PATH" \
  --git-revision "$GIT_REVISION" --sequence "$SEQUENCE" \
  --signing-key "$MCL_DEPLOY_MANIFEST_SIGNING_KEY" --output "$MANIFEST"
mcl-devops deploy-ssh "$TARGET" --manifest "$MANIFEST" --ssh-host "$SSH_HOST" \
  --ssh-user deploy --identity-file "$MCL_DEPLOY_SSH_IDENTITY" \
  --ssh-option BatchMode=yes --ssh-option StrictHostKeyChecking=yes
```

Confirm success with `mcl-devops deploy-status summarize`, target journal evidence,
and any service-specific health checks from the manifest.

## Desired-state Reconciliation

The state directory contains:

- `desired/`: signed desired-state manifests observed by the controller or
  target agent.
- `targets/`: latest manifest per target.
- `current/`: accepted or pending status.
- `failed/`: failed status.
- `superseded/`: older deployments replaced by a higher sequence.
- `converged/`: completed deployments.
- `agent-status/`: pull-agent retry and non-retryable status.

Inspect retry behavior with:

```sh
mcl-devops deploy-reconcile --state-dir "$STATE_DIR" --event-log "$EVENTS_JSONL" --dry-run
systemctl status mcl-deployment-reconciler.service mcl-deployment-reconciler.timer
systemctl status mcl-deploy-agent.service mcl-deploy-agent.timer
```

`pending`, `accepted`, and retryable `failed` can be retried when no newer
sequence exists. `superseded`, `converged`, `succeeded`, ambiguous same-sequence
state, invalid signatures, wrong target, and exhausted retry budget are
terminal until a human approves repair.

## Safe Direct SSH Deploy

Direct SSH is the break-glass and canary path when central deploy services are
unavailable or not yet trusted. Requirements:

- human approval for target and rollback condition;
- verified SSH host key;
- restricted deploy SSH key;
- signed manifest;
- cache substitute proof or explicit accepted cache risk;
- event and journal artifact capture.

Run:

```sh
just deploy-machine-direct-ssh "$TARGET" "$SSH_HOST" deploy
```

The target must receive a signed manifest on stdin. It must not provide an
interactive shell for the deploy key.

## Rollback

Rollback the target directly:

```sh
just rollback-machine-direct-ssh "$TARGET" "$SSH_HOST" deploy "$GENERATION"
ssh -t "deploy@$SSH_HOST" 'sudo nixos-rebuild switch --rollback'
```

Capture the old generation, failed generation, rollback command, final
generation, target journal, and event JSONL. Do not delete failed state files
until the incident is reviewed.

## Forced-command SSH Boundary

`services.mcl-deployment-ssh-apply` installs a restricted deploy user and an
authorized key with a forced command. The key has
`restrict,no-agent-forwarding,no-X11-forwarding,no-port-forwarding,no-pty`.
The forced command invokes `sudo -n` for the root apply wrapper only.

The root wrapper runs:

```sh
mcl-devops deploy-apply --manifest - --allowed-signers "$ALLOWED_SIGNERS" \
  --target "$TARGET" --reject-ssh-original-command
```

The wrapper verifies the manifest signature, expected target, cache
requirements, health checks, and rollback policy before writing target-local
state. Any non-empty `SSH_ORIGINAL_COMMAND` must be rejected.

## Cache Operation

Controller-side cache repair:

```sh
mcl-devops cache push-closure --backend attic --cache "$CACHE" --target "$TARGET" \
  --transport ssh --substituter "$ATTIC_SUBSTITUTER" \
  --trusted-public-key "$ATTIC_TRUSTED_PUBLIC_KEY" --require-substitute "$SYSTEM_PATH"
```

Target-side cache verification:

```sh
just attic-verify-host-substituters --check-env
just attic-verify-host-substituters --dry-run
just attic-verify-host-substituters --dry-run --resolve-netbird-peers
```

Stop before rotating cache keys, broadening tokens, bypassing trusted public
keys, or activating a manifest that requires unavailable cache coverage.

## Incus/LXC Rehearsal

Runtime rehearsal is the M7 production gate. Check-env and dry-run results are
useful evidence, but they are not production enablement. A `pending-runtime`
result is acceptable only as an explicit blocker when no local daemon or
required runtime storage prerequisite is available.

```sh
just test-deployment-incus-rehearsal
just deployment-incus-rehearsal full-topology --check-env
just deployment-incus-rehearsal full-topology --dry-run
bash scripts/deployment-incus-rehearsal.sh full-topology --check-env
bash scripts/deployment-incus-rehearsal.sh full-topology --check-runtime
bash scripts/deployment-incus-rehearsal.sh full-topology --dry-run
bash scripts/deployment-incus-rehearsal.sh full-topology
bash scripts/deployment-incus-rehearsal.sh full-topology-failures --check-env
bash scripts/deployment-incus-rehearsal.sh full-topology-failures --dry-run
bash scripts/deployment-incus-rehearsal.sh full-topology-failures
bash scripts/deployment-incus-rehearsal.sh offline-latest-only --check-env
bash scripts/deployment-incus-rehearsal.sh offline-latest-only --dry-run
bash scripts/deployment-incus-rehearsal.sh offline-latest-only
bash scripts/deployment-incus-rehearsal.sh forced-command --check-env
bash scripts/deployment-incus-rehearsal.sh forced-command --dry-run
bash scripts/deployment-incus-rehearsal.sh forced-command
bash scripts/deployment-incus-rehearsal.sh break-glass --check-env
bash scripts/deployment-incus-rehearsal.sh break-glass --check-runtime
bash scripts/deployment-incus-rehearsal.sh break-glass --dry-run
bash scripts/deployment-incus-rehearsal.sh break-glass
bash scripts/deployment-incus-rehearsal.sh pull-agent --check-env
bash scripts/deployment-incus-rehearsal.sh pull-agent --dry-run
bash scripts/deployment-incus-rehearsal.sh pull-agent
```

The rehearsal topology must model controller, cache, monitoring collector,
direct targets, intermittently reachable targets, and optional pull-agent
targets. Networks must model control, cache, home-lab-like, remote-server-like,
and optional workstation reachability. Failure injections must include target
partition, older and newer desired states, cache missing object or corruption,
forced-command misuse, health-check failure, rollback, and lock contention.
The break-glass scenario must also prove a failed canary recovery path:
arbitrary deploy-key shell access is rejected, a signed break-glass manifest is
accepted through the forced-command boundary, rollback evidence is captured, and
the final generation is preserved in target-side artifacts.

Runtime launches create only resources prefixed by `MCL_DEPLOYMENT_INCUS_PREFIX`
and clean those resources by default. Set `MCL_DEPLOYMENT_INCUS_ARTIFACT_DIR` to
choose the evidence directory. Set `MCL_DEPLOYMENT_INCUS_KEEP=1` only when a
failed run needs its prefixed containers, networks, and imported image alias
preserved for inspection.

Evidence required before production enablement: topology inventory, network
graph, generated credentials, failure injection log, event JSONL, final state
for every target group, per-container assertion JSON, target journal snippets,
cache logs, runtime command log showing no Cachix Deploy command, and a mapping
from rehearsal roles to rollout groups. Removal of Cachix Deploy is blocked
until the deterministic M7 VM checks pass, full-topology Incus/LXC runtime
evidence is captured, and two successful live canary cycles are recorded.

Game-day checklist:

1. Confirm the local Incus/LXC daemon, bridge networking, and test storage.
2. Confirm the topology inventory maps every rehearsal target to a rollout
   group and Avahi policy.
3. Run the VM checks for Attic push/substitute, cache failure, forced-command
   deploy, rollback, lock contention, pull-agent latest-only, and scheduled
   local canary.
4. Run `--check-env`, `--check-runtime`, and `--dry-run` for all topology
   scenarios.
5. Run the runtime scenarios and capture event JSONL, journals, cache logs,
   metrics, topology graph, and final state.
6. Compare rehearsal roles with the production rollout groups before selecting
   any live canary target.

## Production Cutover Gate

M8 cutover starts with local evidence only:

```sh
nix build .#checks.x86_64-linux.deployment-production-cutover-simulation-vm
nix build .#checks.x86_64-linux.deployment-cachix-fallback-simulation
nix build .#checks.x86_64-linux.deployment-no-default-cachix-deploy-call
```

The first target policy is recorded in
`docs/deployment/production-cutover-gates.json`. It requires green M7
full-topology runtime evidence before selecting a production canary. The first
pass target is local simulation only. A live target requires human approval and
an evidence record.

The shadow deploy path builds or selects the desired system path, pushes to
Attic, verifies substitute coverage, signs a manifest, and runs the reconciler
in dry-run mode. It must leave the target generation unchanged.

Cachix Deploy is legacy fallback during the rollback window. It remains
callable explicitly, but default Cachix Deploy removal is blocked until M7 is
green, a live canary target is approved, two successful live canary cycles are
recorded, every batch has migrated, and rollback closeout is documented.

## Updating Deployment Code

Deployment code changes must not strand the control plane.

1. Keep the existing production path available during the migration.
2. Add or update deterministic unit and NixOS VM checks first.
3. Rehearse direct SSH and rollback before changing controller or target agent
   code in production.
4. Stage changes so the code that can repair the controller is deployed before
   code that depends on the new controller behavior.
5. Do not remove Cachix Deploy fallback until the production gate says so.

## Human Approval Required

Ask for human approval before production deploys, rollback, cache key rotation,
secret edits, retry budget increases, target-host remapping, bypassing SSH host
key checks, bypassing manifest signature checks, clearing non-retryable state,
or accepting a runtime-pending rehearsal as a passed production gate. Never
proceed when bypassing SSH host key checks or bypassing manifest signature
checks would be required.
