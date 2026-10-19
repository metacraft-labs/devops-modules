{
  lib,
  stdenv,
  fetchFromGitHub,
  nim,
  pcre,
}:
# Runner-Fleet-Capability-Pools-And-Remote-Driving campaign, milestone RA2.
#
# The `gosti` (formerly `vm-harness`) CLI/daemon binary (public toolkit, metacraft-labs/gosti).
# Its SINGLE binary already includes `vm-harness serve` — the RA1 remoting
# daemon (PR #25, merged on the `dev` branch) — so nothing separate needs
# building for the serve deployment; `services.vm-harness-serve` just packages
# this binary into a hardened systemd unit.
#
# This mirrors the upstream flake's own package derivation (a plain `nim c` of
# `src/vm_harness/cli.nim`, plus the guest-scripts/guest-recipes payload) and is
# VENDORED here — exactly like `garm-provider-vmharness` — rather than pulled in
# as a flake input. A flake input would drag vm-harness's own (heavy)
# `nixos-modules` input tree into THIS repo's flake.lock (vm-harness follows
# nixos-modules for nixpkgs), so vendoring keeps the lock small and builds the
# binary against this repo's own nixpkgs.
#
# Bump `rev`/`hash` to roll the serve binary forward; the mainline is `dev`.
#
# GOSTI1b step 1: installed with gosti's step-0 layout (gosti#55,
# scripts/install-binaries.sh): `bin/gosti` is the binary and `bin/vm-harness`
# a RELATIVE symlink to it, so every consumer naming `bin/vm-harness` (the
# garm provider's `vm_harness_path`, scripts, muscle memory) keeps working,
# and `lib.getExe` yields `bin/gosti`. `share/vm-harness/` keeps its name
# (gosti itself still resolves its guest recipes there). The pinned source
# predates step 0, so the layout is reproduced here rather than by calling
# the script; behaviour does not depend on the invoked name (the serve worker
# re-execs the resolved executable, i.e. `/proc/self/exe`).
stdenv.mkDerivation (finalAttrs: {
  pname = "gosti";
  version = "0.1.2-unstable-2026-10-14";

  src = fetchFromGitHub {
    owner = "metacraft-labs";
    # Repo renamed vm-harness -> gosti (GOSTI1); content-addressed hash is
    # unchanged by the rename. The in-repo vm-harness/vmh CLI brand rename
    # (pname, binary, share/ paths, serve service) is the GOSTI1b follow-up.
    repo = "gosti";
    rev = "6d050ba03dbfc736a5a26e4459b7965398c16a68";
    hash = "sha256-UBQvUnHTBVo60AM1xUqVM1/UbCTlq1dfbrBIidvgEkk=";
  };

  nativeBuildInputs = [ nim ];
  buildInputs = lib.optionals stdenv.isLinux [ pcre ];

  buildPhase = ''
    runHook preBuild
    # Nix sandboxes HOME to /homeless-shelter. Keep Nim's cache in the writable
    # build directory (identical to the upstream flake's package build).
    nim c --hints:off --opt:speed \
      --nimcache:$TMPDIR/nimcache \
      -o:gosti src/vm_harness/cli.nim
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin \
      $out/share/vm-harness/guest-scripts \
      $out/share/vm-harness/guest-recipes
    install -m755 gosti $out/bin/gosti
    ln -s gosti $out/bin/vm-harness
    cp -R guest-scripts/* $out/share/vm-harness/guest-scripts/
    cp -R guest-recipes/* $out/share/vm-harness/guest-recipes/
    runHook postInstall
  '';

  meta = {
    description = "Cross-platform VM lifecycle orchestration (incl. the `vm-harness serve` remoting daemon)";
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
