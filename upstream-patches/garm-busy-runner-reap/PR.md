# Never reap a runner the forge reports busy

## Summary

The pool manager's runner cleanup loop decides whether a runner has timed
out, or is an orphan, without looking at GitHub's `busy` flag. A runner that
is executing a job can be reported `offline` while still `busy`, and today the
only thing that keeps GARM from retiring it mid-job is GitHub refusing the
removal with 422. This PR carries the busy flag through the runner listings
and makes the cleanup paths respect it, and stops one refused removal from
cutting the rest of the cleanup pass short.

## The bug

`runnerCleanup()` lists the forge's runners and then runs
`reapTimedOutRunners()` and `cleanupOrphanedRunners()`. `forgeRunner` has no
busy field, so neither step can tell a finished runner from a working one.

1. `reapTimedOutRunners()` times a runner out when the instance's `UpdatedAt`
   is older than `runner_bootstrap_timeout` and the forge reports the runner
   `offline` (or does not list it). `UpdatedAt` is not refreshed while a job
   runs, so every job longer than the bootstrap timeout is exposed. A runner
   whose listener session lapses mid-job (a starved host, a short network
   partition) shows up as `offline` + `busy` and is handed to
   `DeleteRunner()`.

2. GitHub refuses to remove a busy runner (422, surfaced as
   `ErrBadRequest`). `reapTimedOutRunners()` returns that error immediately,
   so the remaining instances are not examined, and `runnerCleanup()` returns
   before `cleanupOrphanedRunners()`, skipping the orphan sweep for the whole
   entity. This repeats on every pass until the job ends.

3. `cleanupOrphanedProviderRunners()` marks `pending_delete` any instance
   whose name is missing from one listing of the forge's runners, with no age
   check for an `active` runner and without asking the forge. The paginated
   listing can miss a runner that moves between pages while it is being read
   (the code says as much), so an instance can be destroyed under a running
   job.

4. `cleanupOrphanedGithubRunners()` treats an `offline` + `busy` runner as an
   orphan candidate; the removal is refused and the error fails the sweep.

## Impact

Observed on a production controller with pool runners on busy hosts: 17
timed-out-runner reaps in two and a half days hit runners that were running a
job. GitHub refused each one, so no job was lost to GARM, but every refusal
logged an error and skipped the orphan sweep for that entity until the job
ended. Path 3 would lose the job outright whenever a listing omits a busy
runner.

## The fix

- `forgeRunner` gains `Busy`, filled from `github.Runner.GetBusy()` in
  `listRunnersWithPagination()` and from `RunnerReference.Busy` in
  `listRunnersWithScaleSetAPI()`.
- `reapTimedOutRunners()` skips a runner the forge reports busy, and keeps
  going when a `DeleteRunner()` fails, returning all failures joined at the
  end.
- `runnerCleanup()` runs `cleanupOrphanedRunners()` even when the reap
  reported errors, and returns both.
- `cleanupOrphanedProviderRunners()` retires an `active` instance that is
  missing from the listing through `DeleteRunner()`, so the forge is asked
  first: 422 while it is busy (the instance is left alone), not-found when it
  really is gone (the instance is marked for deletion as before). Instances in
  any other runner state keep the existing behaviour.
- `cleanupOrphanedGithubRunners()` skips `offline` + `busy` runners.

Runners that are really finished are retired exactly as before: the busy flag
clears when the job ends, and the completed `workflow_job` webhook still marks
the instance for deletion.

## Tests

`runner/pool/busy_runner_reap_test.go` calls `runnerCleanup()` and
`cleanupOrphanedProviderRunners()` against the real SQLite store with a mocked
forge client (the runner list goes through `listRunnersWithPagination()`):

- `TestBusyRunnerPastBootstrapTimeoutIsNotReaped` — offline + busy, 24 min
  past a 20 min bootstrap timeout: the forge is not asked to remove it and the
  pass returns no error.
- `TestRefusedReapDoesNotSkipOrphanSweep` — one refused removal; the orphan
  sweep still removes an unrelated orphaned runner in the same pass.
- `TestActiveRunnerMissingFromOneListingIsNotDestroyed` — an active instance
  absent from the listing whose removal the forge refuses stays `running`.
- Controls: an idle offline runner past the timeout is still reaped; an
  active runner the forge no longer has is still retired.

The first three fail without the change; the controls pass with and without
it. `go test -tags testing ./runner/...` passes.

## How it was found

Investigating CI jobs that failed with "The self-hosted runner lost
communication with the server". The controller's log showed a "reaping
timed-out/failed runner" line followed by `invalid request` for each of these
runners; correlating with the job timelines showed the runner had gone
offline first and the jobs were lost to the host, not to GARM, but that the
refusal was the only safeguard.
