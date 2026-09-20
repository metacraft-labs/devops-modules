{
  description = "Test fixture for the setup-nix action: a devShell that fails to build and one that succeeds.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          loaderFixture = pkgs.runCommand "setup-nix-loader-fixture" { } ''
            mkdir -p "$out/lib"
          '';
        in
        {
          # A devShell whose build always fails. Used to assert that the
          # setup-nix action fails fast instead of silently reporting success
          # (see the action's "Build the Nix DevShell" step).
          failing = pkgs.mkShell {
            packages = [
              (pkgs.runCommand "always-fails" { } ''
                echo "deliberately failing build for the setup-nix regression test" >&2
                exit 1
              '')
            ];
          };

          # A devShell that builds and puts `hello` on PATH. Used to assert the
          # success path still exports the environment to $GITHUB_ENV.
          default = pkgs.mkShell {
            packages = [ pkgs.hello ];
            LD_LIBRARY_PATH = "${loaderFixture}/lib";
          };
        }
      );
    };
}
