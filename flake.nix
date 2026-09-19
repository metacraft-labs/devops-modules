{
  description = "Metacraft Nixos Modules";

  nixConfig = {
    extra-substituters = [
      "https://cache.metacraft-labs.com/metacraft-private-infrastructure"
      "https://dlang-community.cachix.org"
    ];
    extra-trusted-public-keys = [
      "metacraft-private-infrastructure:TWjFAlGXK9Mky5VG3PBln2MqYz4XPw3MTHHVPYZiAhE="
      "dlang-community.cachix.org-1:eAX1RqX4PjTDPCAp/TvcZP+DYBco2nJBackkAJ2BsDQ="
    ];
  };

  inputs = {
    nixos-2505.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixos-2511.url = "github:NixOS/nixpkgs/nixos-25.11";

    # Windows-Runner-Binary-Cache-Deploy M1 — the reprobuild flake provides the
    # `repro-binary-cache` package (the binary-cache HTTP daemon) that the
    # `services.mcl-repro-binary-cache` NixOS module packages into a systemd
    # unit, mirroring how `mcl.attic-cache-host` packages atticd. reprobuild
    # already pins `nixpkgs.follows = "nixos-modules/nixpkgs-unstable"`, so it is
    # built against the same unstable package set as this repo. (There is no
    # lock cycle: reprobuild's `nixos-modules` input keeps its own pinned
    # revision; Nix resolves each flake's inputs independently.)
    #
    # PINNED to a specific rev (not a bare branch): we deploy reprobuild to
    # servers through this input, so an explicit pin keeps the installed
    # `repro` reproducible. Bump this SHA to roll forward (the mainline is the
    # `dev` branch; `main` was retired). This SHA is the single source of truth
    # for the reprobuild revision: nearly every consumer reaches `repro` through
    # this input with `follows` rather than declaring a pin of its own, so a
    # machine cannot end up running a `repro` other than the one its closure was
    # built against.
    #
    # `codetracer` is a documented exception — it consumes the prebuilt package
    # and overrides six of reprobuild's inputs to get a `repro` built with
    # `ct_interpose`, which a bare `follows` cannot express, so it mirrors this
    # SHA by hand. Bumping is therefore a two-file edit: here first, then
    # codetracer's `flake.nix`. Do not "tidy" that input into a `follows`.
    # See metacraft-specs/how-to-distribute-new-reprobuild-versions-internally.md.
    # Before bumping, check the candidate against a real workspace — it must
    # still parse the current manifests (`repro workspace status`) and still
    # satisfy the installed managed-hook contract
    # (`repro hooks protocol --require=2 --hook-contract=...`).
    #
    # THIS INPUT NOW ALSO SUPPLIES THE MODULES, not just the packages.
    # Distribution-And-Packaging M4 moved `mcl-reprobuild` and
    # `mcl-repro-binary-cache` into reprobuild's own flake
    # (`nixosModules.reprobuild`, `darwinModules.reprobuild`,
    # `homeManagerModules.reprobuild`, `nixosModules.repro-binary-cache`);
    # `modules/mcl-reprobuild` and `modules/mcl-repro-binary-cache` here are
    # thin re-exports of them and hold no schema of their own. So this pin must
    # name a revision that carries reprobuild's `nix/modules/` directory — a pin
    # older than that makes `modules/` fail to evaluate, not merely ship a stale
    # `repro`.
    reprobuild.url = "github:metacraft-labs/reprobuild/35c5754a8fd3b9858508d61701199fab8e69ebda";

    nixpkgs.follows = "nixos-2511";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager-unstable = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/nix-darwin-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-darwin-unstable = {
      url = "github:nix-darwin/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };

    systems.url = "github:nix-systems/default";

    flake-utils = {
      url = "github:numtide/flake-utils";
      inputs.systems.follows = "systems";
    };

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    git-hooks-nix = {
      url = "github:cachix/git-hooks.nix";
      inputs = {
        nixpkgs.follows = "nixpkgs-unstable";
        flake-compat.follows = "flake-compat";
      };
    };

    hercules-ci-effects = {
      url = "github:hercules-ci/hercules-ci-effects";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-parts.follows = "flake-parts";
      };
    };

    ethereum-nix = {
      url = "github:metacraft-labs/ethereum.nix/dev";
      inputs = {
        nixpkgs.follows = "nixos-2505";
        nixpkgs-unstable.follows = "nixpkgs-unstable";
        flake-parts.follows = "flake-parts";
        flake-utils.follows = "flake-utils";
        systems.follows = "systems";
        flake-compat.follows = "flake-compat";
        treefmt-nix.follows = "treefmt-nix";
        fenix.follows = "fenix";
        devshell.follows = "devshell";
      };
    };

    agenix = {
      url = "github:ryantm/agenix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        systems.follows = "systems";
        darwin.follows = "nix-darwin";
        home-manager.follows = "home-manager";
      };
    };

    devenv = {
      url = "github:cachix/devenv";
      inputs = {
        cachix.follows = "cachix";
        nixpkgs.follows = "nixpkgs";
        git-hooks.follows = "git-hooks-nix";
        flake-compat.follows = "flake-compat";
        flake-parts.follows = "flake-parts";
      };
    };

    devshell = {
      url = "github:numtide/devshell";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };

    cachix = {
      url = "github:cachix/cachix";
      inputs = {
        flake-compat.follows = "flake-compat";
        devenv.follows = "devenv";
        nixpkgs.follows = "nixpkgs-unstable";
        git-hooks.follows = "git-hooks-nix";
      };
    };

    nixos-images = {
      url = "github:nix-community/nixos-images";
      inputs = {
        nixos-stable.follows = "nixpkgs";
        nixos-unstable.follows = "nixpkgs-unstable";
      };
    };

    nixos-anywhere = {
      url = "github:numtide/nixos-anywhere";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        nixos-stable.follows = "nixpkgs";
        nixos-images.follows = "nixos-images";
        flake-parts.follows = "flake-parts";
        disko.follows = "disko";
        treefmt-nix.follows = "treefmt-nix";
      };
    };

    nix2container = {
      url = "github:nlewo/nix2container";
      inputs = {
        nixpkgs.follows = "nixpkgs-unstable";
      };
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-utils-plus = {
      url = "github:gytis-ivaskevicius/flake-utils-plus";
      inputs.flake-utils.follows = "flake-utils";
    };

    nixd = {
      url = "github:nix-community/nixd";
      inputs.flake-parts.follows = "flake-parts";
      inputs.treefmt-nix.follows = "treefmt-nix";
      # Please refrain from adding the following line:
      # inputs.nixpkgs.follows = "nixpkgs";
      #
      # See: https://github.com/nix-community/nixd/blob/main/nixd/docs/editor-setup.md#installation---get-a-working-executable:~:text=do%20NOT%20override%20nixpkgs%20revision
    };

    terranix = {
      url = "github:terranix/terranix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-parts.follows = "flake-parts";
        systems.follows = "systems";
      };
    };

    vscode-server = {
      url = "github:nix-community/nixos-vscode-server";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };

    microvm = {
      url = "github:astro/microvm.nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };

    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    crane = {
      url = "github:ipetkov/crane";
    };

    dlang-nix = {
      url = "github:PetarKirov/dlang.nix/feat/build-dub-package";
      inputs = {
        flake-compat.follows = "flake-compat";
        flake-parts.follows = "flake-parts";
      };
    };

    nix-topology = {
      url = "github:oddlama/nix-topology";
      inputs = {
        flake-parts.follows = "flake-parts";
        nixpkgs.follows = "nixpkgs";
      };
    };

    nix-bundlers = {
      url = "github:NixOS/bundlers";
      inputs.nixpkgs.follows = "nixpkgs";
      # TODO: re-add when CI's `nix` starts supporting transitive overrides
      # inputs.nix-utils.inputs.nixpkgs.follows = "nixpkgs";
      # inputs.nix-utils.inputs.flake-utils.follows = "flake-utils";
      # inputs.nix-bundle.inputs.utils.follows = "flake-utils";
    };

    nix-appimage = {
      url = "github:ralismark/nix-appimage";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
      inputs.flake-compat.follows = "flake-compat";
    };

    llm-agents = {
      url = "github:numtide/llm-agents.nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        treefmt-nix.follows = "treefmt-nix";
      };
    };

    nix-on-droid = {
      url = "github:nix-community/nix-on-droid";
      inputs = {
        nixpkgs.follows = "nixpkgs-unstable";
        home-manager.follows = "home-manager-unstable";
      };
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      ...
    }:
    let
      inherit (nixpkgs) lib;
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.flake-parts.flakeModules.modules
        ./checks
        ./modules
        ./packages
        ./shells
      ];
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      perSystem =
        { system, ... }:
        {
          _module.args.pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
        };

      flake.mcl.shard-matrix.systemsToBuild = [
        "x86_64-linux"
        "aarch64-darwin"
      ];

      flake.lib.create =
        {
          rootDir,
          machinesDir ? null,
          usersDir ? null,
        }:
        let
          utils = import ./lib { inherit usersDir rootDir machinesDir; };
        in
        {
          dirs = {
            lib = self + "/lib";
            services = self + "/services";
            modules = self + "/modules";
            machines = rootDir + "/machines";
          };
          libs = {
            make-config = import ./lib/make-config.nix {
              inherit
                lib
                rootDir
                machinesDir
                usersDir
                ;
            };
            inherit utils;
          };

          modules = {
            users = import ./modules/users.nix utils;
          };
        };

      flake.lib.deploymentIncusRehearsal = import ./lib/deployment/incus-rehearsal.nix {
        inherit lib nixpkgs;
      };
    };
}
