---
name: deployment-reconciler
description: Use when inspecting or repairing desired-state reconciliation, latest-only state, pending or failed retries, superseded deployments, target locks, and pull-agent status.
---

# Deployment Reconciler

## Prerequisites

- Know the durable state directory and event log for the controller or target.
- Know whether the path is push reconciliation, target-side pull agent, or
  direct SSH.
- Do not edit desired-state JSON by hand unless a human explicitly approves the
  exact file and replacement state.

## Commands

```sh
mcl-devops deploy-reconcile --state-dir "$STATE_DIR" --event-log "$EVENTS_JSONL" --dry-run
mcl-devops deploy-reconcile --state-dir "$STATE_DIR" --target "$TARGET" \
  --target-host "$TARGET=$SSH_HOST" --ssh-user deploy \
  --identity-file "$MCL_DEPLOY_SSH_IDENTITY" --ssh-option BatchMode=yes
mcl-devops deploy-agent --target "$TARGET" --manifest-dir "$MANIFEST_DIR" \
  --trusted-manifest-public-key "$MCL_DEPLOY_MANIFEST_PUBLIC_KEY" --dry-run
systemctl status mcl-deployment-reconciler.service mcl-deployment-reconciler.timer
systemctl status mcl-deploy-agent.service mcl-deploy-agent.timer
journalctl -u mcl-deployment-reconciler.service -u mcl-deploy-agent.service -b --no-pager -n 200
```

## Workflow

1. Inspect `targets/<target>.json` to identify the latest desired deployment.
2. Compare `desired/`, `current/`, `failed/`, `superseded/`, `converged/`, and
   `agent-status/` entries for the same deployment id.
3. Treat `accepted` and `pending` as retryable states unless a newer sequence
   has superseded them.
4. Treat `superseded` as terminal; do not apply it after a higher sequence was
   accepted.
5. Treat `failed` as retryable only when the event or agent status says
   `retryable: true` and the retry budget is not exhausted.
6. Treat `converged` or `succeeded` as terminal unless the target health check
   later proves false.
7. Check `flock -n` lock ownership before starting another reconciler.

## Desired-state Semantics

State is latest-only per target. A lower `sequence` must not replace a higher
sequence. A same-sequence deployment with a different deployment id is
ambiguous for the pull agent and must be non-retryable. Retry state is bounded
by `maxAttempts`; exhausted retries become `non-retryable`. Already converged
deployments should short-circuit rather than restore or switch again.

## Evidence

- Latest target manifest, sequence, and deployment id.
- State files from `current`, `failed`, `superseded`, `converged`, and
  `agent-status`.
- Event JSONL lines for `activate-requested`, target apply phases, and final
  status.
- Timer status, last run timestamp, and lock contention result.

## Stop And Ask

Stop before deleting state files, rewriting sequences, forcing a superseded
deployment, clearing a non-retryable state, bypassing `flock`, increasing retry
budgets, or changing target-host mappings for production targets.

## Rollback

The reconciler does not invent rollback. It follows the signed manifest
`rollbackPolicy` and target-side apply result. If rollback must be manual, use
the break-glass skill and preserve the reconciler state files for audit.
