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
    nixos-2605.url = "github:NixOS/nixpkgs/nixos-26.05";

    # The organisation's tool pins (metacraft-github-actions `pins/`). This
    # repository keeps NO reprobuild revision of its own: Reprobuild is the
    # revision `pins/reprobuild.json` names, reached in `outputs` below with
    # `builtins.getFlake pins.reprobuild.flakeRef` (pure: the reference carries
    # `rev` and `narHash`). A flake input's URL cannot be computed from another
    # input's file, so a `reprobuild` input here would be a second record of
    # the revision; there is deliberately none, and `flake.lock` has no
    # `reprobuild` node. See metacraft-pm
    # how-to-distribute-new-reprobuild-versions-internally.md, "One pin set in
    # the CI actions repository".
    #
    # This flake has no inputs, so it adds one node and nothing transitive. A
    # consumer that declares its own `metacraft-github-actions` input sets
    # `nixos-modules.inputs.metacraft-github-actions.follows =
    # "metacraft-github-actions"`, so a pin bump reaches it by updating that
    # input alone (the transitive-duplicate rule, applied to the pin).
    #
    # Reprobuild supplies modules as well as packages: `modules/mcl-reprobuild`
    # and `modules/mcl-repro-binary-cache` re-export its `nixosModules`,
    # `darwinModules` and `homeManagerModules`, whose default package is the
    # pinned flake's own. So the pin must name a revision that carries
    # reprobuild's `nix/modules/` directory.
    metacraft-github-actions.url = "github:metacraft-labs/metacraft-github-actions/dev";

    nixpkgs.follows = "nixos-2605";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager-unstable = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
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
        # microvm reads `spectrum` only in its `cloud-hypervisor-graphics`
        # overlay, which is evaluated only for a guest with
        # `microvm.graphics.enable` on the cloud-hypervisor hypervisor. Nothing
        # here or in infra builds one. The input is fetched from
        # spectrum-os.org, which stopped answering on 2026-11-19, and every
        # consumer that fetches all locked inputs (`nix flake archive`) then
        # fails. checks/flake-lock-sources.nix keeps it from coming back.
        spectrum.follows = "";
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
      metacraft-github-actions,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      # Reprobuild at the organisation's pin. Evaluated once, here, and handed
      # to every module as `inputs.reprobuild`. It is reprobuild's own flake
      # under its own lock, so its packages are the derivations
      # `nix build github:metacraft-labs/reprobuild/<rev>` produces, the same
      # ones the pin's gate builds. flake-parts builds `inputs'` from
      # `self.inputs`, which this cannot extend, so per-system code reads
      # `inputs.reprobuild.packages.${system}`; `inputs'.reprobuild` does not
      # exist.
      reprobuildPin = metacraft-github-actions.pins.reprobuild;
      reprobuild = builtins.getFlake reprobuildPin.flakeRef;
      inputsWithPin = inputs // {
        inherit reprobuild;
      };
    in
    flake-parts.lib.mkFlake { inputs = inputsWithPin; } {
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

      # The pinned Reprobuild for consumers. They used to reach it as
      # `nixos-modules.inputs.reprobuild`; there is no such input any more, so
      # it is published here: `nixos-modules.reprobuild` is the pinned flake
      # (`.packages.<system>.default`, `.inputs.runquota-src`, ...) and
      # `nixos-modules.pins` the parsed pin set it came from.
      flake.reprobuild = reprobuild;
      flake.pins = metacraft-github-actions.pins;

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
