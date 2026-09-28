# Don't strand queued jobs when the pool manager's job cache goes stale

## Summary

A queued job for a pool that is at `max_runners` can be abandoned for good:
GARM stops retrying it, and still ignores it after capacity frees up, until
the controller restarts or the job is cancelled on the forge. This PR makes
`consumeQueuedJobs()` keep its in-memory job cache consistent with its own
writes to the store, and recover when the cache and the store disagree.

## The bug

Each pool manager keeps its queued jobs in `r.jobs`, which is fed only by
database-watcher notifications. `consumeQueuedJobs()` reads that cache and
trusts its `LockedBy`:

```go
if time.Since(job.UpdatedAt) >= time.Minute*10 {
    if err := r.store.UnlockJob(r.ctx, job.WorkflowJobID, r.ID()); err != nil { ... }
}

if job.LockedBy.String() == r.ID() {
    // Job is locked by us. ... Skip.
    continue
}
```

When no pool has capacity, one pass locks the job, fails to add a runner and
unlocks it, usually within a millisecond. Two notifications go out: lock, then
unlock. If the manager receives the lock notification last, or never receives
the unlock one, its cached copy says "locked by us" while the store says
unlocked.

The 10-minute retry is meant to recover from this, but it can't:

1. `UnlockJob()` on a row that is already unlocked returns `nil` without
   saving anything and without sending a notification, so the cache is never
   refreshed.
2. The very next check reads the same stale cached `LockedBy` and skips the
   job.

This repeats every pass. The job never gets a runner, even when slots free
up. It stays that way until the controller restarts and rebuilds the cache
from the store, or until the forge sends a new event for the job (for
example, a cancellation).

Before #850 (commits f5d98947, 3e398635, 0d6acdea) the watcher sent each
notification from its own goroutine with a 1-second timeout, so lost and
reordered notifications were routine under load. #850 makes delivery ordered
and lossless, which removes the main trigger. The cache is still a second
copy of state the store owns, though. The concurrent-transaction reordering
that 22e24eb6 guards against, or any future delivery gap, would strand jobs
in exactly the same way, because nothing on this path ever re-reads the store.

A related symptom: a cached job that the store has already deleted (its
delete notification was lost) makes `LockJob()` fail with "not found" on every
pass. If the delete lands between `LockJob()` and the `UnlockJob()` that
follows a failed placement, `consumeQueuedJobs()` returns an error and skips
the rest of the queue for that pass.

## Impact

Observed on a production controller: a pool with `max_runners: 2` was full,
and a third job for it was retried every ~30 s for 12 minutes. Then it was
never attempted again. Both slots freed 26 minutes later. The job stayed
queued, with no runner, for 2.5 hours until it was cancelled. Throughout, the
store had the job `queued` with `locked_by` empty, the forge sent no further
events for it, and the same manager kept serving other jobs every pass. The
same controller logged `could not lock job ... not found` and
`failed to unlock job ... not found` for other entities' cached jobs.

Scale sets are not affected. The forge re-offers their jobs.

## The fix

All changes are in `runner/pool`:

- `refreshCachedJob()`: after `consumeQueuedJobs()` locks or unlocks a job, it
  re-reads that row and stores it in the cache. The cache then reflects the
  manager's own writes whether or not the notification arrives, and the
  timestamps come from the store. It never re-adds a job the watcher has
  already retired, respects `jobUpdateIsStale()`, and retires the job if the
  store now has it completed.
- On the 10-minute path, once `UnlockJob()` succeeds, the local copy is
  treated as unlocked and refreshed. The job is retried in the same pass
  instead of being skipped on a stale lock.
- If `LockJob()` or `UnlockJob()` returns `ErrNotFound`, the job is dropped
  from the cache (with a tombstone) and the pass continues. Before, it was
  retried forever, or aborted the pass.

A genuine lock held by this manager inside the 10-minute window is still
honoured, so the fix does not create duplicate runners.

## Tests

Two tests in `runner/pool/pool_test.go` use the existing
`PoolStressTestSuite` harness (a real SQLite store; only the provider and
the GitHub client are mocked):

- `TestConsumeQueuedJobsRecoversFromStaleLockInCache`: the store has the job
  queued and unlocked, and the cache has it locked by this manager for more
  than 10 minutes. The job must get a runner, and the store must show it
  locked. Fails on `main`: no runner is created.
- `TestConsumeQueuedJobsDropsGhostJobs`: a cached job that the store doesn't
  have is dropped, and the real job behind it is still served. Fails on
  `main`: the ghost stays in the cache.

`go test -tags testing ./runner/pool/` passes.

## How it was found

We traced a job that stayed queued long after its pool had idle capacity.
There were no forge events and no DB changes for it, and every other job on
the same manager was still being served. The only silent `continue` that fit
was the "locked by us" check, and the only way to reach it with an unlocked
row was a cached copy that the 10-minute path cannot refresh.
