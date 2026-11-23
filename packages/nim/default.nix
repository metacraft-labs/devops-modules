# The organisation's single Nim toolchain definition. See ./overlay.nix for
# why it is 2.2.10 and how it is derived from nixpkgs.
#
# Two ways to consume it, both from this one definition:
#
#   * `overlays.nim`, for a flake that builds its own package set. Applied to
#     the package set this flake's `nixpkgs-unstable` input pins, it yields the
#     same derivations as the packages below, so they substitute from the
#     cache this repository's CI fills.
#   * `packages.<system>.{nim,nim-unwrapped,nimble}`, for a flake that only
#     needs the tools (a dev shell). They are built against `nixpkgs-unstable`,
#     not this flake's default `nixpkgs`, because that is the package set the
#     Nim consumers follow (`nixpkgs.follows = "nixos-modules/nixpkgs-unstable"`
#     in isonim, isonim-tui, the nim-* libraries and reprobuild), so the
#     compiler's runtime closure (libc, openssl, the C compiler the wrapper
#     points at) is the one already in their shells.
#
# Being in `packages`, they enter this repository's CI matrix through
# checks/packages-ci-matrix.nix and are pushed to the binary cache for every
# system in `mcl.shard-matrix.systemsToBuild`.
{ inputs, ... }:
let
  overlay = import ./overlay.nix;
in
{
  flake.overlays.nim = overlay;

  perSystem =
    { system, ... }:
    let
      nimPkgs = import inputs.nixpkgs-unstable {
        inherit system;
        overlays = [ overlay ];
      };
    in
    {
      packages = {
        inherit (nimPkgs) nim nimble;
        nim-unwrapped = nimPkgs.nim-unwrapped-2_2;
      };
      checks.nim-toolchain = nimPkgs.callPackage ./check.nix { };
    };
}
