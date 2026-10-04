{
  lib,
  buildGoModule,
}:
# Sovereign-CI-Fleet AH3 — `garm-provider-agentharbor`, GARM's stateless
# external provider that launches ephemeral runners as agent-harbor sandbox
# jobs through ah's REST direct-sandbox-launch endpoints (agent-harbor
# specs/REST-Service/Direct-Sandbox-Launch.md).
#
# It is a second command in the SAME Go module as garm-provider-vmharness
# (../garm-provider-vmharness/src), not a copy: it reuses that module's JIT
# runner-install templates, cached-runner version guard and guest-URL rewrite
# directly, and its vendored garm-provider-common. Offline build against the
# in-tree vendor/ (`vendorHash = null`), pure Go, no cgo.
buildGoModule {
  pname = "garm-provider-agentharbor";
  version = "0.1.0";

  src = ../garm-provider-vmharness/src;
  vendorHash = null;
  env.CGO_ENABLED = "0";

  subPackages = [ "cmd/garm-provider-agentharbor" ];

  ldflags = [
    "-s"
    "-w"
    "-X github.com/metacraft-labs/garm-provider-vmharness/internal/version.Version=v0.1.0"
  ];

  # The Go tests (behavioural matrix + the end-to-end protocol gate that
  # executes the install script) run in the dedicated
  # `t_garm_provider_agentharbor` check, which needs bash/curl/tar on PATH.
  doCheck = false;

  meta = {
    description = "GARM stateless external provider for ephemeral runners launched as agent-harbor sandbox jobs";
    homepage = "https://github.com/metacraft-labs/devops-modules";
    license = lib.licenses.asl20;
    mainProgram = "garm-provider-agentharbor";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
