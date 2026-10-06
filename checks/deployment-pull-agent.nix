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
      oldSystemPath = "/nix/store/11111111111111111111111111111111-nixos-system-target-old";
      newSystemPath = "/nix/store/22222222222222222222222222222222-nixos-system-target-new";
      wrongTargetSystemPath = "/nix/store/33333333333333333333333333333333-nixos-system-other-target";
      tamperedSystemPath = "/nix/store/44444444444444444444444444444444-nixos-system-target-tampered";
      initialGeneration = "/nix/store/00000000000000000000000000000000-nixos-system-target-initial";
      successGeneration = "/nix/store/55555555555555555555555555555555-nixos-system-target-success-generation";
      restoreScript = pkgs.writeShellScript "mcl-test-pull-restore" ''
        set -euo pipefail
        mkdir -p /var/lib/mcl-test
        printf 'restore\n' >> /var/lib/mcl-test/restore-runs
      '';
      generationScript = pkgs.writeShellScript "mcl-test-pull-generation" ''
        set -euo pipefail
        if [ -f /var/lib/mcl-test/current-generation ]; then
          cat /var/lib/mcl-test/current-generation
        else
          printf '%s\n' ${lib.escapeShellArg initialGeneration}
        fi
      '';
      switchScript = pkgs.writeShellScript "mcl-test-pull-switch" ''
        set -euo pipefail
        mkdir -p /var/lib/mcl-test
        install -d -m 0700 /root/mcl-test-pull-agent
        install -d -m 0755 /home/mcl-test-pull-agent
        printf '%s\n' ${lib.escapeShellArg successGeneration} > /var/lib/mcl-test/current-generation
        printf 'root-writable\n' > /root/mcl-test-pull-agent/switch-ran
        printf 'home-writable\n' > /home/mcl-test-pull-agent/switch-ran
        printf 'success\n' >> /var/lib/mcl-test/switch-runs
      '';
      healthScript = pkgs.writeShellScript "mcl-test-pull-health" ''
        set -euo pipefail
        test "$(cat /var/lib/mcl-test/current-generation)" = ${lib.escapeShellArg successGeneration}
      '';
      # Faithful reproduction of the production deploy wedge (FU1). On any deploy
      # that changes mcl-deploy-agent.service's definition, switch-to-configuration
      # (re)starts this very unit. When the switch runs inside the agent's own
      # cgroup, `systemctl restart mcl-deploy-agent.service` makes systemd SIGTERM
      # the running invocation to service the restart job -- which kills the switch
      # process itself mid-activation, so the switch never finishes and its own
      # restart job cannot complete: the deploy wedges. The FU1 fix runs the switch
      # in a detached systemd-run transient unit (its own cgroup), so systemd can
      # restart the agent unit without tearing the switch down; the switch runs to
      # completion.
      #
      # This script mimics that: it writes the new generation, then issues a
      # blocking `systemctl restart mcl-deploy-agent.service` (as the real switch
      # does), then -- only if it SURVIVES that restart -- writes a completion
      # marker. Under the unfixed in-cgroup path the process is SIGTERM'd at the
      # restart and 'switch-survived-restart' is never written; under the fix the
      # detached switch survives and writes it. A `timeout` guards against a hang
      # variant of the wedge.
      selfhealSwitchScript = pkgs.writeShellScript "mcl-test-pull-selfheal-switch" ''
        set -uo pipefail
        mkdir -p /var/lib/mcl-test
        printf 'switch-entered:%s\n' "$$" >> /var/lib/mcl-test/selfheal-switch-runs
        printf '%s\n' ${lib.escapeShellArg successGeneration} > /var/lib/mcl-test/current-generation
        # Mimic switch-to-configuration restarting this very unit -- but only ONCE.
        # The real switch restarts the agent once per changed deploy and is
        # idempotent thereafter; a marker gates the restart so the fresh invocation
        # it spawns (which re-runs this very switch) does not recurse forever.
        #
        # Non-vacuousness hinges on identity: the survival marker is tagged with the
        # PID of the process that ISSUED the restart, and only that process may write
        # it. In-cgroup, that process is SIGTERM'd at the restart line, so no
        # 'survived:<issuer-pid>' is ever written and the spawned invocation (which
        # sees the gate set) issues no restart and writes no survival marker at all.
        # Detached, the issuing process survives the restart and writes
        # 'survived:<its-own-pid>'.
        if [ ! -e /var/lib/mcl-test/selfheal-restart-done ]; then
          touch /var/lib/mcl-test/selfheal-restart-done
          printf 'restart-issuer:%s\n' "$$" >> /var/lib/mcl-test/selfheal-switch-runs
          timeout 60 systemctl restart mcl-deploy-agent.service || true
          # Only reached if this exact process survived the restart it issued.
          printf 'survived:%s\n' "$$" >> /var/lib/mcl-test/selfheal-switch-runs
          printf 'success\n' >> /var/lib/mcl-test/switch-runs
        fi
      '';
      fakeClosureEnv = "MCL_DEPLOY_FAKE_CLOSURE_COUNT=1 MCL_DEPLOY_FAKE_CLOSURE_TOTAL_BYTES=4096";
      healthCommand = "generation|5|${healthScript}";
      commonTargetModule =
        { ... }:
        {
          imports = [ flake.modules.nixos.deployment-pull-agent ];
          networking.hostName = "target";
          environment.systemPackages = [
            self'.packages.mcl-devops
            pkgs.python3
          ];
          services.mcl-deploy-agent = {
            enable = true;
            package = self'.packages.mcl-devops;
            targetName = "target";
            manifestPublicKeys = [ manifestPublicKey ];
            manifestDirectories = [ "/var/lib/mcl/deployments/inbox" ];
            eventLog = "/var/log/mcl/deployments/target.jsonl";
            interval = "1min";
            jitter = "0";
            lockFile = "/run/lock/mcl-test-pull-agent.lock";
            restoreCommand = "${restoreScript}";
            switchCommand = "${switchScript}";
            generationCommand = "${generationScript}";
          };
        };
      slowMcl = pkgs.writeShellApplication {
        name = "mcl-devops";
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          set -euo pipefail
          if [ "''${1:-}" != deploy-agent ]; then
            echo "fake mcl-devops only supports deploy-agent" >&2
            exit 64
          fi

          mkdir -p /var/lib/mcl-test
          printf 'start:%s\n' "$$" >> /var/lib/mcl-test/agent-runs
          touch /var/lib/mcl-test/agent-started
          sleep 12
          printf 'end:%s\n' "$$" >> /var/lib/mcl-test/agent-runs
        '';
      };
      preflightProbeMcl = pkgs.writeShellScriptBin "mcl-devops" ''
        set -euo pipefail
        test "$(${pkgs.coreutils}/bin/stat -c '%u:%g:%a' /var/lib/mcl/preflight-state/locks)" = 0:0:700
        ${pkgs.coreutils}/bin/mkdir -p /var/lib/mcl-test
        printf 'invoked-after-0700\n' >> /var/lib/mcl-test/preflight-mcl-runs
        exec ${lib.getExe self'.packages.mcl-devops} "$@"
      '';
      preflightTargetModule =
        { ... }:
        {
          imports = [ flake.modules.nixos.deployment-pull-agent ];
          networking.hostName = "target";
          environment.systemPackages = [
            self'.packages.mcl-devops
            pkgs.python3
          ];
          services.mcl-deploy-agent = {
            enable = true;
            package = preflightProbeMcl;
            targetName = "target";
            stateDir = "/var/lib/mcl/preflight-state";
            manifestPublicKeys = [ manifestPublicKey ];
            manifestDirectories = [ "/var/lib/mcl-preflight-inbox" ];
            eventLog = "/var/log/mcl/deployments/preflight-target.jsonl";
            interval = "1h";
            jitter = "0";
            lockFile = "/run/lock/mcl-test-preflight-agent.lock";
            restoreCommand = "${restoreScript}";
            switchCommand = "${switchScript}";
            generationCommand = "${generationScript}";
          };
        };
      staticSystem = lib.nixosSystem {
        system = pkgs.stdenv.hostPlatform.system;
        modules = [
          flake.modules.nixos.deployment-pull-agent
          {
            networking.hostName = "target-a";
            services.mcl-deploy-agent = {
              enable = true;
              package = self'.packages.mcl-devops;
              targetName = "target-a";
              manifestPublicKeys = [ manifestPublicKey ];
              manifestSources = [ "/var/lib/mcl/deployments/target-a/latest.json" ];
              manifestDirectories = [ "/var/lib/mcl/deployments/inbox" ];
              stateDir = "/var/lib/mcl/test-deployments";
              eventLog = "/var/log/mcl/deployments/test-agent.jsonl";
              interval = "7min";
              jitter = "73s";
              lockFile = "/run/lock/mcl-test-pull-agent.lock";
              maxAttempts = 5;
              fetchTimeoutSeconds = 11;
              dryRun = true;
            };
          }
        ];
      };
      staticService = staticSystem.config.systemd.services.mcl-deploy-agent;
      staticTimer = staticSystem.config.systemd.timers.mcl-deploy-agent;
      staticExecStart = staticService.serviceConfig.ExecStart;
      staticExecStartPre = staticService.serviceConfig.ExecStartPre or [ ];
      staticEnvironment = staticService.serviceConfig.Environment or [ ];
      staticFailures = lib.flatten [
        (lib.optional (
          builtins.length staticExecStartPre != 1
        ) "pull-agent service must have exactly one lock migration ExecStartPre")
        (lib.optional (
          builtins.length staticExecStartPre == 1
          && !lib.hasInfix "mcl-deploy-agent-prepare-locks" (builtins.head staticExecStartPre)
        ) "pull-agent ExecStartPre does not use the descriptor-safe lock migration helper")
        (lib.optional (
          builtins.length staticExecStartPre == 1
          && !lib.hasSuffix " /var/lib/mcl/test-deployments" (builtins.head staticExecStartPre)
        ) "pull-agent ExecStartPre does not receive the configured state directory")
        (lib.optional (
          !lib.hasInfix "flock -n /run/lock/mcl-test-pull-agent.lock" staticExecStart
        ) "pull-agent service does not use configured flock lock")
        (lib.optional (
          !lib.hasInfix "deploy-agent" staticExecStart
        ) "pull-agent service does not call mcl-devops deploy-agent")
        (lib.optional (
          !lib.hasInfix "--target target-a" staticExecStart
        ) "pull-agent service does not pass target")
        (lib.optional (
          !lib.hasInfix "--manifest /var/lib/mcl/deployments/target-a/latest.json" staticExecStart
        ) "pull-agent service does not pass exact manifest source")
        (lib.optional (
          !lib.hasInfix "--manifest-dir /var/lib/mcl/deployments/inbox" staticExecStart
        ) "pull-agent service does not pass manifest directory")
        (lib.optional (
          !lib.hasInfix "--state-dir /var/lib/mcl/test-deployments" staticExecStart
        ) "pull-agent service does not pass state dir")
        (lib.optional (
          !lib.hasInfix "--event-log /var/log/mcl/deployments/test-agent.jsonl" staticExecStart
        ) "pull-agent service does not pass event log")
        (lib.optional (
          !lib.hasInfix "--max-attempts 5" staticExecStart
        ) "pull-agent service does not pass max attempts")
        (lib.optional (
          !lib.hasInfix "--fetch-timeout-seconds 11" staticExecStart
        ) "pull-agent service does not pass fetch timeout")
        (lib.optional (
          !lib.hasInfix "--dry-run" staticExecStart
        ) "pull-agent service does not pass dry-run")
        (lib.optional (
          staticService.serviceConfig.CacheDirectory != "mcl-deploy-agent"
        ) "pull-agent service does not provision a writable cache directory")
        (lib.optional (
          !(builtins.elem "HOME=/var/cache/mcl-deploy-agent" staticEnvironment)
        ) "pull-agent service does not set HOME to its writable cache directory")
        (lib.optional (
          !(builtins.elem "XDG_CACHE_HOME=/var/cache/mcl-deploy-agent" staticEnvironment)
        ) "pull-agent service does not set XDG_CACHE_HOME to its writable cache directory")
        (lib.optional (
          staticService.serviceConfig.ProtectHome != false
        ) "pull-agent service must leave /root, /home, and /run/user available for switch-to-configuration")
        (lib.optional (
          staticTimer.timerConfig.OnActiveSec != "7min"
        ) "timer initial activation interval drifted")
        (lib.optional (staticTimer.timerConfig.OnUnitActiveSec != "7min") "timer interval drifted")
        (lib.optional (
          (staticTimer.timerConfig.OnBootSec or null) != null
        ) "timer must not poll immediately on live activation")
        (lib.optional (staticTimer.timerConfig.RandomizedDelaySec != "73s") "timer jitter drifted")
        (lib.optional (staticTimer.timerConfig.Persistent != true) "timer is not persistent")
      ];
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        deployment-pull-agent-latest-vm = pkgs.testers.nixosTest {
          name = "deployment-pull-agent-latest-vm";

          nodes.target = commonTargetModule;

          testScript = ''
            start_all()
            target.wait_for_unit("multi-user.target")

            with subtest("publish two signed desired states for the target"):
                target.succeed("install -d -m 0750 /var/lib/mcl/deployments/inbox")
                target.succeed("install -m 0600 ${manifestPrivateKey} /tmp/manifest-key")
                target.succeed(
                    "${fakeClosureEnv} mcl-devops deploy-plan "
                    "--target target "
                    "--desired-system-path ${oldSystemPath} "
                    "--git-revision 0123456789abcdef0123456789abcdef01234567 "
                    "--sequence 41 "
                    "--health-command ${lib.escapeShellArg healthCommand} "
                    "--signing-key /tmp/manifest-key "
                    "--signing-key-id mcl-deployment "
                    "--output /var/lib/mcl/deployments/inbox/old.json"
                )
                target.succeed(
                    "${fakeClosureEnv} mcl-devops deploy-plan "
                    "--target target "
                    "--desired-system-path ${newSystemPath} "
                    "--git-revision 0123456789abcdef0123456789abcdef01234568 "
                    "--sequence 42 "
                    "--health-command ${lib.escapeShellArg healthCommand} "
                    "--signing-key /tmp/manifest-key "
                    "--signing-key-id mcl-deployment "
                    "--output /var/lib/mcl/deployments/inbox/new.json"
                )

            with subtest("agent applies only the newest valid manifest"):
                target.succeed("systemctl start mcl-deploy-agent.service")
                target.succeed("test \"$(wc -l < /var/lib/mcl-test/restore-runs)\" = 1")
                target.succeed("test \"$(wc -l < /var/lib/mcl-test/switch-runs)\" = 1")
                target.succeed("grep -qx success /var/lib/mcl-test/switch-runs")
                target.succeed("test \"$(cat /var/lib/mcl-test/current-generation)\" = '${successGeneration}'")
                target.succeed("grep -qx root-writable /root/mcl-test-pull-agent/switch-ran")
                target.succeed("grep -qx home-writable /home/mcl-test-pull-agent/switch-ran")

            with subtest("status and events are target-local and pull-agent labelled"):
                target.succeed(
                    "python3 - <<'PY'\n"
                    "import json\n"
                    "events = [json.loads(line) for line in open('/var/log/mcl/deployments/target.jsonl') if line.strip()]\n"
                    "ids = {event['deploymentId'] for event in events}\n"
                    "assert ids == {'gh-local-unknown-target'}, ids\n"
                    "paths = {event['storePaths']['system'] for event in events}\n"
                    "assert paths == {'${newSystemPath}'}, paths\n"
                    "assert all(event['target']['name'] == 'target' for event in events), events\n"
                    "assert all(event['target']['transport'] == 'pull-agent' for event in events), events\n"
                    "assert all(event['backend']['controller'] == 'mcl-deploy-agent' for event in events), events\n"
                    "phases = [(event['phase'], event['command']['status']) for event in events]\n"
                    "assert ('agent-restore', 'succeeded') in phases, phases\n"
                    "assert ('switch', 'succeeded') in phases, phases\n"
                    "assert ('healthcheck', 'succeeded') in phases, phases\n"
                    "assert ('complete', 'succeeded') in phases, phases\n"
                    "status = json.load(open('/var/lib/mcl/deployments/agent-status/target.json'))\n"
                    "assert status['target'] == 'target', status\n"
                    "assert status['sequence'] == 42, status\n"
                    "assert status['currentState'] == 'succeeded', status\n"
                    "assert status['attempts'] == 1, status\n"
                    "PY"
                )
          '';
        };

        deployment-pull-agent-rejects-invalid-vm = pkgs.testers.nixosTest {
          name = "deployment-pull-agent-rejects-invalid-vm";

          nodes.target = commonTargetModule;

          testScript = ''
            start_all()
            target.wait_for_unit("multi-user.target")
            target.succeed("install -d -m 0750 /var/lib/mcl/deployments/inbox")
            target.succeed("install -m 0600 ${manifestPrivateKey} /tmp/manifest-key")

            with subtest("wrong target manifest is non-retryable and does not apply"):
                target.succeed(
                    "${fakeClosureEnv} mcl-devops deploy-plan "
                    "--target other-target "
                    "--desired-system-path ${wrongTargetSystemPath} "
                    "--git-revision 0123456789abcdef0123456789abcdef01234567 "
                    "--sequence 1 "
                    "--signing-key /tmp/manifest-key "
                    "--signing-key-id mcl-deployment "
                    "--output /var/lib/mcl/deployments/inbox/wrong-target.json"
                )
                target.fail("systemctl start mcl-deploy-agent.service")
                target.fail("test -e /var/lib/mcl-test/restore-runs")
                target.succeed(
                    "python3 - <<'PY'\n"
                    "import json\n"
                    "status = json.load(open('/var/lib/mcl/deployments/agent-status/target.json'))\n"
                    "assert status['target'] == 'target', status\n"
                    "assert status['currentState'] == 'non-retryable', status\n"
                    "assert status['errorCode'] == 'wrong_target', status\n"
                    "assert status['observedTarget'] == 'other-target', status\n"
                    "PY"
                )

            with subtest("tampered signature is non-retryable and does not apply"):
                target.succeed("rm -f /var/lib/mcl/deployments/inbox/*.json")
                target.succeed("systemctl reset-failed mcl-deploy-agent.service")
                target.succeed(
                    "${fakeClosureEnv} mcl-devops deploy-plan "
                    "--target target "
                    "--desired-system-path ${tamperedSystemPath} "
                    "--git-revision 0123456789abcdef0123456789abcdef01234567 "
                    "--sequence 2 "
                    "--signing-key /tmp/manifest-key "
                    "--signing-key-id mcl-deployment "
                    "--output /var/lib/mcl/deployments/inbox/tampered.json"
                )
                target.succeed(
                    "python3 - <<'PY'\n"
                    "import json\n"
                    "path = '/var/lib/mcl/deployments/inbox/tampered.json'\n"
                    "manifest = json.load(open(path))\n"
                    "manifest['desiredSystemPath'] = '/nix/store/66666666666666666666666666666666-nixos-system-target-tampered-after-sign'\n"
                    "json.dump(manifest, open(path, 'w'), separators=(',', ':'))\n"
                    "PY"
                )
                target.fail("systemctl start mcl-deploy-agent.service")
                target.fail("test -e /var/lib/mcl-test/restore-runs")
                target.succeed(
                    "python3 - <<'PY'\n"
                    "import json\n"
                    "status = json.load(open('/var/lib/mcl/deployments/agent-status/target.json'))\n"
                    "assert status['target'] == 'target', status\n"
                    "assert status['currentState'] == 'non-retryable', status\n"
                    "assert status['errorCode'] == 'invalid_signature', status\n"
                    "assert status['retryable'] is False, status\n"
                    "PY"
            )
          '';
        };

        deployment-pull-agent-locks-migration-vm = pkgs.testers.nixosTest {
          name = "deployment-pull-agent-locks-migration-vm";

          nodes.target = preflightTargetModule;

          testScript = ''
            start_all()
            target.wait_for_unit("multi-user.target")
            target.succeed("systemctl stop mcl-deploy-agent.timer")

            state_dir = "/var/lib/mcl/preflight-state"
            locks_path = state_dir + "/locks"
            marker = "/var/lib/mcl-test/preflight-mcl-runs"
            restore_marker = "/var/lib/mcl-test/restore-runs"
            switch_marker = "/var/lib/mcl-test/switch-runs"
            generation_marker = "/var/lib/mcl-test/current-generation"
            status_path = state_dir + "/agent-status/target.json"
            event_log = "/var/log/mcl/deployments/preflight-target.jsonl"
            deployment_state_paths = [
                state_dir + "/desired",
                state_dir + "/current",
                state_dir + "/failed",
                state_dir + "/superseded",
                state_dir + "/converged",
                state_dir + "/targets",
                state_dir + "/agent-status",
            ]

            def assert_no_agent_observables():
                for path in [
                    marker,
                    restore_marker,
                    switch_marker,
                    generation_marker,
                    event_log,
                ] + deployment_state_paths:
                    target.succeed("test ! -e " + path + " && test ! -L " + path)

            def reset_service():
                target.succeed(
                    "systemctl stop mcl-deploy-agent.service || true; "
                    "systemctl reset-failed mcl-deploy-agent.service || true; "
                    "install -d -m 0755 /var/lib/mcl-test; "
                    "printf 'stale-marker\\n' > " + marker + "; "
                    "printf 'stale-restore\\n' > " + restore_marker + "; "
                    "printf 'stale-switch\\n' > " + switch_marker + "; "
                    "printf 'stale-generation\\n' > " + generation_marker + "; "
                    "install -d -m 0755 /var/log/mcl/deployments; "
                    "printf 'stale-event\\n' > " + event_log + "; "
                    "rm -rf -- "
                    + " ".join(deployment_state_paths)
                    + "; "
                    "install -d -m 0700 " + status_path.rsplit("/", 1)[0] + "; "
                    "printf '{}\\n' > " + status_path + "; "
                    "for category in desired current failed superseded converged targets; do "
                    "install -d -m 0700 " + state_dir + "/$category; "
                    "printf 'stale-artifact\\n' > " + state_dir + "/$category/reset-sentinel; "
                    "done; "
                    "rm -f -- "
                    + " ".join([
                        marker,
                        restore_marker,
                        switch_marker,
                        generation_marker,
                        event_log,
                    ])
                    + "; "
                    "rm -rf -- "
                    + " ".join(deployment_state_paths)
                )
                assert_no_agent_observables()

            def remove_locks():
                target.succeed("rm -rf -- " + locks_path)

            def assert_preflight_blocked():
                target.fail("systemctl start mcl-deploy-agent.service")
                assert_no_agent_observables()
                target.succeed(
                    "journalctl -u mcl-deploy-agent.service --no-pager "
                    "| grep -F 'mcl-deploy-agent lock preparation refused:'"
                )

            def assert_signed_deployment_succeeded(before_path):
                target.succeed(
                    "test \"$(stat -c '%u:%g:%a' " + locks_path + ")\" = 0:0:700; "
                    "test \"$(stat -c '%d:%i' " + locks_path + ")\" "
                    "= \"$(cat " + before_path + ")\""
                )
                target.succeed(
                    "test \"$(wc -l < " + marker + ")\" = 1; "
                    "grep -qx invoked-after-0700 " + marker
                )
                target.succeed(
                    "test \"$(wc -l < " + restore_marker + ")\" = 1; "
                    "grep -qx restore " + restore_marker + "; "
                    "test \"$(wc -l < " + switch_marker + ")\" = 1; "
                    "grep -qx success " + switch_marker
                )
                target.succeed(
                    "test \"$(cat " + generation_marker + ")\" = '${successGeneration}'"
                )
                target.succeed(
                    "test \"$(find " + state_dir + "/desired -mindepth 1 -maxdepth 1 "
                    "-type f | wc -l)\" = 1; "
                    "test \"$(find " + state_dir + "/current -mindepth 1 -maxdepth 1 "
                    "-type f | wc -l)\" = 1; "
                    "test \"$(find " + state_dir + "/converged -mindepth 1 -maxdepth 1 "
                    "-type f | wc -l)\" = 1; "
                    "test -f " + state_dir + "/targets/target.json"
                )
                target.succeed(
                    "python3 - <<'PY'\n"
                    "import json\n"
                    "status = json.load(open('/var/lib/mcl/preflight-state/agent-status/target.json'))\n"
                    "assert status['target'] == 'target', status\n"
                    "assert status['sequence'] == 42, status\n"
                    "assert status['currentState'] == 'succeeded', status\n"
                    "PY"
                )

            def assert_unexpected_directory_mode_refused(mode):
                reset_service()
                remove_locks()
                before_path = "/tmp/unexpected-mode-" + mode + ".before"
                target.succeed(
                    "install -d -o root -g root -m " + mode + " " + locks_path + "; "
                    "stat -c '%F:%u:%g:%a:%d:%i' " + locks_path + " > " + before_path
                )
                assert_preflight_blocked()
                target.succeed(
                    "stat -c '%F:%u:%g:%a:%d:%i' " + locks_path + " "
                    "| cmp - " + before_path + "; "
                    "journalctl -u mcl-deploy-agent.service --no-pager "
                    "| grep -F 'locks directory has unsupported mode " + mode + "'"
                )

            with subtest("generic CLI creates exact 0700 locks under a conventional umask"):
                generic_state = "/var/lib/mcl/generic-cli-state"
                target.succeed("rm -rf -- " + generic_state)
                target.succeed(
                    "umask 0022; "
                    "if ${lib.getExe self'.packages.mcl-devops} deploy-agent "
                    "--target target "
                    "--trusted-manifest-public-key ${lib.escapeShellArg manifestPublicKey} "
                    "--state-dir " + generic_state + " "
                    "--manifest /definitely-missing-manifest.json "
                    ">/tmp/generic-cli.out 2>&1; then exit 1; fi"
                )
                target.succeed(
                    "test \"$(stat -c '%u:%g:%a' " + generic_state + "/locks)\" = 0:0:700"
                )

                # Generic callers fail closed on legacy/unsafe state. Repair is
                # a declarative NixOS service migration, not a runtime side effect.
                target.succeed("chmod 0755 " + generic_state + "/locks")
                target.succeed(
                    "umask 0022; "
                    "if ${lib.getExe self'.packages.mcl-devops} deploy-agent "
                    "--target target "
                    "--trusted-manifest-public-key ${lib.escapeShellArg manifestPublicKey} "
                    "--state-dir " + generic_state + " "
                    "--manifest /definitely-missing-manifest.json "
                    ">/tmp/generic-cli-unsafe.out 2>&1; then exit 1; fi; "
                    "grep -F 'does not have mode 0700' /tmp/generic-cli-unsafe.out"
                )
                target.succeed(
                    "test \"$(stat -c '%u:%g:%a' " + generic_state + "/locks)\" = 0:0:755"
                )

            with subtest("publish signed desired state without invoking the service package"):
                target.succeed("install -m 0600 ${manifestPrivateKey} /tmp/manifest-key")
                target.succeed(
                    "${fakeClosureEnv} ${lib.getExe self'.packages.mcl-devops} deploy-plan "
                    "--target target "
                    "--desired-system-path ${newSystemPath} "
                    "--git-revision 0123456789abcdef0123456789abcdef01234568 "
                    "--sequence 42 "
                    "--health-command ${lib.escapeShellArg healthCommand} "
                    "--signing-key /tmp/manifest-key "
                    "--signing-key-id mcl-deployment "
                    "--output /var/lib/mcl-preflight-inbox/latest.json"
                )
                target.fail("test -e " + marker)

            with subtest("leaf symlink is refused without touching its target"):
                reset_service()
                remove_locks()
                target.succeed(
                    "install -d -m 0711 /var/lib/mcl-preflight-sentinel; "
                    "printf 'sentinel-bytes\\n' > /var/lib/mcl-preflight-sentinel/value; "
                    "chmod 0640 /var/lib/mcl-preflight-sentinel/value; "
                    "stat -c '%F:%u:%g:%a:%d:%i' /var/lib/mcl-preflight-sentinel "
                    "> /tmp/sentinel-dir.before; "
                    "stat -c '%F:%u:%g:%a:%d:%i' /var/lib/mcl-preflight-sentinel/value "
                    "> /tmp/sentinel-file.before; "
                    "sha256sum /var/lib/mcl-preflight-sentinel/value "
                    "> /tmp/sentinel-bytes.before; "
                    "ln -s /var/lib/mcl-preflight-sentinel " + locks_path
                )
                assert_preflight_blocked()
                target.succeed(
                    "test -L " + locks_path + "; "
                    "test \"$(readlink " + locks_path + ")\" = /var/lib/mcl-preflight-sentinel; "
                    "stat -c '%F:%u:%g:%a:%d:%i' /var/lib/mcl-preflight-sentinel "
                    "| cmp - /tmp/sentinel-dir.before; "
                    "stat -c '%F:%u:%g:%a:%d:%i' /var/lib/mcl-preflight-sentinel/value "
                    "| cmp - /tmp/sentinel-file.before; "
                    "sha256sum /var/lib/mcl-preflight-sentinel/value "
                    "| cmp - /tmp/sentinel-bytes.before"
                )

            with subtest("regular file is refused without mutation"):
                reset_service()
                remove_locks()
                target.succeed(
                    "printf 'regular-locks-bytes\\n' > " + locks_path + "; "
                    "chmod 0640 " + locks_path + "; "
                    "stat -c '%F:%u:%g:%a:%d:%i:%h' " + locks_path + " > /tmp/regular.before; "
                    "sha256sum " + locks_path + " > /tmp/regular-bytes.before"
                )
                assert_preflight_blocked()
                target.succeed(
                    "stat -c '%F:%u:%g:%a:%d:%i:%h' " + locks_path + " "
                    "| cmp - /tmp/regular.before; "
                    "sha256sum " + locks_path + " | cmp - /tmp/regular-bytes.before"
                )

            with subtest("FIFO is refused without mutation"):
                reset_service()
                remove_locks()
                target.succeed(
                    "mkfifo -m 0640 " + locks_path + "; "
                    "stat -c '%F:%u:%g:%a:%d:%i:%h' " + locks_path + " > /tmp/fifo.before"
                )
                assert_preflight_blocked()
                target.succeed(
                    "test -p " + locks_path + "; "
                    "stat -c '%F:%u:%g:%a:%d:%i:%h' " + locks_path + " "
                    "| cmp - /tmp/fifo.before"
                )

            with subtest("hardlinked leaf is refused without touching either name"):
                reset_service()
                remove_locks()
                target.succeed(
                    "printf 'hardlink-sentinel\\n' > /var/lib/mcl-hardlink-sentinel; "
                    "chmod 0640 /var/lib/mcl-hardlink-sentinel; "
                    "ln /var/lib/mcl-hardlink-sentinel " + locks_path + "; "
                    "stat -c '%F:%u:%g:%a:%d:%i:%h' /var/lib/mcl-hardlink-sentinel "
                    "> /tmp/hardlink.before; "
                    "sha256sum /var/lib/mcl-hardlink-sentinel > /tmp/hardlink-bytes.before"
                )
                assert_preflight_blocked()
                target.succeed(
                    "stat -c '%F:%u:%g:%a:%d:%i:%h' /var/lib/mcl-hardlink-sentinel "
                    "| cmp - /tmp/hardlink.before; "
                    "stat -c '%F:%u:%g:%a:%d:%i:%h' " + locks_path + " "
                    "| cmp - /tmp/hardlink.before; "
                    "sha256sum /var/lib/mcl-hardlink-sentinel "
                    "| cmp - /tmp/hardlink-bytes.before"
                )

            with subtest("wrong owner is refused without repair"):
                reset_service()
                remove_locks()
                target.succeed(
                    "install -d -m 0755 " + locks_path + "; "
                    "chown 65534:65534 " + locks_path + "; "
                    "stat -c '%F:%u:%g:%a:%d:%i' " + locks_path + " > /tmp/wrong-owner.before"
                )
                assert_preflight_blocked()
                target.succeed(
                    "stat -c '%F:%u:%g:%a:%d:%i' " + locks_path + " "
                    "| cmp - /tmp/wrong-owner.before"
                )

            with subtest("wrong group is refused without repair"):
                reset_service()
                remove_locks()
                target.succeed(
                    "install -d -m 0750 " + locks_path + "; "
                    "chown 0:65534 " + locks_path + "; "
                    "stat -c '%F:%u:%g:%a:%d:%i' " + locks_path + " > /tmp/wrong-group.before"
                )
                assert_preflight_blocked()
                target.succeed(
                    "stat -c '%F:%u:%g:%a:%d:%i' " + locks_path + " "
                    "| cmp - /tmp/wrong-group.before"
                )

            with subtest("unexpected root-owned 0500 directory mode is refused without mutation"):
                assert_unexpected_directory_mode_refused("0500")

            with subtest("unexpected root-owned 0711 directory mode is refused without mutation"):
                assert_unexpected_directory_mode_refused("0711")

            with subtest("unexpected root-owned 0777 directory mode is refused without mutation"):
                assert_unexpected_directory_mode_refused("0777")

            with subtest("legacy root-owned 0755 is migrated before signed deployment"):
                reset_service()
                remove_locks()
                target.succeed(
                    "install -d -o root -g root -m 0755 " + locks_path + "; "
                    "stat -c '%d:%i' " + locks_path + " > /tmp/legacy-0755.inode"
                )
                target.succeed("systemctl start mcl-deploy-agent.service")
                assert_signed_deployment_succeeded("/tmp/legacy-0755.inode")

            with subtest("legacy root-owned 0750 is migrated before signed deployment"):
                reset_service()
                remove_locks()
                target.succeed(
                    "install -d -o root -g root -m 0750 " + locks_path + "; "
                    "stat -c '%d:%i' " + locks_path + " > /tmp/legacy-0750.inode"
                )
                target.succeed("systemctl start mcl-deploy-agent.service")
                assert_signed_deployment_succeeded("/tmp/legacy-0750.inode")

            with subtest("absent locks directory is created exact 0700 before mcl-devops"):
                reset_service()
                remove_locks()
                target.succeed("systemctl start mcl-deploy-agent.service")
                target.succeed(
                    "test \"$(stat -c '%u:%g:%a' " + locks_path + ")\" = 0:0:700"
                )
                target.succeed(
                    "test \"$(wc -l < " + marker + ")\" = 1; "
                    "grep -qx invoked-after-0700 " + marker
                )
          '';
        };

        deployment-pull-agent-lock-contention-vm = pkgs.testers.nixosTest {
          name = "deployment-pull-agent-lock-contention-vm";

          nodes.target =
            { ... }:
            {
              imports = [ flake.modules.nixos.deployment-pull-agent ];
              services.mcl-deploy-agent = {
                enable = true;
                package = slowMcl;
                targetName = "target";
                manifestPublicKeys = [ manifestPublicKey ];
                manifestSources = [ "/var/lib/mcl/deployments/inbox/latest.json" ];
                interval = "1min";
                jitter = "0";
                lockFile = "/run/lock/mcl-test-pull-agent.lock";
              };
            };

          testScript = ''
            start_all()
            target.wait_for_unit("multi-user.target")

            with subtest("service-held lock rejects concurrent agent apply"):
                target.succeed("systemctl start --no-block mcl-deploy-agent.service")
                target.wait_until_succeeds("test -e /var/lib/mcl-test/agent-started")
                target.fail("${pkgs.util-linux}/bin/flock -n /run/lock/mcl-test-pull-agent.lock ${lib.getExe slowMcl} deploy-agent --manual-contender")
                target.succeed("test \"$(grep -c '^start:' /var/lib/mcl-test/agent-runs)\" = 1")
                target.succeed("test \"$(grep -c '^end:' /var/lib/mcl-test/agent-runs || true)\" = 0")

            with subtest("lock releases after the service exits"):
                target.wait_until_succeeds("test \"$(grep -c '^end:' /var/lib/mcl-test/agent-runs)\" = 1")
                target.succeed("${pkgs.util-linux}/bin/flock -n /run/lock/mcl-test-pull-agent.lock ${lib.getExe slowMcl} deploy-agent --after-service")
                target.succeed("test \"$(grep -c '^start:' /var/lib/mcl-test/agent-runs)\" = 2")
                target.succeed("test \"$(grep -c '^end:' /var/lib/mcl-test/agent-runs)\" = 2")
          '';
        };

        # FU1 (DEPLOY-AGENT-SELFHEAL): proves an agent-driven switch that restarts
        # mcl-deploy-agent.service no longer wedges the deploy. The switch command
        # here issues `systemctl restart mcl-deploy-agent.service` from within the
        # switch, exactly as switch-to-configuration does on a deploy that changes
        # this unit's definition. The fix runs the switch in a detached systemd-run
        # transient unit, so systemd can restart the agent without SIGTERM-ing the
        # switch mid-activation; the switch survives its own restart and finishes.
        #
        # Non-vacuousness: with `--no-detach-switch` (the pre-fix in-cgroup path)
        # the `systemctl restart` SIGTERMs the switch process at that line, so
        # 'switch-survived-restart' / 'success' are never written and the run does
        # not converge -- the assertions below fail. Confirmed by building a sibling
        # node with switchCommand pointed at a `--no-detach` wrapper reproduces the
        # wedge (see the reproduceWedge helper referenced in the FU1 status note).
        deployment-pull-agent-selfheal-vm = pkgs.testers.nixosTest {
          name = "deployment-pull-agent-selfheal-vm";

          nodes.target =
            { ... }:
            {
              imports = [ flake.modules.nixos.deployment-pull-agent ];
              networking.hostName = "target";
              environment.systemPackages = [
                self'.packages.mcl-devops
                pkgs.python3
              ];
              services.mcl-deploy-agent = {
                enable = true;
                package = self'.packages.mcl-devops;
                targetName = "target";
                manifestPublicKeys = [ manifestPublicKey ];
                manifestDirectories = [ "/var/lib/mcl/deployments/inbox" ];
                eventLog = "/var/log/mcl/deployments/target.jsonl";
                interval = "1min";
                jitter = "0";
                lockFile = "/run/lock/mcl-test-pull-agent.lock";
                restoreCommand = "${restoreScript}";
                switchCommand = "${selfhealSwitchScript}";
                generationCommand = "${generationScript}";
              };
            };

          testScript = ''
            import time

            start_all()
            target.wait_for_unit("multi-user.target")

            with subtest("publish a signed desired state for the target"):
                target.succeed("install -d -m 0750 /var/lib/mcl/deployments/inbox")
                target.succeed("install -m 0600 ${manifestPrivateKey} /tmp/manifest-key")
                target.succeed(
                    "${fakeClosureEnv} mcl-devops deploy-plan "
                    "--target target "
                    "--desired-system-path ${newSystemPath} "
                    "--git-revision 0123456789abcdef0123456789abcdef01234568 "
                    "--sequence 42 "
                    "--health-command ${lib.escapeShellArg healthCommand} "
                    "--signing-key /tmp/manifest-key "
                    "--signing-key-id mcl-deployment "
                    "--output /var/lib/mcl/deployments/inbox/new.json"
                )

            with subtest("agent-driven switch that restarts the agent unit does not wedge"):
                # Kick the deploy. The first invocation runs the switch, which (in a
                # detached systemd-run unit) restarts this unit. The restart SIGTERMs
                # the invocation that launched it, so we drive it --no-block and
                # observe the *outcome* rather than this call's exit code.
                target.succeed("systemctl start --no-block mcl-deploy-agent.service")

                # Wait for the single restart to be issued.
                target.wait_until_succeeds(
                    "grep -q '^restart-issuer:' /var/lib/mcl-test/selfheal-switch-runs",
                    timeout=120,
                )
                # THE decisive check: the exact process that issued the restart must
                # have survived it and written 'survived:<its-pid>'. Detached, it
                # does. In-cgroup (pre-fix) it is SIGTERM'd at the restart, so no
                # matching survival line ever appears and this bounded wait fails --
                # i.e. the test is non-vacuous. Verified: forcing the in-cgroup path
                # (detach=false) makes exactly this assertion fail.
                target.wait_until_succeeds(
                    "issuer=$(grep '^restart-issuer:' /var/lib/mcl-test/selfheal-switch-runs "
                    "| head -n1 | cut -d: -f2); "
                    "grep -qx \"survived:$issuer\" /var/lib/mcl-test/selfheal-switch-runs",
                    timeout=120,
                )
                target.wait_until_succeeds(
                    "grep -qx success /var/lib/mcl-test/switch-runs", timeout=120
                )
                # The restart happened exactly once (the gate held) and the new
                # generation is active.
                target.succeed("test -e /var/lib/mcl-test/selfheal-restart-done")
                target.succeed(
                    "test \"$(grep -c '^restart-issuer:' /var/lib/mcl-test/selfheal-switch-runs)\" = 1"
                )
                target.succeed("test \"$(cat /var/lib/mcl-test/current-generation)\" = '${successGeneration}'")

            with subtest("the agent quiesces -- no restart storm, converged state recorded"):
                # After the single self-restart the agent must settle (not loop).
                # Wait for it to be inactive, then confirm it stays inactive.
                target.wait_until_fails(
                    "systemctl is-active --quiet mcl-deploy-agent.service", timeout=120
                )
                time.sleep(5)
                target.succeed("! systemctl is-active --quiet mcl-deploy-agent.service")

                # A terminal status is recorded and is not a wedge/failure. The
                # invocation that launched the switch is SIGTERM'd by the very
                # restart it triggered, so a follow-up invocation (or timer poll)
                # finalizes state; that state must reflect the accepted deployment
                # for this target and must not be a hung/failed wedge.
                target.wait_until_succeeds(
                    "test -f /var/lib/mcl/deployments/agent-status/target.json", timeout=120
                )
                target.succeed(
                    "python3 - <<'PY'\n"
                    "import json\n"
                    "status = json.load(open('/var/lib/mcl/deployments/agent-status/target.json'))\n"
                    "assert status['target'] == 'target', status\n"
                    "assert status['sequence'] == 42, status\n"
                    "assert status['currentState'] in ('succeeded', 'failed'), status\n"
                    "# The self-restart must not have driven the retry budget to exhaustion.\n"
                    "assert status['currentState'] != 'non-retryable', status\n"
                    "PY"
                )
          '';
        };

        deployment-pull-agent-static = pkgs.runCommand "deployment-pull-agent-static" { } ''
          ${lib.optionalString (staticFailures != [ ]) ''
            cat > failures.txt <<'EOF'
            ${lib.concatStringsSep "\n" staticFailures}
            EOF
            cat failures.txt >&2
            exit 1
          ''}
          cat > "$out" <<'EOF'
          deployment pull agent rendered expected lock, sources, retry budget, timer, and dry-run options.
          EOF
        '';
      };
    };
}
