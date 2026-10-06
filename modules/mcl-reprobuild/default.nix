{ inputs, ... }:
{
  # A THIN RE-EXPORT. The reprobuild NixOS / nix-darwin / home-manager modules
  # are defined in the reprobuild repository itself
  # (`nix/modules/reprobuild.nix`) and exported from its flake as
  # `nixosModules.reprobuild` / `darwinModules.reprobuild` /
  # `homeManagerModules.reprobuild` (Distribution-And-Packaging M4, §9).
  #
  # THIS FILE HOLDS NO COPY of the option schema, the caches.conf renderer, or
  # the systemd/launchd unit wiring. It used to hold all three; keeping them
  # here after reprobuild started exporting its own would be two implementations
  # of one service definition, and they would drift. `grep -rn
  # 'mkEnableOption "the reprobuild'` across both repos finds exactly one hit,
  # in reprobuild.
  #
  # Direction of the dependency: reprobuild owns, nixos-modules re-exports. It
  # is the only direction the input graph allows — this flake already pins
  # `reprobuild` as an input, so reprobuild cannot in turn need nixos-modules
  # for its modules. (reprobuild keeps a `nixos-modules` input for
  # `nixpkgs.follows` only; that is a lock-time pin, not an import, and each
  # flake resolves its own inputs, so there is no cycle.)
  #
  # What stays HERE is the org-specific wiring: the `mcl-`-prefixed module
  # names the infra fleet and ~/dotfiles import by, and the opt-in
  # compatibility module for the historical `programs.reprobuild` option path
  # (reprobuild's canonical path is now `services.reprobuild`; the alias list is
  # derived from the schema's own attribute names, so the two paths cannot
  # drift). Fleet configuration that says `programs.reprobuild.* = …` keeps
  # working unchanged.
  #
  # REQUIRES a `reprobuild` input revision that carries `nix/modules/`. Bump
  # `inputs.reprobuild.url` in flake.nix together with this file.
  flake.modules.nixos.mcl-reprobuild = {
    imports = [
      inputs.reprobuild.nixosModules.reprobuild
      inputs.reprobuild.nixosModules.reprobuild-legacy-option-names
    ];
  };

  flake.modules.darwin.mcl-reprobuild = {
    imports = [
      inputs.reprobuild.darwinModules.reprobuild
      inputs.reprobuild.darwinModules.reprobuild-legacy-option-names
    ];
  };

  flake.modules.homeManager.mcl-reprobuild = {
    imports = [
      inputs.reprobuild.homeManagerModules.reprobuild
      inputs.reprobuild.homeManagerModules.reprobuild-legacy-option-names
    ];
  };
}
