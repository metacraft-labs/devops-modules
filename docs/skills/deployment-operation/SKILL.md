---
name: deployment-operation
description: Use when performing normal deployment operations, confirming deployment health, running direct SSH deployment wrappers, or deciding whether to fall back to rollback.
---

# Deployment Operation

## Prerequisites

- Confirm the target, git revision, rollout group, and approval state.
- Confirm the deploy path: existing production path, direct SSH, or pull-agent
  desired-state publishing.
- Confirm signing and SSH credentials are available only to the operator
  process that needs them.
- Confirm `ATTIC_SUBSTITUTER` is paired with `ATTIC_TRUSTED_PUBLIC_KEY` when
  Attic restore is required before activation.
- Confirm Cachix Deploy is used only as legacy fallback during the M8 migration
  window, unless the approved procedure still names the old production path.

## Commands

```sh
just deploy-machine "$TARGET"
just deploy-machine-direct-ssh "$TARGET" "$SSH_HOST" deploy
mcl-devops cache push-closure --backend attic --cache "$CACHE" --target "$TARGET" \
  --transport ssh --substituter "$ATTIC_SUBSTITUTER" \
  --trusted-public-key "$ATTIC_TRUSTED_PUBLIC_KEY" --require-substitute "$SYSTEM_PATH"
mcl-devops deploy-plan --target "$TARGET" --desired-system-path "$SYSTEM_PATH" \
  --git-revision "$GIT_REVISION" --sequence "$SEQUENCE" \
  --signing-key "$MCL_DEPLOY_MANIFEST_SIGNING_KEY" --output "$MANIFEST"
mcl-devops deploy-ssh "$TARGET" --manifest "$MANIFEST" --ssh-host "$SSH_HOST" \
  --ssh-user deploy --identity-file "$MCL_DEPLOY_SSH_IDENTITY" \
  --ssh-option BatchMode=yes --ssh-option StrictHostKeyChecking=yes
mcl-devops deploy-status summarize "$EVENTS_JSONL"
```

Prefer the repository wrapper when it exists, because it keeps build, cache
push, manifest signing, deploy, and state directory choices together.
During M8, the Attic/direct path is the cutover candidate and Cachix Deploy is
legacy fallback. Do not treat a fallback activation as evidence that the new
path is ready.

## Workflow

1. Build or select the exact target system path.
2. Push or verify the closure in the configured cache before activation.
3. Create a signed desired-state manifest with a monotonic target-local
   sequence.
4. Apply with the selected transport.
5. Summarize events and confirm target health.
6. Keep the old generation available until the health-check window has passed.

## Evidence

- Target, git revision, sequence, manifest path, and desired system path.
- Cache prefill or substitute proof.
- Event JSONL and `mcl-devops deploy-status summarize` output.
- Target-side `agent-restore`, `switch`, `healthcheck`, and `complete` events
  when the direct apply path is used.

## Stop And Ask

Stop before deploying when the target group is broader than approved, the cache
cannot prove substitute coverage, the signing key identity is unexpected, host
key verification is disabled, the manifest target differs from the target being
contacted, or Cachix fallback is no longer available during migration.

## Rollback

```sh
just rollback-machine-direct-ssh "$TARGET" "$SSH_HOST" deploy
ssh -t "deploy@$SSH_HOST" 'sudo nixos-rebuild switch --rollback'
```

Use rollback only with explicit approval unless the written rollout procedure
already authorizes automatic rollback for the failing health check.
