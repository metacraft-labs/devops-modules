{
  lib,
  stdenv,
  fetchFromGitHub,
  nim,
  pcre,
}:
# Runner-Fleet-Capability-Pools-And-Remote-Driving campaign, milestone RA2.
#
# The `vm-harness` CLI/daemon binary (public toolkit, metacraft-labs/gosti).
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
stdenv.mkDerivation (finalAttrs: {
  pname = "vm-harness";
  version = "0.1.0-unstable-2026-09-14";

  src = fetchFromGitHub {
    owner = "metacraft-labs";
    # Repo renamed vm-harness -> gosti (GOSTI1); content-addressed hash is
    # unchanged by the rename. The in-repo vm-harness/vmh CLI brand rename
    # (pname, binary, share/ paths, serve service) is the GOSTI1b follow-up.
    repo = "gosti";
    rev = "b5df21a2375446d2929a583a112d70d564085d21";
    hash = "sha256-XKtLJTpM+54EILNVeBOL3tHc1b8b9x0yw28CzkxAq3I=";
  };

  nativeBuildInputs = [ nim ];
  buildInputs = lib.optionals stdenv.isLinux [ pcre ];

  buildPhase = ''
    runHook preBuild
    # Nix sandboxes HOME to /homeless-shelter. Keep Nim's cache in the writable
    # build directory (identical to the upstream flake's package build).
    nim c --hints:off --opt:speed \
      --nimcache:$TMPDIR/nimcache \
      -o:vm-harness src/vm_harness/cli.nim
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin \
      $out/share/vm-harness/guest-scripts \
      $out/share/vm-harness/guest-recipes
    install -m755 vm-harness $out/bin/vm-harness
    cp -R guest-scripts/* $out/share/vm-harness/guest-scripts/
    cp -R guest-recipes/* $out/share/vm-harness/guest-recipes/
    runHook postInstall
  '';

  meta = {
    description = "Cross-platform VM lifecycle orchestration (incl. the `vm-harness serve` remoting daemon)";
    homepage = "https://github.com/metacraft-labs/gosti";
    license = lib.licenses.mit;
    mainProgram = "vm-harness";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];
  };
})
