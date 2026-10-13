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
# The darwin leg is UNVERIFIED: no darwin builder was available when this was
# written, and the aarch64-darwin CI batch that would have exercised it died with
# "the self-hosted runner lost communication with the server" before reporting.
{ ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      checks.dev-certificates-minting =
        pkgs.runCommand "dev-certificates-minting"
          {
            nativeBuildInputs = [
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
