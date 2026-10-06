# Deployment Baseline

This directory records the M0 deployment audit and event model. It is
documentation, schema, examples, and static validation only. It does not change
the production deployment path.

## Contents

- [current-cachix-flow.md](current-cachix-flow.md): current CI-to-target
  Cachix deploy flow, inputs, and monitoring path.
- [event-model.md](event-model.md): backend-neutral event, phase, desired-state,
  and correlation-id model.
- [backend-assumptions.md](backend-assumptions.md): Cachix-specific assumptions
  that should become backend abstractions.
- [rehearsal-harness.md](rehearsal-harness.md): current observed rehearsal
  prior art and generic harness candidates.
- [monitoring.md](monitoring.md): M3 deployment and Attic cache metrics,
  incident queries, and current target-side observability limits.
- [pull-agent.md](pull-agent.md): M5 optional target-side pull agent shape,
  state model, locking, retries, and current verification status.
- [production-cutover.md](production-cutover.md): M8 cutover gate, local
  simulations, Cachix fallback policy, and evidence required before production.
- [runbook.md](runbook.md): M6 human operator runbook for investigation,
  normal deploy, cache operation, break-glass direct SSH, rollback,
  reconciliation, and Incus/LXC rehearsal gates.
- [cache-and-deploy-risk-register.md](cache-and-deploy-risk-register.md): M0
  risk register.
- [event-schema.json](event-schema.json): `DeploymentEvent` JSON schema.
- [desired-state-schema.json](desired-state-schema.json): desired-state record
  JSON schema.

Generic docs must not include private hostnames, domains, repository names, or
escalation paths; those operational details live in the private infrastructure
repository, not in this shared repo.
