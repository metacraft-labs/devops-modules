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
      repoRoot = ../.;
      docs = ../docs/deployment;
      repoWorkflow = ../.github/workflows/ci.yml;
      workflow = ../.github/workflows/reusable-flake-checks-ci-matrix.yml;
      setupNix = ../.github/setup-nix/action.yml;
      deployPrivateKey = pkgs.writeText "mcl-cutover-deploy-test-key" ''
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACDxlC1Pq0mEdL5sit20QH3e7/Uax+ldXJQXfKXmfN6eMAAAAJgkvRzyJL0c
        8gAAAAtzc2gtZWQyNTUxOQAAACDxlC1Pq0mEdL5sit20QH3e7/Uax+ldXJQXfKXmfN6eMA
        AAAEB4Us+BAX4cSs+Vg/LReEiceYS1znXvLLIR5yXI9/HM1vGULU+rSYR0vmyK3bRAfd7v
        9RrH6V1clBd8peZ83p4wAAAAD21jbC1kZXBsb3ktdGVzdAECAwQFBg==
        -----END OPENSSH PRIVATE KEY-----
      '';
      deployPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPGULU+rSYR0vmyK3bRAfd7v9RrH6V1clBd8peZ83p4w mcl-deploy-test";
      manifestPrivateKey = pkgs.writeText "mcl-cutover-manifest-test-key" ''
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACDhvqWTBaFX/XLEIco2ux47m8yJz7xl+vTsiB2LGk7h7QAAAJifNGKYnzRi
        mAAAAAtzc2gtZWQyNTUxOQAAACDhvqWTBaFX/XLEIco2ux47m8yJz7xl+vTsiB2LGk7h7Q
        AAAEBvBnhoTQhoz/liGXDGeodsQFCPZfx7B/f10DxJy+VHP+G+pZMFoVf9csQhyja7Hjub
        zInPvGX69OyIHYsaTuHtAAAAEW1jbC1tYW5pZmVzdC10ZXN0AQIDBA==
        -----END OPENSSH PRIVATE KEY-----
      '';
      manifestPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOG+pZMFoVf9csQhyja7HjubzInPvGX69OyIHYsaTuHt mcl-manifest-test";
      targetName = "production-cutover-canary";
      atticCacheName = "mcl-production-cutover-cache";
      fixture = pkgs.writeText "production-cutover-fixture" ''
        production cutover fixture
      '';
      successGeneration = "/nix/store/55555555555555555555555555555555-nixos-system-cutover-success-generation";
      failedGeneration = "/nix/store/66666666666666666666666666666666-nixos-system-cutover-failed-generation";
      initialGeneration = "/nix/store/00000000000000000000000000000000-nixos-system-cutover-initial";
      generationScript = pkgs.writeShellScript "mcl-cutover-test-generation" ''
        set -euo pipefail
        if [ -f /var/lib/mcl-test/current-generation ]; then
          cat /var/lib/mcl-test/current-generation
        else
          printf '%s\n' ${lib.escapeShellArg initialGeneration}
        fi
      '';
      switchScript = pkgs.writeShellScript "mcl-cutover-test-switch" ''
        set -euo pipefail
        mkdir -p /var/lib/mcl-test
        mode=success
        if [ -f /var/lib/mcl-test/next-generation ]; then
          mode="$(cat /var/lib/mcl-test/next-generation)"
        fi
        case "$mode" in
          success)
            generation=${lib.escapeShellArg successGeneration}
            label=cutover-success
            ;;
          failed-health)
            generation=${lib.escapeShellArg failedGeneration}
            label=cutover-failed-health
            ;;
          *)
            echo "unknown cutover test generation mode: $mode" >&2
            exit 64
            ;;
        esac
        printf '%s\n' "$generation" > /var/lib/mcl-test/current-generation
        printf '%s\n' "$label" >> /var/lib/mcl-test/switch-runs
      '';
      rollbackScript = pkgs.writeShellScript "mcl-cutover-test-rollback" ''
        set -euo pipefail
        mkdir -p /var/lib/mcl-test
        printf '%s\n' ${lib.escapeShellArg successGeneration} > /var/lib/mcl-test/current-generation
        printf 'rollback-to-last-good\n' >> /var/lib/mcl-test/rollback-runs
      '';
      successHealthScript = pkgs.writeShellScript "mcl-cutover-test-health" ''
        set -euo pipefail
        test "$(cat /var/lib/mcl-test/current-generation)" = ${lib.escapeShellArg successGeneration}
      '';
      successHealthCommand = "generation|5|${successHealthScript}";
      rollbackHealthCommand = "health-fails|5|false";
      fakeClosureEnv = "MCL_DEPLOY_FAKE_CLOSURE_COUNT=1 MCL_DEPLOY_FAKE_CLOSURE_TOTAL_BYTES=4096";
      atticEnvironmentFile = pkgs.runCommand "deployment-production-cutover-atticd-env" { } ''
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
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        deployment-production-cutover-simulation-vm = pkgs.testers.nixosTest {
          name = "deployment-production-cutover-simulation-vm";

          nodes = {
            attic = atticServerNode;

            controller = {
              nix.settings.experimental-features = [
                "nix-command"
                "flakes"
              ];
              environment.etc."production-cutover-fixture".source = fixture;
              environment.systemPackages = [
                self'.packages.mcl-devops
                pkgs.attic-client
                pkgs.jq
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
                  pkgs.jq
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
                  targetName = targetName;
                  manifestPrincipal = "mcl-deployment";
                  manifestPublicKeys = [ manifestPublicKey ];
                  authorizedKeys = [ deployPublicKey ];
                  switchCommand = "${switchScript}";
                  rollbackCommand = "${rollbackScript}";
                  generationCommand = "${generationScript}";
                };
              };
          };

          testScript = ''
            import shlex

            start_all()
            target.wait_for_unit("sshd.service")

            with subtest("cutover gate blocks production target selection without M7 evidence"):
                controller.succeed(
                    "jq -e '"
                    ".m7FullTopology.requiredBeforeFirstProductionTarget == true and "
                    ".firstTargetSelection.selectedProductionTarget == null and "
                    ".firstTargetSelection.simulationTarget.production == false and "
                    ".liveCanaryCycles.requiredBeforeCachixDeployRemoval == 2 and "
                    ".cachixRetirement.deployBackendRemovedFromCI == true and "
                    ".cachixRetirement.cacheBackendRemovedFromCI == true and "
                    "(.cachixRetirement.removalGateSatisfied == false or .liveCanaryCycles.recorded >= 2)"
                    "' ${docs}/production-cutover-gates.json"
                )
            with subtest("create public Attic cache"):
                attic.wait_for_unit("atticd.service")
                attic.wait_for_open_port(8080)

                token = attic.succeed(
                    "atticd-atticadm make-token "
                    "--sub deployment-production-cutover-test "
                    "--validity 1y "
                    "--create-cache '*' "
                    "--pull '*' "
                    "--push '*' "
                    "--delete '*' "
                    "--configure-cache '*' "
                    "--configure-cache-retention '*'"
                ).strip()
                controller.succeed(f"attic login --set-default local http://attic:8080 {token}")
                controller.succeed("attic cache create --public ${atticCacheName}")
                cache_info = controller.succeed("attic cache info ${atticCacheName} 2>&1")
                public_key = ""
                for line in cache_info.splitlines():
                    marker = "Public Key:"
                    if marker in line:
                        public_key = line.split(marker, 1)[1].strip()
                        break
                assert public_key, "Attic cache info did not expose a public key"

            with subtest("build local fixture closure and prefill Attic"):
                controller.succeed("install -m 0600 ${deployPrivateKey} /tmp/deploy-key")
                controller.succeed("install -m 0600 ${manifestPrivateKey} /tmp/manifest-key")
                closure = "${fixture}"
                controller.succeed(f"nix path-info {shlex.quote(closure)}")
                substituter = "http://attic:8080/${atticCacheName}"
                controller.succeed(
                    "mcl-devops cache push-closure "
                    "--backend attic "
                    "--cache ${atticCacheName} "
                    "--target ${targetName} "
                    "--system x86_64-linux "
                    "--kind server "
                    "--transport shadow-direct-ssh "
                    f"--substituter {shlex.quote(substituter)} "
                    f"--trusted-public-key {shlex.quote(public_key)} "
                    "--require-substitute "
                    "--event-log /tmp/shadow-events.jsonl "
                    f"{shlex.quote(closure)}"
                )
                target.fail(f"nix path-info {shlex.quote(closure)}")

            with subtest("create signed production-cutover manifest"):
                restored_health = f"restored|5|test -e {closure}"
                controller.succeed(
                    "${fakeClosureEnv} GITHUB_RUN_ID=9001 GITHUB_SHA=9999999999999999999999999999999999999999 "
                    "mcl-devops deploy-plan "
                    "--target ${targetName} "
                    f"--desired-system-path {shlex.quote(closure)} "
                    "--git-revision 9999999999999999999999999999999999999999 "
                    "--sequence 9001 "
                    f"--health-command {shlex.quote(restored_health)} "
                    "--health-command ${lib.escapeShellArg successHealthCommand} "
                    f"--substituter {shlex.quote(substituter)} "
                    f"--trusted-public-key {shlex.quote(public_key)} "
                    "--availability-mode closure-substitutable "
                    "--require-availability "
                    "--signing-key /tmp/manifest-key "
                    "--signing-key-id mcl-deployment "
                    "--output /tmp/cutover-manifest.json "
                    "--state-dir /tmp/cutover-state"
                )

            with subtest("shadow deploy is dry-run only and does not switch target"):
                controller.succeed(
                    "mcl-devops deploy-ssh ${targetName} "
                    "--manifest /tmp/cutover-manifest.json "
                    "--state-dir /tmp/shadow-state "
                    "--ssh-host target "
                    "--ssh-user deploy "
                    "--identity-file /tmp/deploy-key "
                    "--ssh-option StrictHostKeyChecking=no "
                    "--ssh-option UserKnownHostsFile=/dev/null "
                    "--event-log /tmp/shadow-events.jsonl "
                    "--dry-run"
                )
                target.fail("test -e /var/lib/mcl-test/switch-runs")
                controller.succeed(
                    "jq -s -e 'any(.[]; .phase == \"cache-push\" and .backend.controller == \"attic\" and .command.status == \"succeeded\")' /tmp/shadow-events.jsonl"
                )
                controller.succeed(
                    "jq -s -e '[.[] | select(.phase == \"activate-requested\" and .command.name == \"mcl-devops deploy-reconcile --dry-run\" and .command.status == \"pending\")] | length == 1' /tmp/shadow-events.jsonl"
                )
                controller.succeed(
                    "jq -s -e 'all(.[]; ((.command.argv | join(\" \") | ascii_downcase) | contains(\"cachix deploy activate\") | not))' /tmp/shadow-events.jsonl"
                )

            with subtest("supervised local cutover simulation converges"):
                target.succeed("install -d -m 0755 /var/lib/mcl-test")
                target.succeed("printf 'success\\n' > /var/lib/mcl-test/next-generation")
                controller.succeed(
                    "mcl-devops deploy-ssh ${targetName} "
                    "--manifest /tmp/cutover-manifest.json "
                    "--state-dir /tmp/cutover-state "
                    "--ssh-host target "
                    "--ssh-user deploy "
                    "--identity-file /tmp/deploy-key "
                    "--ssh-option StrictHostKeyChecking=no "
                    "--ssh-option UserKnownHostsFile=/dev/null "
                    "--event-log /tmp/cutover-controller-events.jsonl"
                )
                target.succeed(f"nix path-info {shlex.quote(closure)}")
                target.succeed(f"test -e {shlex.quote(closure)}")
                target.succeed("grep -qx cutover-success /var/lib/mcl-test/switch-runs")
                target.succeed("test \"$(cat /var/lib/mcl-test/current-generation)\" = '${successGeneration}'")

            with subtest("monitoring and event artifacts show healthy final generation"):
                target.succeed(
                    "mcl-devops deploy-status summarize /var/log/mcl/deployments/${targetName}.jsonl "
                    "--output /tmp/cutover-summary.md "
                    "--json-output /tmp/cutover-summary.json"
                )
                target.succeed(
                    "jq -e '.finalState == \"succeeded\" and .targetCount == 1 and .failureCount == 0' /tmp/cutover-summary.json"
                )
                target.succeed(
                    "jq -s -e '"
                    "any(.[]; .phase == \"agent-restore\" and .command.status == \"succeeded\") and "
                    "any(.[]; .phase == \"switch\" and .command.status == \"succeeded\") and "
                    "any(.[]; .phase == \"healthcheck\" and .command.status == \"succeeded\") and "
                    "any(.[]; .phase == \"complete\" and .command.status == \"succeeded\") and "
                    "([.[] | select(.phase == \"complete\")][-1].metadata.newGeneration == \"${successGeneration}\")"
                    "' /var/log/mcl/deployments/${targetName}.jsonl"
                )
                target.succeed(
                    "jq -s -e '"
                    "([.[] | select(.phase == \"agent-restore\")][0].command.argv[0:4] == [\"nix\", \"copy\", \"--from\", \"http://attic:8080/${atticCacheName}\"]) and "
                    "([.[] | select(.phase == \"agent-restore\")][0].backend.substituters == [\"http://attic:8080/${atticCacheName}\"])"
                    "' /var/log/mcl/deployments/${targetName}.jsonl"
                )
                target.succeed(
                    "jq -s '{target: \"${targetName}\", finalGeneration: ([.[] | select(.phase == \"complete\")][-1].metadata.newGeneration), eventCount: length, summaryFinalState: \"succeeded\"}' "
                    "/var/log/mcl/deployments/${targetName}.jsonl > /tmp/cutover-monitoring-artifact.json"
                )
                target.succeed(
                    "jq -e '.target == \"${targetName}\" and .finalGeneration == \"${successGeneration}\" and .summaryFinalState == \"succeeded\" and .eventCount > 0' /tmp/cutover-monitoring-artifact.json"
                )

            with subtest("rollback drill preserves the last good generation"):
                target.succeed("printf 'failed-health\\n' > /var/lib/mcl-test/next-generation")
                controller.succeed(
                    "${fakeClosureEnv} GITHUB_RUN_ID=9002 GITHUB_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "
                    "mcl-devops deploy-plan "
                    "--target ${targetName} "
                    f"--desired-system-path {shlex.quote(closure)} "
                    "--git-revision aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "
                    "--sequence 9002 "
                    "--health-command ${lib.escapeShellArg rollbackHealthCommand} "
                    f"--substituter {shlex.quote(substituter)} "
                    f"--trusted-public-key {shlex.quote(public_key)} "
                    "--availability-mode closure-substitutable "
                    "--require-availability "
                    "--rollback-mode automatic "
                    "--rollback-max-attempts 1 "
                    "--on-health-check-failure rollback "
                    "--signing-key /tmp/manifest-key "
                    "--signing-key-id mcl-deployment "
                    "--output /tmp/rollback-manifest.json "
                    "--state-dir /tmp/cutover-state"
                )
                controller.fail(
                    "mcl-devops deploy-ssh ${targetName} "
                    "--manifest /tmp/rollback-manifest.json "
                    "--state-dir /tmp/cutover-state "
                    "--ssh-host target "
                    "--ssh-user deploy "
                    "--identity-file /tmp/deploy-key "
                    "--ssh-option StrictHostKeyChecking=no "
                    "--ssh-option UserKnownHostsFile=/dev/null "
                    "--event-log /tmp/cutover-controller-events.jsonl"
                )
                target.succeed("grep -qx rollback-to-last-good /var/lib/mcl-test/rollback-runs")
                target.succeed("test \"$(cat /var/lib/mcl-test/current-generation)\" = '${successGeneration}'")
                target.succeed(
                    "jq -s -e '"
                    "([.[] | select(.phase == \"rollback\")][-1].command.status == \"succeeded\") and "
                    "([.[] | select(.phase == \"rollback\")][-1].metadata.previousGeneration == \"${successGeneration}\") and "
                    "([.[] | select(.phase == \"rollback\")][-1].metadata.failedGeneration == \"${failedGeneration}\") and "
                    "(.[-1].phase == \"complete\") and "
                    "(.[-1].command.status == \"failed\") and "
                    "all(.[]; ((.command.argv | join(\" \") | ascii_downcase) | contains(\"cachix deploy activate\") | not))"
                    "' /var/log/mcl/deployments/${targetName}.jsonl"
                )
          '';
        };

        deployment-cachix-fallback-simulation =
          pkgs.runCommand "deployment-cachix-fallback-simulation"
            {
              nativeBuildInputs = [
                pkgs.coreutils
                pkgs.jq
                pkgs.python3
              ];
            }
            ''
              tmp="$(mktemp -d)"
              fake_bin="$tmp/bin"
              mkdir -p "$fake_bin" "$NIX_BUILD_TOP/.result"
              cat > "$fake_bin/cachix" <<'SH'
              #!${pkgs.bash}/bin/bash
              set -euo pipefail
              printf '%s\n' "$*" >> "$FAKE_CACHIX_LOG"
              test "''${1:-}" = deploy
              test "''${2:-}" = activate
              test "''${3:-}" = .result/cachix-deploy-spec.json
              test "''${4:-}" = --async
              SH
              chmod +x "$fake_bin/cachix"

              spec="$NIX_BUILD_TOP/.result/cachix-deploy-spec.json"
              events="$tmp/fallback-events.jsonl"
              cat > "$spec" <<JSON
              {
                "agents": {
                  "fallback-canary": "${pkgs.hello}"
                }
              }
              JSON

              export FAKE_CACHIX_LOG="$tmp/fake-cachix.log"
              cd "$NIX_BUILD_TOP"
              PATH="$fake_bin:$PATH" cachix deploy activate .result/cachix-deploy-spec.json --async

              cat > "$events" <<JSON
              {"schemaVersion":1,"deploymentId":"fallback-simulation","correlationId":"fallback-simulation","phase":"activate-requested","target":{"name":"fallback-canary","system":"x86_64-linux","kind":"server","transport":"cachix-agent"},"backend":{"cache":"fallback-cache","substituters":["https://fallback-cache.cachix.org"],"controller":"cachix-deploy"},"storePaths":{"system":"${pkgs.hello}"},"timestamps":{"startedAt":"2026-06-03T00:00:00Z","finishedAt":"2026-06-03T00:00:00Z"},"command":{"name":"cachix deploy activate","argv":["cachix","deploy","activate",".result/cachix-deploy-spec.json","--async"],"status":"succeeded","exitCode":0},"metadata":{"fallback":true,"explicitOnly":true}}
              JSON

              grep -qx 'deploy activate .result/cachix-deploy-spec.json --async' "$FAKE_CACHIX_LOG"
              export FALLBACK_EVENTS="$events"
              python3 - <<'PY'
              import json
              import os
              from pathlib import Path

              events = [
                  json.loads(line)
                  for line in Path(os.environ["FALLBACK_EVENTS"]).read_text().splitlines()
                  if line.strip()
              ]
              activate = [event for event in events if event["phase"] == "activate-requested"]
              assert len(activate) == 1, events
              event = activate[0]
              assert event["target"]["name"] == "fallback-canary", event
              assert event["backend"]["controller"] == "cachix-deploy", event
              assert event["command"]["name"] == "cachix deploy activate", event
              assert event["command"]["status"] == "succeeded", event
              assert event["metadata"]["fallback"] is True, event
              assert event["metadata"]["explicitOnly"] is True, event
              assert event["command"]["argv"] == [
                  "cachix",
                  "deploy",
                  "activate",
                  ".result/cachix-deploy-spec.json",
                  "--async",
              ], event
              PY

              touch "$out"
            '';

        deployment-no-default-cachix-deploy-call =
          pkgs.runCommand "deployment-no-default-cachix-deploy-call"
            {
              nativeBuildInputs = [ pkgs.python3 ];
            }
            ''
              python3 - <<'PY'
              import json
              import re
              from pathlib import Path

              gate = json.loads(Path("${docs}/production-cutover-gates.json").read_text())
              repo_workflow = Path("${repoWorkflow}").read_text()
              workflow = Path("${workflow}").read_text()
              setup_nix = Path("${setupNix}").read_text()
              cutover_doc = Path("${docs}/production-cutover.md").read_text()
              deploy_spec = Path("${repoRoot}/packages/mcl-devops/src/mcl/commands/deploy_spec.d").read_text()

              assert gate["defaultCutoverPath"]["usesCachixDeploy"] is False, gate
              assert gate["defaultCutoverPath"]["cacheBackend"] == "attic", gate
              assert gate["defaultCutoverPath"]["activation"] == "mcl-devops deploy-ssh or mcl-devops deploy-reconcile", gate
              assert gate["firstTargetSelection"]["selectedProductionTarget"] is None, gate
              assert gate["firstTargetSelection"]["simulationTarget"]["production"] is False, gate
              assert gate["m7FullTopology"]["requiredBeforeFirstProductionTarget"] is True, gate
              retire = gate["cachixRetirement"]
              assert retire["deployBackendRemovedFromCI"] is True, gate
              assert retire["cacheBackendRemovedFromCI"] is True, gate
              canary = gate["liveCanaryCycles"]
              assert canary["requiredBeforeCachixDeployRemoval"] == 2, gate
              assert isinstance(canary["recorded"], int) and canary["recorded"] >= 0, gate
              if retire["removalGateSatisfied"]:
                  assert canary["recorded"] >= canary["requiredBeforeCachixDeployRemoval"], "removal gate cannot be satisfied without the required live canary cycles"
                  assert gate["m7FullTopology"]["evidenceRecorded"] is True, gate
                  assert retire["manualFallbackRetired"] is True, gate
              else:
                  assert retire["manualFallbackRetired"] is False, gate
              if retire["manualFallbackRetired"]:
                  assert "cachix deploy activate" not in deploy_spec, "manual Cachix fallback must be removed once retired"
              else:
                  assert "cachix deploy activate" in deploy_spec, "manual Cachix fallback must remain available until the removal gate is satisfied"

              assert re.search(
                  r"non-nix-runner:\s*\n"
                  r"\s+description:.*\n"
                  r"\s+default:\s*'\[\"self-hosted\",\s*\"linux\",\s*\"x64\"\]'\s*\n"
                  r"\s+required:\s*false\s*\n"
                  r"\s+type:\s*string",
                  workflow,
              ), "workflow must default non-nix-runner to the RC1 Linux x64 capability label set"
              assert re.search(
                  r"results-runner:\s*\n"
                  r"\s+description:.*\n"
                  r"\s+default:\s*'\[\"self-hosted\",\s*\"linux\",\s*\"x64\"\]'\s*\n"
                  r"\s+required:\s*false\s*\n"
                  r"\s+type:\s*string",
                  workflow,
              ), "workflow must default results-runner to the RC1 Linux x64 capability label set"
              assert "runs-on: ''${{ fromJSON(inputs.non-nix-runner) }}" in workflow, "non-nix helper jobs must use JSON runner labels"
              assert "foundry-darwin-bootstrap-runner: '[\"aarch64-darwin\"]'" in repo_workflow, "only the long Foundry Darwin bootstrap build must use the persistent runner class"
              assert "matrix.name == 'foundry'" in workflow, "Foundry bootstrap runner selection must stay package-scoped"
              assert "matrix.system == 'aarch64-darwin'" in workflow, "Foundry bootstrap runner selection must stay Darwin-scoped"
              assert "inputs.foundry-darwin-bootstrap-runner" in workflow, "Foundry bootstrap runner override must remain opt-in for reusable-workflow callers"
              results_job_match = re.search(
                  r"(?ms)^  results:\n(?P<body>.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)",
                  workflow,
              )
              assert results_job_match is not None, "workflow results job disappeared"
              results_job = results_job_match.group("body")
              assert "runs-on: ''${{ fromJSON(inputs.results-runner) }}" in results_job, "Final Results must run on the results-runner input"
              assert "runs-on: ''${{ fromJSON(inputs.runners).x86_64-linux }}" not in results_job, "Final Results must not run on the x86_64-linux fleet runner map"
              assert "run-cachix-deploy" not in repo_workflow, "repo CI must not reference the removed Cachix Deploy gate"
              assert "run-cachix-deploy" not in workflow, "reusable workflow must not reference the removed Cachix Deploy gate"
              assert "deploy-spec" not in workflow, "legacy deploy-spec invocation must be absent from CI"
              assert "cachix" not in workflow.lower(), "reusable workflow must be free of Cachix references"
              assert "cachix" not in setup_nix.lower(), "setup-nix must be free of Cachix references"
              assert "DeterminateSystems/nix-installer-action" in setup_nix, "setup-nix must use the Determinate installer that replaced cachix/install-nix-action"
              assert "push-deployment-caches:" in workflow
              assert re.search(r"push-deployment-caches:.*?default:\s*false", workflow, re.S)
              assert "if: ''${{ inputs.push-deployment-caches && !matrix.noop && matrix.deploymentTarget }}" in workflow
              assert "if: ''${{ always() && inputs.push-deployment-caches && !matrix.noop && matrix.deploymentTarget }}" in workflow
              assert re.search(r"deployment-cache-push-backends:.*?default:\s*'attic'", workflow, re.S)
              assert re.search(r"deployment-cache-required-backends:.*?default:\s*'attic'", workflow, re.S)
              assert "--transport attic-ci" in workflow, "deployment cache push must use the Attic CI transport"

              required_doc_terms = [
                  "Attic is the sole deployment cache and activation backend",
                  "Cachix Deploy is removed from CI",
                  "two successful live canary cycles",
                  "M7 full-topology runtime evidence",
                  "local-production-cutover-canary",
                  "must not switch a real host",
              ]
              for term in required_doc_terms:
                  assert term in cutover_doc, f"production cutover docs missing {term!r}"

              lowered_doc = cutover_doc.lower()
              assert "defaultcutoverpath cachix" not in lowered_doc, "cutover doc implies default Cachix use"
              assert "usescachixdeploy true" not in lowered_doc, "cutover doc implies default Cachix use"
              PY

              touch "$out"
            '';
      };
    };
}
