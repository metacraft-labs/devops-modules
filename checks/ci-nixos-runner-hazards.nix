{ ... }:
{
  # t_ci_nixos_runner_hazards: the NixOS-runner hazard linter
  # (scripts/ci/check_nixos_runner_hazards.py) FIRES on each hazard class the
  # 2026-10-06 audit found failing (or passing vacuously) on the self-hosted
  # NixOS runners -- #!/bin/bash action entrypoints, glibc tool downloads,
  # magic-nix-cache's xz restore, distro package managers, FHS shells, docker
  # container jobs -- and PASSES the Nix-native equivalents, guarded non-Linux
  # legs, hosted and dynamic runs-on, and documented exceptions. It also keeps
  # this repository's own workflows clean.
  #
  # No mock objects: the linter reads real workflow files.
  perSystem =
    { pkgs, ... }:
    let
      py = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
      linter = ../scripts/ci/check_nixos_runner_hazards.py;
      fixtures = ../scripts/tests/fixtures/nixos-runner-hazards;
      workflowsDir = ../.github/workflows;
    in
    {
      # `nix run github:metacraft-labs/devops-modules/dev#check-nixos-runner-hazards -- [--warn] [paths]`
      # (reusable-lint.yml runs it over the consumer's .github/workflows).
      packages.check-nixos-runner-hazards = pkgs.writeShellApplication {
        name = "check-nixos-runner-hazards";
        runtimeInputs = [ py ];
        text = ''
          exec python3 ${linter} "$@"
        '';
      };

      checks.t_ci_nixos_runner_hazards =
        pkgs.runCommand "t_ci_nixos_runner_hazards" { nativeBuildInputs = [ py ]; }
          ''
            set -euo pipefail
            fail() { echo "[t_ci_nixos_runner_hazards][FAIL] $1" >&2; exit 1; }
            lint() { python3 ${linter} "$@"; }

            if lint ${fixtures}/hazardous.yml 2>h.err; then
              cat h.err >&2; fail "hazardous fixture was NOT flagged"
            fi
            cat h.err
            for want in lycheeverse/lychee-action jiro4989/setup-nim-action \
                        DeterminateSystems/magic-nix-cache-action "apt-get update" \
                        "/bin/bash -e" "declares \`container:\`"; do
              grep -qF -- "$want" h.err || fail "linter did not flag: $want"
            done
            [ "$(grep -c '^NRH' h.err)" = 6 ] || fail "expected exactly 6 findings"

            lint ${fixtures}/clean.yml || fail "clean fixture was wrongly flagged"
            lint --warn ${fixtures}/hazardous.yml > w.out || fail "--warn must exit 0"
            grep -q '^::warning::NRH1' w.out || fail "--warn did not emit annotations"

            lint ${workflowsDir} || fail "a devops-modules workflow has a NixOS-runner hazard"
            echo "[t_ci_nixos_runner_hazards][PASS]"
            touch $out
          '';
    };
}
