top@{ config, ... }:
{
  perSystem =
    {
      pkgs,
      lib,
      self',
      ...
    }:
    let
      flake = top.config.flake;
      indent = prefix: text: prefix + lib.replaceStrings [ "\n" ] [ "\n${prefix}" ] text;
      deployPrivateKey = pkgs.writeText "mcl-deploy-test-key" ''
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACDxlC1Pq0mEdL5sit20QH3e7/Uax+ldXJQXfKXmfN6eMAAAAJgkvRzyJL0c
        8gAAAAtzc2gtZWQyNTUxOQAAACDxlC1Pq0mEdL5sit20QH3e7/Uax+ldXJQXfKXmfN6eMA
        AAAEB4Us+BAX4cSs+Vg/LReEiceYS1znXvLLIR5yXI9/HM1vGULU+rSYR0vmyK3bRAfd7v
        9RrH6V1clBd8peZ83p4wAAAAD21jbC1kZXBsb3ktdGVzdAECAwQFBg==
        -----END OPENSSH PRIVATE KEY-----
      '';
      deployPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPGULU+rSYR0vmyK3bRAfd7v9RrH6V1clBd8peZ83p4w mcl-deploy-test";
      manifestPrivateKey = pkgs.writeText "mcl-manifest-test-key" ''
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACDhvqWTBaFX/XLEIco2ux47m8yJz7xl+vTsiB2LGk7h7QAAAJifNGKYnzRi
        mAAAAAtzc2gtZWQyNTUxOQAAACDhvqWTBaFX/XLEIco2ux47m8yJz7xl+vTsiB2LGk7h7Q
        AAAEBvBnhoTQhoz/liGXDGeodsQFCPZfx7B/f10DxJy+VHP+G+pZMFoVf9csQhyja7Hjub
        zInPvGX69OyIHYsaTuHtAAAAEW1jbC1tYW5pZmVzdC10ZXN0AQIDBA==
        -----END OPENSSH PRIVATE KEY-----
      '';
      manifestPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOG+pZMFoVf9csQhyja7HjubzInPvGX69OyIHYsaTuHt mcl-manifest-test";
      successSystemPath = "/nix/store/11111111111111111111111111111111-nixos-system-target-success";
      rollbackSystemPath = "/nix/store/22222222222222222222222222222222-nixos-system-target-rollback";
      oldSystemPath = "/nix/store/33333333333333333333333333333333-nixos-system-target-old";
      newSystemPath = "/nix/store/44444444444444444444444444444444-nixos-system-target-new";
      initialGeneration = "/nix/store/00000000000000000000000000000000-nixos-system-target-initial";
      successGeneration = "/nix/store/55555555555555555555555555555555-nixos-system-target-success-generation";
      rollbackFailedGeneration = "/nix/store/66666666666666666666666666666666-nixos-system-target-failed-generation";
      supersededGeneration = "/nix/store/77777777777777777777777777777777-nixos-system-target-superseded-generation";
      restoreScript = pkgs.writeShellScript "mcl-test-restore" ''
        set -euo pipefail
        mkdir -p /var/lib/mcl-test
        printf 'restore\n' >> /var/lib/mcl-test/restore-runs
      '';
      generationScript = pkgs.writeShellScript "mcl-test-generation" ''
        set -euo pipefail
        if [ -f /var/lib/mcl-test/current-generation ]; then
          cat /var/lib/mcl-test/current-generation
        else
          printf '%s\n' ${lib.escapeShellArg initialGeneration}
        fi
      '';
      mkSwitchScript =
        label: generation:
        pkgs.writeShellScript "mcl-test-switch-${label}" ''
          set -euo pipefail
          mkdir -p /var/lib/mcl-test
          printf '%s\n' ${lib.escapeShellArg generation} > /var/lib/mcl-test/current-generation
          printf '%s\n' ${lib.escapeShellArg label} >> /var/lib/mcl-test/switch-runs
        '';
      rollbackScript = pkgs.writeShellScript "mcl-test-rollback" ''
        set -euo pipefail
        mkdir -p /var/lib/mcl-test
        printf '%s\n' ${lib.escapeShellArg initialGeneration} > /var/lib/mcl-test/current-generation
        printf 'rollback\n' >> /var/lib/mcl-test/rollback-runs
      '';
      mkHealthScript =
        label: generation:
        pkgs.writeShellScript "mcl-test-health-${label}" ''
          set -euo pipefail
          test "$(cat /var/lib/mcl-test/current-generation)" = ${lib.escapeShellArg generation}
        '';
      successSwitchScript = mkSwitchScript "success" successGeneration;
      rollbackSwitchScript = mkSwitchScript "failing-health" rollbackFailedGeneration;
      supersededSwitchScript = mkSwitchScript "superseded-newest-only" supersededGeneration;
      successHealthScript = mkHealthScript "success" successGeneration;
      supersededHealthScript = mkHealthScript "superseded" supersededGeneration;
      fakeClosureEnv = "MCL_DEPLOY_FAKE_CLOSURE_COUNT=1 MCL_DEPLOY_FAKE_CLOSURE_TOTAL_BYTES=4096";
      successHealthCommand = "generation|5|${successHealthScript}";
      rollbackHealthCommand = "health-fails|5|false";
      supersededHealthCommand = "generation|5|${supersededHealthScript}";
      atticCacheName = "mcl-deploy-apply-cache";
      atticEnvironmentFile = pkgs.runCommand "deployment-reconciler-atticd-env" { } ''
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
      createAtticCacheScript = client: ''
        attic.wait_for_unit("atticd.service")
        attic.wait_for_open_port(8080)

        token = attic.succeed(
            "atticd-atticadm make-token "
            "--sub deployment-reconciler-restore-test "
            "--validity 1y "
            "--create-cache '*' "
            "--pull '*' "
            "--push '*' "
            "--delete '*' "
            "--configure-cache '*' "
            "--configure-cache-retention '*'"
        ).strip()
        ${client}.succeed(f"attic login --set-default local http://attic:8080 {token}")
        ${client}.succeed("attic cache create --public ${atticCacheName}")
        cache_info = ${client}.succeed("attic cache info ${atticCacheName} 2>&1")
        public_key = ""
        for line in cache_info.splitlines():
            marker = "Public Key:"
            if marker in line:
                public_key = line.split(marker, 1)[1].strip()
                break
        assert public_key, "Attic cache info did not expose a public key"
      '';
      slowMcl = pkgs.writeShellApplication {
        name = "mcl-devops";
        runtimeInputs = [
          pkgs.coreutils
        ];
        text = ''
          set -euo pipefail
          if [ "''${1:-}" != deploy-reconcile ]; then
            echo "fake mcl-devops only supports deploy-reconcile" >&2
            exit 64
          fi

          mkdir -p /var/lib/mcl-test
          printf 'start:%s:%s\n' "$$" "$*" >> /var/lib/mcl-test/reconciler-runs
          touch /var/lib/mcl-test/reconciler-started
          sleep 12
          printf 'end:%s:%s\n' "$$" "$*" >> /var/lib/mcl-test/reconciler-runs
        '';
      };

      timerSystem = lib.nixosSystem {
        system = pkgs.stdenv.hostPlatform.system;
        modules = [
          flake.modules.nixos.deployment-reconciler-timer
          {
            services.mcl-deployment-reconciler = {
              enable = true;
              package = self'.packages.mcl-devops;
              stateDir = "/var/lib/mcl/test-deployments";
              eventLog = "/var/log/mcl/deployments/test-reconciler.jsonl";
              interval = "7min";
              jitter = "73s";
              lockFile = "/run/lock/mcl-test-reconciler.lock";
              targets = [ "target-a" ];
              targetHosts.target-a = "10.0.0.12";
              sshUser = "deploy-test";
              sshOptions = [
                "BatchMode=yes"
                "ConnectTimeout=3"
              ];
              identityFile = "/run/keys/deploy";
              dryRun = true;
            };
          }
        ];
      };
      timerService = timerSystem.config.systemd.services.mcl-deployment-reconciler;
      timer = timerSystem.config.systemd.timers.mcl-deployment-reconciler;
      execStart = timerService.serviceConfig.ExecStart;
      failures = lib.flatten [
        (lib.optional (
          !lib.hasInfix "flock -n /run/lock/mcl-test-reconciler.lock" execStart
        ) "reconciler service does not use configured flock lock")
        (lib.optional (
          !lib.hasInfix "deploy-reconcile" execStart
        ) "reconciler service does not call mcl-devops deploy-reconcile")
        (lib.optional (
          !lib.hasInfix "--state-dir /var/lib/mcl/test-deployments" execStart
        ) "reconciler service does not pass state dir")
        (lib.optional (
          !lib.hasInfix "--target target-a" execStart
        ) "reconciler service does not pass target selector")
        (lib.optional (
          !lib.hasInfix "--target-host 'target-a=10.0.0.12'" execStart
        ) "reconciler service does not pass target host mapping")
        (lib.optional (
          !lib.hasInfix "--identity-file /run/keys/deploy" execStart
        ) "reconciler service does not pass identity file")
        (lib.optional (!lib.hasInfix "--dry-run" execStart) "reconciler service does not pass dry-run")
        (lib.optional (timer.timerConfig.OnUnitActiveSec != "7min") "timer interval drifted")
        (lib.optional (timer.timerConfig.RandomizedDelaySec != "73s") "timer jitter drifted")
        (lib.optional (timer.timerConfig.Persistent != true) "timer is not persistent")
      ];
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        deployment-direct-ssh-success-vm = pkgs.testers.nixosTest {
          name = "deployment-direct-ssh-success-vm";

          nodes = {
            controller = {
              environment.systemPackages = [
                self'.packages.mcl-devops
                pkgs.openssh
                pkgs.python3
              ];
            };

            target =
              { ... }:
              {
                imports = [ flake.modules.nixos.deployment-forced-command-apply ];

                networking.hostName = "target";
                environment.systemPackages = [ pkgs.python3 ];
                services.openssh = {
                  enable = true;
                  settings.PasswordAuthentication = false;
                };
                services.mcl-deployment-ssh-apply = {
                  enable = true;
                  package = self'.packages.mcl-devops;
                  targetName = "target";
                  manifestPrincipal = "mcl-deployment";
                  manifestPublicKeys = [ manifestPublicKey ];
                  authorizedKeys = [ deployPublicKey ];
                  restoreCommand = "${restoreScript}";
                  switchCommand = "${successSwitchScript}";
                  generationCommand = "${generationScript}";
                };
              };
          };

          testScript = ''
            start_all()
            target.wait_for_unit("sshd.service")

            with subtest("create signed desired-state manifest"):
                controller.succeed("install -m 0600 ${deployPrivateKey} /tmp/deploy-key")
                controller.succeed("install -m 0600 ${manifestPrivateKey} /tmp/manifest-key")
                controller.succeed(
                    "${fakeClosureEnv} mcl-devops deploy-plan "
                    "--target target "
                    "--desired-system-path ${successSystemPath} "
                    "--git-revision 0123456789abcdef0123456789abcdef01234567 "
                    "--sequence 1 "
                    "--health-command ${lib.escapeShellArg successHealthCommand} "
                    "--signing-key /tmp/manifest-key "
                    "--signing-key-id mcl-deployment "
                    "--output /tmp/manifest.json "
                    "--state-dir /tmp/reconciler-state"
                )

            with subtest("forced command rejects arbitrary shell"):
                controller.fail(
                    "ssh -i /tmp/deploy-key "
                    "-o StrictHostKeyChecking=no "
                    "-o UserKnownHostsFile=/dev/null "
                    "deploy@target true"
                )

            with subtest("forced command accepts signed manifest on stdin"):
                controller.succeed(
                    "ssh -i /tmp/deploy-key "
                    "-o StrictHostKeyChecking=no "
                    "-o UserKnownHostsFile=/dev/null "
                    "deploy@target < /tmp/manifest.json"
                )

            with subtest("target ran non-dry-run restore, switch, and health check"):
                target.succeed("test -s /var/lib/mcl-test/restore-runs")
                target.succeed("test -s /var/lib/mcl-test/switch-runs")
                target.succeed("grep -qx restore /var/lib/mcl-test/restore-runs")
                target.succeed("grep -qx success /var/lib/mcl-test/switch-runs")
                target.succeed("test \"$(cat /var/lib/mcl-test/current-generation)\" = '${successGeneration}'")

            with subtest("target recorded non-dry-run convergence events and state"):
                target.succeed("test -s /var/log/mcl/deployments/target.jsonl")
                target.succeed(
                    "python3 - <<'PY'\n"
                    "import json\n"
                    "events = [json.loads(line) for line in open('/var/log/mcl/deployments/target.jsonl') if line.strip()]\n"
                    "phases = [(event['phase'], event['command']['status']) for event in events]\n"
                    "assert ('activate-requested', 'succeeded') in phases, phases\n"
                    "assert ('agent-restore', 'succeeded') in phases, phases\n"
                    "assert ('switch', 'succeeded') in phases, phases\n"
                    "assert ('healthcheck', 'succeeded') in phases, phases\n"
                    "assert ('complete', 'succeeded') in phases, phases\n"
                    "assert all(event['deploymentId'] == 'gh-local-unknown-target' for event in events), events\n"
                    "activate = next(event for event in events if event['phase'] == 'activate-requested')\n"
                    "assert activate['metadata']['dryRun'] is False, activate\n"
                    "restore = next(event for event in events if event['phase'] == 'agent-restore')\n"
                    "assert restore['command']['argv'][0:2] == ['sh', '-c'], restore\n"
                    "switch = next(event for event in events if event['phase'] == 'switch')\n"
                    "assert switch['metadata']['previousGeneration'] == '${initialGeneration}', switch\n"
                    "assert switch['metadata']['newGeneration'] == '${successGeneration}', switch\n"
                    "complete = next(event for event in events if event['phase'] == 'complete')\n"
                    "assert complete['metadata']['previousGeneration'] == '${initialGeneration}', complete\n"
                    "assert complete['metadata']['newGeneration'] == '${successGeneration}', complete\n"
                    "PY"
                )
                target.succeed(
                    "python3 - <<'PY'\n"
                    "import json\n"
                    "state = json.load(open('/var/lib/mcl/deployments/converged/gh-local-unknown-target.json'))\n"
                    "assert state['currentState'] == 'succeeded', state\n"
                    "assert state['desiredSystemPath'] == '${successSystemPath}', state\n"
                    "PY"
                )
          '';
        };

        deployment-direct-ssh-rollback-vm = pkgs.testers.nixosTest {
          name = "deployment-direct-ssh-rollback-vm";

          nodes = {
            controller = {
              environment.systemPackages = [
                self'.packages.mcl-devops
                pkgs.openssh
                pkgs.python3
              ];
            };

            target =
              { ... }:
              {
                imports = [ flake.modules.nixos.deployment-forced-command-apply ];

                networking.hostName = "target";
                environment.systemPackages = [ pkgs.python3 ];
                services.openssh = {
                  enable = true;
                  settings.PasswordAuthentication = false;
                };
                services.mcl-deployment-ssh-apply = {
                  enable = true;
                  package = self'.packages.mcl-devops;
                  targetName = "target";
                  manifestPrincipal = "mcl-deployment";
                  manifestPublicKeys = [ manifestPublicKey ];
                  authorizedKeys = [ deployPublicKey ];
                  restoreCommand = "${restoreScript}";
                  switchCommand = "${rollbackSwitchScript}";
                  rollbackCommand = "${rollbackScript}";
                  generationCommand = "${generationScript}";
                };
              };
          };

          testScript = ''
            start_all()
            target.wait_for_unit("sshd.service")

            with subtest("create signed rollback manifest"):
                controller.succeed("install -m 0600 ${deployPrivateKey} /tmp/deploy-key")
                controller.succeed("install -m 0600 ${manifestPrivateKey} /tmp/manifest-key")
                controller.succeed(
                    "${fakeClosureEnv} mcl-devops deploy-plan "
                    "--target target "
                    "--desired-system-path ${rollbackSystemPath} "
                    "--git-revision 2222222222222222222222222222222222222222 "
                    "--sequence 1 "
                    "--health-command ${lib.escapeShellArg rollbackHealthCommand} "
                    "--rollback-mode automatic "
                    "--rollback-max-attempts 1 "
                    "--on-health-check-failure rollback "
                    "--signing-key /tmp/manifest-key "
                    "--signing-key-id mcl-deployment "
                    "--output /tmp/manifest.json"
                )

            with subtest("forced command exits failed after successful automatic rollback"):
                controller.fail(
                    "ssh -i /tmp/deploy-key "
                    "-o StrictHostKeyChecking=no "
                    "-o UserKnownHostsFile=/dev/null "
                    "deploy@target < /tmp/manifest.json"
                )

            with subtest("target ran restore, switch, and rollback commands"):
                target.succeed("grep -qx restore /var/lib/mcl-test/restore-runs")
                target.succeed("grep -qx failing-health /var/lib/mcl-test/switch-runs")
                target.succeed("grep -qx rollback /var/lib/mcl-test/rollback-runs")
                target.succeed("test \"$(cat /var/lib/mcl-test/current-generation)\" = '${initialGeneration}'")

            with subtest("target recorded health failure, rollback, and failed completion"):
                target.succeed(
                    "python3 - <<'PY'\n"
                    "import json\n"
                    "events = [json.loads(line) for line in open('/var/log/mcl/deployments/target.jsonl') if line.strip()]\n"
                    "phases = [(event['phase'], event['command']['status']) for event in events]\n"
                    "assert ('activate-requested', 'succeeded') in phases, phases\n"
                    "assert ('agent-restore', 'succeeded') in phases, phases\n"
                    "assert ('switch', 'succeeded') in phases, phases\n"
                    "assert ('healthcheck', 'failed') in phases, phases\n"
                    "assert ('rollback', 'succeeded') in phases, phases\n"
                    "assert ('complete', 'failed') in phases, phases\n"
                    "switch = next(event for event in events if event['phase'] == 'switch')\n"
                    "assert switch['metadata']['previousGeneration'] == '${initialGeneration}', switch\n"
                    "assert switch['metadata']['newGeneration'] == '${rollbackFailedGeneration}', switch\n"
                    "rollback = next(event for event in events if event['phase'] == 'rollback')\n"
                    "assert rollback['metadata']['previousGeneration'] == '${initialGeneration}', rollback\n"
                    "assert rollback['metadata']['failedGeneration'] == '${rollbackFailedGeneration}', rollback\n"
                    "complete = next(event for event in events if event['phase'] == 'complete')\n"
                    "assert complete['command']['status'] == 'failed', complete\n"
                    "PY"
                )
                target.succeed(
                    "python3 - <<'PY'\n"
                    "import json\n"
                    "state = json.load(open('/var/lib/mcl/deployments/current/gh-local-unknown-target.json'))\n"
                    "assert state['currentState'] == 'rolled-back', state\n"
                    "assert state['desiredSystemPath'] == '${rollbackSystemPath}', state\n"
                    "PY"
                )
          '';
        };

        deployment-reconciler-supersession-vm = pkgs.testers.nixosTest {
          name = "deployment-reconciler-supersession-vm";

          nodes = {
            controller = {
              environment.systemPackages = [
                self'.packages.mcl-devops
                pkgs.openssh
                pkgs.python3
              ];
            };

            target =
              { ... }:
              {
                imports = [ flake.modules.nixos.deployment-forced-command-apply ];

                networking.hostName = "target";
                environment.systemPackages = [ pkgs.python3 ];
                services.openssh = {
                  enable = true;
                  settings.PasswordAuthentication = false;
                };
                services.mcl-deployment-ssh-apply = {
                  enable = true;
                  package = self'.packages.mcl-devops;
                  targetName = "target";
                  manifestPrincipal = "mcl-deployment";
                  manifestPublicKeys = [ manifestPublicKey ];
                  authorizedKeys = [ deployPublicKey ];
                  restoreCommand = "${restoreScript}";
                  switchCommand = "${supersededSwitchScript}";
                  generationCommand = "${generationScript}";
                };
              };
          };

          testScript = ''
            start_all()
            target.wait_for_unit("sshd.service")

            with subtest("create old and new signed manifests"):
                controller.succeed("install -m 0600 ${deployPrivateKey} /tmp/deploy-key")
                controller.succeed("install -m 0600 ${manifestPrivateKey} /tmp/manifest-key")
                controller.succeed(
                    "${fakeClosureEnv} GITHUB_RUN_ID=41 GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 "
                    "mcl-devops deploy-plan "
                    "--target target "
                    "--desired-system-path ${oldSystemPath} "
                    "--git-revision 0123456789abcdef0123456789abcdef01234567 "
                    "--sequence 1 "
                    "--health-command ${lib.escapeShellArg supersededHealthCommand} "
                    "--signing-key /tmp/manifest-key "
                    "--signing-key-id mcl-deployment "
                    "--output /tmp/old.json"
                )
                controller.succeed(
                    "${fakeClosureEnv} GITHUB_RUN_ID=42 GITHUB_SHA=1123456789abcdef0123456789abcdef01234567 "
                    "mcl-devops deploy-plan "
                    "--target target "
                    "--desired-system-path ${newSystemPath} "
                    "--git-revision 1123456789abcdef0123456789abcdef01234567 "
                    "--sequence 2 "
                    "--health-command ${lib.escapeShellArg supersededHealthCommand} "
                    "--signing-key /tmp/manifest-key "
                    "--signing-key-id mcl-deployment "
                    "--output /tmp/new.json"
                )

            with subtest("reconciler sends only the newest manifest over forced-command ssh"):
                controller.succeed(
                    "mcl-devops deploy-reconcile "
                    "--state-dir /tmp/reconciler-state "
                    "--manifest /tmp/old.json "
                    "--manifest /tmp/new.json "
                    "--target target "
                    "--target-host target=target "
                    "--identity-file /tmp/deploy-key "
                    "--ssh-option StrictHostKeyChecking=no "
                    "--ssh-option UserKnownHostsFile=/dev/null"
                )

            with subtest("controller recorded old manifest as superseded and new as succeeded"):
                controller.succeed("test -f /tmp/reconciler-state/superseded/gh-41-0123456-target.json")
                controller.succeed(
                    "python3 - <<'PY'\n"
                    "import json\n"
                    "state = json.load(open('/tmp/reconciler-state/converged/gh-42-1123456-target.json'))\n"
                    "assert state['currentState'] == 'succeeded', state\n"
                    "assert state['desiredSystemPath'] == '${newSystemPath}', state\n"
                    "PY"
                )

            with subtest("target applied only the newest manifest"):
                target.succeed("test \"$(wc -l < /var/lib/mcl-test/restore-runs)\" = 1")
                target.succeed("test \"$(wc -l < /var/lib/mcl-test/switch-runs)\" = 1")
                target.succeed("grep -qx superseded-newest-only /var/lib/mcl-test/switch-runs")
                target.succeed(
                    "python3 - <<'PY'\n"
                    "import json\n"
                    "events = [json.loads(line) for line in open('/var/log/mcl/deployments/target.jsonl') if line.strip()]\n"
                    "ids = {event['deploymentId'] for event in events}\n"
                    "assert ids == {'gh-42-1123456-target'}, ids\n"
                    "paths = {event['storePaths']['system'] for event in events}\n"
                    "assert paths == {'${newSystemPath}'}, paths\n"
                    "phases = [(event['phase'], event['command']['status']) for event in events]\n"
                    "assert ('agent-restore', 'succeeded') in phases, phases\n"
                    "assert ('switch', 'succeeded') in phases, phases\n"
                    "assert ('healthcheck', 'succeeded') in phases, phases\n"
                    "assert ('complete', 'succeeded') in phases, phases\n"
                    "PY"
                )
                target.succeed("test ! -e /var/lib/mcl/deployments/desired/gh-41-0123456-target.json")
                target.succeed(
                    "python3 - <<'PY'\n"
                    "import json\n"
                    "state = json.load(open('/var/lib/mcl/deployments/converged/gh-42-1123456-target.json'))\n"
                    "assert state['currentState'] == 'succeeded', state\n"
                    "assert state['desiredSystemPath'] == '${newSystemPath}', state\n"
                    "PY"
                )
          '';
        };

        deployment-reconciler-timer-retry-vm = pkgs.testers.nixosTest {
          name = "deployment-reconciler-timer-retry-vm";

          nodes = {
            controller =
              { ... }:
              {
                imports = [ flake.modules.nixos.deployment-reconciler-timer ];

                environment.systemPackages = [
                  self'.packages.mcl-devops
                  pkgs.openssh
                  pkgs.python3
                ];
                services.mcl-deployment-reconciler = {
                  enable = true;
                  package = self'.packages.mcl-devops;
                  stateDir = "/var/lib/mcl/deployments";
                  eventLog = "/var/log/mcl/deployments/reconciler.jsonl";
                  interval = "1min";
                  jitter = "0";
                  lockFile = "/run/lock/mcl-test-reconciler.lock";
                  targets = [ "target" ];
                  targetHosts.target = "target";
                  identityFile = "/run/mcl-test/deploy-key";
                  sshOptions = [
                    "StrictHostKeyChecking=no"
                    "UserKnownHostsFile=/dev/null"
                    "ConnectTimeout=2"
                  ];
                };
              };

            target =
              { ... }:
              {
                imports = [ flake.modules.nixos.deployment-forced-command-apply ];

                networking.hostName = "target";
                environment.systemPackages = [ pkgs.python3 ];
                services.openssh = {
                  enable = true;
                  settings.PasswordAuthentication = false;
                };
                services.mcl-deployment-ssh-apply = {
                  enable = true;
                  package = self'.packages.mcl-devops;
                  targetName = "target";
                  manifestPrincipal = "mcl-deployment";
                  manifestPublicKeys = [ manifestPublicKey ];
                  authorizedKeys = [ deployPublicKey ];
                  restoreCommand = "${restoreScript}";
                  switchCommand = "${successSwitchScript}";
                  generationCommand = "${generationScript}";
                };
              };
          };

          testScript = ''
            start_all()
            controller.wait_for_unit("multi-user.target")
            target.wait_for_unit("sshd.service")

            with subtest("record pending manifest for timer reconciliation"):
                controller.succeed("install -d -m 0700 /run/mcl-test")
                controller.succeed("install -m 0600 ${deployPrivateKey} /run/mcl-test/deploy-key")
                controller.succeed("install -m 0600 ${manifestPrivateKey} /tmp/manifest-key")
                controller.succeed(
                    "${fakeClosureEnv} mcl-devops deploy-plan "
                    "--target target "
                    "--desired-system-path ${successSystemPath} "
                    "--git-revision 0123456789abcdef0123456789abcdef01234567 "
                    "--sequence 1 "
                    "--health-command ${lib.escapeShellArg successHealthCommand} "
                    "--signing-key /tmp/manifest-key "
                    "--signing-key-id mcl-deployment "
                    "--output /tmp/manifest.json "
                    "--state-dir /var/lib/mcl/deployments"
                )

            with subtest("first retry fails while target ssh is unreachable"):
                target.succeed("systemctl stop sshd.service")
                controller.fail("systemctl start mcl-deployment-reconciler.service")
                target.succeed("test ! -e /var/lib/mcl-test/restore-runs")
                controller.succeed(
                    "python3 - <<'PY'\n"
                    "import json\n"
                    "events = [json.loads(line) for line in open('/var/log/mcl/deployments/reconciler.jsonl') if line.strip()]\n"
                    "assert any(event['phase'] == 'activate-requested' and event['command']['status'] == 'failed' for event in events), events\n"
                    "failed = next(event for event in events if event['command']['status'] == 'failed')\n"
                    "assert failed['error']['code'] == 'ssh_reconcile_failed', failed\n"
                    "PY"
                )

            with subtest("second retry applies the same pending manifest after ssh recovers"):
                target.succeed("systemctl start sshd.service")
                target.wait_for_unit("sshd.service")
                controller.succeed("systemctl reset-failed mcl-deployment-reconciler.service")
                controller.succeed("systemctl start mcl-deployment-reconciler.service")
                target.succeed("grep -qx restore /var/lib/mcl-test/restore-runs")
                target.succeed("grep -qx success /var/lib/mcl-test/switch-runs")
                controller.succeed(
                    "python3 - <<'PY'\n"
                    "import json\n"
                    "events = [json.loads(line) for line in open('/var/log/mcl/deployments/reconciler.jsonl') if line.strip()]\n"
                    "statuses = [event['command']['status'] for event in events if event['phase'] == 'activate-requested']\n"
                    "assert statuses.count('failed') == 1, statuses\n"
                    "assert statuses.count('succeeded') == 1, statuses\n"
                    "state = json.load(open('/var/lib/mcl/deployments/converged/gh-local-unknown-target.json'))\n"
                    "assert state['currentState'] == 'succeeded', state\n"
                    "PY"
                )
                target.succeed(
                    "python3 - <<'PY'\n"
                    "import json\n"
                    "events = [json.loads(line) for line in open('/var/log/mcl/deployments/target.jsonl') if line.strip()]\n"
                    "phases = [(event['phase'], event['command']['status']) for event in events]\n"
                    "assert ('agent-restore', 'succeeded') in phases, phases\n"
                    "assert ('switch', 'succeeded') in phases, phases\n"
                    "assert ('healthcheck', 'succeeded') in phases, phases\n"
                    "assert ('complete', 'succeeded') in phases, phases\n"
                    "PY"
                )
          '';
        };

        deployment-direct-ssh-attic-restore-vm = pkgs.testers.nixosTest {
          name = "deployment-direct-ssh-attic-restore-vm";

          nodes = {
            attic = atticServerNode;

            controller = {
              nix.settings.experimental-features = [
                "nix-command"
                "flakes"
              ];
              environment.systemPackages = [
                self'.packages.mcl-devops
                pkgs.attic-client
                pkgs.openssh
                pkgs.python3
              ];
            };

            target =
              { ... }:
              {
                imports = [ flake.modules.nixos.deployment-forced-command-apply ];

                networking.hostName = "target";
                nix.settings.experimental-features = [
                  "nix-command"
                  "flakes"
                ];
                environment.systemPackages = [
                  pkgs.nix
                  pkgs.python3
                ];
                services.openssh = {
                  enable = true;
                  settings.PasswordAuthentication = false;
                };
                services.mcl-deployment-ssh-apply = {
                  enable = true;
                  package = self'.packages.mcl-devops;
                  targetName = "target";
                  manifestPrincipal = "mcl-deployment";
                  manifestPublicKeys = [ manifestPublicKey ];
                  authorizedKeys = [ deployPublicKey ];
                  switchCommand = "${successSwitchScript}";
                  generationCommand = "${generationScript}";
                };
              };
          };

          testScript = ''
            import shlex

            start_all()

            with subtest("create public Attic cache"):
            ${indent "    " (createAtticCacheScript "controller")}

            with subtest("create runtime closure and push it to Attic"):
                controller.succeed("install -m 0600 ${deployPrivateKey} /tmp/deploy-key")
                controller.succeed("install -m 0600 ${manifestPrivateKey} /tmp/manifest-key")
                closure = controller.succeed(
                    "payload=$(mktemp -d); "
                    "printf 'deployment restore fixture\\n' > \"$payload/file\"; "
                    "nix-store --add \"$payload\""
                ).strip()
                substituter = "http://attic:8080/${atticCacheName}"
                controller.succeed(f"attic push ${atticCacheName} {shlex.quote(closure)}")

            with subtest("target starts without the runtime closure"):
                target.wait_for_unit("sshd.service")
                target.fail(f"nix path-info {shlex.quote(closure)}")

            with subtest("create signed manifest requiring Attic substitution"):
                restored_health = f"restored|5|test -e {closure}/file"
                controller.succeed(
                    "mcl-devops deploy-plan "
                    "--target target "
                    f"--desired-system-path {shlex.quote(closure)} "
                    "--git-revision 0123456789abcdef0123456789abcdef01234567 "
                    "--sequence 1 "
                    f"--health-command {shlex.quote(restored_health)} "
                    f"--substituter {shlex.quote(substituter)} "
                    f"--trusted-public-key {shlex.quote(public_key)} "
                    "--availability-mode all-roots-substitutable "
                    "--require-availability "
                    "--signing-key /tmp/manifest-key "
                    "--signing-key-id mcl-deployment "
                    "--output /tmp/manifest.json"
                )

            with subtest("forced command restores from Attic with default nix copy path"):
                controller.succeed(
                    "ssh -i /tmp/deploy-key "
                    "-o StrictHostKeyChecking=no "
                    "-o UserKnownHostsFile=/dev/null "
                    "deploy@target < /tmp/manifest.json"
                )

            with subtest("target now has the restored closure and converged"):
                target.succeed(f"nix path-info {shlex.quote(closure)}")
                target.succeed(f"test -e {shlex.quote(closure + '/file')}")
                target.succeed("grep -qx success /var/lib/mcl-test/switch-runs")
                target.succeed("test \"$(cat /var/lib/mcl-test/current-generation)\" = '${successGeneration}'")

            with subtest("events prove default restore succeeded before switch and health"):
                target.succeed(
                    "python3 - <<'PY'\n"
                    "import json\n"
                    f"closure = {closure!r}\n"
                    f"substituter = {substituter!r}\n"
                    f"public_key = {public_key!r}\n"
                    "events = [json.loads(line) for line in open('/var/log/mcl/deployments/target.jsonl') if line.strip()]\n"
                    "phases = [event['phase'] for event in events]\n"
                    "assert phases.index('agent-restore') < phases.index('switch') < phases.index('healthcheck') < phases.index('complete'), phases\n"
                    "restore = next(event for event in events if event['phase'] == 'agent-restore')\n"
                    "assert restore['command']['status'] == 'succeeded', restore\n"
                    "assert restore['command']['argv'][0:3] == ['nix', 'copy', '--from'], restore\n"
                    "assert restore['command']['argv'][3] == substituter, restore\n"
                    "assert restore['command']['argv'][4] == closure, restore\n"
                    "assert restore['command']['argv'][-3:] == ['--option', 'trusted-public-keys', public_key], restore\n"
                    "assert restore['backend']['substituters'] == [substituter], restore\n"
                    "health = next(event for event in events if event['phase'] == 'healthcheck')\n"
                    "assert health['command']['status'] == 'succeeded', health\n"
                    "complete = next(event for event in events if event['phase'] == 'complete')\n"
                    "assert complete['command']['status'] == 'succeeded', complete\n"
                    "PY"
                )
                target.succeed(
                    "python3 - <<'PY'\n"
                    "import json\n"
                    "state = json.load(open('/var/lib/mcl/deployments/converged/gh-local-unknown-target.json'))\n"
                    f"assert state['desiredSystemPath'] == {closure!r}, state\n"
                    "assert state['currentState'] == 'succeeded', state\n"
                    "PY"
            )
          '';
        };

        deployment-scheduled-canary-local-vm = pkgs.testers.nixosTest {
          name = "deployment-scheduled-canary-local-vm";

          nodes = {
            controller =
              { ... }:
              {
                imports = [ flake.modules.nixos.deployment-reconciler-timer ];

                environment.systemPackages = [
                  self'.packages.mcl-devops
                  pkgs.openssh
                  pkgs.python3
                ];
                services.mcl-deployment-reconciler = {
                  enable = true;
                  package = self'.packages.mcl-devops;
                  stateDir = "/var/lib/mcl/canary-deployments";
                  eventLog = "/var/log/mcl/deployments/local-canary-reconciler.jsonl";
                  interval = "4h";
                  jitter = "0";
                  lockFile = "/run/lock/mcl-local-canary-reconciler.lock";
                  targets = [ "local-canary" ];
                  targetHosts.local-canary = "target";
                  identityFile = "/run/mcl-test/deploy-key";
                  sshOptions = [
                    "StrictHostKeyChecking=no"
                    "UserKnownHostsFile=/dev/null"
                    "ConnectTimeout=2"
                  ];
                };
              };

            target =
              { ... }:
              {
                imports = [ flake.modules.nixos.deployment-forced-command-apply ];

                networking.hostName = "target";
                environment.systemPackages = [ pkgs.python3 ];
                services.openssh = {
                  enable = true;
                  settings.PasswordAuthentication = false;
                };
                services.mcl-deployment-ssh-apply = {
                  enable = true;
                  package = self'.packages.mcl-devops;
                  targetName = "local-canary";
                  manifestPrincipal = "mcl-deployment";
                  manifestPublicKeys = [ manifestPublicKey ];
                  authorizedKeys = [ deployPublicKey ];
                  restoreCommand = "${restoreScript}";
                  switchCommand = "${successSwitchScript}";
                  generationCommand = "${generationScript}";
                };
              };
          };

          testScript = ''
            start_all()
            controller.wait_for_unit("multi-user.target")
            target.wait_for_unit("sshd.service")

            with subtest("prepare a local-only scheduled canary manifest"):
                controller.succeed("install -d -m 0700 /run/mcl-test")
                controller.succeed("install -m 0600 ${deployPrivateKey} /run/mcl-test/deploy-key")
                controller.succeed("install -m 0600 ${manifestPrivateKey} /tmp/manifest-key")
                controller.succeed(
                    "${fakeClosureEnv} GITHUB_RUN_ID=7001 GITHUB_SHA=7777777777777777777777777777777777777777 "
                    "mcl-devops deploy-plan "
                    "--target local-canary "
                    "--desired-system-path ${successSystemPath} "
                    "--git-revision 7777777777777777777777777777777777777777 "
                    "--sequence 7001 "
                    "--health-command ${lib.escapeShellArg successHealthCommand} "
                    "--signing-key /tmp/manifest-key "
                    "--signing-key-id mcl-deployment "
                    "--output /tmp/local-canary-manifest.json "
                    "--state-dir /var/lib/mcl/canary-deployments"
                )

            with subtest("timer configuration is scheduled but production-free"):
                controller.succeed("systemctl cat mcl-deployment-reconciler.timer | grep -q 'OnUnitActiveSec=4h'")
                controller.succeed("systemctl cat mcl-deployment-reconciler.timer | grep -q 'RandomizedDelaySec=0'")
                controller.succeed("test ! -e /var/lib/mcl-test/restore-runs")
                controller.succeed("! grep -R -E 'gpu-node|gpu-server|example-site|hetzner|app-node' /var/lib/mcl/canary-deployments /var/log/mcl 2>/dev/null")

            with subtest("scheduled canary service applies through the reconciler path"):
                controller.succeed("systemctl start mcl-deployment-reconciler.service")
                target.succeed("grep -qx restore /var/lib/mcl-test/restore-runs")
                target.succeed("grep -qx success /var/lib/mcl-test/switch-runs")
                target.succeed("test \"$(cat /var/lib/mcl-test/current-generation)\" = '${successGeneration}'")

            with subtest("canary evidence is local, latest, and converged"):
                controller.succeed(
                    "python3 - <<'PY'\n"
                    "import json\n"
                    "events = [json.loads(line) for line in open('/var/log/mcl/deployments/local-canary-reconciler.jsonl') if line.strip()]\n"
                    "assert any(event['phase'] == 'activate-requested' and event['command']['status'] == 'succeeded' for event in events), events\n"
                    "assert all(event['target']['name'] == 'local-canary' for event in events), events\n"
                    "state = json.load(open('/var/lib/mcl/canary-deployments/converged/gh-7001-7777777-local-canary.json'))\n"
                    "assert state['currentState'] == 'succeeded', state\n"
                    "assert state['desiredSystemPath'] == '${successSystemPath}', state\n"
                    "PY"
                )
                target.succeed(
                    "python3 - <<'PY'\n"
                    "import json\n"
                    "events = [json.loads(line) for line in open('/var/log/mcl/deployments/local-canary.jsonl') if line.strip()]\n"
                    "phases = [(event['phase'], event['command']['status']) for event in events]\n"
                    "assert ('agent-restore', 'succeeded') in phases, phases\n"
                    "assert ('switch', 'succeeded') in phases, phases\n"
                    "assert ('healthcheck', 'succeeded') in phases, phases\n"
                    "assert ('complete', 'succeeded') in phases, phases\n"
                    "assert all(event['target']['name'] == 'local-canary' for event in events), events\n"
                    "PY"
                )
          '';
        };

        deployment-reconciler-lock-contention-vm = pkgs.testers.nixosTest {
          name = "deployment-reconciler-lock-contention-vm";

          nodes = {
            controller =
              { ... }:
              {
                imports = [ flake.modules.nixos.deployment-reconciler-timer ];

                services.mcl-deployment-reconciler = {
                  enable = true;
                  package = slowMcl;
                  stateDir = "/var/lib/mcl/deployments";
                  eventLog = "/var/log/mcl/deployments/reconciler.jsonl";
                  interval = "1min";
                  jitter = "0";
                  lockFile = "/run/lock/mcl-test-reconciler.lock";
                  targets = [ "target" ];
                  targetHosts.target = "target";
                  dryRun = true;
                };
              };
          };

          testScript = ''
            start_all()
            controller.wait_for_unit("multi-user.target")

            with subtest("first service run holds the configured flock lock"):
                controller.succeed("systemctl start --no-block mcl-deployment-reconciler.service")
                controller.wait_until_succeeds("test -e /var/lib/mcl-test/reconciler-started")
                controller.fail("${pkgs.util-linux}/bin/flock -n /run/lock/mcl-test-reconciler.lock ${lib.getExe slowMcl} deploy-reconcile --manual-contender")
                controller.succeed("test \"$(grep -c '^start:' /var/lib/mcl-test/reconciler-runs)\" = 1")
                controller.succeed("test \"$(grep -c '^end:' /var/lib/mcl-test/reconciler-runs || true)\" = 0")

            with subtest("lock releases after the service exits"):
                controller.wait_until_succeeds("test \"$(grep -c '^end:' /var/lib/mcl-test/reconciler-runs)\" = 1")
                controller.succeed("${pkgs.util-linux}/bin/flock -n /run/lock/mcl-test-reconciler.lock ${lib.getExe slowMcl} deploy-reconcile --after-service")
                controller.succeed("test \"$(grep -c '^start:.*--after-service' /var/lib/mcl-test/reconciler-runs)\" = 1")
                controller.succeed("test \"$(grep -c '^end:.*--after-service' /var/lib/mcl-test/reconciler-runs)\" = 1")
          '';
        };

        deployment-reconciler-timer-static = pkgs.runCommand "deployment-reconciler-timer-static" { } ''
          ${lib.optionalString (failures != [ ]) ''
            cat > failures.txt <<'EOF'
            ${lib.concatStringsSep "\n" failures}
            EOF
            cat failures.txt >&2
            exit 1
          ''}
          cat > "$out" <<'EOF'
          deployment reconciler timer rendered expected lock, interval, jitter, selector, dry-run, and ssh options.
          EOF
        '';
      };
    };
}
