{
  lib,
  # GARM's go.mod pins `go 1.26.2`. This flake's default `nixpkgs`
  # (nixos-25.11) ships go 1.25.9 as the default `buildGoModule` toolchain, so
  # use the explicit 1.26 builder to satisfy the module directive without
  # letting the Go toolchain try to auto-download 1.26.2 in the sandbox
  # (GOTOOLCHAIN=local under buildGoModule).
  buildGo126Module,
  fetchFromGitHub,
}:
# Ephemeral-Windows-Runners-GARM M0 — package cloudbase/garm (the GitHub
# Actions Runner Manager control plane) for NixOS. GARM vendors all of its Go
# dependencies in-tree (`vendor/` + `vendor/modules.txt`), so the build is
# fully offline with `vendorHash = null` — Nix builds against the checked-in
# vendor directory and pulls NO k8s/cloud SDKs beyond what the pin already
# vendors. The daemon (`garm`) and admin CLI (`garm-cli`) are both produced.
buildGo126Module rec {
  pname = "garm";
  version = "0.2.1-unstable-2026-07-08";

  # v0.2.1 can wedge a scale-set listener forever when a delayed job message
  # races an already-terminal runner transition. Pin the upstream fix merged
  # by cloudbase/garm#817 until the next tagged release includes it. Do not
  # depend on the local references/garm overlay: CI builds this flake alone.
  rev = "0a9a939c10f1e253947b63b0708acaa0c9d5e0bc";

  src = fetchFromGitHub {
    owner = "cloudbase";
    repo = "garm";
    inherit rev;
    hash = "sha256-lv15Q8gzg+SeRxlBXA70W26W+chIOqtgvuMahsMHb6s=";
  };

  # Deps are vendored in-tree → build offline against `vendor/`.
  vendorHash = null;

  patches = [
    ./patches/allow-macos-runner-install-templates.patch
    # Upstream cloudbase/garm gap, the POOL half of the one above. macOS works
    # end to end in SCALE SETS today — m3 has run macOS Tart scale sets in
    # production for months — because that path never consults an OS allow-list.
    # The POOL path does: `runner/types.go` declares
    #   supportedOSType = { params.Linux: {}, params.Windows: {} }
    # and `appendTagsToCreatePoolParams` (runner/runner.go) rejects anything
    # outside it, which is the ONLY caller of IsSupportedOSType in the whole
    # tree. So `garm-cli pool add --os-type macos` 400s with
    #   error fetching pool params: invalid OS type macos
    # (runner/organizations.go:215 wraps it) while the identical scale set is
    # accepted. Observed live on high-mem-server 2026-09-16: the central GARM's
    # reconcile created `metacraft-labs-linux-arm64`, then died on
    # `metacraft-labs-macos-arm64` and restart-looped past 65 attempts, taking
    # the fleet's whole control-plane reconcile with it.
    #
    # This is the capability-pool model's blocker: the fleet is migrating from
    # scale sets (targeted by one precise NAME) to POOLS of classic runners
    # carrying capability labels, so a class that cannot be a pool cannot be
    # reached by `runs-on: [self-hosted, macos, arm64]` at all.
    #
    # For an EXTERNAL provider — which is what this fleet uses — OSType on a
    # pool is close to a passthrough label: it is stored, exported as a metrics
    # label, forwarded to the provider as GARM_POOL_OS_TYPE/the bootstrap
    # params, and used to pick the runner-install template, which the sibling
    # patch above already taught about macOS (and which m3's macOS template is
    # deliberately a stub of — garm-provider-vmharness renders the real
    # bootstrap inside the Tart guest).
    #
    # DEPENDS ON the sibling patch above for `params.MacOS`: the OSType
    # constants live in cloudbase/garm-provider-common, which has only
    # Windows/Linux/Unknown, and that patch adds `MacOS OSType = "macos"` to the
    # vendored copy. Keep it FIRST in this list.
    # See upstream-patches/garm-allow-macos-pools/ and the gate
    # t_garm_macos_pools_supported.
    ./patches/allow-macos-pools.patch
    # Upstream cloudbase/garm bug: the v0.1.1 external-provider ListInstances
    # path guards garmExec.Exec with an INVERTED `if err == nil` (every other
    # command path uses `if err != nil`). On a SUCCESSFUL provider run it took
    # the failure branch and formatted the nil error with %s — the recurring
    #   provider binary <path> returned error: %!s(<nil>)
    # ERROR — AND discarded the real instance list (returned an empty slice),
    # so scale-set runner-state consolidation never saw the provider's runners.
    # The provider (garm-provider-vmharness) is correct: it exits 0 with a valid
    # JSON list per the external-provider contract. One-char fix inverts the
    # check so the error branch fires only on genuine provider failure.
    ./patches/fix-listinstances-inverted-error-check.patch
    # Upstream cloudbase/garm bug: reconcileStaleJobs() — the loop whose whole
    # purpose is to clear jobs that are stuck in `queued` for ever — can never
    # see a SCALE SET job, so on a scale-set-only controller it is a no-op.
    # It selects candidates via ListEntityJobsByStatus(), which hard-filters
    # `workflow_job_id > 0`, and scale set jobs never populate WorkflowJobID
    # (only ScaleSetJobID). It then addresses jobs by WorkflowJobID
    # throughout — dedupe map, lock key, GitHub lookup and store.DeleteJob(),
    # which resolves rows with `WHERE workflow_job_id = ?` — so merely
    # relaxing the filter would make DeleteJob(ctx, 0) delete an ARBITRARY
    # scale set row. Observed on high-mem-server as a permanently `queued`
    # phantom in `garm_job_status` (job_id=16820, workflow_job_id=0), minted
    # when a watchdog reset lost the terminal update for a job whose forge
    # messages had already been consumed. Every reset can mint another and
    # they never clear, which corrupts the CI queue dashboards.
    # See upstream-patches/garm-stale-scaleset-job-reaper/ and the gate
    # t_garm_stale_scaleset_job_reaped.
    ./patches/fix-stale-scaleset-job-reaper.patch
    # Instance-lifecycle leaks (three pool-manager defects, observed on central
    # GARM, high-mem-server, 2026-09-22/23):
    #  1. cleanupOrphanedGithubRunners DELETED the DB row of a runner that was
    #     offline in GitHub and absent from ListInstances, never calling the
    #     provider's DeleteInstance. With a provider that could not enumerate
    #     (the remote vmharness backend answered every list with []) every
    #     Windows runner still booting at 5 minutes was forgotten while its VM
    #     ran on: ~210 leaked libvirt domains / 55 GiB. Now: pending_delete, so
    #     the provider's (idempotent) delete runs first.
    #  2. retryFailedInstances ran a pool's cleanup deletes in one
    #     errgroup.WithContext: the first failure SIGKILLed every sibling
    #     delete and all were retried every 5s (~88k failures/24h, ~31k
    #     `signal: killed`, ~23k `context canceled`). Now: independent deletes,
    #     per-instance backoff.
    #  3. Fast-failing creates (full storage pool) were re-queued every 5s.
    #     Now: 30s * 2^(attempt-1), capped at 20m.
    # See upstream-patches/garm-instance-lifecycle-leaks/ and the gate
    # t_garm_instance_lifecycle.
    ./patches/fix-instance-lifecycle-leaks.patch
    # Stranded queued jobs (central GARM, high-mem-server, 2026-09-28). The
    # agent-harbor Windows pool (maxRunners 2) was full; GARM retried the
    # third job every ~30 s until 11:57:56Z, then never looked at it again.
    # The slots freed at 12:23Z and the job sat queued for 2.5 h until it was
    # cancelled. GitHub sent no update for it in between (webhook delivery
    # log), and the row stayed queued and unlocked in the DB.
    #
    # Cause: each pool manager keeps an in-memory copy of its queued jobs,
    # fed by database-watcher notifications. At this pin the watcher
    # delivered each notification from its own goroutine with a 1 s timeout
    # into a 1-slot channel, so notifications could be DROPPED or arrive OUT
    # OF ORDER. consumeQueuedJobs() locks a job, fails to place it, and
    # unlocks it about 1 ms later. If the unlock notification is lost or
    # overtaken by the lock's, the cache says "locked by us" while the DB
    # says unlocked. The 10-minute retry then calls UnlockJob(), which is a
    # silent no-op on an unlocked row and sends no notification, and the
    # cache is trusted again: the job is skipped on every pass until GARM
    # restarts. Pools depend on this cache; scale sets do not (GitHub
    # re-offers their jobs), which is why only pools strand.
    #
    # Two patches:
    #  1. backport-watcher-lossless-delivery: upstream's own fix for the
    #     dropped/reordered notifications (cloudbase/garm f5d98947, 3e398635,
    #     0d6acdea, 2026-09-01..08; ordered, unbounded per-consumer queue).
    #     Drop it when the pin moves past 0d6acdea.
    #  2. fix-job-cache-stale-lock: consumeQueuedJobs() writes its own
    #     unlocks through to the cache, heals a cached "locked by us" once
    #     the 10-minute retry has unlocked the row, and drops cached jobs the
    #     DB no longer has (instead of erroring on them every pass). Upstream
    #     HEAD still trusts the cache here, so this is proposed upstream.
    # See upstream-patches/garm-job-cache-stale-lock/ and the gate
    # t_garm_job_cache_self_heal.
    ./patches/backport-watcher-lossless-delivery.patch
    ./patches/fix-job-cache-stale-lock.patch
    # Busy runners and the runner cleanup loop (central GARM, high-mem-server,
    # 2026-09-27..29). 63 pool runners were "reaped" in 2.5 days; 17 of them
    # were mid-job. GitHub reported them offline (the listener session
    # lapsed on a starved or partitioned host) but BUSY, and refused the
    # removal with 422 ("invalid request" in the log). GARM did not destroy
    # them — the jobs had already died of "lost communication", and every
    # instance was removed after GitHub ended its job — but only GitHub's
    # 422 stood in the way:
    #  1. reapTimedOutRunners times a runner out from UpdatedAt, which is not
    #     refreshed while a job runs, and never reads the forge's busy flag.
    #     Now: a runner the forge reports busy is never reaped.
    #  2. Each refusal returned from reapTimedOutRunners, so the rest of the
    #     pass was skipped and runnerCleanup never ran the orphan sweep for
    #     the entity, every pass, until the job ended. Now: per-runner
    #     failures are collected; the orphan sweep always runs.
    #  3. cleanupOrphanedProviderRunners force-marks pending_delete any
    #     instance missing from ONE runner listing (the paginated API can drop
    #     a runner that moves between pages), with no age check and without
    #     asking the forge. Now: an ACTIVE instance goes through DeleteRunner,
    #     so the forge answers first (422 while busy, not-found when gone).
    #  4. cleanupOrphanedGithubRunners skips offline-but-busy runners.
    # Cut against the tree with every patch above applied; keep it LAST.
    # See upstream-patches/garm-busy-runner-reap/ and the gate
    # t_garm_busy_runner_not_reaped.
    ./patches/fix-busy-runner-reap.patch
  ];

  # go-sqlite3 is a cgo module; the daemon needs cgo to link SQLite.
  # (The upstream Makefile builds with sqlite_omit_load_extension; we keep
  # cgo on so the SQLite driver links.)
  env.CGO_ENABLED = "1";

  # Build both binaries the upstream Makefile builds.
  subPackages = [
    "cmd/garm"
    "cmd/garm-cli"
  ];

  # Match the upstream build tags (osusergo/netgo static-ish build + the
  # SQLite extension-loading omission) so runtime behaviour matches a stock
  # `make build`.
  tags = [
    "osusergo"
    "netgo"
    "sqlite_omit_load_extension"
  ];

  # Stamp the version the way the Makefile does
  # (-X .../util/appdefaults.Version). Without this, `garm --version` prints
  # "v0.0.0-unknown". The M0 gate asserts this equals the pin.
  ldflags = [
    "-s"
    "-w"
    "-X github.com/cloudbase/garm/util/appdefaults.Version=v${version}"
  ];

  # The repo has no compilable tests wired for an offline vendored build and
  # the M0 gate exercises the binaries in a VM; skip the Go check phase.
  doCheck = false;

  meta = {
    description = "GitHub Actions Runner Manager (GARM) — control plane for self-hosted runners";
    homepage = "https://github.com/cloudbase/garm";
    license = lib.licenses.asl20;
    mainProgram = "garm";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
