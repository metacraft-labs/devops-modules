let
  currentFlake = builtins.fromJSON (builtins.readFile ../flake.lock);
  inherit (currentFlake.nodes.nixos-2605.locked)
    owner
    repo
    rev
    narHash
    ;
  nixpkgs = builtins.fetchTarball {
    url = "https://github.com/${owner}/${repo}/archive/${rev}.tar.gz";
    sha256 = narHash;
  };
  flake = import ../flake.nix;
in
{
  inherit currentFlake flake;
  lib = (import nixpkgs { system = "x86_64-linux"; }).lib;
}
