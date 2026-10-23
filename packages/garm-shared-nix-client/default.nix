{
  lib,
  runCommand,
  bash,
  nix,
}:
# The caller supplies the target host's selected Nix package. In particular,
# remote controllers must not resolve their own /run/current-system for this.
runCommand "garm-shared-nix-client"
  {
    nativeBuildInputs = [ bash ];
    passthru.nixClient = nix;
    meta = {
      description = "Immutable host-daemon client wrappers for Linux runners";
      platforms = [ "x86_64-linux" ];
    };
  }
  ''
    mkdir -p "$out/bin"
    bash ${../garm-provider-vmharness/src/internal/backend/shared_nix_client.sh} \
      ${lib.escapeShellArg "${lib.getBin nix}/bin"} "$out/bin"
    test -x "$out/bin/nix"
  ''
