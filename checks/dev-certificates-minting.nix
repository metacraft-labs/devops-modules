# environment-domains-and-dev-certificates.md §4 + §7 — the minting tool's
# integration test, run as a flake check.
#
# §7 is the reason this is not a file-shape assertion: "certificates being
# installed is not evidence that TLS works". The script this runs mints a real
# root and real leaves with real openssl and then completes a real TLS handshake
# against `openssl s_server`, with hostname verification on, plus the three
# negative controls that make the positive one mean something (a name the leaf
# does not carry, a client with no trust anchor, and a connection that was
# actually established rather than refused).
#
# Loopback TCP is available inside the Nix build sandbox, which is what lets the
# handshake half run here rather than only by hand — but only on Linux by
# default. macOS's sandbox denies even loopback unless the derivation asks, which
# is what `__darwinAllowLocalNetworking` does; without it this check cannot bind a
# port on a darwin builder and the handshake subtests fail there while passing on
# Linux. It is set unconditionally because the attribute is simply ignored
# elsewhere.
#
# The darwin leg was verified on aarch64-darwin with `--option sandbox true`:
# all assertions pass with the attribute; with it set to false the build FAILS at
# "TLS server came up on the minted leaf" -- so the attribute is load-bearing
# and a darwin sandbox that denies loopback turns this check red, not green.
{ ... }:
{
  perSystem =
    { pkgs, lib, ... }:
    let
      # CARRY: NixOS/nixpkgs#588798 (bash: disable NLS on Darwin). On darwin
      # the stdenv bash's bundled libintl calls CoreFoundation from
      # setlocale(), and bash calls that in forked subshells when a temporary
      # `LC_ALL=C cmd` inside `$(...)` restores the locale -- which
      # mint-dev-certificates.sh does in its SAN comparison. CoreFoundation is
      # not fork-safe, so those subshells intermittently die with SIGSEGV and
      # this check failed with a different assertion on every run on m3
      # (metacraft-pm issues/2026-11-13-dev-certificates-minting-crashes-on-m3-
      # darwin-runners.md). Putting the NLS-free bash first on PATH makes every
      # `bash` the test and the tool start the fixed one. This is applied here,
      # not as a stdenv override, because replacing the darwin stdenv's shell
      # rebuilds every darwin derivation in this flake from source.
      # DROP this once that fix reaches the pinned nixos-26.05 channel.
      darwinForkSafeBash = pkgs.bashNonInteractive.overrideAttrs (old: {
        configureFlags = old.configureFlags ++ [ "--disable-nls" ];
      });
    in
    {
      checks.dev-certificates-minting =
        pkgs.runCommand "dev-certificates-minting"
          {
            nativeBuildInputs = lib.optional pkgs.stdenv.hostPlatform.isDarwin darwinForkSafeBash ++ [
              pkgs.openssl
              pkgs.jq
              pkgs.coreutils
            ];
            __darwinAllowLocalNetworking = true;
          }
          ''
            cp ${../scripts/mint-dev-certificates.sh} ./mint-dev-certificates.sh
            mkdir -p tests
            cp ${../scripts/tests/dev-certificates-minting.sh} ./tests/dev-certificates-minting.sh
            chmod +x ./mint-dev-certificates.sh ./tests/dev-certificates-minting.sh

            # The test resolves the tool relative to its own location, so the
            # two have to keep their on-disk relationship. Copying rather than
            # running from the store is what allows that AND keeps the script
            # writable-adjacent for mktemp work.
            bash ./tests/dev-certificates-minting.sh | tee result.log

            mkdir -p "$out"
            cp result.log "$out/"
          '';
    };
}
