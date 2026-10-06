---
name: deployment-investigation
description: Use when investigating a failed, stuck, superseded, or ambiguous deployment across GitHub Actions, deployment event artifacts, mcl-devops status summaries, target journals, cache health, and post-switch health checks.
---

# Deployment Investigation

## Prerequisites

- Work from the repository that owns the deployment workflow and target list.
- Do not use deploy, cache, or target credentials until the failing target,
  deployment id, and blast radius are known.
- Collect the GitHub run id, target name, git revision, deployment id, and event
  artifact path if they exist.

## Commands

```sh
gh run view "$RUN_ID" --log
gh run download "$RUN_ID" --dir .result/deployment-artifacts
mcl-devops deploy-status summarize .result/deployment-artifacts/events.jsonl \
  --output .result/deployment-summary.md \
  --json-output .result/deployment-summary.json
ssh "$TARGET" 'sudo journalctl -u mcl-deploy-agent.service -u mcl-deployment-reconciler.service -b --no-pager -n 200'
ssh "$TARGET" 'sudo journalctl -u sshd.service -u ssh.service -b --no-pager -n 120'
nix path-info --store "$SUBSTITUTER" --recursive "$SYSTEM_PATH" \
  --option trusted-public-keys "$TRUSTED_PUBLIC_KEY"
```

Use `mcl-devops deploy-status summarize` first when an event JSONL artifact exists.
Use target journals next only for phases that reached the target:
`agent-restore`, `switch`, `healthcheck`, `rollback`, or `complete`.

## Workflow

1. Identify the final observed phase and `command.status` from the status
   summary.
2. Join by `correlationId` or `deploymentId`; do not mix events from separate
   attempts.
3. Classify the failure:
   `evaluate`, `build`, or `cache-push` is controller-side;
   `activate-requested` is transport or reconciler-side;
   `agent-restore`, `switch`, `healthcheck`, `rollback`, and `complete` are
   target-side.
4. For cache suspicion, compare the manifest `desiredSystemPath` with
   `nix path-info --store` and the cache operation logs.
5. For target suspicion, inspect the target journal and the desired-state status
   files under `/var/lib/mcl/deployments`.

## Evidence

- GitHub run URL and failing job or step.
- Deployment summary markdown and JSON.
- Event JSONL lines for the failed deployment id.
- Target journal excerpt with timestamps matching the event stream.
- Cache query result for the exact system path and trusted public key.
- Health-check command, timeout, status, and output summary.

## Stop And Ask

Stop and ask a human operator before changing desired state, retrying a
production target, rolling back, exposing secrets or tokens, rotating cache
keys, overriding host-key checking, or acting on a target whose name does not
match the signed manifest.

## Rollback

Investigation does not roll back by itself. If rollback is required, hand off to
the break-glass workflow with the deployment id, target, current generation,
failed generation, and evidence collected above.
