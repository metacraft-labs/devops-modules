# Never forget an instance the provider may still hold; stop delete storms

## Summary

Four pool-manager fixes that together stop instances from leaking on the
provider and stop one unreachable provider host from stalling the pool
manager or turning into a retry storm against every other host.

## The bugs

1. **`cleanupOrphanedGithubRunners` deletes the record without deleting the
   instance.** For a runner that is offline in the forge and absent from the
   provider's `ListInstances`, the database record is deleted directly and
   `DeleteInstance` is never called. "Absent from the list" is only the
   provider's claim; a provider that cannot see a class of instance (or answers
   an enumeration failure with an empty list) makes it about instances that are
   still running, and those instances leak for good. A slow-booting guest
   (e.g. Windows, which is routinely still booting five minutes after creation)
   is exactly such a runner.

2. **`retryFailedInstancesForOnePool` cancels sibling deletes.** Cleanup
   deletes for a pool's failed instances run in one `errgroup.WithContext`.
   The first failing delete cancels the shared context, which kills every
   in-flight sibling delete (external providers are terminated on
   cancellation), and the pass is retried on the next 5s consolidation tick.
   One unreachable provider host therefore produces a continuous stream of
   killed deletes against all the others.

3. **Create retries are not spaced.** An instance whose create fails fast
   (e.g. a full storage pool) is re-queued on every 5s tick, so all
   `maxCreateAttempts` are spent within seconds.

4. **One failing pool stops the orphan sweep for all of them.**
   `cleanupOrphanedGithubRunners` returns on the first pool whose
   `ListInstances` fails, so a single unreachable provider host skips the
   orphan check for every other pool of the entity, on every pass.

## The fix

1. Mark such an instance `pending_delete` instead; `deletePendingInstances`
   then calls the provider's `DeleteInstance` (which providers implement
   idempotently) before removing the record. Each event is counted in a new
   `garm_runner_absent_from_provider_total{provider}` counter, so a provider
   that has lost sight of its instances is alertable.
2. Use a plain `errgroup.Group`, never return a per-instance failure from the
   goroutine, and back off a failing instance with the existing instance
   backoff.
3. Re-queue an errored instance only after `30s * 2^(attempt-1)` (capped at 20
   minutes) since it last changed. The per-instance backoff entry is dropped
   once nothing will retry it (delete succeeded, attempts exhausted, record
   deleted), so the in-memory map does not grow without bound.
4. Skip only the failing pool for the rest of the pass, keep sweeping the
   others, and return the skipped pools as one error after the sweep.

## Tests

`runner/pool/instance_lifecycle_test.go` drives the real functions against the
real SQLite store with a mocked provider and forge. The five defect tests fail
on the current tree and pass with the fix; a sixth pins that the backoff
entries introduced here are released.
