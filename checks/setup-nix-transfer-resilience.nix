{ ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      checks.setup-nix-transfer-resilience =
        pkgs.runCommand "setup-nix-transfer-resilience"
          {
            nativeBuildInputs = [ pkgs.python3 ];
          }
          ''
            python3 - <<'PY'
            import re
            from pathlib import Path

            action = Path("${../.github/setup-nix/action.yml}").read_text()

            assert "stalled-download-timeout = 30" in action
            assert "http2 = false" in action
            assert action.index("stalled-download-timeout = 30") < action.index("substituters = ")

            # libcurl charges time QUEUED for a pooled connection against
            # CURLOPT_CONNECTTIMEOUT. connect-timeout = 5 with an 8-slot pool
            # produced "Operation timed out after 5000 milliseconds with 0
            # bytes received" on every transfer queued behind 8 busy NARs, and
            # that disabled cache.nixos.org in production.
            assert "connect-timeout = 5\n" not in action, "connect-timeout = 5 counts connection-queue time; see setup-nix action.yml"
            assert "connect-timeout = 20" in action
            # >= max-substitution-jobs (16) so NAR downloads alone never queue.
            assert "http-connections = 16" in action
            assert "download-attempts = 5" in action

            # fallback stays true by default: with false, Nix rethrows ANY
            # substituter error (5xx/timeout), even for a derivation in no
            # cache. It is an explicit opt-in for jobs that must not build
            # the world.
            assert re.search(r"fallback = \$\{\{ inputs\.fallback == 'false' && 'false' \|\| 'true' \}\}", action)
            fallback_input = re.search(r"\n  fallback:\n(?:    .*\n)+", action)
            assert fallback_input and "default: 'true'" in fallback_input.group(0), "the fallback input must default to 'true'"

            # The probe must not interpolate the attic token (it inspects the
            # netrc instead), and must be handed nix.conf to prune.
            probe_step = action.split("name: Probe binary caches", 1)[1].split("\n    - name:", 1)[0]
            assert "attic-token" not in probe_step
            assert "SETUP_NIX_PROBE_NIX_CONF=" in probe_step

            # nix.conf is written by an UNQUOTED heredoc (it interpolates
            # $HOME): a backtick or $( in a comment there is executed by bash.
            heredoc = action.split('cat << EOF > "$HOME/.config/nix/nix.conf"', 1)[1].split("\n        EOF\n", 1)[0]
            assert "`" not in heredoc and "$(" not in heredoc, "command substitution inside the nix.conf heredoc"

            # The binary-cache preflight runs after nix.conf + netrc are
            # written and before anything substitutes.
            assert action.index("/write-netrc.sh") < action.index("name: Probe binary caches")
            assert action.index("name: Probe binary caches") < action.index("name: Build the Nix DevShell")
            PY
            touch "$out"
          '';

      # Contract suite for probe-substituters.sh: the real script, real curl,
      # a real netrc and a real loopback HTTP origin (no mocks).
      checks.setup-nix-substituter-preflight =
        pkgs.runCommand "setup-nix-substituter-preflight"
          {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.coreutils
              pkgs.curl
              pkgs.gnugrep
              pkgs.gnused
              pkgs.python3
            ];
          }
          ''
            cp -r ${../.github/setup-nix} setup-nix
            chmod -R u+w setup-nix
            bash setup-nix/tests/probe-substituters-test.sh
            touch "$out"
          '';

      checks.setup-nix-hosted-disk-reclamation =
        pkgs.runCommand "setup-nix-hosted-disk-reclamation"
          {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.coreutils
              pkgs.gawk
              pkgs.python3
            ];
          }
          ''
            cd ${../.}
            python3 scripts/tests/test_setup_nix_hosted_disk.py
            touch "$out"
          '';
    };
}
