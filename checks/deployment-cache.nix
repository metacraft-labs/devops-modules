{ ... }:
{
  perSystem =
    {
      pkgs,
      self',
      ...
    }:
    let
      lib = pkgs.lib;
      indent = prefix: text: prefix + lib.replaceStrings [ "\n" ] [ "\n${prefix}" ] text;
      cacheName = "example-deploy-cache";
      fixture = pkgs.writeText "deployment-cache-fixture" ''
        deployment cache fixture
      '';
      atticEnvironmentFile = pkgs.runCommand "deployment-cache-atticd-env" { } ''
        echo ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64="$(${lib.getExe pkgs.openssl} genrsa -traditional 4096 | ${pkgs.coreutils}/bin/base64 -w0)" > "$out"
      '';
      atticServerNode = {
        networking.firewall.allowedTCPPorts = [ 8080 ];
        services.atticd = {
          enable = true;
          environmentFile = atticEnvironmentFile;
          settings = {
            listen = "[::]:8080";
            api-endpoint = "http://attic:8080/";
            allowed-hosts = [
              "attic:8080"
              "localhost:8080"
              "127.0.0.1:8080"
            ];
          };
        };
      };
      clientBaseNode = {
        nix.settings.experimental-features = [
          "nix-command"
          "flakes"
        ];
        environment.etc."deployment-cache-fixture".source = fixture;
        environment.systemPackages = [
          pkgs.attic-client
          pkgs.python3
        ];
      };
      createCacheScript = ''
        attic.wait_for_unit("atticd.service")
        attic.wait_for_open_port(8080)

        token = attic.succeed(
            "atticd-atticadm make-token "
            "--sub deployment-cache-test "
            "--validity 1y "
            "--create-cache '*' "
            "--pull '*' "
            "--push '*' "
            "--delete '*' "
            "--configure-cache '*' "
            "--configure-cache-retention '*'"
        ).strip()
        client.succeed(f"attic login --set-default local http://attic:8080 {token}")
        client.succeed("attic cache create --public ${cacheName}")
        cache_info = client.succeed("attic cache info ${cacheName} 2>&1")
        public_key = ""
        for line in cache_info.splitlines():
            marker = "Public Key:"
            if marker in line:
                public_key = line.split(marker, 1)[1].strip()
                break
        assert public_key, "Attic cache info did not expose a public key"
      '';
      fakeCachix = pkgs.writeShellScriptBin "cachix" ''
        set -eu
        if [ "''${1:-}" != push ]; then
          echo "fake cachix only supports push" >&2
          exit 64
        fi
        printf '%s\n' "$*" >> /tmp/fake-cachix-commands
      '';
      mclFakeCachix = self'.packages.mcl-devops.overrideAttrs (_old: {
        postFixup = ''
          wrapProgram "$out/bin/mcl-devops" \
            --prefix PATH : "${
              lib.makeBinPath (
                [
                  fakeCachix
                  pkgs.attic-client
                  pkgs.nix
                  pkgs.nix-eval-jobs
                  pkgs.gitMinimal
                  pkgs.jc
                  pkgs.util-linux
                  pkgs.alejandra
                  pkgs.openssh
                ]
                ++ lib.optionals (pkgs.stdenv.hostPlatform.isLinux && pkgs.stdenv.hostPlatform.isx86) [
                  pkgs.dmidecode
                  pkgs.systemd
                ]
              )
            }" \
            --prefix LD_LIBRARY_PATH : "${
              lib.makeLibraryPath (
                [
                  fakeCachix
                  pkgs.attic-client
                  pkgs.nix
                  pkgs.nix-eval-jobs
                  pkgs.gitMinimal
                  pkgs.jc
                  pkgs.util-linux
                  pkgs.alejandra
                  pkgs.openssh
                ]
                ++ lib.optionals (pkgs.stdenv.hostPlatform.isLinux && pkgs.stdenv.hostPlatform.isx86) [
                  pkgs.dmidecode
                  pkgs.systemd
                ]
              )
            }"
        '';
      });
    in
    {
      # NixOS VM tests below build a NixOS guest, which is only possible on
      # Linux builders. aarch64-darwin runners would try to build aarch64-linux
      # systemd unit derivations and fail with "required system or feature not
      # available". Gate the whole attrset on Linux so the matrix doesn't even
      # schedule these on Darwin.
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        deployment-attic-push-substitute-vm = pkgs.testers.nixosTest {
          name = "deployment-attic-push-substitute-vm";

          nodes = {
            attic = atticServerNode;
            client = lib.recursiveUpdate clientBaseNode {
              environment.systemPackages = clientBaseNode.environment.systemPackages ++ [
                self'.packages.mcl-devops
              ];
            };
          };

          testScript = ''
            start_all()

            with subtest("create public Attic cache"):
            ${indent "    " createCacheScript}

            with subtest("push closure through mcl-devops and verify substitute probe"):
                client.succeed(
                    "mcl-devops cache push-closure "
                    "--backend attic "
                    "--cache ${cacheName} "
                    "--target attic-client "
                    "--system x86_64-linux "
                    "--kind vm "
                    "--transport nixos-test "
                    "--substituter http://attic:8080/${cacheName} "
                    f"--trusted-public-key '{public_key}' "
                    "--require-substitute "
                    "--event-log /tmp/attic-cache-events.jsonl "
                    "${fixture}"
                )

            with subtest("restore pushed closure from Attic through Nix"):
                client.succeed(
                    "nix copy "
                    "--from http://attic:8080/${cacheName} "
                    "--to file:///tmp/attic-restore-store "
                    f"--option trusted-public-keys '{public_key}' "
                    "${fixture}"
                )

            with subtest("check event coverage"):
                client.succeed(
                    "python3 - <<'PY'\n"
                    "import json\n"
                    "events = [json.loads(line) for line in open('/tmp/attic-cache-events.jsonl') if line.strip()]\n"
                    "assert len(events) == 1, events\n"
                    "event = events[0]\n"
                    "assert event['backend']['controller'] == 'attic', event\n"
                    "assert event['command']['status'] == 'succeeded', event\n"
                    "assert event['metadata']['coverage']['complete'] is True, event\n"
                    "assert event['metadata']['coverage']['probedPathCount'] > 0, event\n"
                    "assert {probe['outcome'] for probe in event['metadata']['probes']} == {'successful-substitute'}, event\n"
                    "PY"
            )
          '';
        };

        deployment-cache-corruption-vm = pkgs.testers.nixosTest {
          name = "deployment-cache-corruption-vm";

          nodes = {
            client = lib.recursiveUpdate clientBaseNode {
              environment.systemPackages = clientBaseNode.environment.systemPackages ++ [
                self'.packages.mcl-devops
              ];
            };
          };

          testScript = ''
            start_all()

            with subtest("missing substitute fails the cache integrity gate"):
                client.fail(
                    "mcl-devops cache push-closure "
                    "--backend none "
                    "--cache missing-cache "
                    "--target missing-cache-target "
                    "--system x86_64-linux "
                    "--kind vm "
                    "--transport nixos-test "
                    "--substituter http://127.0.0.1:9/missing-cache "
                    "--require-substitute "
                    "--event-log /tmp/cache-corruption-events.jsonl "
                    "${fixture}"
                )

            with subtest("failure event identifies the unavailable substitute"):
                client.succeed(
                    "python3 - <<'PY'\n"
                    "import json\n"
                    "events = [json.loads(line) for line in open('/tmp/cache-corruption-events.jsonl') if line.strip()]\n"
                    "assert len(events) == 1, events\n"
                    "event = events[0]\n"
                    "assert event['phase'] == 'cache-push', event\n"
                    "assert event['backend']['controller'] == 'none', event\n"
                    "assert event['backend']['substituters'] == ['http://127.0.0.1:9/missing-cache'], event\n"
                    "assert event['command']['status'] == 'failed', event\n"
                    "assert event['error']['code'] == 'cache_probe_failed', event\n"
                    "assert 'Cache substitute integrity probe failed' in event['error']['message'], event\n"
                    "coverage = event['metadata']['coverage']\n"
                    "assert coverage['complete'] is False, coverage\n"
                    "assert coverage['probedPathCount'] > 0, coverage\n"
                    "assert coverage['successfulSubstituteCount'] == 0, coverage\n"
                    "outcomes = {probe['outcome'] for probe in event['metadata']['probes']}\n"
                    "assert outcomes <= {'narinfo-missing', 'narinfo-present-object-unavailable', 'signature-not-trusted'}, outcomes\n"
                    "assert outcomes, event\n"
                    "PY"
                )
          '';
        };

        deployment-parallel-cache-push-local = pkgs.testers.nixosTest {
          name = "deployment-parallel-cache-push-local";

          nodes = {
            attic = atticServerNode;
            client = lib.recursiveUpdate clientBaseNode {
              environment.systemPackages = clientBaseNode.environment.systemPackages ++ [
                mclFakeCachix
              ];
            };
          };

          testScript = ''
            start_all()

            with subtest("create public Attic cache"):
            ${indent "    " createCacheScript}

            with subtest("push through fake Cachix backend"):
                client.succeed(
                    "mcl-devops cache push-closure "
                    "--backend cachix "
                    "--cache fake-cachix-cache "
                    "--target app-server-01 "
                    "--system x86_64-linux "
                    "--kind server "
                    "--transport local "
                    "--event-log /tmp/deployment-cache-push-events.jsonl "
                    "${fixture}"
                )
                client.succeed("grep -q '^push fake-cachix-cache ${fixture}$' /tmp/fake-cachix-commands")

            with subtest("push through real Attic backend and substitute it"):
                client.succeed(
                    "mcl-devops cache push-closure "
                    "--backend attic "
                    "--cache ${cacheName} "
                    "--target app-server-01 "
                    "--system x86_64-linux "
                    "--kind server "
                    "--transport local "
                    "--substituter http://attic:8080/${cacheName} "
                    f"--trusted-public-key '{public_key}' "
                    "--require-substitute "
                    "--event-log /tmp/deployment-cache-push-events.jsonl "
                    "${fixture}"
                )

            with subtest("check parallel backend coverage"):
                client.succeed(
                    "python3 - <<'PY'\n"
                    "import json\n"
                    "events = [json.loads(line) for line in open('/tmp/deployment-cache-push-events.jsonl') if line.strip()]\n"
                    "assert len(events) == 2, events\n"
                    "controllers = [event['backend']['controller'] for event in events]\n"
                    "assert controllers == ['cachix', 'attic'], controllers\n"
                    "assert [event['command']['status'] for event in events] == ['succeeded', 'succeeded'], events\n"
                    "assert events[0]['metadata']['coverage']['complete'] is False, events[0]\n"
                    "assert events[0]['metadata']['coverage']['probedPathCount'] == 0, events[0]\n"
                    "assert events[1]['metadata']['coverage']['complete'] is True, events[1]\n"
                    "assert events[1]['metadata']['coverage']['probedPathCount'] > 0, events[1]\n"
                    "PY"
                )
          '';
        };
      };
    };
}
