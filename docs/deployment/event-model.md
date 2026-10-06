# Deployment Event Model

`DeploymentEvent` is a backend-neutral JSON event for deployment observability.
It must represent the current Cachix Deploy path and a future direct SSH or
desired-state reconciler path without changing phase names.

## Phase Names

The only M0 phase names are:

- `evaluate`
- `build`
- `closure-prefill`
- `cache-push`
- `activate-requested`
- `agent-restore`
- `switch`
- `healthcheck`
- `rollback`
- `complete`

Producers must not emit backend-specific phase names. Backend-specific details
belong in `backend` or `metadata`.

## DeploymentEvent

The JSON schema is [event-schema.json](event-schema.json). Required fields are:

- `schemaVersion`
- `deploymentId`
- `correlationId`
- `phase`
- `target`
- `storePaths`
- `timestamps`
- `command`

`target` identifies the logical deployment target without requiring a private
hostname in generic tooling. `storePaths.system` records the desired system
toplevel path. `storePaths.closure` is optional but should contain closure
`count`, `totalBytes`, and root store-path hashes when available.

`command.status` is one of `pending`, `running`, `succeeded`, `failed`,
`cancelled`, or `skipped`. Failed events should include `error`, with a stable
error code, human-readable message, retryability flag, and optional backend
details.

## Desired State

The desired-state schema is [desired-state-schema.json](desired-state-schema.json).
Each record is latest-only per target and contains:

- `deploymentId`
- `target`
- `gitRevision`
- `sequence`
- `manifestSignature`
- `desiredSystemPath`
- `cacheRequirements`
- `healthChecks`
- `rollbackPolicy`
- `currentState`
- `supersededState`
- `retryTimestamps`

`target.name` is the backend-neutral target name. `gitRevision` records the
source commit that produced the desired system path. `cacheRequirements`
records the closure summary, substituter trust material, and required cache
availability before activation. `healthChecks` lists the backend-neutral
post-switch checks a reconciler should evaluate. `rollbackPolicy` declares how
health-check or activation failure should be handled.

`sequence` is monotonic per target. A reconciler must not apply a lower sequence
after a higher sequence has been accepted. `supersededState` records the
deployment that was replaced and when it was superseded.

## Correlation Id Propagation

The correlation id is the stable join key across systems. A producer should
derive it from GitHub run identity, git revision, target, and desired system
path. The exact format can evolve, but it must be stable for every event in one
deployment attempt.

Propagation points:

- GitHub Actions: expose `DEPLOYMENT_CORRELATION_ID` in deploy jobs and upload
  it with status artifacts.
- `mcl-devops` logs: include `correlationId`, `deploymentId`, `phase`, and `target` in
  every structured log line.
- Target journald: pass the id to target-side apply or agent wrappers and log
  it through systemd journal fields or structured JSON.
- Metrics: attach `correlation_id`, `deployment_id`, `target`, and `phase`
  labels where cardinality policy allows; otherwise expose exemplars or status
  artifact links.
- Status artifacts: write event JSONL and final desired-state status files with
  the correlation id in the artifact name and record body.

## Examples

[examples/events-success.jsonl](examples/events-success.jsonl) contains one
successful event sequence. The `deployment-event-schema-examples` check validates
the checked-in examples against required schema fields and phase enums.
