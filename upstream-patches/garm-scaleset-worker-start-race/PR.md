# Re-read the scale set after the worker subscribes to updates

## Summary

A scale set worker can miss an update to its scale set that is committed
while the worker is starting. The worker then runs on a stale copy until
GARM restarts. The visible case is a scale set enabled during startup: the
worker stays disabled, never opens a message session, and jobs queue. This
PR re-reads the scale set once the worker's watcher consumer is registered,
and adds info-level logs for a worker that is parked because its scale set
is disabled.

## The bug

`NewWorker()` stores the `params.ScaleSet` it is given, which the scale set
controller loaded from the database when it built the worker. `Start()`
then lists the scale set's instances, calls `ensureScaleSetInGitHub()`
(several forge calls), and only after that registers its watcher consumer.
The controller starts its workers one at a time from the retry loop, so for
the later workers this window lasts as long as the earlier workers' forge
calls.

The watcher delivers changes made after `RegisterConsumer()`. An update
committed inside the window is published to nobody that cares: the
controller's consumer receives it, but `handleScaleSetUpdateOperation()`
sees a running worker (`IsRunning()` waits for `Start()` to release the
mutex) and leaves the update to the worker's own consumer, which did not
exist yet. Repeating the update does not help. The row does not change, so
nothing is published.

If the missed update was `enabled: true`, `sessionLoopMayRun()` keeps
returning false and `keepListenerAlive()` sleeps in 2 second steps forever.
Nothing above debug level says why.

We hit this when a deploy disabled every scale set, restarted GARM, and
enabled them again as soon as the API answered. Five of six workers
subscribed before their update. The sixth subscribed 0.17 s after it and
stayed disabled until the next restart, about a day later.

## The fix

In `Start()`, after `RegisterConsumer()` succeeds, read the scale set again
with `GetScaleSetByID()` and replace the worker's copy. A write is now
either committed before that read, or delivered as an event. `Start()`
holds `w.mux` throughout, and the event handlers only run once the loops it
starts are running, so the copy is never written concurrently.

Logging, at info level:

- `Start()`: when the scale set is disabled, so the listener will not
  start.
- `handleScaleSetEvent()`: when an update enables or disables the scale set.
- the re-read: when the fresh copy's `Enabled` differs from the one the
  worker was built from.

## Tests

`workers/scaleset/scaleset_worker_update_race_test.go` (build tag
`testing`) builds a worker from a disabled scale set over a real SQLite
store and the real watcher, with a fake forge on `httptest`. The fake
forge's scale set lookup, which `ensureScaleSetInGitHub()` calls before the
worker subscribes, enables the scale set in the database. The test then
requires that the worker's copy is enabled and that the listener asks the
fake forge for a message session.

Without the re-read the test fails on both checks: the worker keeps the
disabled copy and never requests a session.

```
go test -tags testing -race ./workers/scaleset/ -run TestWorkerStartSeesUpdateCommittedBeforeSubscribe
```

## Other workers

`runner/pool` reads each pool's `Enabled` from the cache on every pass, so
pools do not have this problem. The scale set controller and the cache
worker also load their state before they register a consumer. With this
change a missed update to an existing scale set no longer matters for its
worker, but a scale set created inside the controller's own window would
still be missed until restart. That is left for a separate change.
