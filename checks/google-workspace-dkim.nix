# Google Workspace mail tooling (docs/Google-Workspace-DKIM.md,
# docs/Google-Workspace-Domains.md):
#
#   cloudflare-mail-auth   the Terranix helper terraform/cloudflare/mail-auth.nix,
#                          evaluated against example data (pure Nix, at eval time)
#                          and compared with the reviewed renderings (version 1
#                          and version 2); and the tools' jq restatement of its
#                          resource addresses (scripts/lib/mail-auth.jq)
#                          compared with what it renders.
#   google-workspace-dkim-test  scripts/google-workspace-dkim.sh against stub dig/gh and
#                          a local bare origin; no network.
#   google-workspace-domains-test  scripts/google-workspace-domains.sh, its API
#                          helper and scripts/google-workspace-setup.sh (the
#                          guided per-domain path and the batched two-phase one,
#                          interrupted and resumed; the merge gate, aliases,
#                          dkim-collect, registrar-debris, the credentials)
#                          against a local Google API stub, a Cloudflare API
#                          stub, an SMTP stub, stub dig/gh/gcloud and local
#                          bare origins; no network.
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
      rendered2 = import ../terraform/cloudflare/mail-auth.nix {
        data = builtins.fromJSON (builtins.readFile ../terraform/cloudflare/tests/mail-auth/data-v2.json);
        comment = "DKIM (runbook)";
        recordsComment = "Mail (runbook)";
      };
      # Version 2 with the domain kinds, TLS-RPT, MTA-STS and a pending zone.
      rendered3 = import ../terraform/cloudflare/mail-auth.nix {
        data = builtins.fromJSON (
          builtins.readFile ../terraform/cloudflare/tests/mail-auth/data-v2-kinds.json
        );
        comment = "DKIM (runbook)";
        recordsComment = "Mail (runbook)";
      };
    in
    {
      checks.cloudflare-mail-auth =
        pkgs.runCommand "cloudflare-mail-auth-test"
          {
            nativeBuildInputs = [ pkgs.jq ];
            rendered = builtins.toJSON rendered;
            rendered2 = builtins.toJSON rendered2;
            rendered3 = builtins.toJSON rendered3;
            failures = builtins.concatStringsSep "\n" failures;
            passAsFile = [
              "rendered"
              "rendered2"
              "rendered3"
            ];
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
            if ! diff -u ${../terraform/cloudflare/tests/mail-auth/expected-v2.json} <(jq -S . "$rendered2Path"); then
              echo "FAIL: the rendering of tests/mail-auth/data-v2.json differs from tests/mail-auth/expected-v2.json"
              exit 1
            fi
            if ! diff -u ${../terraform/cloudflare/tests/mail-auth/expected-v2-kinds.json} <(jq -S . "$rendered3Path"); then
              echo "FAIL: the rendering of tests/mail-auth/data-v2-kinds.json differs from tests/mail-auth/expected-v2-kinds.json"
              exit 1
            fi
            # The tools compute the addresses an edit adds or drops with
            # scripts/lib/mail-auth.jq; it must name exactly what the helper renders.
            for f in data data-v2 data-v2-kinds; do
              case "$f" in
                data) r="$renderedPath" ;;
                data-v2) r="$rendered2Path" ;;
                *) r="$rendered3Path" ;;
              esac
              diff -u \
                <(jq -r '.resource.cloudflare_dns_record | to_entries[] | .key as $r | .value.for_each | keys[] | "cloudflare_dns_record.\($r)[\"\(.)\"]"' "$r" | LC_ALL=C sort) \
                <(jq -r -L ${../scripts/lib} 'include "mail-auth"; mail_auth_addresses' ${../terraform/cloudflare/tests/mail-auth}/$f.json | LC_ALL=C sort) ||
                { echo "FAIL: scripts/lib/mail-auth.jq names different addresses than mail-auth.nix renders for $f.json"; exit 1; }
            done
            echo "mail-auth.nix: all assertions passed, the three renderings match, mail-auth.jq agrees"
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
              GOOGLE_WORKSPACE_TOOLS_LIB=${../scripts/lib} \
              bash ${../scripts/tests/test-google-workspace-dkim.sh}
            touch "$out"
          '';

      checks.google-workspace-domains-test =
        pkgs.runCommand "google-workspace-domains-test"
          {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.coreutils
              # registrar-debris talks to the Cloudflare API with curl.
              pkgs.curl
              pkgs.gawk
              pkgs.git
              pkgs.gnugrep
              pkgs.gnused
              pkgs.jq
              pkgs.openssl
              # setsid: the test interrupts a background follower's process
              # group. (The key-unlock offer's terminal is python's pty.)
              pkgs.util-linux
              (pkgs.python3.withPackages (p: [
                p.google-auth
                p.requests
              ]))
            ];
          }
          ''
            GOOGLE_WORKSPACE_DOMAINS_SCRIPT=${../scripts/google-workspace-domains.sh} \
              GOOGLE_WORKSPACE_SETUP_SCRIPT=${../scripts/google-workspace-setup.sh} \
              GOOGLE_WORKSPACE_DKIM_SCRIPT=${../scripts/google-workspace-dkim.sh} \
              GOOGLE_WORKSPACE_DOMAINS_API="python3 ${../scripts/google-workspace-domains-api.py}" \
              GOOGLE_WORKSPACE_TOOLS_LIB=${../scripts/lib} \
              GOOGLE_API_STUB=${../scripts/tests/google-api-stub.py} \
              bash ${../scripts/tests/test-google-workspace-domains.sh}
            touch "$out"
          '';
    };
}
