{ ... }:
{
  # t_ci_nixos_runner_hazards: the NixOS-runner hazard linter
  # (scripts/ci/check_nixos_runner_hazards.py) FIRES on each hazard class the
  # 2026-10-06 audit found failing (or passing vacuously) on the self-hosted
  # NixOS runners -- #!/bin/bash action entrypoints, glibc tool downloads,
  # magic-nix-cache's xz restore, distro package managers, FHS shells, docker
  # container jobs, rustup bootstraps, pip outside a venv; including jobs whose
  # runs-on is a plain self-hosted Linux string such as `eph-linux-x64` -- and
  # PASSES the Nix-native equivalents, steps guarded to non-Linux legs or to
  # GitHub-hosted runners, hosted and dynamic runs-on, and documented
  # exceptions. It also keeps this repository's own workflows clean.
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

            # Self-hosted Linux jobs named by a plain string / single-name
            # list / matrix value (eph-linux-x64, self-hosted, nixos, ...), and
            # GitHub-hosted guards that a self-hosted runner can still pass
            # (a disjunction, a negation).
            if lint ${fixtures}/plain-runs-on-and-guards.yml 2>p.err; then
              cat p.err >&2; fail "plain-string runs-on fixture was NOT flagged"
            fi
            cat p.err
            for want in "job \`overlay-container\` declares \`container:\`" \
                        "job \`bare-self-hosted\` step 1: uses actions/setup-node" \
                        "job \`matrix-plain\` step 1: uses lycheeverse/lychee-action" \
                        "job \`guard-disjunction\` step 1: uses DeterminateSystems/nix-installer-action" \
                        "job \`guard-disjunction\` step 2: uses DeterminateSystems/magic-nix-cache-action" \
                        "job \`nixos-label\` step 1: runs \`apt-get install\`" \
                        "job \`single-name-list\` step 1: shell \`/bin/bash -e {0}\`"; do
              grep -qF -- "$want" p.err || fail "linter did not flag: $want"
            done
            [ "$(grep -c '^NRH' p.err)" = 7 ] || fail "expected exactly 7 plain-string/guard findings"

            # rustup bootstrap (glibc rustup-init) and pip outside a venv.
            if lint ${fixtures}/rust-and-pip.yml 2>r.err; then
              cat r.err >&2; fail "rust/pip fixture was NOT flagged"
            fi
            cat r.err
            for want in "uses dtolnay/rust-toolchain" "runs \`python3 -m pip install\`" "runs \`pip3 install\`"; do
              grep -qF -- "$want" r.err || fail "linter did not flag: $want"
            done
            [ "$(grep -c '^NRH' r.err)" = 3 ] || fail "expected exactly 3 rust/pip findings"

            # clean.yml also holds the negatives: plain-string macOS/Windows/
            # hosted runs-on, dynamic `[self-hosted, <expr>]`, steps guarded by
            # `runner.environment == 'github-hosted'` (bare, wrapped, conjunct),
            # pip into a venv, and crazy-max/ghaction-import-gpg (gpg is on PATH).
            lint ${fixtures}/clean.yml 2>c.err || { cat c.err >&2; fail "clean fixture was wrongly flagged"; }
            lint --warn ${fixtures}/hazardous.yml > w.out || fail "--warn must exit 0"
            grep -q '^::warning::NRH1' w.out || fail "--warn did not emit annotations"

            lint ${workflowsDir} || fail "a devops-modules workflow has a NixOS-runner hazard"
            echo "[t_ci_nixos_runner_hazards][PASS]"
            touch $out
          '';
    };
}
