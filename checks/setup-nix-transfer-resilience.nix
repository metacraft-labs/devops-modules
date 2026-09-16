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
            from pathlib import Path

            action = Path("${../.github/setup-nix/action.yml}").read_text()

            assert "stalled-download-timeout = 30" in action
            assert "http2 = false" in action
            assert "http-connections = 8" in action
            assert action.index("connect-timeout = 5") < action.index("stalled-download-timeout = 30")
            assert action.index("stalled-download-timeout = 30") < action.index("substituters = ")
            PY
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
