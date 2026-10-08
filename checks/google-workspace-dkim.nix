# Google Workspace DKIM tooling (docs/Google-Workspace-DKIM.md):
#
#   cloudflare-mail-auth   the Terranix helper terraform/cloudflare/mail-auth.nix,
#                          evaluated against example data (pure Nix, at eval time)
#                          and compared with the reviewed rendering.
#   google-workspace-dkim-test  scripts/google-workspace-dkim.sh against stub dig/gh and
#                          a local bare origin; no network.
{ ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      failures = import ../terraform/cloudflare/tests/mail-auth.nix;
      rendered = import ../terraform/cloudflare/mail-auth.nix {
        data = builtins.fromJSON (builtins.readFile ../terraform/cloudflare/tests/mail-auth/data.json);
        comment = "DKIM (runbook)";
      };
    in
    {
      checks.cloudflare-mail-auth =
        pkgs.runCommand "cloudflare-mail-auth-test"
          {
            nativeBuildInputs = [ pkgs.jq ];
            rendered = builtins.toJSON rendered;
            failures = builtins.concatStringsSep "\n" failures;
            passAsFile = [ "rendered" ];
          }
          ''
            if [ -n "$failures" ]; then
              printf 'FAIL: %s\n' "$failures"
              exit 1
            fi
            if ! diff -u ${../terraform/cloudflare/tests/mail-auth/expected.json} <(jq -S . "$renderedPath"); then
              echo "FAIL: the rendering of tests/mail-auth/data.json differs from tests/mail-auth/expected.json"
              exit 1
            fi
            echo "mail-auth.nix: all assertions passed, rendering matches expected.json"
            touch "$out"
          '';

      checks.google-workspace-dkim-test =
        pkgs.runCommand "google-workspace-dkim-test"
          {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.coreutils
              pkgs.gawk
              pkgs.git
              pkgs.gnugrep
              pkgs.gnused
              pkgs.jq
              pkgs.openssl
            ];
          }
          ''
            GOOGLE_WORKSPACE_DKIM_SCRIPT=${../scripts/google-workspace-dkim.sh} \
              bash ${../scripts/tests/test-google-workspace-dkim.sh}
            touch "$out"
          '';
    };
}
