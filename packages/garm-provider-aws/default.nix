{
  lib,
  buildGoModule,
  fetchFromGitHub,
  applyPatches,
}:
# Runner-Fleet-Capability-Pools-And-Remote-Driving RE3/RE4 — package
# cloudbase/garm-provider-aws, GARM's official EC2 external provider, for NixOS.
# It provisions ephemeral EC2 runners (`--ephemeral` one-job auto-terminate) and
# is the AWS BURST tier of the fleet: the central GARM spills to it, via a lower
# pool `--priority`, only when the on-prem hosts are saturated, keeping a small
# always-warm floor (`min-idle-runners`).
#
# Packaged like `garm` (fetchFromGitHub + `vendorHash = null`): the upstream
# vendors ALL of its Go deps in-tree (`vendor/` + `vendor/modules.txt`), incl.
# the AWS SDK v2, so the build is fully offline. Pure Go — no cgo.
#
# SPOT PATCH PROVENANCE (Apache-2.0). Upstream garm-provider-aws launches
# ON-DEMAND instances only: its extra-specs schema (internal/spec/spec.go) has
# NO spot / InstanceMarketOptions field (verified against `main` @ 5df254e4).
# `patches/0001-add-spot-instance-market-options.patch` is a Metacraft Labs
# downstream patch that adds it. garm-provider-aws is Apache-2.0
# (LICENSE = Apache License 2.0, per-file `SPDX-License-Identifier: Apache-2.0`),
# and this patch is contributed under the SAME Apache-2.0 terms so it can be
# upstreamed (RE4 deliverable: "upstream it if accepted"). It:
#   * adds `market_type` (enum: spot), `spot_max_price`, `spot_instance_type`
#     (one-time|persistent), `spot_instance_interruption_behavior`
#     (terminate|stop|hibernate), and `on_demand_fallback` to the per-pool
#     extra-specs (internal/spec/spec.go);
#   * sets EC2 `InstanceMarketOptions{MarketType: spot, SpotOptions{…}}` on the
#     RunInstances call when a pool requests spot (internal/client/aws.go);
#   * implements the on-demand FALLBACK: a spot capacity/price rejection retries
#     the SAME launch on-demand (InstanceMarketOptions cleared) when
#     `on_demand_fallback` is set, so a burst still lands — at on-demand cost —
#     rather than starving the queue;
#   * ships white-box tests (internal/client/spot_test.go) that drive the
#     provider's own EC2-client mock to assert the rendered RunInstances, the
#     fallback path, and that FindInstances excludes interrupted (terminated /
#     shutting-down) spot instances so GARM's reconcile re-queues the job.
# Graceful spot-interruption handling itself is GARM control-plane behaviour
# (GitHub re-queues the job, GARM's DB-as-truth reconcile drops the vanished
# instance); the provider's part is exactly that state-filter, which the patch's
# test pins.
let
  rev = "5df254e4845326d27a069174810cda36423e556a";
  src = applyPatches {
    name = "garm-provider-aws-src-${rev}-spot";
    src = fetchFromGitHub {
      owner = "cloudbase";
      repo = "garm-provider-aws";
      inherit rev;
      hash = "sha256-6lYt7l+JPLBCrfbQ9lG8OZ5+10X6ua4ZjJc7u6JKWkA=";
    };
    patches = [ ./patches/0001-add-spot-instance-market-options.patch ];
  };
in
buildGoModule {
  pname = "garm-provider-aws";
  version = "0.1.6";

  # `src` is the PATCHED tree (applyPatches above), so it is referenceable by
  # the hermetic gates (`self'.packages.garm-provider-aws.src`) to run the spot
  # unit tests offline against the vendored deps — and no `patches = [ … ]` is
  # applied a second time here.
  inherit src;

  # Deps are vendored in-tree → build offline against `vendor/`.
  vendorHash = null;

  # Pure-Go provider: no cgo (unlike garm, which links SQLite).
  env.CGO_ENABLED = "0";

  # main.go lives at the module root; the binary is `garm-provider-aws`.
  subPackages = [ "." ];

  ldflags = [
    "-s"
    "-w"
  ];

  # The Go tests (incl. the spot patch's spot_test.go) run in the dedicated
  # hermetic gates t_aws_burst_runners / t_aws_spot_runners against this same
  # patched source, not in the package build sandbox.
  doCheck = false;

  meta = {
    description = "GARM external provider for ephemeral AWS EC2 runners (with a Metacraft Labs spot/InstanceMarketOptions patch)";
    homepage = "https://github.com/cloudbase/garm-provider-aws";
    license = lib.licenses.asl20;
    mainProgram = "garm-provider-aws";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
