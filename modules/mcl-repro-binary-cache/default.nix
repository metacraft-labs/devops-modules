{ inputs, ... }:
{
  # A THIN RE-EXPORT. The binary-cache host module is defined in the reprobuild
  # repository itself (`nix/modules/repro-binary-cache.nix`) and exported from
  # its flake as `nixosModules.repro-binary-cache`
  # (Distribution-And-Packaging M4, §9), so an external Nix user can host the
  # cache without depending on this repo.
  #
  # THIS FILE HOLDS NO COPY of the option schema or the hardened systemd unit.
  # It used to hold both; keeping them here after reprobuild started exporting
  # its own would be two implementations of one service definition, and they
  # would drift. `grep -rn 'services.mcl-repro-binary-cache = {' ` across both
  # repos finds the option declaration exactly once, in reprobuild.
  #
  # The option path (`services.mcl-repro-binary-cache`) and the unit name
  # (`mcl-repro-binary-cache.service`) are UNCHANGED by the move, so deployed
  # hosts, infra configuration, and the three VM checks in `checks/` that wait
  # on the unit by name all keep working verbatim.
  #
  # REQUIRES a `reprobuild` input revision that carries `nix/modules/`. Bump
  # `inputs.reprobuild.url` in flake.nix together with this file.
  flake.modules.nixos.mcl-repro-binary-cache = inputs.reprobuild.nixosModules.repro-binary-cache;
}
