{ ... }:
{
  # t_garm_skip_queued_jobs_when_pools_full: GARM's own pool stress suite
  # (runner/pool, build tag `testing`, a real SQLite store) on the PATCHED
  # source, including the two tests the skip-queued-jobs-when-pools-full patch
  # adds:
  #   - a pass over a backlog behind full pools leaves every job row untouched
  #     (no lock/unlock churn); it fails on the unpatched source;
  #   - a pass with free capacity still fills it, and no further.
  perSystem =
    { self', ... }:
    {
      checks.t_garm_skip_queued_jobs_when_pools_full = self'.packages.garm.overrideAttrs (_old: {
        doCheck = true;
        checkPhase = ''
          runHook preCheck
          export HOME="$TMPDIR"
          go test -tags testing -count=1 ./runner/pool/ -run 'TestPoolStressTestSuite'
          runHook postCheck
        '';
      });
    };
}
