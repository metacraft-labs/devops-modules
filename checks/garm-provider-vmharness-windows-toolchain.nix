{ ... }:
{
  # The Windows guest-provisioning tests in `internal/provider` were written to
  # pin one thing that cannot be recovered later: `Initialize-RunnerToolchain`
  # must run BEFORE `Runner.Listener` starts, because actions/checkout is the
  # first step of a job and inherits whatever PATH the runner was launched with.
  # Provisioning that happens afterwards satisfies every content assertion and
  # still leaves checkout without git, silently degrading it to a REST-API zip
  # download with no submodules, no history and no LFS.
  #
  # Nothing ran those tests. `packages/garm-provider-vmharness/default.nix` sets
  # `doCheck = false`, and no workflow invokes `go test` for this package, so the
  # suite existed without ever executing -- a check that cannot report anything
  # is the same class of defect it was written to catch.
  #
  # This mirrors `garm-macos-runner-install-wrapper.nix`, which already enables
  # `doCheck` on a sibling package for exactly this reason. The tests are pure
  # template rendering: no network, no daemon, no guest.
  #
  # The cached-runner version guard tests additionally EXECUTE the rendered
  # guard snippets against real directories: with bash/sh (always present in
  # the build sandbox), with curl (the upstream-Linux guard downloads the
  # offered runner itself; the test serves a local tarball over file://, so no
  # network) and with pwsh, so the PowerShell guards of both Windows templates
  # are gated too. The tests skip a tool only where it is absent, eg an ad-hoc
  # `go test` on a workstation.
  perSystem =
    { self', pkgs, ... }:
    {
      checks.t_garm_provider_vmharness_windows_toolchain =
        self'.packages.garm-provider-vmharness.overrideAttrs
          (old: {
            doCheck = true;
            nativeCheckInputs = (old.nativeCheckInputs or [ ]) ++ [
              pkgs.curl
              pkgs.powershell
            ];
            checkPhase = ''
              runHook preCheck
              # pwsh needs a writable HOME for its module/telemetry caches.
              export HOME="$TMPDIR/home"
              export POWERSHELL_TELEMETRY_OPTOUT=1
              mkdir -p "$HOME"
              go test ./internal/provider
              runHook postCheck
            '';
          });
    };
}
