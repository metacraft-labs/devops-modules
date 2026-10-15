{ ... }:
{
  # t_garm_skip_queued_jobs_when_pools_full: the consumeQueuedJobs tests of
  # GARM's own pool stress suite (runner/pool, build tag `testing`, a real
  # SQLite store) on the PATCHED source, including the two tests the
  # skip-queued-jobs-when-pools-full patch adds:
  #   - a pass over a backlog behind a full pool writes to at most the first
  #     job (no lock/unlock churn); it fails on the unpatched source;
  #   - a pass with free capacity still fills it, and no further.
  perSystem =
    { self', ... }:
    {
      checks.t_garm_skip_queued_jobs_when_pools_full = self'.packages.garm.overrideAttrs (_old: {
        doCheck = true;
        checkPhase = ''
          runHook preCheck
          export HOME="$TMPDIR"
          # The consumeQueuedJobs tests only: the whole stress suite runs past
          # go test's 10 min default on a loaded builder.
          go test -tags testing -count=1 -timeout 30m ./runner/pool/ \
            -run 'TestPoolStressTestSuite/(TestConsumeQueuedJobs|TestConcurrentQueuedJobs|TestJobStuckInQueued|TestMissedWebhookRecovery)' -v \
            | grep -E '^(    --- |--- |ok|FAIL|PASS)'
          runHook postCheck
        '';
      });
    };
}
