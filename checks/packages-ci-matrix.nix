{
  lib,
  inputs,
  ...
}:
{
  perSystem =
    {
      inputs',
      self',
      pkgs,
      ...
    }:
    let
      inherit (lib) optionalAttrs;
      inherit (pkgs.stdenv.hostPlatform) system isLinux;
    in
    rec {
      checks =
        # `packages.mcl` is the deliberate throwing alias left behind by the
        # `mcl` → `mcl-devops` rename (metacraft-cli.md §2.5, supporting rule 1).
        # It must stay in `packages` so that a stale `pkgs.mcl` / `#mcl` fails
        # loudly at evaluation, but it must not enter the CI matrix: nix-eval-jobs
        # reports it as a per-attribute `error`, and `mcl-devops ci-matrix` treats
        # any such error as a hard failure of the whole evaluation.
        # Remove this exclusion when the throwing alias is removed.
        (builtins.removeAttrs self'.packages [ "mcl" ])
        // {
          inherit (self'.legacyPackages) rustToolchain;
          # dlang.nix bundles ldc 1.30, which segfaults compiling dub 1.31's
          # build.d on current macOS (the FOD output was previously served from
          # the binary cache, so the crash only surfaces on a clean rebuild).
          # Build dub with the current nixpkgs ldc (1.41), which compiles it
          # fine on darwin. Linux still builds with dlang.nix's own compiler.
          dub =
            let
              dub' = self'.legacyPackages.inputs.dlang-nix.dub;
            in
            if isLinux then dub' else dub'.override { dcompiler = pkgs.ldc; };
          inherit (self'.legacyPackages.inputs.nixpkgs)
            cachix
            nix
            nix-eval-jobs
            nix-fast-build
            nixos-rebuild-ng
            ;
          inherit (self'.legacyPackages.inputs.ethereum-nix) foundry;
        }
        // optionalAttrs (system == "x86_64-linux" || system == "aarch64-darwin") {
          inherit (self'.legacyPackages.inputs.ethereum-nix) geth;
        }
        // optionalAttrs isLinux {
          disko = self'.legacyPackages.inputs.disko.default;
          nixos-anywhere = self'.legacyPackages.inputs.nixos-anywhere.default;
        }
        // optionalAttrs (system == "x86_64-linux") {
          inherit (pkgs) terraform;
          inherit (self'.legacyPackages.inputs.terranix) terranix;
          inherit (self'.legacyPackages.inputs.dlang-nix)
            dcd
            dscanner
            serve-d
            dmd
            ldc
            ;
          inherit (self'.legacyPackages.inputs.ethereum-nix)
            mev-boost
            nethermind
            web3signer
            nimbus
            erigon
            ;
        };
    };
}
