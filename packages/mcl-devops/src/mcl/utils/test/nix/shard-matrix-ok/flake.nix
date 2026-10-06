{
  inputs = {
    nixos-modules.url = "../../../../../../../..";
    nixpkgs.follows = "nixos-modules/nixpkgs";
    flake-parts.follows = "nixos-modules/flake-parts";
  };

  outputs =
    inputs@{
      flake-parts,
      nixos-modules,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } (
      { config, lib, ... }:
      {
        systems = [
          "x86_64-linux"
          "aarch64-linux"
          "x86_64-darwin"
          "aarch64-darwin"
        ];
        imports = [ nixos-modules.modules.flake.shardSplit ];

        flake.mcl.shard-matrix = {
          shardSize = 10;
          perSystemAttributePath = [
            "legacyPackages"
            "ci-checks"
          ];
          systemsToBuild = [
            "x86_64-linux"
            "aarch64-darwin"
          ];
        };

        debug = true;

        perSystem =
          {
            pkgs,
            lib,
            ...
          }:
          {
            legacyPackages.ci-checks = lib.pipe (lib.range 0 100) [
              (map (i: "test-${lib.fixedWidthNumber 3 i}"))
              (
                x:
                lib.genAttrs x (
                  i:
                  pkgs.runCommandLocal "test-${i}" { } ''
                    echo 'The answer is ${i}!' > $out
                  ''
                )
              )
            ];
          };
      }
    );
}
