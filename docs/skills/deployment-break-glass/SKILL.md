---
name: deployment-break-glass
description: Use when central deployment automation is unavailable and an approved operator must recover a target through direct SSH, signed manifests, forced-command deploy keys, and explicit rollback evidence.
---

# Deployment Break Glass

## Prerequisites

- human approval naming the target, desired action, and rollback condition.
- A reachable SSH host with verified host key material.
- `MCL_DEPLOY_MANIFEST_SIGNING_KEY` for the desired-state manifest.
- `MCL_DEPLOY_SSH_IDENTITY` for the restricted deploy SSH key.
- The target has `services.mcl-deployment-ssh-apply` enabled and trusts the
  manifest public key.
- Cache substitute coverage is proven or the operator accepted cache risk.

## Commands

```sh
just deploy-machine-direct-ssh "$TARGET" "$SSH_HOST" deploy
mcl-devops deploy-plan --target "$TARGET" --desired-system-path "$SYSTEM_PATH" \
  --git-revision "$GIT_REVISION" --sequence "$SEQUENCE" \
  --signing-key "$MCL_DEPLOY_MANIFEST_SIGNING_KEY" --output "$MANIFEST"
mcl-devops deploy-ssh "$TARGET" --manifest "$MANIFEST" --ssh-host "$SSH_HOST" \
  --ssh-user deploy --identity-file "$MCL_DEPLOY_SSH_IDENTITY" \
  --ssh-option BatchMode=yes --ssh-option StrictHostKeyChecking=yes
bash scripts/deployment-incus-rehearsal.sh break-glass --check-env
bash scripts/deployment-incus-rehearsal.sh break-glass --check-runtime
bash scripts/deployment-incus-rehearsal.sh break-glass --dry-run
bash scripts/deployment-incus-rehearsal.sh break-glass
just rollback-machine-direct-ssh "$TARGET" "$SSH_HOST" deploy
ssh "$SSH_HOST" 'sudo journalctl -u sshd.service -u ssh.service -b --no-pager -n 120'
```

Use the wrapper when possible. Use the explicit `mcl-devops deploy-plan` and
`mcl-devops deploy-ssh` sequence when the wrapper cannot express the recovery
condition.

## Workflow

1. Record approval, target, previous generation, desired generation, and cache
   proof.
2. Build or locate the desired system path.
3. Create a signed manifest for the exact target with a new sequence.
4. Apply over SSH with `BatchMode=yes` and `StrictHostKeyChecking=yes`.
5. Confirm `agent-restore`, `switch`, `healthcheck`, and `complete` events or
   capture the failed phase.
6. Roll back immediately if the approved health condition fails.

## Forced-command SSH Boundary

The deploy SSH key is not a shell. The target module installs an authorized key
with a forced command and restrictions:
`restrict,no-agent-forwarding,no-X11-forwarding,no-port-forwarding,no-pty`.
The forced command runs `sudo -n` for the root apply wrapper only. The wrapper
executes `mcl-devops deploy-apply --manifest - --allowed-signers ... --target ...`
and includes `--reject-ssh-original-command`, so arbitrary
`SSH_ORIGINAL_COMMAND` content is rejected. The manifest signature and target
match are verified before restore, switch, health check, or rollback.

## Evidence

- Approval record and reason for break-glass.
- Host-key verification method.
- Signed manifest path, sequence, target, desired system path, and git revision.
- Event JSONL and target journal lines.
- Rollback command and final generation when rollback was used.
- Local break-glass rehearsal artifacts when practicing the runbook:
  `break-glass-evidence.json`, `break-glass-events.jsonl`, and
  `break-glass-generation-state.json`.

## Stop And Ask

Stop if approval is missing, the host key is unknown, the deploy key opens an
interactive shell, `sudo -n` fails unexpectedly, the forced-command boundary is
absent, the manifest signature fails, the manifest target differs from the SSH
target, or the proposed change updates deployment control-plane code.

## Rollback

```sh
just rollback-machine-direct-ssh "$TARGET" "$SSH_HOST" deploy "$GENERATION"
ssh -t "deploy@$SSH_HOST" 'sudo nixos-rebuild switch --rollback'
```

Capture the rollback event, current generation, and health-check result before
closing the incident.
