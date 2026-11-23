# The organisation's Nim compiler: 2.2.10, over the nixpkgs 2.2.x recipe.
#
# Why this exists. The nixpkgs revisions this flake pins (`nixpkgs`,
# `nixpkgs-unstable`) ship Nim 2.2.4. Its allocator can free a whole small
# chunk while another thread is still pushing a cell onto that chunk's shared
# free list, so a program that frees `system.Channel` buffers from a thread
# other than the one that allocated them corrupts its heap and crashes (seen
# as SIGSEGV in `alloc.nim` `rawDealloc` / `addToSharedFreeList`). Upstream
# fixed it in https://github.com/nim-lang/Nim/pull/25513, first released in
# 2.2.8. 2.2.10 is the version the rest of the fleet already uses (the
# reprobuild tool store's Nim tarballs are 2.2.10), so the Nix toolchain moves
# to the same release rather than to a third one.
#
# How. Only the compiler source changes. The overlay replaces
# `nim-unwrapped-2_2`'s version, source and patch list and keeps the rest of
# the pinned nixpkgs recipe (build steps, inputs, wrapper). Every attribute
# nixpkgs derives from it follows through the package-set fixpoint:
# `nim-unwrapped`, `nim-unwrapped-2`, the `nim` / `nim2` / `nim-2_2` wrapper,
# and Nim-built tools such as `nimble`.
#
# The patch list is the one nixpkgs itself used for 2.2.10, at
# https://github.com/NixOS/nixpkgs/tree/eec3e392d1862d49969beb75dd07a729002b6800/pkgs/by-name/ni/nim-unwrapped
# Three of its four patches are byte-identical to the 2.2.4 recipe's and are
# taken from the pinned nixpkgs. The fourth, `extra-mangling.patch`, is
# vendored here: 2.2.10's `mangleModuleName` already derives module names
# relative to the search paths, so nixpkgs dropped the 2.2.4 patch's
# `compiler/modulepaths.nim` hunk (which no longer applies) and kept only the
# `uniqueModuleName` one.
#
# Scope. This targets the nixpkgs package layout that still carries
# `nim-unwrapped-2_2` at a release older than 2.2.10. Newer nixpkgs renamed it
# to `nim-unwrapped` and ships a newer Nim, and its recipe differs (no pcre,
# different patches), so the overlay refuses such a package set instead of
# guessing; drop the overlay when the pinned nixpkgs carries 2.2.10 or later.
final: prev:
let
  inherit (prev) lib;
  version = "2.2.10";
  pinned = prev.nim-unwrapped-2_2 or null;
  stockDir = "${prev.path}/pkgs/by-name/ni/nim-unwrapped-2_2";
in
{
  # The guards sit inside the attribute, not around the overlay's attribute
  # set: the fixpoint needs that set's names before any package exists, and
  # reading `pinned.version` there recurses into `final`.
  nim-unwrapped-2_2 =
    assert lib.assertMsg (pinned != null)
      "devops-modules nim overlay: this nixpkgs has no nim-unwrapped-2_2; it targets the 2.2.4-era recipe, drop it for this package set";
    assert lib.assertMsg (lib.versionOlder pinned.version version)
      "devops-modules nim overlay: nixpkgs already provides Nim ${pinned.version}; drop the overlay";
    pinned.overrideAttrs (_old: {
      inherit version;
      # The recipe's bootstrap compiler and the wrapper both read `src` and
      # `version` through `finalAttrs`, so they follow this override.
      src = final.fetchurl {
        url = "https://nim-lang.org/download/nim-${version}.tar.xz";
        hash = "sha256-eVe37QBCBrzxC8xPO0dEFTh45i8kMVUqmo6dP0Do1dU=";
      };
      patches = [
        # Override compiler configuration via an environment variable.
        "${stockDir}/NIM_CONFIG_DIR.patch"
        # Load libraries at runtime by absolute path.
        "${stockDir}/nixbuild.patch"
        # Mangle store paths of modules to prevent a runtime dependence.
        ./extra-mangling.patch
        # Link OpenSSL at build time instead of loading it with dlopen.
        "${stockDir}/openssl.patch"
      ];
    });
}
