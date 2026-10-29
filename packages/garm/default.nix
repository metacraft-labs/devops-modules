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
  version = "0.2.1-unstable-2026-10-23";

  # cloudbase/garm main at 33ec0921 (2026-10-23). It carries the upstream
  # fixes that replaced three local patches: 488cf98b (ListInstances inverted
  # error check), 8c64910f (scale set jobs in their own table, pruned after
  # 24h, superseding the stale scale-set job reaper) and f5d98947/3e398635/
  # 0d6acdea (lossless watcher delivery). It also still carries the
  # cloudbase/garm#817 fix the previous pin (0a9a939c) was chosen for. Do not
  # depend on the local references/garm overlay: CI builds this flake alone.
  #
  # Restarting garm.service on this pin runs upstream's database migrations
  # between 0a9a939c and 33ec0921 (pseudo pool IDs, constraint parity, the
  # scale set jobs table, tags.name widening). Restart it in a quiet window
  # and only after garm-provider-gosti `serve` has rolled out to every
  # runner host.
  rev = "33ec0921418a470ca7e00dfb20ae111595da24e1";

  src = fetchFromGitHub {
    owner = "cloudbase";
    repo = "garm";
    inherit rev;
    hash = "sha256-8BMEcFuTntcYDVoI+6VxSOyIT3m4t7ZVbbLb+YEd/uk=";
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
    # deliberately a stub of — garm-provider-gosti renders the real
    # bootstrap inside the Tart guest).
    #
    # DEPENDS ON the sibling patch above for `params.MacOS`: the OSType
    # constants live in cloudbase/garm-provider-common, which has only
    # Windows/Linux/Unknown, and that patch adds `MacOS OSType = "macos"` to the
    # vendored copy. Keep it FIRST in this list.
    # See upstream-patches/garm-allow-macos-pools/ and the gate
    # t_garm_macos_pools_supported.
    ./patches/allow-macos-pools.patch
    # Instance-lifecycle leaks (three pool-manager defects, observed on central
    # GARM, high-mem-server, 2026-09-22/23):
    #  1. cleanupOrphanedGithubRunners DELETED the DB row of a runner that was
    #     offline in GitHub and absent from ListInstances, never calling the
    #     provider's DeleteInstance. With a provider that could not enumerate
    #     (the remote gosti backend answered every list with []) every
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
    # fed by database-watcher notifications. At the previous pin (0a9a939c) the watcher
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
    # The dropped/reordered notifications are fixed upstream (f5d98947,
    # 3e398635, 0d6acdea, 2026-09-01..08; ordered, unbounded per-consumer
    # queue), which this pin carries, so the backport is gone. The cache can
    # still go stale on its own, so fix-job-cache-stale-lock remains:
    # consumeQueuedJobs() writes its own unlocks through to the cache, heals a
    # cached "locked by us" once the 10-minute retry has unlocked the row, and
    # drops cached jobs the DB no longer has (instead of erroring on them every
    # pass). Upstream HEAD still trusts the cache here, so this is proposed
    # upstream.
    # See upstream-patches/garm-job-cache-stale-lock/ and the gate
    # t_garm_job_cache_self_heal.
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
    # Stuck deletes consumed pool capacity (central GARM, high-mem-server,
    # 2026-09-30). incus deletes failed for hours with `zfs destroy: dataset
    # is busy` (a nix build pinned the stopped containers' rootfs; fixed in
    # infra), and the rows sat in deleting/pending_delete. GARM counts EVERY
    # row against MaxRunners in three places: the pool manager's
    # addRunnerToPool (PoolInstanceCount) and ensureIdleRunnersForOnePool,
    # the database's own transactional check in CreateInstance, and the
    # scale-set worker's runnerCount (len(w.runners)). So a pool whose deletes
    # stall has no runners left. That also blocked the Terraform lane.
    # Now: an instance on the deletion lane does not hold a slot, up to
    # MaxRunners of them (internal/capacity.Occupied). The bound keeps a
    # provider whose deletes never succeed at <= 2 x MaxRunners on the host.
    # A deleting row with runner status `pending` is also no longer counted
    # as an idle runner for min-idle, and scale-set scale-down acts on live
    # runners only. Cut against the tree with every patch above applied; keep
    # it LAST. Gates: internal/capacity tests and
    # TestPoolStressTestSuite/TestStuckDeletesDoNotConsumePoolCapacity (real
    # sqlite store, defined in checks/garm/deleting_capacity_test.go), both run
    # by t_garm_deleting_capacity (checks/garm-deleting-capacity.nix) against
    # this tree and, as a negative control, the tree without this patch. The
    # test stays outside the patch so the control can run it too.
    ./patches/fix-deleting-instances-hold-capacity.patch
    # consumeQueuedJobs skips, without touching the store, a queued job whose
    # every matching pool already refused a runner in the same pass. Upstream locks the job, tries every
    # pool (each "max workers reached"), and unlocks it: two write transactions
    # per job per pass. During a CI backlog behind full pools on
    # high-mem-server (2026-10-14) that was thousands a minute on SQLite's
    # single connection (GARM sets MaxOpenConns=1). POST /webhooks requests
    # waited 50 s to 3 min, every /api/v1 request waited behind them (the
    # init middleware reads the DB), and the API watchdog restarted
    # garm.service twice. A pool that refuses a runner (ErrNoCapacity from
    # addRunnerToPool, so whatever accounting the patches above give it,
    # including deleting instances not holding a slot) is remembered as full
    # for the rest of the pass, and a job whose every pool is full is skipped
    # before LockJob. Tests in runner/pool (testing tag), run by
    # t_garm_skip_queued_jobs_when_pools_full.
    ./patches/skip-queued-jobs-when-pools-full.patch
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
