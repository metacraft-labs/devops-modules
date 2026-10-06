{
  lib,
  buildGoModule,
}:
# Ephemeral-Windows-Runners-GARM M1 — the stateless external provider
# `garm-provider-vmharness`. It speaks GARM's external-provider protocol
# (env + stdin/stdout JSON) via github.com/cloudbase/garm-provider-common
# v0.1.9 (the same execution/params/cloudconfig library GARM's own
# azure/openstack providers use — pinned to the version GARM v0.2.1 vendors,
# see references/garm/vendor/modules.txt), and shells to virsh/vm-harness for
# the libvirt VM lifecycle.
#
# Deps are vendored IN-TREE under src/vendor (like the M0 garm package), so the
# build is fully offline with `vendorHash = null`. The provider itself is pure
# Go (CGO disabled) — no cgo/sqlite, unlike garm.
buildGoModule {
  pname = "garm-provider-vmharness";
  version = "0.1.0";

  # Self-contained Go source (its own go.mod + vendored deps). Kept inside
  # nixos-modules for M1 (may graduate to its own repo later, like the M0
  # garm package graduated conceptually).
  #
  # The same Go module also hosts `garm-provider-agentharbor` (Sovereign-CI-Fleet
  # AH3; see ../garm-provider-agentharbor). Its files are filtered OUT of this
  # package's source so garm-provider-vmharness keeps a byte-identical store
  # path — adding the sibling provider must not roll GARM on every vmharness
  # host. `builtins.path` with the original name "src" keeps the hash equal to
  # the unfiltered `./src` of before. (runner_install_shared.go only exports
  # this package's templates to the sibling; nothing here calls it.)
  src = builtins.path {
    path = ./src;
    name = "src";
    filter =
      path: _type:
      let
        rel = lib.removePrefix (toString ./src + "/") (toString path);
      in
      !(builtins.elem rel [
        "cmd/garm-provider-agentharbor"
        "internal/agentharbor"
        "internal/protocoltest/agentharbor_protocol_test.go"
        "internal/provider/runner_install_shared.go"
      ]);
  };

  # Deps are vendored in-tree → build offline against `vendor/`.
  vendorHash = null;

  # Pure-Go provider: no cgo. Static-ish build.
  env.CGO_ENABLED = "0";

  subPackages = [ "cmd/garm-provider-vmharness" ];

  # Stamp the provider version so `GARM_COMMAND=GetVersion` reports it.
  ldflags = [
    "-s"
    "-w"
    "-X github.com/metacraft-labs/garm-provider-vmharness/internal/version.Version=v0.1.0"
  ];

  # The Go tests (backend lifecycle + the real-protocol gate) run in the
  # dedicated `t_garm_provider_vmharness_protocol` check, not in the package
  # build (the protocol test shells `go build` + a mock virsh, which needs a
  # writable Go env not available in the package's build sandbox check phase).
  doCheck = false;

  meta = {
    description = "GARM stateless external provider for libvirt/KVM Windows runners via vm-harness/virsh";
    homepage = "https://github.com/metacraft-labs/infra";
    license = lib.licenses.asl20;
    mainProgram = "garm-provider-vmharness";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
