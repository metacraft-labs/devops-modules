{
  lib,
  stdenv,
  fetchFromGitHub,
  nim,
  pcre,
}:
# Runner-Fleet-Capability-Pools-And-Remote-Driving campaign, milestone RA2.
#
# The `gosti` CLI/daemon binary (public toolkit, metacraft-labs/gosti).
# Its SINGLE binary already includes `gosti serve` — the RA1 remoting
# daemon (PR #25, merged on the `dev` branch) — so nothing separate needs
# building for the serve deployment; `services.gosti-serve` just packages
# this binary into a hardened systemd unit.
#
# This mirrors the upstream flake's own package derivation (a plain `nim c` of
# `src/gosti/cli.nim`, plus the guest-scripts/guest-recipes payload) and is
# VENDORED here — exactly like `garm-provider-gosti` — rather than pulled in
# as a flake input. A flake input would drag gosti's own (heavy)
# `nixos-modules` input tree into THIS repo's flake.lock (gosti follows
# nixos-modules for nixpkgs), so vendoring keeps the lock small and builds the
# binary against this repo's own nixpkgs.
#
# Bump `rev`/`hash` to roll the serve binary forward; the mainline is `dev`.
#
# `share/gosti/` carries the guest recipes and in-guest scripts gosti resolves
# at run time.
stdenv.mkDerivation (finalAttrs: {
  pname = "gosti";
  version = "0.1.2-unstable-2026-10-31";

  src = fetchFromGitHub {
    owner = "metacraft-labs";
    repo = "gosti";
    rev = "2ea450e2347f5f11639423b8a410e557c60e14dd";
    hash = "sha256-nm5Zm7R4WciS+gyuQsyh9EuF9Teka440QEw3qDUw/w8=";
  };

  nativeBuildInputs = [ nim ];
  buildInputs = lib.optionals stdenv.isLinux [ pcre ];

  buildPhase = ''
    runHook preBuild
    # Nix sandboxes HOME to /homeless-shelter. Keep Nim's cache in the writable
    # build directory (identical to the upstream flake's package build).
    nim c --hints:off --opt:speed \
      --nimcache:$TMPDIR/nimcache \
      -o:gosti src/gosti/cli.nim
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin \
      $out/share/gosti/guest-scripts \
      $out/share/gosti/guest-recipes
    install -m755 gosti $out/bin/gosti
    cp -R guest-scripts/* $out/share/gosti/guest-scripts/
    cp -R guest-recipes/* $out/share/gosti/guest-recipes/
    runHook postInstall
  '';

  meta = {
    description = "Cross-platform VM lifecycle orchestration (incl. the `gosti serve` remoting daemon)";
    homepage = "https://github.com/metacraft-labs/gosti";
    license = lib.licenses.mit;
    mainProgram = "gosti";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];
  };
})
