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
  version = "0.2.1";

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
