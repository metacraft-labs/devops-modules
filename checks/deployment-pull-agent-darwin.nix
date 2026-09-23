top@{
  config,
  inputs,
  ...
}:
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
      manifestPrivateKey = pkgs.writeText "mcl-darwin-pull-agent-test-key" ''
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACDhvqWTBaFX/XLEIco2ux47m8yJz7xl+vTsiB2LGk7h7QAAAJifNGKYnzRi
        mAAAAAtzc2gtZWQyNTUxOQAAACDhvqWTBaFX/XLEIco2ux47m8yJz7xl+vTsiB2LGk7h7Q
        AAAEBvBnhoTQhoz/liGXDGeodsQFCPZfx7B/f10DxJy+VHP+G+pZMFoVf9csQhyja7Hjub
        zInPvGX69OyIHYsaTuHtAAAAEW1jbC1tYW5pZmVzdC10ZXN0AQIDBA==
        -----END OPENSSH PRIVATE KEY-----
      '';
      manifestPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOG+pZMFoVf9csQhyja7HjubzInPvGX69OyIHYsaTuHt mcl-manifest-test";
      stableEntrypoint = "/run/current-system/sw/bin/mcl-deploy-agent";
      fixtureChown = pkgs.writeShellApplication {
        name = "mcl-deploy-preparation-fixture-chown";
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          path="''${!#}"
          if [[ -d "$path" ]]; then
            kind=directory
          else
            kind=log
          fi
          if [[ -n "''${MCL_DEPLOY_PREP_FIXTURE_CHOWN_LOG:-}" ]]; then
            printf '%s %s\n' "$kind" "$path" >> "$MCL_DEPLOY_PREP_FIXTURE_CHOWN_LOG"
          fi
          if [[ "''${MCL_DEPLOY_PREP_FIXTURE_CHOWN_FAIL:-}" == "$kind" ]]; then
            exit 88
          fi
          translated=()
          for argument in "$@"; do
            if [[ "$argument" == fixture-self ]]; then
              translated+=("$(id -u)")
            else
              translated+=("$argument")
            fi
          done
          exec chown "''${translated[@]}"
        '';
      };
      eventLogValidator = pkgs.writeText "mcl-validate-deployment-events.py" ''
        import json
        import pathlib
        import sys

        from jsonschema import Draft202012Validator, FormatChecker

        event_log = pathlib.Path(sys.argv[1])
        schema = json.loads(pathlib.Path(sys.argv[2]).read_text())
        Draft202012Validator.check_schema(schema)
        validator = Draft202012Validator(schema, format_checker=FormatChecker())
        events = [json.loads(line) for line in event_log.read_text().splitlines() if line.strip()]
        if not events:
            raise AssertionError(f"event log is empty: {event_log}")
        for index, event in enumerate(events, start=1):
            errors = sorted(validator.iter_errors(event), key=lambda error: list(error.path))
            if errors:
                rendered = "; ".join(error.message for error in errors)
                raise AssertionError(f"{event_log}:{index}: {rendered}")
      '';
      replacementFixtureHook = pkgs.writeShellScript "mcl-replace-after-snapshot" ''
        set -eu
        target="$MCL_DEPLOY_PREP_REPLACE_PATH"
        case "$MCL_DEPLOY_PREP_REPLACE_KIND" in
          directory)
            rmdir -- "$target"
            mkdir -m 0716 -- "$target"
            ;;
          log)
            rm -f -- "$target"
            printf 'external-replacement-log\n' > "$target"
            chmod 0603 "$target"
            ;;
          *) exit 92 ;;
        esac
        stat -c '%d:%i' -- "$target" > "$MCL_DEPLOY_PREP_REPLACE_MARKER"
      '';
      rollbackRaceFixtureHook = pkgs.writeShellScript "mcl-rollback-race-hook" ''
        set -eu
        kind="$1"
        path="$2"
        if [ "$kind" = log ] && [ ! -e "$MCL_DEPLOY_PREP_RACE_MARKER" ]; then
          rm -f -- "$path"
          printf 'external-race-object\n' > "$path"
          chmod 0603 "$path"
          stat -c '%d:%i' "$path" > "$MCL_DEPLOY_PREP_RACE_MARKER"
        fi
      '';
      createRaceFixtureHook = pkgs.writeShellScript "mcl-create-race-hook" ''
        set -eu
        kind="$1"
        path="$2"
        case "$kind" in
          directory) mkdir -m 0750 -- "$path" ;;
          log)
            printf 'racing-log\n' > "$path"
            chmod 0600 "$path"
            ;;
          *) exit 91 ;;
        esac
      '';
      fixturePathOptions = {
        preparationOwner = "fixture-self";
        preparationGroup = null;
        preparationExpectedUid = null;
        preparationExpectedGid = null;
        preparationAllowedRoots = [ "/private/tmp" ];
        preparationAllowTestOverrides = true;
        preparationFixtureChownCommand = lib.getExe fixtureChown;
      };

      assertionFailures =
        system:
        map (assertion: assertion.message or "unnamed nix-darwin assertion") (
          builtins.filter (assertion: !assertion.assertion) system.config.assertions
        );
      requireAssertions =
        label: system:
        let
          failures = assertionFailures system;
        in
        if failures == [ ] then
          true
        else
          throw ''
            ${label} has false nix-darwin assertions:
            ${builtins.concatStringsSep "\n" (map (message: "- ${message}") failures)}
          '';
      checkedSystem =
        label: system:
        assert requireAssertions label system;
        system;

      fakeMcl =
        generation:
        pkgs.writeShellApplication {
          name = "mcl-devops";
          text = ''
            if [[ -n "''${MCL_DARWIN_PREREQUISITE_MARKER:-}" ]]; then
              touch "$MCL_DARWIN_PREREQUISITE_MARKER"
            fi
            printf '%s\n' ${lib.escapeShellArg generation}
          '';
        };
      failingRuntimePrerequisite = pkgs.writeShellApplication {
        name = "mcl-deploy-runtime-prerequisite";
        text = "exit 75";
      };

      staticSystem =
        package:
        inputs.nix-darwin.lib.darwinSystem {
          system = pkgs.stdenv.hostPlatform.system;
          modules = [
            flake.modules.darwin.deployment-pull-agent
            {
              networking.hostName = "m3";
              system.stateVersion = 6;
              services.mcl-deploy-agent = {
                enable = true;
                inherit package;
                targetName = "m3";
                manifestPublicKeys = [ manifestPublicKey ];
                manifestSources = [ "https://deployments.example.invalid/m3/latest.json" ];
                manifestDirectories = [ "/private/var/lib/mcl/test-deployments/inbox" ];
                stateDir = "/private/var/lib/mcl/test-deployments";
                eventLog = "/private/var/log/mcl/deployments/test-agent.jsonl";
                standardOutLog = "/private/var/log/mcl/deployments/test-agent.stdout.log";
                standardErrorLog = "/private/var/log/mcl/deployments/test-agent.stderr.log";
                intervalSeconds = 421;
                lockFile = "/private/var/run/mcl/test-pull-agent/m3.lock";
                maxAttempts = 5;
                fetchTimeoutSeconds = 11;
                systemProfile = "/nix/var/nix/profiles/system";
                preSwitchHook = "/run/current-system/sw/bin/mcl-deploy-pre-switch";
                postSwitchHook = "/run/current-system/sw/bin/mcl-deploy-post-switch";
                alreadyCurrentRecoveryHook = "/run/current-system/sw/bin/mcl-deploy-recover-current";
                runtimePrerequisite = lib.getExe failingRuntimePrerequisite;
              };
            }
          ];
        };

      staticA = checkedSystem "static generation A" (staticSystem (fakeMcl "generation-a"));
      staticB = checkedSystem "static generation B" (staticSystem (fakeMcl "generation-b"));
      staticServiceA = staticA.config.launchd.daemons.mcl-deploy-agent.serviceConfig;
      staticServiceB = staticB.config.launchd.daemons.mcl-deploy-agent.serviceConfig;
      staticEntrypointPackage =
        lib.findFirst (package: lib.getName package == "mcl-deploy-agent")
          (throw "Darwin pull-agent entrypoint package is absent from environment.systemPackages")
          staticA.config.environment.systemPackages;
      staticEntrypointPackageB =
        lib.findFirst (package: lib.getName package == "mcl-deploy-agent")
          (throw "second Darwin pull-agent entrypoint package is absent from environment.systemPackages")
          staticB.config.environment.systemPackages;
      staticLaunchdLauncherPackage =
        lib.findFirst (package: lib.getName package == "mcl-deploy-agent-launcher")
          (throw "Darwin pull-agent immutable launchd launcher is absent from environment.systemPackages")
          staticA.config.environment.systemPackages;
      staticLaunchdLauncherPackageB =
        lib.findFirst (package: lib.getName package == "mcl-deploy-agent-launcher")
          (throw "second Darwin pull-agent immutable launchd launcher is absent")
          staticB.config.environment.systemPackages;
      expectedLaunchdArguments = [
        "/bin/sh"
        "-c"
        ''/bin/wait4path /nix/store && exec "$@"''
        "mcl-deploy-agent"
        (lib.getExe staticLaunchdLauncherPackage)
        stableEntrypoint
        "120"
        "1"
      ];
      staticSystemEntrypoint = "${staticA.config.system.path}/bin/mcl-deploy-agent";
      staticSystemEntrypointB = "${staticB.config.system.path}/bin/mcl-deploy-agent";
      staticActivation = staticA.config.system.activationScripts.preActivation.text;
      staticPreparationPackage = staticA.config.services.mcl-deploy-agent.preparationPackage;
      staticActivationText = builtins.unsafeDiscardStringContext staticActivation;
      staticPreparationExe = builtins.unsafeDiscardStringContext (lib.getExe staticPreparationPackage);
      prerequisiteNamespace = "/private/tmp/mcl-darwin-pull-agent-prerequisite";
      prerequisiteRoot = "${prerequisiteNamespace}/fixture";
      prerequisiteSystem = checkedSystem "runtime-prerequisite fixture" (
        inputs.nix-darwin.lib.darwinSystem {
          system = pkgs.stdenv.hostPlatform.system;
          modules = [
            flake.modules.darwin.deployment-pull-agent
            {
              networking.hostName = "m3-prerequisite";
              system.stateVersion = 6;
              services.mcl-deploy-agent = fixturePathOptions // {
                enable = true;
                package = fakeMcl "prerequisite-must-not-run";
                targetName = "m3-prerequisite";
                manifestPublicKeys = [ manifestPublicKey ];
                manifestSources = [ "https://deployments.example.invalid/m3/latest.json" ];
                manifestDirectories = [ "${prerequisiteRoot}/state/inbox" ];
                stateDir = "${prerequisiteRoot}/state";
                eventLog = "${prerequisiteRoot}/logs/events.jsonl";
                standardOutLog = "${prerequisiteRoot}/logs/stdout.log";
                standardErrorLog = "${prerequisiteRoot}/logs/stderr.log";
                lockFile = "${prerequisiteRoot}/run/agent.lock";
                runtimePrerequisite = lib.getExe failingRuntimePrerequisite;
              };
            }
          ];
        }
      );
      prerequisiteEntrypointPackage =
        lib.findFirst (package: lib.getName package == "mcl-deploy-agent")
          (throw "prerequisite Darwin pull-agent entrypoint package is absent")
          prerequisiteSystem.config.environment.systemPackages;
      prerequisitePreparationPackage =
        prerequisiteSystem.config.services.mcl-deploy-agent.preparationPackage;

      disabledSystem = checkedSystem "disabled fixture" (
        inputs.nix-darwin.lib.darwinSystem {
          system = pkgs.stdenv.hostPlatform.system;
          modules = [
            flake.modules.darwin.deployment-pull-agent
            {
              networking.hostName = "disabled-m3";
              system.stateVersion = 6;
            }
          ];
        }
      );

      invalidFixtureRoot = "/private/tmp/mcl-darwin-pull-agent/invalid-assertion-proof";
      invalidFixtureSystem = inputs.nix-darwin.lib.darwinSystem {
        system = pkgs.stdenv.hostPlatform.system;
        modules = [
          flake.modules.darwin.deployment-pull-agent
          {
            networking.hostName = "invalid-m3";
            system.stateVersion = 6;
            services.mcl-deploy-agent = fixturePathOptions // {
              enable = true;
              package = fakeMcl "invalid-assertion-proof";
              targetName = "invalid-m3";
              manifestPublicKeys = [ manifestPublicKey ];
              stateDir = "${invalidFixtureRoot}/state";
              manifestDirectories = [ "${invalidFixtureRoot}/outside-state/inbox" ];
              eventLog = "${invalidFixtureRoot}/logs/events.jsonl";
              standardOutLog = "${invalidFixtureRoot}/logs/stdout.log";
              standardErrorLog = "${invalidFixtureRoot}/logs/stderr.log";
              lockFile = "${invalidFixtureRoot}/run/agent.lock";
            };
          }
        ];
      };
      invalidAssertionGateTrips =
        !(builtins.tryEval (requireAssertions "deliberately invalid fixture" invalidFixtureSystem)).success;
      missingRecoveryAssertionMessage = "services.mcl-deploy-agent lifecycle hooks require alreadyCurrentRecoveryHook for safe exact-current convergence.";
      missingRecoverySystem = inputs.nix-darwin.lib.darwinSystem {
        system = pkgs.stdenv.hostPlatform.system;
        modules = [
          flake.modules.darwin.deployment-pull-agent
          {
            networking.hostName = "missing-recovery-m3";
            system.stateVersion = 6;
            services.mcl-deploy-agent = {
              enable = true;
              package = fakeMcl "missing-recovery-assertion-proof";
              targetName = "missing-recovery-m3";
              manifestPublicKeys = [ manifestPublicKey ];
              manifestSources = [ "https://deployments.example.invalid/m3/latest.json" ];
              stateDir = "/private/var/lib/mcl/missing-recovery-deployments";
              eventLog = "/private/var/log/mcl/missing-recovery/events.jsonl";
              standardOutLog = "/private/var/log/mcl/missing-recovery/stdout.log";
              standardErrorLog = "/private/var/log/mcl/missing-recovery/stderr.log";
              lockFile = "/private/var/run/mcl/missing-recovery/agent.lock";
              preSwitchHook = "/run/current-system/sw/bin/mcl-deploy-pre-switch";
              postSwitchHook = "/run/current-system/sw/bin/mcl-deploy-post-switch";
            };
          }
        ];
      };
      missingRecoveryFailures = assertionFailures missingRecoverySystem;
      missingRecoveryAssertionPresent = builtins.elem missingRecoveryAssertionMessage missingRecoveryFailures;
      missingRecoveryAssertionGateTrips =
        !(builtins.tryEval (
          requireAssertions "missing already-current recovery hook" missingRecoverySystem
        )).success;

      assertionGateCheck =
        assert requireAssertions "static generation A" staticA;
        assert requireAssertions "static generation B" staticB;
        assert requireAssertions "runtime-prerequisite fixture" prerequisiteSystem;
        assert requireAssertions "disabled fixture" disabledSystem;
        assert requireAssertions "agent integration fixture" integrationSystem;
        assert requireAssertions "lock-contention fixture" lockSystem;
        assert missingRecoveryAssertionPresent;
        assert missingRecoveryAssertionGateTrips;
        pkgs.runCommand "test-darwin-pull-agent-assertion-gate" { } ''
          ${lib.optionalString (!invalidAssertionGateTrips) ''
            echo 'explicit assertion gate accepted a deliberately invalid fixture' >&2
            exit 1
          ''}
          mkdir -p "$out"
          printf '%s\n' 'test_darwin_pull_agent_assertion_gate: passed' > "$out/result"
        '';

      staticFailures = lib.flatten [
        (lib.optional (
          !invalidAssertionGateTrips
        ) "explicit assertion gate accepted a deliberately invalid fixture")
        (lib.optional (
          !missingRecoveryAssertionPresent
        ) "lifecycle configuration did not expose the exact missing-recovery assertion")
        (lib.optional (
          !missingRecoveryAssertionGateTrips
        ) "assertion gate accepted lifecycle hooks without an already-current recovery hook")
        (lib.optional (
          disabledSystem.config.launchd.daemons ? mcl-deploy-agent
        ) "Darwin pull agent is not disabled by default")
        (lib.optional (
          staticServiceA.ProgramArguments != expectedLaunchdArguments
        ) "LaunchDaemon does not use the immutable bounded launcher")
        (lib.optional (
          builtins.head staticServiceA.ProgramArguments == stableEntrypoint
        ) "LaunchDaemon still executes the not-yet-published current-system link directly")
        (lib.optional (staticServiceA.UserName != "root") "LaunchDaemon is not explicitly root-owned")
        (lib.optional (
          staticServiceA.GroupName != "wheel"
        ) "LaunchDaemon is not assigned to the root wheel group")
        (lib.optional (staticServiceA.RunAtLoad != true) "LaunchDaemon does not poll at load")
        (lib.optional (staticServiceA.StartInterval != 421) "LaunchDaemon polling interval drifted")
        (lib.optional (
          staticServiceA.StandardOutPath != "/private/var/log/mcl/deployments/test-agent.stdout.log"
        ) "LaunchDaemon stdout is not durable")
        (lib.optional (
          staticServiceA.StandardErrorPath != "/private/var/log/mcl/deployments/test-agent.stderr.log"
        ) "LaunchDaemon stderr is not durable")
        (lib.optional (
          staticServiceA.Label != "org.metacraft-labs.mcl-deploy-agent"
        ) "LaunchDaemon label drifted")
        (lib.optional (
          staticServiceA != staticServiceB
        ) "generation-specific packages change the LaunchDaemon plist")
        (lib.optional (
          staticEntrypointPackage == staticEntrypointPackageB
        ) "generation-specific packages do not change the resolved wrapper")
        (lib.optional (
          staticLaunchdLauncherPackage != staticLaunchdLauncherPackageB
        ) "immutable launchd launcher changes with the wrapped agent generation")
        (lib.optional (
          builtins.elem (lib.getExe staticEntrypointPackage) staticServiceA.ProgramArguments
          || builtins.elem (lib.getExe staticEntrypointPackageB) staticServiceA.ProgramArguments
        ) "LaunchDaemon plist embeds a generation-specific agent wrapper")
        (lib.optional (lib.hasInfix "sudo" (builtins.toJSON staticServiceA)) "LaunchDaemon plist requires sudo")
        (lib.optional (
          !lib.hasInfix staticPreparationExe staticActivationText
        ) "activation does not invoke the hardened durable-path preparation executable")
      ];

      launchdContractCheck = pkgs.runCommand "test-darwin-pull-agent-launchd-contract" { } ''
        ${lib.optionalString (staticFailures != [ ]) ''
          printf '%s\n' ${lib.escapeShellArgs staticFailures} >&2
          exit 1
        ''}
        entrypoint=${lib.escapeShellArg (lib.getExe staticEntrypointPackage)}
        system_entrypoint=${lib.escapeShellArg staticSystemEntrypoint}
        test -x "$entrypoint"
        test -L "$system_entrypoint"
        test "$(readlink "$system_entrypoint")" = "$entrypoint"
        grep -F -- '--target m3' "$entrypoint" >/dev/null
        grep -F -- '--state-dir /private/var/lib/mcl/test-deployments' "$entrypoint" >/dev/null
        grep -F -- '--event-log /private/var/log/mcl/deployments/test-agent.jsonl' "$entrypoint" >/dev/null
        grep -F -- '--max-attempts 5' "$entrypoint" >/dev/null
        grep -F -- '--fetch-timeout-seconds 11' "$entrypoint" >/dev/null
        grep -F -- '--activation-mode nix-darwin' "$entrypoint" >/dev/null
        grep -F -- '--system-profile /nix/var/nix/profiles/system' "$entrypoint" >/dev/null
        grep -F -- '--pre-switch-hook /run/current-system/sw/bin/mcl-deploy-pre-switch' "$entrypoint" >/dev/null
        grep -F -- '--post-switch-hook /run/current-system/sw/bin/mcl-deploy-post-switch' "$entrypoint" >/dev/null
        grep -F -- '--already-current-recovery-hook /run/current-system/sw/bin/mcl-deploy-recover-current' "$entrypoint" >/dev/null
        prerequisite_line=$(grep -nF -- ${lib.escapeShellArg (lib.getExe failingRuntimePrerequisite)} "$entrypoint" | head -n1 | cut -d: -f1)
        flock_line=$(grep -nF -- 'flock -n /private/var/run/mcl/test-pull-agent/m3.lock' "$entrypoint" | head -n1 | cut -d: -f1)
        test -n "$prerequisite_line"
        test -n "$flock_line"
        test "$prerequisite_line" -lt "$flock_line"
        grep -F -- 'flock -n /private/var/run/mcl/test-pull-agent/m3.lock' "$entrypoint" >/dev/null
        ! grep -F -- 'sudo' "$entrypoint"
        grep -F -- 'umask 0027' "$entrypoint" >/dev/null

        production_preparation=${lib.escapeShellArg (lib.getExe staticPreparationPackage)}
        grep -F -- 'mkdir -m 0750' "$production_preparation" >/dev/null
        grep -F -- 'chown -h root:wheel' "$production_preparation" >/dev/null
        grep -F -- 'expected_uid=0' "$production_preparation" >/dev/null
        grep -F -- 'expected_gid=0' "$production_preparation" >/dev/null
        ! grep -F -- 'MCL_DEPLOY_PREP_ROOT' "$production_preparation"
        ! grep -F -- 'MCL_DEPLOY_PREP_EXPECTED_UID' "$production_preparation"
        ! grep -F -- 'MCL_DEPLOY_PREP_EXPECTED_LOG_UID' "$production_preparation"
        ! grep -F -- 'MCL_DEPLOY_PREP_BEFORE_CREATE_HOOK' "$production_preparation"
        ! grep -F -- 'MCL_DEPLOY_PREP_INJECT_FAILURE' "$production_preparation"
        ! grep -F -- 'MCL_DEPLOY_PREP_INJECT_ROLLBACK_FAILURE' "$production_preparation"
        ! grep -F -- 'MCL_DEPLOY_PREP_ROLLBACK_HOOK' "$production_preparation"
        ! grep -F -- 'MCL_DEPLOY_PREP_AFTER_SNAPSHOT_HOOK' "$production_preparation"
        ! grep -F -- 'MCL_DEPLOY_PREP_FIXTURE_CHOWN' "$production_preparation"
        ! grep -F -- 'fixture-self' "$production_preparation"

        # The generated fixture variant executes the same path-walk, exact-mode,
        # hardlink, and post-verification code without production chown rights.
        preparation=${lib.escapeShellArg (lib.getExe prerequisitePreparationPackage)}
        sentinel=${lib.escapeShellArg "${prerequisiteRoot}-sentinel"}
        symlink_target=${lib.escapeShellArg "${prerequisiteRoot}-symlink-target"}
        hardlink_peer=${lib.escapeShellArg "${prerequisiteRoot}-event-hardlink"}
        rm -rf ${lib.escapeShellArg prerequisiteNamespace} "$symlink_target"
        rm -f "$sentinel" "$hardlink_peer"
        mkdir -p ${lib.escapeShellArg prerequisiteNamespace}
        printf 'shared-sentinel\n' > "$sentinel"
        chmod 0711 "$sentinel"
        sentinel_sha="$(sha256sum "$sentinel" | cut -d ' ' -f 1)"
        shared_mode="$(stat -c %a /private/tmp)"
        shared_uid="$(stat -c %u /private/tmp)"
        shared_gid="$(stat -c %g /private/tmp)"
        mkdir -p ${lib.escapeShellArg prerequisiteRoot}
        export MCL_DEPLOY_PREP_EXPECTED_UID="$(stat -c %u ${lib.escapeShellArg prerequisiteRoot})"
        export MCL_DEPLOY_PREP_EXPECTED_GID="$(stat -c %g ${lib.escapeShellArg prerequisiteRoot})"
        "$preparation"
        test "$(stat -c %a ${lib.escapeShellArg prerequisiteRoot})" = 750
        test "$(stat -c %a ${lib.escapeShellArg prerequisiteRoot}/state)" = 750
        test "$(stat -c %a ${lib.escapeShellArg prerequisiteRoot}/logs/events.jsonl)" = 640
        chmod 0777 ${lib.escapeShellArg prerequisiteRoot}/state
        chmod 0666 ${lib.escapeShellArg prerequisiteRoot}/logs/events.jsonl
        "$preparation"
        test "$(stat -c %a ${lib.escapeShellArg prerequisiteRoot}/state)" = 750
        test "$(stat -c %a ${lib.escapeShellArg prerequisiteRoot}/logs/events.jsonl)" = 640

        transaction_snapshot() {
          local path kind
          for path in \
            ${lib.escapeShellArg prerequisiteNamespace} \
            ${lib.escapeShellArg prerequisiteRoot} \
            ${lib.escapeShellArg prerequisiteRoot}/state \
            ${lib.escapeShellArg prerequisiteRoot}/state/inbox \
            ${lib.escapeShellArg prerequisiteRoot}/logs \
            ${lib.escapeShellArg prerequisiteRoot}/run \
            ${lib.escapeShellArg prerequisiteRoot}/logs/events.jsonl \
            ${lib.escapeShellArg prerequisiteRoot}/logs/stdout.log \
            ${lib.escapeShellArg prerequisiteRoot}/logs/stderr.log \
            ${lib.escapeShellArg prerequisiteNamespace}/unrelated \
            "$sentinel" \
            /private/tmp; do
            if [ "$path" = /private/tmp ]; then
              # Other local builders legitimately create/remove siblings in
              # this shared root. Its inode identity and link count are ambient;
              # owner, group, and mode are the safety properties this
              # invocation must preserve.
              printf 'shared-root path=%s uid=%s gid=%s mode=%s\n' \
                "$path" "$(stat -c %u "$path")" "$(stat -c %g "$path")" \
                "$(stat -c %a "$path")"
            elif [ -L "$path" ]; then
              printf 'symlink path=%s target=%s\n' "$path" "$(readlink "$path")"
            elif [ -d "$path" ]; then
              printf 'directory path=%s uid=%s gid=%s mode=%s links=%s inode=%s\n' \
                "$path" "$(stat -c %u "$path")" "$(stat -c %g "$path")" \
                "$(stat -c %a "$path")" "$(stat -c %h "$path")" \
                "$(stat -c '%d:%i' "$path")"
            elif [ -f "$path" ]; then
              printf 'file path=%s uid=%s gid=%s mode=%s links=%s inode=%s sha256=%s\n' \
                "$path" "$(stat -c %u "$path")" "$(stat -c %g "$path")" \
                "$(stat -c %a "$path")" "$(stat -c %h "$path")" \
                "$(stat -c '%d:%i' "$path")" "$(sha256sum "$path" | cut -d ' ' -f 1)"
            else
              printf 'absent path=%s\n' "$path"
            fi
          done
        }

        reset_transaction_fixture() {
          rm -rf ${lib.escapeShellArg prerequisiteNamespace}
          mkdir -p ${lib.escapeShellArg prerequisiteRoot}
          chmod 0711 ${lib.escapeShellArg prerequisiteNamespace}
          chmod 0713 ${lib.escapeShellArg prerequisiteRoot}
          printf 'unrelated-transaction-sentinel\n' > ${lib.escapeShellArg prerequisiteNamespace}/unrelated
          chmod 0601 ${lib.escapeShellArg prerequisiteNamespace}/unrelated
          printf 'shared-sentinel\n' > "$sentinel"
          chmod 0711 "$sentinel"
          export MCL_DEPLOY_PREP_EXPECTED_UID="$(stat -c %u ${lib.escapeShellArg prerequisiteRoot})"
          export MCL_DEPLOY_PREP_EXPECTED_GID="$(stat -c %g ${lib.escapeShellArg prerequisiteRoot})"
          unset MCL_DEPLOY_PREP_EXPECTED_LOG_UID MCL_DEPLOY_PREP_EXPECTED_LOG_GID
        }

        assert_transaction_failure_is_restored() {
          local failure="$1"
          local rollback_failure="''${2:-0}"
          reset_transaction_fixture
          transaction_snapshot > "$TMPDIR/$failure.before"
          if MCL_DEPLOY_PREP_INJECT_FAILURE="$failure" \
            MCL_DEPLOY_PREP_INJECT_ROLLBACK_FAILURE="$rollback_failure" \
            "$preparation" > "$TMPDIR/$failure.stdout" 2> "$TMPDIR/$failure.stderr"; then
            echo "transactional path preparation accepted $failure" >&2
            exit 1
          fi
          transaction_snapshot > "$TMPDIR/$failure.after"
          cmp "$TMPDIR/$failure.before" "$TMPDIR/$failure.after"
          if [ "$rollback_failure" = 1 ]; then
            grep -Fq 'injected rollback failure' "$TMPDIR/$failure.stderr"
            grep -Fq 'transactional rollback was incomplete' "$TMPDIR/$failure.stderr"
          else
            ! grep -Fq 'transactional rollback was incomplete' "$TMPDIR/$failure.stderr"
          fi
        }

        # Each failure occurs after at least one mutation. The complete object
        # ledger (including absent paths, inode, ownership, mode, link count, and
        # file content), the shared root, and an unrelated sibling are identical
        # after rollback.
        for failure in late-directory-create late-log-create revalidation; do
          assert_transaction_failure_is_restored "$failure"
        done
        assert_transaction_failure_is_restored revalidation 1

        # The fixture-only executable forwards successful calls to the real
        # coreutils chown, but deterministically fails the selected real
        # generated chown call only after that invocation created the object.
        # Complete before/after ledgers prove rollback removes every created
        # inode and restores every original mode/content.
        assert_generated_chown_failure_is_restored() {
          local kind="$1"
          local log="$TMPDIR/chown-$kind.invocations"
          reset_transaction_fixture
          : > "$log"
          transaction_snapshot > "$TMPDIR/chown-$kind.before"
          if MCL_DEPLOY_PREP_FIXTURE_CHOWN_LOG="$log" \
            MCL_DEPLOY_PREP_FIXTURE_CHOWN_FAIL="$kind" \
            "$preparation" > "$TMPDIR/chown-$kind.stdout" \
            2> "$TMPDIR/chown-$kind.stderr"; then
            echo "generated $kind chown failure unexpectedly succeeded" >&2
            exit 1
          fi
          transaction_snapshot > "$TMPDIR/chown-$kind.after"
          cmp "$TMPDIR/chown-$kind.before" "$TMPDIR/chown-$kind.after"
          test "$(grep -c "^$kind " "$log")" -eq 1
          grep -Fq "could not set managed $kind ownership" "$TMPDIR/chown-$kind.stderr"
          ! grep -Fq 'transactional rollback was incomplete' "$TMPDIR/chown-$kind.stderr"
        }
        assert_generated_chown_failure_is_restored directory
        assert_generated_chown_failure_is_restored log

        prepare_replacement_fixture() {
          reset_transaction_fixture
          mkdir -p \
            ${lib.escapeShellArg prerequisiteRoot}/state/inbox \
            ${lib.escapeShellArg prerequisiteRoot}/logs \
            ${lib.escapeShellArg prerequisiteRoot}/run
          printf 'events-before-replacement\n' > ${lib.escapeShellArg prerequisiteRoot}/logs/events.jsonl
          printf 'stdout-before-replacement\n' > ${lib.escapeShellArg prerequisiteRoot}/logs/stdout.log
          printf 'stderr-before-replacement\n' > ${lib.escapeShellArg prerequisiteRoot}/logs/stderr.log
          chmod 0712 \
            ${lib.escapeShellArg prerequisiteRoot}/state \
            ${lib.escapeShellArg prerequisiteRoot}/state/inbox \
            ${lib.escapeShellArg prerequisiteRoot}/logs \
            ${lib.escapeShellArg prerequisiteRoot}/run
          chmod 0612 \
            ${lib.escapeShellArg prerequisiteRoot}/logs/events.jsonl \
            ${lib.escapeShellArg prerequisiteRoot}/logs/stdout.log \
            ${lib.escapeShellArg prerequisiteRoot}/logs/stderr.log
        }

        replacement_hook=${replacementFixtureHook}

        assert_snapshot_replacement_is_preserved() {
          local kind="$1"
          local target="$2"
          local marker="$TMPDIR/replace-$kind.identity"
          prepare_replacement_fixture
          original_identity="$(stat -c '%d:%i' -- "$target")"
          transaction_snapshot > "$TMPDIR/replace-$kind.before"
          if MCL_DEPLOY_PREP_AFTER_SNAPSHOT_HOOK="$replacement_hook" \
            MCL_DEPLOY_PREP_REPLACE_KIND="$kind" \
            MCL_DEPLOY_PREP_REPLACE_PATH="$target" \
            MCL_DEPLOY_PREP_REPLACE_MARKER="$marker" \
            "$preparation" > "$TMPDIR/replace-$kind.stdout" \
            2> "$TMPDIR/replace-$kind.stderr"; then
            echo "same-owner $kind replacement was accepted" >&2
            exit 1
          fi
          transaction_snapshot > "$TMPDIR/replace-$kind.after"
          test "$(cat "$marker")" != "$original_identity"
          test "$(stat -c '%d:%i' -- "$target")" = "$(cat "$marker")"
          grep -Fq 'snapshotted managed object changed identity' "$TMPDIR/replace-$kind.stderr"
          ! grep -Fq 'transactional rollback was incomplete' "$TMPDIR/replace-$kind.stderr"
          grep -Fv "path=$target " "$TMPDIR/replace-$kind.before" \
            > "$TMPDIR/replace-$kind.before-others"
          grep -Fv "path=$target " "$TMPDIR/replace-$kind.after" \
            > "$TMPDIR/replace-$kind.after-others"
          cmp "$TMPDIR/replace-$kind.before-others" "$TMPDIR/replace-$kind.after-others"
          if [ "$kind" = directory ]; then
            test "$(stat -c %a -- "$target")" = 716
          else
            test "$(stat -c %a -- "$target")" = 603
            grep -Fxq external-replacement-log "$target"
          fi
        }
        assert_snapshot_replacement_is_preserved directory \
          ${lib.escapeShellArg prerequisiteRoot}/run
        assert_snapshot_replacement_is_preserved log \
          ${lib.escapeShellArg prerequisiteRoot}/logs/events.jsonl

        # The chmod failure needs pre-existing objects with deliberately varied
        # modes so it proves those exact original modes, not merely 0750/0640,
        # are restored after a late repair fails.
        reset_transaction_fixture
        mkdir -p \
          ${lib.escapeShellArg prerequisiteRoot}/state/inbox \
          ${lib.escapeShellArg prerequisiteRoot}/logs \
          ${lib.escapeShellArg prerequisiteRoot}/run
        printf 'events-before\n' > ${lib.escapeShellArg prerequisiteRoot}/logs/events.jsonl
        printf 'stdout-before\n' > ${lib.escapeShellArg prerequisiteRoot}/logs/stdout.log
        printf 'stderr-before\n' > ${lib.escapeShellArg prerequisiteRoot}/logs/stderr.log
        chmod 0712 \
          ${lib.escapeShellArg prerequisiteRoot}/state \
          ${lib.escapeShellArg prerequisiteRoot}/state/inbox \
          ${lib.escapeShellArg prerequisiteRoot}/logs \
          ${lib.escapeShellArg prerequisiteRoot}/run
        chmod 0612 \
          ${lib.escapeShellArg prerequisiteRoot}/logs/events.jsonl \
          ${lib.escapeShellArg prerequisiteRoot}/logs/stdout.log \
          ${lib.escapeShellArg prerequisiteRoot}/logs/stderr.log
        transaction_snapshot > "$TMPDIR/late-chmod.before"
        if MCL_DEPLOY_PREP_INJECT_FAILURE=late-chmod \
          "$preparation" > "$TMPDIR/late-chmod.stdout" 2> "$TMPDIR/late-chmod.stderr"; then
          echo 'transactional path preparation accepted late chmod failure' >&2
          exit 1
        fi
        transaction_snapshot > "$TMPDIR/late-chmod.after"
        cmp "$TMPDIR/late-chmod.before" "$TMPDIR/late-chmod.after"

        # Replace one newly created log immediately before rollback. The inode
        # created by this invocation has gone, so rollback preserves the raced
        # replacement byte-for-byte while removing the other created logs.
        reset_transaction_fixture
        mkdir -p \
          ${lib.escapeShellArg prerequisiteRoot}/state/inbox \
          ${lib.escapeShellArg prerequisiteRoot}/logs \
          ${lib.escapeShellArg prerequisiteRoot}/run
        chmod 0712 \
          ${lib.escapeShellArg prerequisiteRoot}/state \
          ${lib.escapeShellArg prerequisiteRoot}/state/inbox \
          ${lib.escapeShellArg prerequisiteRoot}/logs \
          ${lib.escapeShellArg prerequisiteRoot}/run
        rollback_race_hook=${rollbackRaceFixtureHook}
        rollback_race_marker="$TMPDIR/rollback-race-marker"
        if MCL_DEPLOY_PREP_INJECT_FAILURE=revalidation \
          MCL_DEPLOY_PREP_ROLLBACK_HOOK="$rollback_race_hook" \
          MCL_DEPLOY_PREP_RACE_MARKER="$rollback_race_marker" \
          "$preparation" > "$TMPDIR/rollback-race.stdout" 2> "$TMPDIR/rollback-race.stderr"; then
          echo 'transactional path preparation accepted rollback race' >&2
          exit 1
        fi
        raced_log=${lib.escapeShellArg prerequisiteRoot}/logs/stderr.log
        test "$(stat -c '%d:%i' "$raced_log")" = "$(cat "$rollback_race_marker")"
        test "$(stat -c %a "$raced_log")" = 603
        test "$(stat -c %h "$raced_log")" = 1
        grep -Fxq external-race-object "$raced_log"
        test ! -e ${lib.escapeShellArg prerequisiteRoot}/logs/events.jsonl
        test ! -e ${lib.escapeShellArg prerequisiteRoot}/logs/stdout.log
        test "$(stat -c %a ${lib.escapeShellArg prerequisiteRoot}/state)" = 712
        test "$(stat -c %a ${lib.escapeShellArg prerequisiteRoot}/logs)" = 712
        grep -Fq 'rollback preserved raced object' "$TMPDIR/rollback-race.stderr"
        grep -Fq 'transactional rollback was incomplete' "$TMPDIR/rollback-race.stderr"
        grep -Fxq unrelated-transaction-sentinel ${lib.escapeShellArg prerequisiteNamespace}/unrelated
        test "$(stat -c %a /private/tmp)" = "$shared_mode"
        test "$(stat -c %u /private/tmp)" = "$shared_uid"
        test "$(stat -c %g /private/tmp)" = "$shared_gid"

        # A subsequent successful transaction is disarmed only at the very end:
        # every managed object persists with its production mode and no rollback
        # diagnostic is emitted.
        rm -f "$raced_log" "$rollback_race_marker"
        "$preparation" > "$TMPDIR/transaction-success.stdout" 2> "$TMPDIR/transaction-success.stderr"
        test ! -s "$TMPDIR/transaction-success.stderr"
        test "$(stat -c %a ${lib.escapeShellArg prerequisiteRoot}/state)" = 750
        test "$(stat -c %a ${lib.escapeShellArg prerequisiteRoot}/logs)" = 750
        test "$(stat -c %a ${lib.escapeShellArg prerequisiteRoot}/logs/events.jsonl)" = 640
        test "$(stat -c %a ${lib.escapeShellArg prerequisiteRoot}/logs/stdout.log)" = 640
        test "$(stat -c %a ${lib.escapeShellArg prerequisiteRoot}/logs/stderr.log)" = 640

        managed_snapshot() {
          {
            stat -c 'mode=%a uid=%u gid=%g links=%h path=%n' \
              ${lib.escapeShellArg prerequisiteRoot}/state \
              ${lib.escapeShellArg prerequisiteRoot}/logs \
              ${lib.escapeShellArg prerequisiteRoot}/logs/events.jsonl \
              ${lib.escapeShellArg prerequisiteRoot}/logs/stdout.log \
              ${lib.escapeShellArg prerequisiteRoot}/logs/stderr.log
            sha256sum \
              ${lib.escapeShellArg prerequisiteRoot}/logs/events.jsonl \
              ${lib.escapeShellArg prerequisiteRoot}/logs/stdout.log \
              ${lib.escapeShellArg prerequisiteRoot}/logs/stderr.log
          }
        }

        assert_wrong_ownership_is_non_mutating() {
          local variable="$1"
          local value="$2"
          local label="$3"
          chmod 0777 \
            ${lib.escapeShellArg prerequisiteRoot}/state \
            ${lib.escapeShellArg prerequisiteRoot}/logs
          chmod 0666 \
            ${lib.escapeShellArg prerequisiteRoot}/logs/events.jsonl \
            ${lib.escapeShellArg prerequisiteRoot}/logs/stdout.log \
            ${lib.escapeShellArg prerequisiteRoot}/logs/stderr.log
          printf 'events-%s\n' "$label" > ${lib.escapeShellArg prerequisiteRoot}/logs/events.jsonl
          printf 'stdout-%s\n' "$label" > ${lib.escapeShellArg prerequisiteRoot}/logs/stdout.log
          printf 'stderr-%s\n' "$label" > ${lib.escapeShellArg prerequisiteRoot}/logs/stderr.log
          managed_snapshot > "$TMPDIR/$label.before"
          sentinel_before="$(sha256sum "$sentinel")"
          if env "$variable=$value" "$preparation"; then
            echo "path preparation accepted $label" >&2
            exit 1
          fi
          managed_snapshot > "$TMPDIR/$label.after"
          cmp "$TMPDIR/$label.before" "$TMPDIR/$label.after"
          test "$(sha256sum "$sentinel")" = "$sentinel_before"
          test "$(stat -c %a /private/tmp)" = "$shared_mode"
          test "$(stat -c %u /private/tmp)" = "$shared_uid"
          test "$(stat -c %g /private/tmp)" = "$shared_gid"
          "$preparation"
          test "$(stat -c %a ${lib.escapeShellArg prerequisiteRoot}/state)" = 750
          test "$(stat -c %a ${lib.escapeShellArg prerequisiteRoot}/logs)" = 750
          test "$(stat -c %a ${lib.escapeShellArg prerequisiteRoot}/logs/events.jsonl)" = 640
          test "$(stat -c %a ${lib.escapeShellArg prerequisiteRoot}/logs/stdout.log)" = 640
          test "$(stat -c %a ${lib.escapeShellArg prerequisiteRoot}/logs/stderr.log)" = 640
        }

        # UID and GID are independent fail-closed checks for existing managed
        # directories and existing managed logs. Deliberately wrong modes on
        # earlier paths prove a later failure cannot partially repair the set.
        assert_wrong_ownership_is_non_mutating \
          MCL_DEPLOY_PREP_EXPECTED_UID "$(( MCL_DEPLOY_PREP_EXPECTED_UID + 1 ))" directory-wrong-uid
        assert_wrong_ownership_is_non_mutating \
          MCL_DEPLOY_PREP_EXPECTED_GID "$(( MCL_DEPLOY_PREP_EXPECTED_GID + 1 ))" directory-wrong-gid
        assert_wrong_ownership_is_non_mutating \
          MCL_DEPLOY_PREP_EXPECTED_LOG_UID "$(( MCL_DEPLOY_PREP_EXPECTED_UID + 1 ))" log-wrong-uid
        assert_wrong_ownership_is_non_mutating \
          MCL_DEPLOY_PREP_EXPECTED_LOG_GID "$(( MCL_DEPLOY_PREP_EXPECTED_GID + 1 ))" log-wrong-gid

        race_hook=${createRaceFixtureHook}

        # A path that appears after the validation pass is never adopted and
        # never chmod/chowned by this invocation.
        rm -rf ${lib.escapeShellArg prerequisiteRoot}
        if MCL_DEPLOY_PREP_BEFORE_CREATE_HOOK="$race_hook" "$preparation"; then
          echo 'path preparation adopted a racing directory' >&2
          exit 1
        fi
        test -d ${lib.escapeShellArg prerequisiteRoot}
        test "$(stat -c %a ${lib.escapeShellArg prerequisiteRoot})" = 750
        "$preparation"
        rm -f ${lib.escapeShellArg prerequisiteRoot}/logs/events.jsonl
        if MCL_DEPLOY_PREP_BEFORE_CREATE_HOOK="$race_hook" "$preparation"; then
          echo 'path preparation adopted a racing log' >&2
          exit 1
        fi
        grep -Fxq racing-log ${lib.escapeShellArg prerequisiteRoot}/logs/events.jsonl
        test "$(stat -c %a ${lib.escapeShellArg prerequisiteRoot}/logs/events.jsonl)" = 600
        rm -f ${lib.escapeShellArg prerequisiteRoot}/logs/events.jsonl
        "$preparation"
        rm -rf ${lib.escapeShellArg prerequisiteRoot}
        mkdir -p "$symlink_target"
        printf 'symlink-target\n' > "$symlink_target/sentinel"
        ln -s "$symlink_target" ${lib.escapeShellArg prerequisiteRoot}
        if "$preparation"; then
          echo 'path preparation followed a symlink component' >&2
          exit 1
        fi
        grep -Fxq symlink-target "$symlink_target/sentinel"
        rm -f ${lib.escapeShellArg prerequisiteRoot}
        mkdir -p ${lib.escapeShellArg prerequisiteRoot}
        "$preparation"
        rm -f ${lib.escapeShellArg prerequisiteRoot}/logs/events.jsonl
        ln -s "$sentinel" ${lib.escapeShellArg prerequisiteRoot}/logs/events.jsonl
        if "$preparation"; then
          echo 'path preparation followed a symlink log' >&2
          exit 1
        fi
        test "$(sha256sum "$sentinel" | cut -d ' ' -f 1)" = "$sentinel_sha"
        test "$(stat -c %a "$sentinel")" = 711

        # A regular file with another directory entry is still unsafe: reject
        # the actual managed event inode before chmod/chown can affect its peer.
        rm -f ${lib.escapeShellArg prerequisiteRoot}/logs/events.jsonl
        "$preparation"
        printf 'managed-event-sentinel\n' > ${lib.escapeShellArg prerequisiteRoot}/logs/events.jsonl
        event_sha="$(sha256sum ${lib.escapeShellArg prerequisiteRoot}/logs/events.jsonl | cut -d ' ' -f 1)"
        ln ${lib.escapeShellArg prerequisiteRoot}/logs/events.jsonl "$hardlink_peer"
        test "$(stat -c %h ${lib.escapeShellArg prerequisiteRoot}/logs/events.jsonl)" = 2
        test "$(stat -c %h "$hardlink_peer")" = 2
        if "$preparation"; then
          echo 'path preparation accepted a hard-linked log' >&2
          exit 1
        fi
        test "$(sha256sum ${lib.escapeShellArg prerequisiteRoot}/logs/events.jsonl | cut -d ' ' -f 1)" = "$event_sha"
        test "$(sha256sum "$hardlink_peer" | cut -d ' ' -f 1)" = "$event_sha"
        test "$(sha256sum "$sentinel" | cut -d ' ' -f 1)" = "$sentinel_sha"
        test "$(stat -c %a /private/tmp)" = "$shared_mode"
        test "$(stat -c %u /private/tmp)" = "$shared_uid"
        test "$(stat -c %g /private/tmp)" = "$shared_gid"
        rm -f "$hardlink_peer"
        "$preparation"
        rm -rf ${lib.escapeShellArg prerequisiteNamespace} "$symlink_target"
        rm -f "$sentinel" "$hardlink_peer"

        prerequisite_entrypoint=${lib.escapeShellArg (lib.getExe prerequisiteEntrypointPackage)}
        rm -rf ${lib.escapeShellArg prerequisiteRoot}
        export MCL_DARWIN_PREREQUISITE_MARKER=${lib.escapeShellArg prerequisiteRoot}/mcl-ran
        if "$prerequisite_entrypoint"; then
          echo 'failing runtime prerequisite was ignored' >&2
          exit 1
        else
          test "$?" -eq 75
        fi
        test ! -e ${lib.escapeShellArg prerequisiteRoot}
        mkdir -p "$out"
        printf '%s\n' 'test_darwin_pull_agent_launchd_contract: passed' > "$out/result"
      '';

      generationStabilityCheck =
        pkgs.runCommand "test-darwin-pull-agent-entrypoint-survives-generation-change" { }
          ''
            test ${lib.escapeShellArg (toString staticServiceA.Label)} = ${lib.escapeShellArg (toString staticServiceB.Label)}
            test ${lib.escapeShellArg (builtins.toJSON staticServiceA.ProgramArguments)} = ${lib.escapeShellArg (builtins.toJSON staticServiceB.ProgramArguments)}
            launcher=${lib.escapeShellArg (lib.getExe staticLaunchdLauncherPackage)}
            test "$(printf '%s' ${lib.escapeShellArg (builtins.toJSON staticServiceA.ProgramArguments)} | ${pkgs.jq}/bin/jq -r '.[4]')" = "$launcher"
            test "$launcher" != ${lib.escapeShellArg stableEntrypoint}
            test ${lib.escapeShellArg (lib.getExe staticEntrypointPackage)} != ${lib.escapeShellArg (lib.getExe staticEntrypointPackageB)}
            test ${lib.escapeShellArg (lib.getExe staticLaunchdLauncherPackage)} = ${lib.escapeShellArg (lib.getExe staticLaunchdLauncherPackageB)}
            test -x ${lib.escapeShellArg (lib.getExe staticEntrypointPackage)}
            test -x ${lib.escapeShellArg (lib.getExe staticEntrypointPackageB)}
            test -L ${lib.escapeShellArg staticSystemEntrypoint}
            test -L ${lib.escapeShellArg staticSystemEntrypointB}
            test "$(readlink ${lib.escapeShellArg staticSystemEntrypoint})" = ${lib.escapeShellArg (lib.getExe staticEntrypointPackage)}
            test "$(readlink ${lib.escapeShellArg staticSystemEntrypointB})" = ${lib.escapeShellArg (lib.getExe staticEntrypointPackageB)}

            # Simulate nix-darwin's first-enable ordering with the exact
            # evaluated launcher: launchd starts it while the current-system
            # entrypoint is absent, then activation publishes that executable.
            fixture="$TMPDIR/first-enable/current-system/sw/bin/mcl-deploy-agent"
            mkdir -p "$(dirname "$fixture")"
            "$launcher" "$fixture" 100 0.01 > "$TMPDIR/first-enable.stdout" \
              2> "$TMPDIR/first-enable.stderr" &
            launcher_pid=$!
            sleep 0.05
            kill -0 "$launcher_pid"
            printf '%s\n' '#!/bin/sh' 'printf "%s\\n" first-enable-ran' > "$fixture"
            chmod +x "$fixture"
            wait "$launcher_pid"
            grep -Fxq first-enable-ran "$TMPDIR/first-enable.stdout"
            test ! -s "$TMPDIR/first-enable.stderr"

            # Permanent absence is bounded and diagnostic rather than an
            # ENOENT launch failure or an activation-long hang.
            if "$launcher" "$TMPDIR/permanently-absent" 2 0.01 \
              > "$TMPDIR/absent.stdout" 2> "$TMPDIR/absent.stderr"; then
              echo 'immutable launchd launcher accepted a permanently absent entrypoint' >&2
              exit 1
            else
              test "$?" -eq 75
            fi
            grep -Fq 'entrypoint unavailable after 2 attempts' "$TMPDIR/absent.stderr"
            test ! -s "$TMPDIR/absent.stdout"
            if "$launcher" 'relative/path' 2 0.01 >/dev/null 2>&1; then
              echo 'immutable launchd launcher accepted a relative executable path' >&2
              exit 1
            else
              test "$?" -eq 64
            fi
            mkdir -p "$out"
            printf '%s\n' 'test_darwin_pull_agent_entrypoint_survives_generation_change: passed' > "$out/result"
          '';

      integrationNamespace = "/private/tmp/mcl-darwin-pull-agent-integration";
      integrationRoot = "${integrationNamespace}/agent";
      lockNamespace = "/private/tmp/mcl-darwin-pull-agent-lock";
      lockRoot = "${lockNamespace}/agent";
      preSwitchHook = pkgs.writeShellScript "mcl-darwin-pull-agent-pre-switch" ''
        set -eu
        test -n "''${MCL_DARWIN_TEST_ROOT:-}"
        printf '%s\n%s\n' "$1" "$2" > "$MCL_DARWIN_TEST_ROOT/pre-switch-ran"
      '';
      postSwitchHook = pkgs.writeShellScript "mcl-darwin-pull-agent-post-switch" ''
        set -eu
        test -n "''${MCL_DARWIN_TEST_ROOT:-}"
        printf '%s\n%s\n%s\n' "$1" "$2" "$3" > "$MCL_DARWIN_TEST_ROOT/post-switch-ran"
      '';
      alreadyCurrentRecoveryHook = pkgs.writeShellScript "mcl-darwin-pull-agent-already-current-recovery" ''
        set -eu
        test -n "''${MCL_DARWIN_TEST_ROOT:-}"
        test "$1" = "$2"
        printf '%s\n' "$1" >> "$MCL_DARWIN_TEST_ROOT/already-current-recovery-runs"
        if test -e "$MCL_DARWIN_TEST_ROOT/pending-lifecycle-recovery"; then
          printf 'pending\n' >> "$MCL_DARWIN_TEST_ROOT/already-current-recovery-states"
          if test -e "$MCL_DARWIN_TEST_ROOT/fail-lifecycle-recovery"; then
            exit 91
          fi
          rm "$MCL_DARWIN_TEST_ROOT/pending-lifecycle-recovery"
          printf 'recovered\n' >> "$MCL_DARWIN_TEST_ROOT/already-current-recovery-states"
        else
          printf 'clean\n' >> "$MCL_DARWIN_TEST_ROOT/already-current-recovery-states"
        fi
      '';
      blockingPreSwitchHook = pkgs.writeShellScript "mcl-darwin-pull-agent-blocking-pre-switch" ''
        set -eu
        test -n "''${MCL_DARWIN_TEST_ROOT:-}"
        printf 'entered\n' >> "$MCL_DARWIN_TEST_ROOT/pre-switch-runs"
        touch "$MCL_DARWIN_TEST_ROOT/pre-switch-entered"
        sleep 8
        exit 75
      '';

      integrationSystem = checkedSystem "agent integration fixture" (
        inputs.nix-darwin.lib.darwinSystem {
          system = pkgs.stdenv.hostPlatform.system;
          modules = [
            flake.modules.darwin.deployment-pull-agent
            {
              networking.hostName = "m3";
              system.stateVersion = 6;
              services.mcl-deploy-agent = fixturePathOptions // {
                enable = true;
                package = self'.packages.mcl-devops;
                targetName = "m3";
                manifestPublicKeys = [ manifestPublicKey ];
                manifestDirectories = [ "${integrationRoot}/state/inbox" ];
                stateDir = "${integrationRoot}/state";
                eventLog = "${integrationRoot}/logs/events.jsonl";
                standardOutLog = "${integrationRoot}/logs/stdout.log";
                standardErrorLog = "${integrationRoot}/logs/stderr.log";
                lockFile = "${integrationRoot}/run/agent.lock";
                systemProfile = "${integrationRoot}/system-profile";
                inherit alreadyCurrentRecoveryHook preSwitchHook postSwitchHook;
                maxAttempts = 2;
                fetchTimeoutSeconds = 7;
              };
            }
          ];
        }
      );
      integrationEntrypointPackage =
        lib.findFirst (package: lib.getName package == "mcl-deploy-agent")
          (throw "integration Darwin pull-agent entrypoint package is absent")
          integrationSystem.config.environment.systemPackages;
      integrationPreparationPackage =
        integrationSystem.config.services.mcl-deploy-agent.preparationPackage;

      generationActivation = pkgs.writeShellScript "mcl-darwin-pull-agent-activate" ''
        set -eu
        test -n "''${MCL_DARWIN_TEST_ROOT:-}"
        printf '%s\n' "$(dirname "$0")" >> "$MCL_DARWIN_TEST_ROOT/activation-runs"
      '';
      generation =
        name:
        pkgs.runCommand "mcl-darwin-pull-agent-generation-${name}" { } ''
          mkdir -p "$out"
          cp ${generationActivation} "$out/activate"
        '';
      previousGeneration = generation "previous";
      desiredGeneration = generation "desired";
      profileClosure = pkgs.closureInfo {
        rootPaths = [
          previousGeneration
          desiredGeneration
        ];
      };

      lockSystem = checkedSystem "lock-contention fixture" (
        inputs.nix-darwin.lib.darwinSystem {
          system = pkgs.stdenv.hostPlatform.system;
          modules = [
            flake.modules.darwin.deployment-pull-agent
            {
              networking.hostName = "m3";
              system.stateVersion = 6;
              services.mcl-deploy-agent = fixturePathOptions // {
                enable = true;
                package = self'.packages.mcl-devops;
                targetName = "m3";
                manifestPublicKeys = [ manifestPublicKey ];
                manifestDirectories = [ "${lockRoot}/state/inbox" ];
                stateDir = "${lockRoot}/state";
                eventLog = "${lockRoot}/logs/events.jsonl";
                standardOutLog = "${lockRoot}/logs/stdout.log";
                standardErrorLog = "${lockRoot}/logs/stderr.log";
                lockFile = "${lockRoot}/run/agent.lock";
                systemProfile = "${lockRoot}/system-profile";
                preSwitchHook = blockingPreSwitchHook;
                inherit alreadyCurrentRecoveryHook postSwitchHook;
                maxAttempts = 1;
              };
            }
          ];
        }
      );
      lockEntrypointPackage =
        lib.findFirst (package: lib.getName package == "mcl-deploy-agent")
          (throw "lock-test Darwin pull-agent entrypoint package is absent")
          lockSystem.config.environment.systemPackages;
      lockPreparationPackage = lockSystem.config.services.mcl-deploy-agent.preparationPackage;

      darwinIntegrationCheck =
        pkgs.runCommand "deployment-pull-agent-darwin-integration"
          {
            nativeBuildInputs = [
              self'.packages.mcl-devops
              pkgs.coreutils
              pkgs.jq
              pkgs.nix
              pkgs.openssh
              (pkgs.python3.withPackages (pythonPackages: [ pythonPackages.jsonschema ]))
            ];
          }
          ''
                    set -euo pipefail
                    cleanup() {
                      rm -rf ${lib.escapeShellArg integrationNamespace} ${lib.escapeShellArg lockNamespace}
                    }
                    trap cleanup EXIT
                    cleanup

                    key="$TMPDIR/manifest-key"
                    cp ${manifestPrivateKey} "$key"
                    chmod 0600 "$key"

                    make_manifest() {
                      local target=$1
                      local desired=$2
                  local sequence=$3
                  local output=$4
                  local revision=''${5:-0123456789abcdef0123456789abcdef01234567}
                  local run_id=''${6:-darwin-integration-$sequence}
                  local -a extra_args=()
                  if [[ $# -gt 6 ]]; then
                    extra_args=("''${@:7}")
                  fi
                  GITHUB_RUN_ID="$run_id" mcl-devops deploy-plan \
                        --target "$target" \
                        --system aarch64-darwin \
                        --desired-system-path "$desired" \
                        --git-revision "$revision" \
                        --sequence "$sequence" \
                        --signing-key "$key" \
                        --signing-key-id mcl-deployment \
                        --output "$output" \
                        "''${extra_args[@]}"
                    }

            validate_event_log() {
              python ${eventLogValidator} "$1" ${../docs/deployment/event-schema.json}
            }

                    entrypoint=${lib.escapeShellArg (lib.getExe integrationEntrypointPackage)}
                    system_entrypoint=${lib.escapeShellArg "${integrationSystem.config.system.path}/bin/mcl-deploy-agent"}
                    test -x "$entrypoint"
                    test -L "$system_entrypoint"
                    test "$(readlink "$system_entrypoint")" = "$entrypoint"
                    mkdir -p ${lib.escapeShellArg integrationNamespace}
                    export MCL_DEPLOY_PREP_EXPECTED_UID="$(stat -c %u ${lib.escapeShellArg integrationNamespace})"
                    export MCL_DEPLOY_PREP_EXPECTED_GID="$(stat -c %g ${lib.escapeShellArg integrationNamespace})"
                    ${lib.escapeShellArg (lib.getExe integrationPreparationPackage)}
                    export MCL_DARWIN_TEST_ROOT=${lib.escapeShellArg integrationRoot}
                    export HOME=${lib.escapeShellArg integrationRoot}/home
                    export XDG_CACHE_HOME=${lib.escapeShellArg integrationRoot}/cache
                    export NIX_CONFIG='experimental-features = nix-command'
                    export NIX_STATE_DIR=${lib.escapeShellArg integrationRoot}/nix-state
                    export NIX_PROFILES_DIR="$NIX_STATE_DIR/profiles"
                    export NIX_USER_PROFILE_DIR="$NIX_PROFILES_DIR/per-user/$(id -un)"
                    mkdir -p \
                      "$HOME" \
                      "$XDG_CACHE_HOME" \
                      "$NIX_STATE_DIR/gcroots/auto" \
                      "$NIX_STATE_DIR/temproots" \
                      "$NIX_USER_PROFILE_DIR"
                    nix-store --init
                    nix-store --load-db < ${profileClosure}/registration
                    nix-env --profile ${lib.escapeShellArg integrationRoot}/system-profile --set ${previousGeneration}

                    # test_darwin_pull_agent_rejects_untrusted_and_wrong_target_manifests:
                    # an absent desired state fails closed before any lifecycle hook.
                    "$entrypoint"
                    jq -e '.currentState == "waiting" and .attempts == 0 and .retryable == true' \
                      ${lib.escapeShellArg integrationRoot}/state/agent-status/m3.json >/dev/null
                    test "$(nix-store --realise ${lib.escapeShellArg integrationRoot}/system-profile)" = ${previousGeneration}
                    test ! -e ${lib.escapeShellArg integrationRoot}/pre-switch-ran
                    test ! -e ${lib.escapeShellArg integrationRoot}/post-switch-ran
                    test ! -e ${lib.escapeShellArg integrationRoot}/activation-runs

                    make_manifest other-target ${desiredGeneration} 1 ${lib.escapeShellArg integrationRoot}/state/inbox/wrong-target.json
                    if "$entrypoint"; then
                      echo 'agent accepted a wrong-target manifest' >&2
                      exit 1
                    fi
                    jq -e '.currentState == "non-retryable" and .errorCode == "wrong_target" and .observedTarget == "other-target"' \
                      ${lib.escapeShellArg integrationRoot}/state/agent-status/m3.json >/dev/null
                    test "$(nix-store --realise ${lib.escapeShellArg integrationRoot}/system-profile)" = ${previousGeneration}
                    test ! -e ${lib.escapeShellArg integrationRoot}/pre-switch-ran
                    test ! -e ${lib.escapeShellArg integrationRoot}/post-switch-ran
                    test ! -e ${lib.escapeShellArg integrationRoot}/activation-runs

                    rm -rf ${lib.escapeShellArg integrationRoot}/state
                    mkdir -p ${lib.escapeShellArg integrationRoot}/state/inbox
                    make_manifest m3 ${desiredGeneration} 2 ${lib.escapeShellArg integrationRoot}/state/inbox/tampered.json
                    jq '.desiredSystemPath = "${previousGeneration}"' \
                      ${lib.escapeShellArg integrationRoot}/state/inbox/tampered.json > ${lib.escapeShellArg integrationRoot}/state/inbox/tampered.tmp
                    mv ${lib.escapeShellArg integrationRoot}/state/inbox/tampered.tmp ${lib.escapeShellArg integrationRoot}/state/inbox/tampered.json
                    if "$entrypoint"; then
                      echo 'agent accepted a manifest whose signed content was changed' >&2
                      exit 1
                    fi
                    jq -e '.currentState == "non-retryable" and .errorCode == "invalid_signature" and .retryable == false' \
                      ${lib.escapeShellArg integrationRoot}/state/agent-status/m3.json >/dev/null
                    test "$(nix-store --realise ${lib.escapeShellArg integrationRoot}/system-profile)" = ${previousGeneration}
                    test ! -e ${lib.escapeShellArg integrationRoot}/pre-switch-ran
                    test ! -e ${lib.escapeShellArg integrationRoot}/post-switch-ran
                    test ! -e ${lib.escapeShellArg integrationRoot}/activation-runs

                    # A correctly signed target manifest proves that this same generated
                    # entrypoint can reach the real profile, lifecycle, and activation path.
                    rm -rf ${lib.escapeShellArg integrationRoot}/state
                    mkdir -p ${lib.escapeShellArg integrationRoot}/state/inbox
                    make_manifest m3 ${desiredGeneration} 3 ${lib.escapeShellArg integrationRoot}/state/inbox/trusted.json
                    "$entrypoint"
                    jq -e '.currentState == "succeeded" and .attempts == 1' \
                      ${lib.escapeShellArg integrationRoot}/state/agent-status/m3.json >/dev/null
                    test "$(nix-store --realise ${lib.escapeShellArg integrationRoot}/system-profile)" = ${desiredGeneration}
                    test "$(cat ${lib.escapeShellArg integrationRoot}/activation-runs)" = ${desiredGeneration}
                    test "$(sed -n '1p' ${lib.escapeShellArg integrationRoot}/pre-switch-ran)" = ${desiredGeneration}
                    test "$(sed -n '2p' ${lib.escapeShellArg integrationRoot}/pre-switch-ran)" = ${previousGeneration}
                    test "$(sed -n '1p' ${lib.escapeShellArg integrationRoot}/post-switch-ran)" = ${desiredGeneration}
                    test "$(sed -n '2p' ${lib.escapeShellArg integrationRoot}/post-switch-ran)" = ${previousGeneration}
                    test "$(sed -n '3p' ${lib.escapeShellArg integrationRoot}/post-switch-ran)" = succeeded
                    validate_event_log ${lib.escapeShellArg integrationRoot}/logs/events.jsonl
                    jq -e -s '
                      length > 0 and
                      all(.[]; .target.kind == "darwin" and .target.name == "m3") and
                      any(.[]; .phase == "complete" and .command.status == "succeeded")
                    ' ${lib.escapeShellArg integrationRoot}/logs/events.jsonl >/dev/null

                    # test_darwin_pull_agent_rejects_invalid_durable_state: the
                    # high-water record is the full signed manifest. A malformed,
                    # mismatched, or signature-invalid copy must never suppress a later
                    # authentic desired state or reach any activation surface.
                    target_record=${lib.escapeShellArg integrationRoot}/state/targets/m3.json
                    authentic_target="$TMPDIR/authentic-target.json"
                    cp "$target_record" "$authentic_target"
                    trusted_id=$(jq -r .deploymentId "$authentic_target")
                    future_manifest=${lib.escapeShellArg integrationRoot}/state/inbox/future.json
                    make_manifest m3 ${previousGeneration} 4 "$future_manifest"
                    future_id=$(jq -r .deploymentId "$future_manifest")

                    trusted_desired=${lib.escapeShellArg integrationRoot}/state/desired/"$trusted_id".json
                    trusted_current=${lib.escapeShellArg integrationRoot}/state/current/"$trusted_id".json
                    trusted_converged=${lib.escapeShellArg integrationRoot}/state/converged/"$trusted_id".json
                    desired_sha=$(sha256sum "$trusted_desired" | cut -d' ' -f1)
                    current_sha=$(sha256sum "$trusted_current" | cut -d' ' -f1)
                    converged_sha=$(sha256sum "$trusted_converged" | cut -d' ' -f1)
                    events_sha=$(sha256sum ${lib.escapeShellArg integrationRoot}/logs/events.jsonl | cut -d' ' -f1)
                    activation_sha=$(sha256sum ${lib.escapeShellArg integrationRoot}/activation-runs | cut -d' ' -f1)
                    pre_sha=$(sha256sum ${lib.escapeShellArg integrationRoot}/pre-switch-ran | cut -d' ' -f1)
                    post_sha=$(sha256sum ${lib.escapeShellArg integrationRoot}/post-switch-ran | cut -d' ' -f1)

                    assert_invalid_durable_refusal() {
                      local variant=$1
                      local corrupt_sha
                      corrupt_sha=$(sha256sum "$target_record" | cut -d' ' -f1)
                      if "$entrypoint"; then
                        echo "agent accepted invalid durable state: $variant" >&2
                        exit 1
                      fi
                      jq -e \
                        --arg deployment_id "$future_id" \
                        '.deploymentId == $deployment_id
                          and .sequence == 4
                          and .currentState == "non-retryable"
                          and .errorCode == "invalid_durable_state"
                          and .attempts == 0
                          and .retryable == false' \
                        ${lib.escapeShellArg integrationRoot}/state/agent-status/m3.json >/dev/null
                      test "$(sha256sum "$target_record" | cut -d' ' -f1)" = "$corrupt_sha"
                      test "$(sha256sum "$trusted_desired" | cut -d' ' -f1)" = "$desired_sha"
                      test "$(sha256sum "$trusted_current" | cut -d' ' -f1)" = "$current_sha"
                      test "$(sha256sum "$trusted_converged" | cut -d' ' -f1)" = "$converged_sha"
                      test "$(sha256sum ${lib.escapeShellArg integrationRoot}/logs/events.jsonl | cut -d' ' -f1)" = "$events_sha"
                      test "$(sha256sum ${lib.escapeShellArg integrationRoot}/activation-runs | cut -d' ' -f1)" = "$activation_sha"
                      test "$(sha256sum ${lib.escapeShellArg integrationRoot}/pre-switch-ran | cut -d' ' -f1)" = "$pre_sha"
                      test "$(sha256sum ${lib.escapeShellArg integrationRoot}/post-switch-ran | cut -d' ' -f1)" = "$post_sha"
                      test "$(nix-store --realise ${lib.escapeShellArg integrationRoot}/system-profile)" = ${desiredGeneration}
                      test ! -e ${lib.escapeShellArg integrationRoot}/state/desired/"$future_id".json
                      test ! -e ${lib.escapeShellArg integrationRoot}/state/current/"$future_id".json
                      test ! -e ${lib.escapeShellArg integrationRoot}/state/converged/"$future_id".json
                      test ! -e ${lib.escapeShellArg integrationRoot}/state/superseded/"$future_id".json
                      cp "$authentic_target" "$target_record"
                    }

                    printf '%s' '{not-json' > "$target_record"
                    assert_invalid_durable_refusal parse-invalid

                    printf '%s' '{"deploymentId":42,"sequence":"bad","target":{"name":"m3"}}' \
                      > "$target_record"
                    assert_invalid_durable_refusal wrong-types

                    printf '%s' '{}' > "$target_record"
                    assert_invalid_durable_refusal missing-fields

                    make_manifest other-target ${desiredGeneration} 98 "$TMPDIR/wrong-target-durable.json"
                    cp "$TMPDIR/wrong-target-durable.json" "$target_record"
                    assert_invalid_durable_refusal wrong-target

                    jq '.sequence = 999' "$authentic_target" > "$target_record"
                    assert_invalid_durable_refusal tampered-sequence

                    jq '.manifestSignature.signature = "not-an-openssh-signature"' \
                      "$authentic_target" > "$target_record"
                    assert_invalid_durable_refusal tampered-signature

                    # Restoring the authentic sequence-3 record lets the already
                    # published signed sequence-4 candidate converge. This proves a
                    # forged high-water value cannot permanently suppress it.
                    "$entrypoint"
                    jq -e \
                      --arg deployment_id "$future_id" \
                      '.deploymentId == $deployment_id
                        and .sequence == 4
                        and .currentState == "succeeded"
                        and .attempts == 1' \
                      ${lib.escapeShellArg integrationRoot}/state/agent-status/m3.json >/dev/null
                    jq -e \
                      --arg deployment_id "$future_id" \
                      '.deploymentId == $deployment_id and .sequence == 4' \
                      "$target_record" >/dev/null
                    test "$(nix-store --realise ${lib.escapeShellArg integrationRoot}/system-profile)" = ${previousGeneration}
                    test -e ${lib.escapeShellArg integrationRoot}/state/converged/"$future_id".json
                    validate_event_log ${lib.escapeShellArg integrationRoot}/logs/events.jsonl

                    # test_darwin_pull_agent_already_current_recovers_lifecycle_before_convergence:
                    # a new revision and higher signed sequence may publish the exact
                    # generation already selected by the system profile. Authentication and
                    # durable high-water identity must advance, but convergence requires the
                    # dedicated recovery-only contract to certify or restore host lifecycle
                    # state. Failure remains retryable with zero transaction attempts; success
                    # then converges without restore, ordinary lifecycle hooks, profile
                    # selection, activation, health checks, or rollback. The poison restore
                    # and byte snapshots enforce those boundaries.
                    already_current=${lib.escapeShellArg integrationRoot}/state/inbox/already-current.json
                    make_manifest \
                      m3 \
                      ${previousGeneration} \
                      5 \
                      "$already_current" \
                      5555555555555555555555555555555555555555 \
                      darwin-already-current-5 \
                      --health-command 'already-current-health|5|printf health > "$MCL_DARWIN_TEST_ROOT/unexpected-health"; exit 97'
                    already_current_id=$(jq -r .deploymentId "$already_current")
                    test "$already_current_id" != "$future_id"

                    profile_link_before=$(readlink ${lib.escapeShellArg integrationRoot}/system-profile)
                    profile_generation_before=$(nix-store --realise ${lib.escapeShellArg integrationRoot}/system-profile)
                    activation_before=$(sha256sum ${lib.escapeShellArg integrationRoot}/activation-runs | cut -d' ' -f1)
                    pre_before=$(sha256sum ${lib.escapeShellArg integrationRoot}/pre-switch-ran | cut -d' ' -f1)
                    post_before=$(sha256sum ${lib.escapeShellArg integrationRoot}/post-switch-ran | cut -d' ' -f1)
                    export MCL_DEPLOY_RESTORE_COMMAND='printf restore > "$MCL_DARWIN_TEST_ROOT/unexpected-restore"; exit 97'
                    touch \
                      ${lib.escapeShellArg integrationRoot}/pending-lifecycle-recovery \
                      ${lib.escapeShellArg integrationRoot}/fail-lifecycle-recovery
                    if "$entrypoint"; then
                      echo 'agent converged while already-current lifecycle recovery failed' >&2
                      exit 1
                    fi

                    already_current_status=${lib.escapeShellArg integrationRoot}/state/agent-status/m3.json
                    already_current_target=${lib.escapeShellArg integrationRoot}/state/targets/m3.json
                    already_current_desired=${lib.escapeShellArg integrationRoot}/state/desired/"$already_current_id".json
                    already_current_state=${lib.escapeShellArg integrationRoot}/state/current/"$already_current_id".json
                    already_current_converged=${lib.escapeShellArg integrationRoot}/state/converged/"$already_current_id".json
                    jq -e \
                      --arg deployment_id "$already_current_id" \
                      '.deploymentId == $deployment_id
                        and .sequence == 5
                        and .currentState == "failed"
                        and .attempts == 0
                        and .maxAttempts == 2
                        and .retryable == true
                        and .errorCode == "already_current_recovery_failed"' \
                      "$already_current_status" >/dev/null
                    test -e ${lib.escapeShellArg integrationRoot}/pending-lifecycle-recovery
                    test "$(wc -l < ${lib.escapeShellArg integrationRoot}/already-current-recovery-runs | tr -d ' ')" = 1
                    test "$(tail -n1 ${lib.escapeShellArg integrationRoot}/already-current-recovery-states)" = pending
                    test ! -e "$already_current_converged"
                    test ! -e ${lib.escapeShellArg integrationRoot}/unexpected-restore
                    test ! -e ${lib.escapeShellArg integrationRoot}/unexpected-health
                    test "$(readlink ${lib.escapeShellArg integrationRoot}/system-profile)" = "$profile_link_before"
                    test "$(sha256sum ${lib.escapeShellArg integrationRoot}/activation-runs | cut -d' ' -f1)" = "$activation_before"
                    test "$(sha256sum ${lib.escapeShellArg integrationRoot}/pre-switch-ran | cut -d' ' -f1)" = "$pre_before"
                    test "$(sha256sum ${lib.escapeShellArg integrationRoot}/post-switch-ran | cut -d' ' -f1)" = "$post_before"

                    rm ${lib.escapeShellArg integrationRoot}/fail-lifecycle-recovery
                    "$entrypoint"
                    unset MCL_DEPLOY_RESTORE_COMMAND

                    jq -e \
                      --arg deployment_id "$already_current_id" \
                      '.deploymentId == $deployment_id
                        and .sequence == 5
                        and .currentState == "succeeded"
                        and .attempts == 0
                        and .maxAttempts == 2
                        and .retryable == false' \
                      "$already_current_status" >/dev/null
                    cmp "$already_current" "$already_current_target"
                    jq -e \
                      '.sequence == 5
                        and .gitRevision == "5555555555555555555555555555555555555555"
                        and .desiredSystemPath == "${previousGeneration}"' \
                      "$already_current_desired" >/dev/null
                    jq -e '.sequence == 5 and .currentState == "accepted"' \
                      "$already_current_state" >/dev/null
                    jq -e '.sequence == 5 and .currentState == "succeeded"' \
                      "$already_current_converged" >/dev/null
                    test "$(readlink ${lib.escapeShellArg integrationRoot}/system-profile)" = "$profile_link_before"
                    test "$(nix-store --realise ${lib.escapeShellArg integrationRoot}/system-profile)" = "$profile_generation_before"
                    test "$profile_generation_before" = ${previousGeneration}
                    test "$(sha256sum ${lib.escapeShellArg integrationRoot}/activation-runs | cut -d' ' -f1)" = "$activation_before"
                    test "$(sha256sum ${lib.escapeShellArg integrationRoot}/pre-switch-ran | cut -d' ' -f1)" = "$pre_before"
                    test "$(sha256sum ${lib.escapeShellArg integrationRoot}/post-switch-ran | cut -d' ' -f1)" = "$post_before"
                    test ! -e ${lib.escapeShellArg integrationRoot}/unexpected-restore
                    test ! -e ${lib.escapeShellArg integrationRoot}/unexpected-health
                    test ! -e ${lib.escapeShellArg integrationRoot}/pending-lifecycle-recovery
                    test "$(wc -l < ${lib.escapeShellArg integrationRoot}/already-current-recovery-runs | tr -d ' ')" = 2
                    test "$(tail -n1 ${lib.escapeShellArg integrationRoot}/already-current-recovery-states)" = recovered
                    validate_event_log ${lib.escapeShellArg integrationRoot}/logs/events.jsonl
                    jq -e -s \
                      --arg deployment_id "$already_current_id" \
                      '[.[] | select(.deploymentId == $deployment_id)] as $events
                        | ($events | length) == 4
                        and ($events[0].phase == "activate-requested")
                        and ($events[1].phase == "complete")
                        and ($events[1].command.status == "failed")
                        and ($events[1].error.code == "already_current_recovery_failed")
                        and ($events[1].metadata.outcome == "already-current-recovery-failed")
                        and ($events[2].phase == "activate-requested")
                        and ($events[3].phase == "complete")
                        and ($events[3].command.status == "succeeded")
                        and ($events[3].metadata.outcome == "already-current")
                        and ($events[3].metadata.lifecycleRecoveryChecked == true)
                        and ($events[3].metadata.previousGeneration == "${previousGeneration}")
                        and ($events[3].metadata.newGeneration == "${previousGeneration}")
                        and all($events[];
                          .phase != "agent-restore"
                          and .phase != "switch"
                          and .phase != "healthcheck"
                          and .phase != "rollback")' \
                      ${lib.escapeShellArg integrationRoot}/logs/events.jsonl >/dev/null

                    already_current_target_sha=$(sha256sum "$already_current_target" | cut -d' ' -f1)
                    already_current_desired_sha=$(sha256sum "$already_current_desired" | cut -d' ' -f1)
                    already_current_state_sha=$(sha256sum "$already_current_state" | cut -d' ' -f1)
                    already_current_converged_sha=$(sha256sum "$already_current_converged" | cut -d' ' -f1)
                    already_current_status_sha=$(sha256sum "$already_current_status" | cut -d' ' -f1)
                    already_current_events_sha=$(sha256sum ${lib.escapeShellArg integrationRoot}/logs/events.jsonl | cut -d' ' -f1)
                    already_current_recovery_runs_sha=$(sha256sum ${lib.escapeShellArg integrationRoot}/already-current-recovery-runs | cut -d' ' -f1)
                    already_current_recovery_states_sha=$(sha256sum ${lib.escapeShellArg integrationRoot}/already-current-recovery-states | cut -d' ' -f1)

                    # Exact replay is a byte-for-byte no-op, including durable state,
                    # event/status timestamps, profile identity, and all hook sentinels.
                    "$entrypoint"
                    test "$(sha256sum "$already_current_target" | cut -d' ' -f1)" = "$already_current_target_sha"
                    test "$(sha256sum "$already_current_desired" | cut -d' ' -f1)" = "$already_current_desired_sha"
                    test "$(sha256sum "$already_current_state" | cut -d' ' -f1)" = "$already_current_state_sha"
                    test "$(sha256sum "$already_current_converged" | cut -d' ' -f1)" = "$already_current_converged_sha"
                    test "$(sha256sum "$already_current_status" | cut -d' ' -f1)" = "$already_current_status_sha"
                    test "$(sha256sum ${lib.escapeShellArg integrationRoot}/logs/events.jsonl | cut -d' ' -f1)" = "$already_current_events_sha"
                    test "$(sha256sum ${lib.escapeShellArg integrationRoot}/already-current-recovery-runs | cut -d' ' -f1)" = "$already_current_recovery_runs_sha"
                    test "$(sha256sum ${lib.escapeShellArg integrationRoot}/already-current-recovery-states | cut -d' ' -f1)" = "$already_current_recovery_states_sha"
                    test "$(readlink ${lib.escapeShellArg integrationRoot}/system-profile)" = "$profile_link_before"
                    test "$(nix-store --realise ${lib.escapeShellArg integrationRoot}/system-profile)" = "$profile_generation_before"
                    test "$(sha256sum ${lib.escapeShellArg integrationRoot}/activation-runs | cut -d' ' -f1)" = "$activation_before"
                    test "$(sha256sum ${lib.escapeShellArg integrationRoot}/pre-switch-ran | cut -d' ' -f1)" = "$pre_before"
                    test "$(sha256sum ${lib.escapeShellArg integrationRoot}/post-switch-ran | cut -d' ' -f1)" = "$post_before"
                    test ! -e ${lib.escapeShellArg integrationRoot}/unexpected-restore
                    test ! -e ${lib.escapeShellArg integrationRoot}/unexpected-health

                    # test_darwin_pull_agent_same_id_sequence_high_water: deployment IDs
                    # intentionally repeat for the same target/system path. A higher
                    # sequence must advance, while stale, exact replay, and equal-sequence
                    # signed collision inputs must leave every durable/activation surface
                    # byte-identical.
                    same_id_next=${lib.escapeShellArg integrationRoot}/state/inbox/same-id-next.json
                make_manifest \
                  m3 \
                  ${previousGeneration} \
                  6 \
                  "$same_id_next" \
                  5555555555555555555555555555555555555555 \
                  darwin-already-current-5
                    same_id=$(jq -r .deploymentId "$same_id_next")
                    test "$same_id" = "$already_current_id"
                    "$entrypoint"
                    jq -e \
                      --arg deployment_id "$same_id" \
                      '.deploymentId == $deployment_id
                        and .sequence == 6
                        and .currentState == "succeeded"
                        and .attempts == 0' \
                      ${lib.escapeShellArg integrationRoot}/state/agent-status/m3.json >/dev/null
                    cmp "$same_id_next" "$target_record"
                    jq -e '.sequence == 6' \
                      ${lib.escapeShellArg integrationRoot}/state/converged/"$same_id".json >/dev/null
                    test "$(readlink ${lib.escapeShellArg integrationRoot}/system-profile)" = "$profile_link_before"
                    test "$(sha256sum ${lib.escapeShellArg integrationRoot}/activation-runs | cut -d' ' -f1)" = "$activation_before"
                    test "$(sha256sum ${lib.escapeShellArg integrationRoot}/pre-switch-ran | cut -d' ' -f1)" = "$pre_before"
                    test "$(sha256sum ${lib.escapeShellArg integrationRoot}/post-switch-ran | cut -d' ' -f1)" = "$post_before"
                    test "$(wc -l < ${lib.escapeShellArg integrationRoot}/already-current-recovery-runs | tr -d ' ')" = 3
                    test "$(tail -n1 ${lib.escapeShellArg integrationRoot}/already-current-recovery-states)" = clean

                    same_id_desired=${lib.escapeShellArg integrationRoot}/state/desired/"$same_id".json
                    same_id_current=${lib.escapeShellArg integrationRoot}/state/current/"$same_id".json
                    same_id_converged=${lib.escapeShellArg integrationRoot}/state/converged/"$same_id".json
                    same_id_superseded=${lib.escapeShellArg integrationRoot}/state/superseded/"$same_id".json
                    same_id_status=${lib.escapeShellArg integrationRoot}/state/agent-status/m3.json
                    same_id_target_sha=$(sha256sum "$target_record" | cut -d' ' -f1)
                    same_id_desired_sha=$(sha256sum "$same_id_desired" | cut -d' ' -f1)
                    same_id_current_sha=$(sha256sum "$same_id_current" | cut -d' ' -f1)
                    same_id_converged_sha=$(sha256sum "$same_id_converged" | cut -d' ' -f1)
                    same_id_superseded_sha=$(sha256sum "$same_id_superseded" | cut -d' ' -f1)
                    same_id_status_sha=$(sha256sum "$same_id_status" | cut -d' ' -f1)
                    same_id_events_sha=$(sha256sum ${lib.escapeShellArg integrationRoot}/logs/events.jsonl | cut -d' ' -f1)
                    same_id_activation_sha=$(sha256sum ${lib.escapeShellArg integrationRoot}/activation-runs | cut -d' ' -f1)
                    same_id_pre_sha=$(sha256sum ${lib.escapeShellArg integrationRoot}/pre-switch-ran | cut -d' ' -f1)
                    same_id_post_sha=$(sha256sum ${lib.escapeShellArg integrationRoot}/post-switch-ran | cut -d' ' -f1)

                    assert_same_id_high_water_unchanged() {
                      test "$(sha256sum "$target_record" | cut -d' ' -f1)" = "$same_id_target_sha"
                      test "$(sha256sum "$same_id_desired" | cut -d' ' -f1)" = "$same_id_desired_sha"
                      test "$(sha256sum "$same_id_current" | cut -d' ' -f1)" = "$same_id_current_sha"
                      test "$(sha256sum "$same_id_converged" | cut -d' ' -f1)" = "$same_id_converged_sha"
                      test "$(sha256sum "$same_id_superseded" | cut -d' ' -f1)" = "$same_id_superseded_sha"
                      test "$(sha256sum "$same_id_status" | cut -d' ' -f1)" = "$same_id_status_sha"
                      test "$(sha256sum ${lib.escapeShellArg integrationRoot}/logs/events.jsonl | cut -d' ' -f1)" = "$same_id_events_sha"
                      test "$(sha256sum ${lib.escapeShellArg integrationRoot}/activation-runs | cut -d' ' -f1)" = "$same_id_activation_sha"
                      test "$(sha256sum ${lib.escapeShellArg integrationRoot}/pre-switch-ran | cut -d' ' -f1)" = "$same_id_pre_sha"
                      test "$(sha256sum ${lib.escapeShellArg integrationRoot}/post-switch-ran | cut -d' ' -f1)" = "$same_id_post_sha"
                      test "$(nix-store --realise ${lib.escapeShellArg integrationRoot}/system-profile)" = ${previousGeneration}
                    }

                    # Removing sequence 6 exposes the signed sequence-5 manifest with the
                    # same ID. It is stale and must not regress any high-water evidence.
                    cp "$same_id_next" "$TMPDIR/same-id-sequence-6.json"
                    rm "$same_id_next"
                    "$entrypoint"
                    assert_same_id_high_water_unchanged

                    # Restoring the exact sequence-6 bytes is an idempotent no-op.
                    cp "$TMPDIR/same-id-sequence-6.json" "$same_id_next"
                    "$entrypoint"
                    assert_same_id_high_water_unchanged

                    # A different, correctly signed sequence-6 payload with the same
                    # derived ID is a non-retryable collision, also without mutation.
                    make_manifest \
                      m3 \
                      ${previousGeneration} \
                      6 \
                  "$same_id_next" \
                  6555555555555555555555555555555555555555 \
                  darwin-already-current-5
                    test "$(jq -r .deploymentId "$same_id_next")" = "$same_id"
                    if "$entrypoint"; then
                      echo 'agent accepted a signed same-ID same-sequence collision' >&2
                      exit 1
                    fi
                    assert_same_id_high_water_unchanged

                    cp "$TMPDIR/same-id-sequence-6.json" "$same_id_next"

                    # test_darwin_pull_agent_lock_contention_is_non_destructive: the first
                    # real agent invocation holds the module's flock while readiness waits.
                    mkdir -p ${lib.escapeShellArg lockNamespace}
                    export MCL_DEPLOY_PREP_EXPECTED_UID="$(stat -c %u ${lib.escapeShellArg lockNamespace})"
                    export MCL_DEPLOY_PREP_EXPECTED_GID="$(stat -c %g ${lib.escapeShellArg lockNamespace})"
                    ${lib.escapeShellArg (lib.getExe lockPreparationPackage)}
                    export MCL_DARWIN_TEST_ROOT=${lib.escapeShellArg lockRoot}
                    export HOME=${lib.escapeShellArg lockRoot}/home
                    export XDG_CACHE_HOME=${lib.escapeShellArg lockRoot}/cache
                    export NIX_CONFIG='experimental-features = nix-command'
                    export NIX_STATE_DIR=${lib.escapeShellArg lockRoot}/nix-state
                    export NIX_PROFILES_DIR="$NIX_STATE_DIR/profiles"
                    export NIX_USER_PROFILE_DIR="$NIX_PROFILES_DIR/per-user/$(id -un)"
                    mkdir -p \
                      "$HOME" \
                      "$XDG_CACHE_HOME" \
                      "$NIX_STATE_DIR/gcroots/auto" \
                      "$NIX_STATE_DIR/temproots" \
                      "$NIX_USER_PROFILE_DIR"
                    nix-store --init
                    nix-store --load-db < ${profileClosure}/registration
                    nix-env --profile ${lib.escapeShellArg lockRoot}/system-profile --set ${previousGeneration}
                    make_manifest m3 ${desiredGeneration} 4 ${lib.escapeShellArg lockRoot}/state/inbox/desired.json

                    lock_entrypoint=${lib.escapeShellArg (lib.getExe lockEntrypointPackage)}
                    "$lock_entrypoint" > ${lib.escapeShellArg lockRoot}/first.stdout 2> ${lib.escapeShellArg lockRoot}/first.stderr &
                    first_pid=$!
                    for _ in $(seq 1 100); do
                      test -e ${lib.escapeShellArg lockRoot}/pre-switch-entered && break
                      kill -0 "$first_pid"
                      sleep 0.1
                    done
                    test -e ${lib.escapeShellArg lockRoot}/pre-switch-entered
                    if "$lock_entrypoint" > ${lib.escapeShellArg lockRoot}/contender.stdout 2> ${lib.escapeShellArg lockRoot}/contender.stderr; then
                      echo 'concurrent Darwin pull-agent invocation acquired the held lock' >&2
                      exit 1
                    fi
                    wait "$first_pid"
                    test "$(wc -l < ${lib.escapeShellArg lockRoot}/pre-switch-runs | tr -d ' ')" = 1
                    test "$(nix-store --realise ${lib.escapeShellArg lockRoot}/system-profile)" = ${previousGeneration}
                    test ! -e ${lib.escapeShellArg lockRoot}/activation-runs
                    test ! -e ${lib.escapeShellArg lockRoot}/post-switch-ran
                    jq -e '.currentState == "deferred" and .attempts == 0 and .maxAttempts == 1 and .retryable == true' \
                      ${lib.escapeShellArg lockRoot}/state/agent-status/m3.json >/dev/null
                    validate_event_log ${lib.escapeShellArg lockRoot}/logs/events.jsonl
                    jq -e -s '
                      all(.[]; .target.kind == "darwin" and .target.name == "m3") and
                      any(.[];
                        .phase == "switch" and
                        .command.status == "skipped" and
                        .command.exitCode == 75 and
                        .error.code == "deployment_deferred" and
                        .error.retryable == true)
                    ' ${lib.escapeShellArg lockRoot}/logs/events.jsonl >/dev/null

                    mkdir -p "$out"
                    printf '%s\n' 'test_darwin_pull_agent_rejects_untrusted_and_wrong_target_manifests: passed' > "$out/hostile"
                    printf '%s\n' 'test_darwin_pull_agent_rejects_invalid_durable_state: passed' > "$out/durable"
                    printf '%s\n' 'test_darwin_pull_agent_already_current_recovers_lifecycle_before_convergence: passed' > "$out/already-current"
                    printf '%s\n' 'test_darwin_pull_agent_same_id_sequence_high_water: passed' > "$out/high-water"
                    printf '%s\n' 'test_darwin_pull_agent_lock_contention_is_non_destructive: passed' > "$out/lock"
                    printf '%s\n' 'deployment-pull-agent-darwin-integration: passed' > "$out/result"
          '';
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
        test_darwin_pull_agent_assertion_gate = assertionGateCheck;
        test_darwin_pull_agent_launchd_contract = launchdContractCheck;
        test_darwin_pull_agent_entrypoint_survives_generation_change = generationStabilityCheck;
        test_darwin_pull_agent_rejects_untrusted_and_wrong_target_manifests = darwinIntegrationCheck;
        test_darwin_pull_agent_rejects_invalid_durable_state = darwinIntegrationCheck;
        # Keep the original public check name as a compatibility alias. The
        # strengthened scenario is still transaction-free; it now also proves
        # that recovery-only lifecycle work finishes before convergence.
        test_darwin_pull_agent_already_current_is_transaction_free = darwinIntegrationCheck;
        test_darwin_pull_agent_already_current_recovers_lifecycle_before_convergence =
          darwinIntegrationCheck;
        test_darwin_pull_agent_same_id_sequence_high_water = darwinIntegrationCheck;
        test_darwin_pull_agent_lock_contention_is_non_destructive = darwinIntegrationCheck;
        deployment-pull-agent-darwin-integration = darwinIntegrationCheck;
      };
    };
}
