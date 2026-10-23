# Don't let instances stuck in deletion fill a pool

## Summary

Every instance row counts against `max_runners`, including the ones that are
already on the deletion lane (`pending_delete`, `pending_force_delete`,
`deleting`). When a provider's deletes stall, a pool of N runners can end up
with N rows that are all being deleted and no runner that can take a job. New
jobs then wait until the provider manages to finish the deletes, which can
take hours. This PR stops instances on the deletion lane from holding a slot,
up to `max_runners` of them, so the pool can keep serving while the provider
catches up, and the provider footprint stays bounded.

## The bug

`max_runners` is enforced in four places, and each counts every row:

1. `addRunnerToPool()` compares `PoolInstanceCount()` with `max_runners`.
2. `ensureIdleRunnersForOnePool()` compares `len(existingInstances)` with
   `max_runners`, and also treats a deleting instance whose runner status is
   still `pending` as an idle runner for `min_idle_runners`.
3. `CreateInstance()` repeats the count inside its transaction.
4. The scale set worker's `runnerCount()` counts every runner except
   `deleted`.

An instance on the deletion lane has already been removed from the forge (or
is about to be), so it can never take another job. It only stays in the table
until the provider confirms the teardown. If that teardown keeps failing (in
our case a storage backend that refused to destroy busy volumes for several
hours), the pool is stuck at `max_runners` and every queued job gets "max
workers reached".

## The fix

A small `internal/capacity` package decides which instances occupy a slot:

- `deleted` never counts (the provider resource is gone; the row awaits
  cleanup).
- Instances on the deletion lane do not count, up to `max_runners` of them.
  Any beyond that DO count. This keeps the worst case at 2 x `max_runners`
  instances on the provider even if no delete ever succeeds, so a provider
  whose deletes are permanently broken cannot turn this into unbounded
  creation.
- Everything else counts, as before.

All four call sites use it, so the pool manager's check and the database's
transactional check agree. `ensureIdleRunnersForOnePool()` no longer counts a
deleting instance as idle. The scale set's `handleScaleDown()` computes its
delta from live runners only, so deleting runners beyond the allowance never
cause idle runners to be removed.

## Tests

- `internal/capacity`: table tests for the counting rules, plus a property
  test that a pool whose deletes never complete never holds more than
  2 x `max_runners` instances.
- `runner/pool` (`-tags testing`, real SQLite store):
  `TestStuckDeletesDoNotConsumePoolCapacity` fills a pool, stalls every
  delete, checks that the pool can fill again, then checks that a second
  round of stalled deletes is refused (bound reached, footprint
  2 x `max_runners`).
- `database/sql`: the mocked `CreateInstance` expectation follows the new
  status query.

## How it was found

A pool on a busy host stopped creating runners for several hours. Every row
in the pool was in `deleting` or `pending_delete` because the provider's
teardown kept failing, and every queued job got "max workers reached" until
the deletes finally went through.
