{ ... }:
{
  # t_garm_metrics_snapshots: the runner/metrics tests that the
  # publish-metric-snapshots patch adds, on the PATCHED source. The race test
  # gathers a 50-series family while it is refreshed 2000 times and requires
  # that no gather sees it empty. With upstream's Reset() before the refill
  # it saw the family empty 215 times (measured 2026-11-02 against the
  # 33ec0921 tree with every patch applied).
  #
  # The grep keeps the patched collectors from drifting back: none of them
  # may Reset() a family it publishes through a snapshot.
  perSystem =
    { self', ... }:
    {
      checks.t_garm_metrics_snapshots = self'.packages.garm.overrideAttrs (_old: {
        doCheck = true;
        checkPhase = ''
          runHook preCheck
          export HOME="$TMPDIR"
          if grep -n 'Reset()' runner/metrics/instance.go runner/metrics/jobs.go \
            runner/metrics/pool.go runner/metrics/scaleset.go; then
            echo "a snapshot-published collector calls Reset() again" >&2
            exit 1
          fi
          go test -count=1 -race ./runner/metrics/ -v \
            | grep -E '^(    --- |--- |ok|FAIL|PASS)'
          runHook postCheck
        '';
      });
    };
}
