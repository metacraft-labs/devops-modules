# Make reconcileStaleJobs able to see and reap scale set jobs

## Summary

`reconcileStaleJobs()` exists so that a job GARM believes is `queued`, but which
the forge has since finished, does not sit in the database for ever. On any
controller that uses runner scale sets it has never been able to do that. Two
independent defects stop it, and the second one means fixing only the first
would be actively dangerous.

## The bug

### 1. The candidate query cannot return a scale set job

`reconcileStaleJobs()` (`runner/pool/pool.go`) selects its candidates with:

```go
queued, err := r.store.ListEntityJobsByStatus(r.ctx, r.entity.EntityType, r.entity.ID, params.JobStatusQueued)
```

and `ListEntityJobsByStatus` (`database/sql/jobs.go`) hard-filters on the
workflow job ID:

```go
query := s.conn.
    Model(&WorkflowJob{}).
    Preload("Instance").
    Where("status = ?", status).
    Where("workflow_job_id > 0")
```

Scale set jobs are recorded by `workers/scaleset` from the runner-scale-set
message protocol, which has no workflow job ID at all —
`ScaleSetJobMessage.ToJob()` (`params/github.go`) populates `ScaleSetJobID` and
leaves `WorkflowJobID` at its zero value:

```go
func (s ScaleSetJobMessage) ToJob() Job {
    return Job{
        ScaleSetJobID:   s.JobID,
        ...
```

So the candidate list is _guaranteed_ to exclude every scale set job. On a
scale-set-only controller `reconcileStaleJobs()` lists nothing, calls the forge
for nothing and deletes nothing — it is a no-op, every five minutes, for ever.

### 2. The reconciler addresses jobs by an ID scale set jobs do not have

`reconcileStaleJobs()` keys its "recently checked" map, its advisory lock, its
GitHub lookup and its delete on `WorkflowJobID`. The delete goes through
`store.DeleteJob()`, which resolves the row by that column alone:

```go
func (s *sqlDatabase) DeleteJob(_ context.Context, jobID int64) error {
    ...
        q := tx.Where("workflow_job_id = ?", jobID).Preload("Instance").First(&workflowJob)
```

Because every scale set row carries `workflow_job_id = 0`, relaxing the filter
on its own would: collapse every scale set job of an entity onto the single map
key `0` and the single lock key `stale-job-check-0`; ask GitHub for job `0` (a 404,
which the reaper reads as "the job is gone"); and then call
`DeleteJob(ctx, 0)`, whose `First()` matches an _arbitrary_ row with
`workflow_job_id = 0` — quite possibly one that is running.

## Impact

A scale set job whose terminal message is lost — the daemon is killed, the host
resets, the database write does not survive — stays `queued` in the database
permanently. The forge message queue has already been consumed
(`DeleteMessage`), so the terminal state can never be redelivered, and
`DeleteInactionableJobs()` deliberately exempts the row, since its predicate is
`(status != 'queued' AND instance_id IS NULL) OR (status = 'completed' AND
instance_id IS NOT NULL)`. `reconcileStaleJobs()` is the only mechanism in GARM
that could ever clear it, and it cannot see it.

The row is then reported for ever by `garm_job_status{status="queued"}` and by
`GET /api/v1/jobs`, so any queue dashboard built on either is quietly wrong —
and gains one more permanent phantom on every subsequent loss event.

We hit this on a controller that serves three organisations entirely through
scale sets: every row in its `workflow_jobs` table has `workflow_job_id = 0`, so
its stale-job reconciler had never had a single candidate to consider in months
of uptime, and one job left `queued` by a host reset had been sitting there for
four days when we went looking.

## The fix

- `ListEntityJobsByStatus()` now accepts a row that carries _either_ forge-side
  identifier: `workflow_job_id > 0 OR scale_set_job_id <> ''`. Rows with
  neither remain excluded.

- A new `store.DeleteJobByID()` resolves the row by its own primary key — the
  one identifier both job kinds always have — and `reconcileStaleJobs()` uses
  it, and keys its dedupe map and advisory lock on `params.Job.ID` too.

- Scale set jobs have no workflow-job endpoint to query, so they are checked at
  the granularity that does exist: the workflow _run_. `GithubClient` gains
  `GetWorkflowRunByID()`, satisfied for free by the embedded
  `*github.ActionsService`. A scale set job is treated as stale only when its
  run reports `status == "completed"`, or when the run 404s. Anything short of
  completed — `queued`, `in_progress`, `waiting`, `requested`, `pending` — is
  left alone, so a genuinely queued job is never reaped.

- Two callers relied on the old filter to keep scale set jobs away from pool
  machinery, so they are guarded explicitly now that the filter is relaxed:
  `scaleDown()`'s stale-job cleanup and `consumeQueuedJobs()` both skip rows
  with `WorkflowJobID == 0`. Neither can serve a scale set job, and both would
  otherwise call `DeleteJob`/`LockJob`/`UnlockJob` with a job ID of `0`.
  `consumeQueuedJobs()` can already reach that state today, because
  `runWatcher()`'s event handler adds scale set jobs to the in-memory job map
  without consulting the filter at all — only the startup seed goes through
  `ListEntityJobsByStatus()`.

## Testing

`runner/pool/stale_scaleset_job_test.go` drives the real
`basePoolManager.reconcileStaleJobs()` — both directly and through the real
`startLoopForFunction()` loop — against the real `database/sql` store on a real
SQLite file, with only the forge mocked. It covers:

- a queued scale set job appears in the reconciler's candidate list at all;
- one reconcile pass clears a scale set job whose run has completed;
- a scale set job whose run is still `in_progress` is **not** cleared;
- with three scale set rows all carrying `workflow_job_id = 0`, exactly the
  stale one is deleted and the live siblings — including one `in_progress` —
  survive;
- an ordinary workflow-job row is still reaped through the unchanged path.

Every one of the scale-set cases fails on `main` and passes with this change;
the workflow-job case passes on both.

<!-- After opening, record the PR URL here: -->
<!-- PR: https://github.com/cloudbase/garm/pull/XXXX -->
