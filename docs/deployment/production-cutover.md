# Production Cutover Gate

M8 is a production gate, not an automatic rollout. The CI backend cutover is
complete: Attic is the sole deployment cache and activation backend in CI, and
Cachix Deploy is removed from CI. The remaining work is the operational
retirement of the manual `cachix deploy activate` fallback. The first
operational pass is limited to local simulation, evidence checks, and operator
documentation. No live target is selected until M7 full-topology runtime
evidence is green and a human approves the canary target.

## Required Evidence

The gate file is
[production-cutover-gates.json](production-cutover-gates.json). It records that
Attic is the sole deployment cache and activation backend, that Cachix Deploy is
removed from CI, and it requires before retiring the manual fallback:

- successful M7 full-topology runtime evidence for all topology scenarios;
- a runtime command log proving the new path did not call Cachix Deploy
  activation;
- deployment event JSONL and status summaries;
- cache logs and target journal snippets;
- final state for every rollout group;
- two successful live canary cycles before the manual `cachix deploy activate`
  fallback is retired.

## First Target Policy

The generic policy intentionally does not name a production host. The only
selected target in this pass is `local-production-cutover-canary`, a local
simulation target. A private infrastructure repository may list candidates, but
the live canary remains unselected until the evidence gate and human approval
are both present.

## Shadow Deploy

The shadow path builds or selects the desired system path, pushes the closure to
Attic, verifies substitute coverage, creates a signed manifest, and runs the
direct SSH reconciler in dry-run mode. It must not switch a real host.

Expected evidence:

- Attic cache-push event with complete substitute coverage;
- signed desired-state manifest;
- dry-run `activate-requested` event with `pending` status;
- no target-side switch or rollback event;
- no Cachix Deploy activation command.

## Supervised Local Cutover Simulation

The local VM simulation applies the same signed manifest to a test target over
the forced-command SSH path. It verifies target-side restore, switch,
healthcheck, summary artifacts, rollback drill evidence, and final generation.
This proves the operator evidence format without mutating production hosts.

## Manual Cachix Deploy Fallback

The CI deploy and cache backends are already Attic-only; Cachix Deploy is removed
from CI. The manual `cachix deploy activate` fallback remains callable by an
operator for a rollback window, but the Attic/direct cutover path must not depend
on it. Retiring the manual fallback is blocked until the M7 gate is green, a live
canary target is approved, two successful live canary cycles are recorded, and
all rollout batches have migrated.

## Removal Gate

Do not retire the manual `cachix deploy activate` fallback until the gate
records:

1. green M7 full-topology runtime evidence;
2. selected live canary target and approval record;
3. two successful live canary cycles;
4. completed batch rollout evidence;
5. explicit rollback-window closeout.
