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
            ;
          # The Ethereum clients (foundry, geth, nimbus, erigon, nethermind,
          # web3signer, mev-boost) are NOT in this matrix, by decision. They
          # came from the `ethereum-nix` input, which pins its own nixpkgs to
          # the end-of-life 25.05 release because the clients do not evaluate
          # against newer ones. Building them here kept that package set alive
          # in the tree and made every unrelated nixpkgs bump a cold rebuild of
          # seven packages that then fail.
          #
          # Nothing deploys them any more: the one host that served a node was
          # given a different role, so no machine or module asks for them.
          #
          # ONE CONSUMER REMAINS, and it is not a deployment.
          # nix-blockchain-development's DEFAULT devShell takes `geth` (and
          # `nimbus` on x86_64-linux) from this same input, which it reaches by
          # following ours. Those are the identical derivations this matrix used
          # to build — measured, not assumed:
          #
          #   checks.x86_64-linux.geth   -> 4jh2r6adnja3fzdq2n2van02k30ik856
          #   checks.x86_64-linux.nimbus -> 82nqj86qxqg6dgqx8n87yrzpg70winaw
          #
          # so this matrix was what populated the cache for that shell, and
          # cache.nixos.org does not carry them. Entering that shell will build
          # from source once the existing cache entries age out. That repo's own
          # CI does not cover them: its `checks` re-export of geth/nimbus is
          # commented out. If that shell is meant to stay warm, it should build
          # them itself rather than rely on this matrix as a side effect.
          #
          # The input is otherwise reachable only through a passthrough
          # re-export in packages/default.nix. Removing it (and its pinned
          # end-of-life release) additionally requires dropping the
          # `ethereum-nix` follows in nix-blockchain-development and
          # nimbus-test, which would otherwise fail to lock.
        }
        // optionalAttrs isLinux {
          # Linux only. This is `nixos-rebuild-ng` rebuilt against the Nix that
          # `nix-eval-jobs` uses (packages/default.nix), so it is never
          # substituted from cache.nixos.org and its pytest suite runs on our own
          # builders. On aarch64-darwin `test_tmpdir.py::test_make_tmpdir` fails
          # there: it points TMPDIR at /tmp/not-too-long, which the darwin
          # sandbox does not let the build write to, so `tempfile` falls back to
          # TMP/TEMP -- the build directory, /nix/var/nix/builds/nix-* since
          # Nix moved build directories there -- and the test's own sanity
          # assertion fails. nixos-26.05 still carries that version of the test
          # (nixpkgs master reworked it in aead86a3b8, July 2026; not backported).
          #
          # Nothing needs this variant on darwin: no consumer reads
          # `legacyPackages.inputs.nixpkgs.nixos-rebuild-ng` at all, and the
          # darwin dev shells that ship nixos-rebuild-ng take the plain
          # `pkgs.nixos-rebuild-ng`, which cache.nixos.org serves.
          inherit (self'.legacyPackages.inputs.nixpkgs) nixos-rebuild-ng;
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
        };
    };
}
