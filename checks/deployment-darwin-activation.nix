{ ... }:
{
  perSystem =
    {
      pkgs,
      self',
      ...
    }:
    let
      manifestPrivateKey = pkgs.writeText "mcl-darwin-manifest-test-key" ''
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACDhvqWTBaFX/XLEIco2ux47m8yJz7xl+vTsiB2LGk7h7QAAAJifNGKYnzRi
        mAAAAAtzc2gtZWQyNTUxOQAAACDhvqWTBaFX/XLEIco2ux47m8yJz7xl+vTsiB2LGk7h7Q
        AAAEBvBnhoTQhoz/liGXDGeodsQFCPZfx7B/f10DxJy+VHP+G+pZMFoVf9csQhyja7Hjub
        zInPvGX69OyIHYsaTuHtAAAAEW1jbC1tYW5pZmVzdC10ZXN0AQIDBA==
        -----END OPENSSH PRIVATE KEY-----
      '';
      manifestPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOG+pZMFoVf9csQhyja7HjubzInPvGX69OyIHYsaTuHt mcl-manifest-test";
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
      generationActivation =
        name: shouldFail:
        pkgs.writeShellScript "mcl-darwin-generation-${name}-activate" ''
          set -eu
          generation=$(dirname "$0")
          printf '%s\n' "$generation" >> "$MCL_DARWIN_TEST_ROOT/activation-runs"
          ${
            if shouldFail then
              ''
                printf '%s\n' "$generation" > "$MCL_DARWIN_TEST_ROOT/failed-activation"
                exit 31
              ''
            else
              ''
                printf '%s\n' "$generation" > "$MCL_DARWIN_TEST_ROOT/active-generation"
              ''
          }
        '';
      generation =
        name: shouldFail:
        pkgs.runCommand "mcl-darwin-generation-${name}" { } ''
          mkdir -p "$out"
          cp ${generationActivation name shouldFail} "$out/activate"
        '';
      previousGeneration = generation "previous" false;
      desiredGeneration = generation "desired" false;
      failingGeneration = generation "failing" true;
      profileClosure = pkgs.closureInfo {
        rootPaths = [
          previousGeneration
          desiredGeneration
          failingGeneration
        ];
      };
      preSwitchHook = pkgs.writeShellScript "mcl-darwin-pre-switch-test" ''
        set -eu
        printf '%s\n%s\n' "$1" "$2" > "$MCL_DARWIN_TEST_ROOT/$MCL_TEST_SCENARIO.pre"
      '';
      deferredPreSwitchHook = pkgs.writeShellScript "mcl-darwin-deferred-pre-switch-test" ''
        set -eu
        printf 'deferred\n' >> "$MCL_DARWIN_TEST_ROOT/deferral-runs"
        exit 75
      '';
      postSwitchHook = pkgs.writeShellScript "mcl-darwin-post-switch-test" ''
        set -eu
        printf '%s\n%s\n%s\n' "$1" "$2" "$3" > "$MCL_DARWIN_TEST_ROOT/$MCL_TEST_SCENARIO.post"
      '';
      fatalLifecycleHook = pkgs.writeShellScript "mcl-darwin-fatal-lifecycle-test" ''
        set -eu
        printf '%s\n' "$*" >> "$MCL_DARWIN_TEST_ROOT/unexpected-lifecycle-hook"
        exit 97
      '';
    in
    {
      checks.deployment-darwin-activation-integration =
        pkgs.runCommand "deployment-darwin-activation-integration"
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
            export MCL_DARWIN_TEST_ROOT="$TMPDIR/mcl darwin activation"
            mkdir -p "$MCL_DARWIN_TEST_ROOT"
            export HOME="$MCL_DARWIN_TEST_ROOT/home"
            export XDG_CACHE_HOME="$MCL_DARWIN_TEST_ROOT/cache"
            export NIX_CONFIG='experimental-features = nix-command'
            mkdir -p "$HOME" "$XDG_CACHE_HOME"

            export NIX_STATE_DIR="$MCL_DARWIN_TEST_ROOT/nix-state"
            export NIX_PROFILES_DIR="$NIX_STATE_DIR/profiles"
            export NIX_USER_PROFILE_DIR="$NIX_PROFILES_DIR/per-user/$(id -un)"
            mkdir -p \
              "$NIX_STATE_DIR/gcroots/auto" \
              "$NIX_STATE_DIR/temproots" \
              "$NIX_USER_PROFILE_DIR"
            nix-store --init
            nix-store --load-db < ${profileClosure}/registration
            key="$MCL_DARWIN_TEST_ROOT/manifest-key"
            cp ${manifestPrivateKey} "$key"
            chmod 0600 "$key"

            make_manifest() {
              local desired=$1
              local sequence=$2
              local output=$3
              shift 3
              mcl-devops deploy-plan \
                --target m3 \
                --system aarch64-darwin \
                --desired-system-path "$desired" \
                --git-revision 0123456789abcdef0123456789abcdef01234567 \
                --sequence "$sequence" \
                --signing-key "$key" \
                --signing-key-id mcl-deployment \
                --output "$output" \
                "$@"
            }

            validate_event_log() {
              python ${eventLogValidator} "$1" ${../docs/deployment/event-schema.json}
            }

            profile="$MCL_DARWIN_TEST_ROOT/system profile"
            nix-env --profile "$profile" --set ${previousGeneration}
            test -L "$profile"
            test "$(readlink "$profile")" = "$(basename "$profile")-1-link"
            test "$(readlink "$profile-1-link")" = ${previousGeneration}
            ${previousGeneration}/activate

            export MCL_TEST_SCENARIO=success
            success_manifest="$MCL_DARWIN_TEST_ROOT/success.json"
            success_state="$MCL_DARWIN_TEST_ROOT/success-state"
            success_events="$MCL_DARWIN_TEST_ROOT/success-events.jsonl"
            make_manifest ${desiredGeneration} 1 "$success_manifest"
            mcl-devops deploy-apply \
              --manifest "$success_manifest" \
              --target m3 \
              --trusted-manifest-public-key ${pkgs.lib.escapeShellArg manifestPublicKey} \
              --state-dir "$success_state" \
              --event-log "$success_events" \
              --activation-mode nix-darwin \
              --system-profile "$profile" \
              --pre-switch-hook ${preSwitchHook} \
              --post-switch-hook ${postSwitchHook}
            test "$(nix-store --realise "$profile")" = ${desiredGeneration}
            test "$(cat "$MCL_DARWIN_TEST_ROOT/active-generation")" = ${desiredGeneration}
            test "$(sed -n '1p' "$MCL_DARWIN_TEST_ROOT/success.pre")" = ${desiredGeneration}
            test "$(sed -n '2p' "$MCL_DARWIN_TEST_ROOT/success.pre")" = ${previousGeneration}
            test "$(sed -n '1p' "$MCL_DARWIN_TEST_ROOT/success.post")" = ${desiredGeneration}
            test "$(sed -n '2p' "$MCL_DARWIN_TEST_ROOT/success.post")" = ${previousGeneration}
            test "$(sed -n '3p' "$MCL_DARWIN_TEST_ROOT/success.post")" = succeeded
            test "$(find "$success_state/converged" -name '*.json' | wc -l | tr -d ' ')" = 1
            validate_event_log "$success_events"
            jq -e -s '
              length > 0 and
              all(.[]; .target.kind == "darwin") and
              ([.[] | select(.metadata.lifecycleStage? == "pre-switch")] | length == 1) and
              ([.[] | select(.metadata.lifecycleStage? == "post-switch")] | length == 1) and
              any(.[]; .phase == "complete" and .command.status == "succeeded")
            ' "$success_events" >/dev/null

            nix-env --profile "$profile" --set ${previousGeneration}
            ${previousGeneration}/activate
            export MCL_TEST_SCENARIO=activation-failure
            failure_manifest="$MCL_DARWIN_TEST_ROOT/activation-failure.json"
            failure_state="$MCL_DARWIN_TEST_ROOT/activation-failure-state"
            failure_events="$MCL_DARWIN_TEST_ROOT/activation-failure-events.jsonl"
            make_manifest ${failingGeneration} 2 "$failure_manifest"
            if mcl-devops deploy-apply \
              --manifest "$failure_manifest" \
              --target m3 \
              --trusted-manifest-public-key ${pkgs.lib.escapeShellArg manifestPublicKey} \
              --state-dir "$failure_state" \
              --event-log "$failure_events" \
              --activation-mode nix-darwin \
              --system-profile "$profile" \
              --pre-switch-hook ${preSwitchHook} \
              --post-switch-hook ${postSwitchHook}; then
              echo "failing Darwin activation unexpectedly converged" >&2
              exit 1
            fi
            test "$(cat "$MCL_DARWIN_TEST_ROOT/failed-activation")" = ${failingGeneration}
            test "$(nix-store --realise "$profile")" = ${previousGeneration}
            test "$(cat "$MCL_DARWIN_TEST_ROOT/active-generation")" = ${previousGeneration}
            test "$(sed -n '3p' "$MCL_DARWIN_TEST_ROOT/activation-failure.post")" = switch-failed
            test "$(find "$failure_state/failed" -name '*.json' | wc -l | tr -d ' ')" = 1
            validate_event_log "$failure_events"
            jq -e -s '
              all(.[]; .target.kind == "darwin") and
              any(.[]; .phase == "switch" and .command.name == "nix-darwin profile activation" and .command.status == "failed") and
              any(.[]; .phase == "rollback" and .command.status == "succeeded") and
              any(.[]; .metadata.lifecycleStage? == "post-switch" and .metadata.outcome == "switch-failed")
            ' "$failure_events" >/dev/null

            nix-env --profile "$profile" --set ${previousGeneration}
            ${previousGeneration}/activate
            export MCL_TEST_SCENARIO=health-failure
            health_manifest="$MCL_DARWIN_TEST_ROOT/health-failure.json"
            health_state="$MCL_DARWIN_TEST_ROOT/health-failure-state"
            health_events="$MCL_DARWIN_TEST_ROOT/health-failure-events.jsonl"
            make_manifest ${desiredGeneration} 3 "$health_manifest" \
              --health-command 'forced-failure|5|false' \
              --rollback-mode automatic \
              --rollback-max-attempts 1 \
              --on-health-check-failure rollback
            if mcl-devops deploy-apply \
              --manifest "$health_manifest" \
              --target m3 \
              --trusted-manifest-public-key ${pkgs.lib.escapeShellArg manifestPublicKey} \
              --state-dir "$health_state" \
              --event-log "$health_events" \
              --activation-mode nix-darwin \
              --system-profile "$profile" \
              --pre-switch-hook ${preSwitchHook} \
              --post-switch-hook ${postSwitchHook}; then
              echo "failed health check unexpectedly converged" >&2
              exit 1
            fi
            test "$(nix-store --realise "$profile")" = ${previousGeneration}
            test "$(cat "$MCL_DARWIN_TEST_ROOT/active-generation")" = ${previousGeneration}
            test "$(sed -n '3p' "$MCL_DARWIN_TEST_ROOT/health-failure.post")" = rolled-back
            test "$(jq -r .currentState "$health_state/current/"*.json)" = rolled-back
            validate_event_log "$health_events"
            jq -e -s '
              all(.[]; .target.kind == "darwin") and
              any(.[]; .phase == "healthcheck" and .command.status == "failed") and
              any(.[]; .phase == "rollback" and .command.status == "succeeded") and
              any(.[]; .metadata.lifecycleStage? == "post-switch" and .metadata.outcome == "rolled-back")
            ' "$health_events" >/dev/null

            nix-env --profile "$profile" --set ${previousGeneration}
            ${previousGeneration}/activate
            export MCL_TEST_SCENARIO=deferred
            deferred_manifest="$MCL_DARWIN_TEST_ROOT/deferred.json"
            deferred_state="$MCL_DARWIN_TEST_ROOT/deferred-state"
            deferred_events="$MCL_DARWIN_TEST_ROOT/deferred-events.jsonl"
            make_manifest ${desiredGeneration} 4 "$deferred_manifest"
            for poll in 1 2 3; do
              mcl-devops deploy-agent \
                --manifest "$deferred_manifest" \
                --target m3 \
                --trusted-manifest-public-key ${pkgs.lib.escapeShellArg manifestPublicKey} \
                --state-dir "$deferred_state" \
                --event-log "$deferred_events" \
                --max-attempts 1 \
                --activation-mode nix-darwin \
                --system-profile "$profile" \
                --pre-switch-hook ${deferredPreSwitchHook} \
                --post-switch-hook ${postSwitchHook}
            done
            status="$deferred_state/agent-status/m3.json"
            test "$(jq -r .currentState "$status")" = deferred
            test "$(jq -r .attempts "$status")" = 0
            test "$(jq -r .maxAttempts "$status")" = 1
            test "$(jq -r .retryable "$status")" = true
            test "$(jq -r .errorCode "$status")" = deployment_deferred
            test "$(wc -l < "$MCL_DARWIN_TEST_ROOT/deferral-runs" | tr -d ' ')" = 3
            test "$(nix-store --realise "$profile")" = ${previousGeneration}
            test ! -e "$MCL_DARWIN_TEST_ROOT/deferred.post"
            test "$(find "$deferred_state/converged" -name '*.json' | wc -l | tr -d ' ')" = 0
            validate_event_log "$deferred_events"
            jq -e -s '
              all(.[]; .target.kind == "darwin") and
              ([.[] | select(.phase == "switch" and .metadata.lifecycleStage? == "pre-switch")] |
                length == 3 and all(.[];
                  .phase == "switch" and
                  .command.status == "skipped" and
                  .command.exitCode == 75 and
                  .error.code == "deployment_deferred" and
                  .error.retryable == true)) and
              ([.[] | select(.phase == "complete" and .metadata.outcome? == "deferred")] |
                length == 3 and all(.[];
                  .command.status == "skipped" and
                  .command.exitCode == 75 and
                  .error.code == "deployment_deferred" and
                  .error.retryable == true))
            ' "$deferred_events" >/dev/null || {
              jq -s . "$deferred_events" >&2
              exit 1
            }

            # A dry-run records only the authenticated desired/current/converged
            # state and its two events. Every activation surface is populated
            # with a command that leaves evidence and fails if it is reached.
            dry_profile="$MCL_DARWIN_TEST_ROOT/dry-run profile"
            nix-env --profile "$dry_profile" --set ${previousGeneration}
            dry_profile_link=$(readlink "$dry_profile")
            dry_generation_link=$(readlink "$dry_profile-1-link")
            dry_active_before=$(cat "$MCL_DARWIN_TEST_ROOT/active-generation")
            dry_manifest="$MCL_DARWIN_TEST_ROOT/dry-run.json"
            dry_state="$MCL_DARWIN_TEST_ROOT/dry-run-state"
            dry_events="$MCL_DARWIN_TEST_ROOT/dry-run-events.jsonl"
            make_manifest ${desiredGeneration} 5 "$dry_manifest" \
              --health-command 'fatal-health|5|printf health > "$MCL_DARWIN_TEST_ROOT/unexpected-health"; exit 97' \
              --rollback-mode automatic \
              --rollback-max-attempts 1 \
              --on-health-check-failure rollback
            fatal_restore='printf restore > "$MCL_DARWIN_TEST_ROOT/unexpected-restore"; exit 97'
            fatal_generation='printf generation > "$MCL_DARWIN_TEST_ROOT/unexpected-generation"; exit 97'
            fatal_switch='printf switch > "$MCL_DARWIN_TEST_ROOT/unexpected-switch"; exit 97'
            fatal_rollback='printf rollback > "$MCL_DARWIN_TEST_ROOT/unexpected-rollback"; exit 97'
            mcl-devops deploy-apply \
              --manifest "$dry_manifest" \
              --target m3 \
              --trusted-manifest-public-key ${pkgs.lib.escapeShellArg manifestPublicKey} \
              --state-dir "$dry_state" \
              --event-log "$dry_events" \
              --activation-mode nix-darwin \
              --system-profile "$dry_profile" \
              --pre-switch-hook ${fatalLifecycleHook} \
              --post-switch-hook ${fatalLifecycleHook} \
              --restore-command "$fatal_restore" \
              --generation-command "$fatal_generation" \
              --switch-command "$fatal_switch" \
              --rollback-command "$fatal_rollback" \
              --dry-run
            test "$(readlink "$dry_profile")" = "$dry_profile_link"
            test "$(readlink "$dry_profile-1-link")" = "$dry_generation_link"
            test "$(cat "$MCL_DARWIN_TEST_ROOT/active-generation")" = "$dry_active_before"
            for marker in \
              unexpected-lifecycle-hook \
              unexpected-restore \
              unexpected-generation \
              unexpected-switch \
              unexpected-rollback \
              unexpected-health
            do
              test ! -e "$MCL_DARWIN_TEST_ROOT/$marker"
            done
            dry_id=$(jq -r .deploymentId "$dry_manifest")
            cmp -s "$dry_manifest" "$dry_state/desired/$dry_id.json"
            cmp -s "$dry_manifest" "$dry_state/targets/m3.json"
            jq -e '.currentState == "accepted" and .sequence == 5' \
              "$dry_state/current/$dry_id.json" >/dev/null
            jq -e \
              '.currentState == "succeeded"
                and .message == "Dry-run verified signed manifest."' \
              "$dry_state/converged/$dry_id.json" >/dev/null
            test ! -e "$dry_state/failed/$dry_id.json"
            test ! -e "$dry_state/superseded/$dry_id.json"
            validate_event_log "$dry_events"
            jq -e -s \
              'length == 2
                and .[0].phase == "activate-requested"
                and .[0].command.status == "succeeded"
                and .[0].metadata.sequence == 5
                and .[0].metadata.dryRun == true
                and .[1].phase == "complete"
                and .[1].command.name == "mcl-devops deploy-apply --dry-run"
                and .[1].command.status == "succeeded"' \
              "$dry_events" >/dev/null

            # The forced-command stdin transport is byte preserving. JSON
            # whitespace is not part of signature verification, but it is part
            # of the equal-sequence protocol identity stored in targets/.
            stdin_source="$MCL_DARWIN_TEST_ROOT/stdin-source.json"
            stdin_compact="$MCL_DARWIN_TEST_ROOT/stdin-compact-no-eol.json"
            stdin_compact_lf="$MCL_DARWIN_TEST_ROOT/stdin-compact-lf.json"
            stdin_crlf="$MCL_DARWIN_TEST_ROOT/stdin-crlf-no-eol.json"
            stdin_crlf_lf="$MCL_DARWIN_TEST_ROOT/stdin-crlf-lf.json"
            make_manifest ${desiredGeneration} 6 "$stdin_source"
            python - \
              "$stdin_source" \
              "$stdin_compact" \
              "$stdin_compact_lf" \
              "$stdin_crlf" \
              "$stdin_crlf_lf" <<'PY'
            import json
            import pathlib
            import sys

            source, compact, compact_lf, crlf, crlf_lf = map(pathlib.Path, sys.argv[1:])
            compact_bytes = source.read_bytes().rstrip(b"\r\n")
            compact.write_bytes(compact_bytes)
            compact_lf.write_bytes(compact_bytes + b"\n")

            parsed = json.loads(compact_bytes)
            pretty = json.dumps(
                parsed,
                ensure_ascii=False,
                indent=2,
                separators=(",", ": "),
            ).encode().replace(b"\n", b"\r\n")
            crlf.write_bytes(pretty)
            crlf_lf.write_bytes(pretty + b"\n")
            PY
            python - \
              "$stdin_compact" \
              "$stdin_compact_lf" \
              "$stdin_crlf" \
              "$stdin_crlf_lf" <<'PY'
            import pathlib
            import sys

            compact, compact_lf, crlf, crlf_lf = (
                pathlib.Path(path).read_bytes() for path in sys.argv[1:]
            )
            assert compact
            assert not compact.endswith((b"\n", b"\r"))
            assert compact_lf == compact + b"\n"
            assert b"\r\n" in crlf
            assert not crlf.endswith((b"\n", b"\r"))
            assert crlf_lf == crlf + b"\n"
            PY

            assert_stdin_equal_sequence_identity() {
              local label=$1
              local accepted=$2
              local rejected=$3
              local state="$MCL_DARWIN_TEST_ROOT/stdin-$label-state"
              local events="$MCL_DARWIN_TEST_ROOT/stdin-$label-events.jsonl"
              local status="$state/agent-status/m3.json"
              local deployment_id
              local target
              local desired
              local current
              local converged
              local target_sha
              local desired_sha
              local current_sha
              local converged_sha
              local events_sha
              local status_sha
              local activation_sha
              local active_sha
              local success_pre_sha
              local success_post_sha
              local profile_link
              local generation_link
              local exit_code

              mkdir -p "$state/agent-status"
              printf '%s' \
                '{"target":"m3","deploymentId":"prior-status","sequence":4,"currentState":"succeeded","attempts":41,"maxAttempts":42,"retryable":false}' \
                > "$status"
              status_sha=$(sha256sum "$status" | cut -d' ' -f1)
              activation_sha=$(sha256sum "$MCL_DARWIN_TEST_ROOT/activation-runs" | cut -d' ' -f1)
              active_sha=$(sha256sum "$MCL_DARWIN_TEST_ROOT/active-generation" | cut -d' ' -f1)
              success_pre_sha=$(sha256sum "$MCL_DARWIN_TEST_ROOT/success.pre" | cut -d' ' -f1)
              success_post_sha=$(sha256sum "$MCL_DARWIN_TEST_ROOT/success.post" | cut -d' ' -f1)
              profile_link=$(readlink "$dry_profile")
              generation_link=$(readlink "$dry_profile-1-link")

              SSH_ORIGINAL_COMMAND= mcl-devops deploy-apply \
                --manifest - \
                --target m3 \
                --trusted-manifest-public-key ${pkgs.lib.escapeShellArg manifestPublicKey} \
                --state-dir "$state" \
                --event-log "$events" \
                --activation-mode nix-darwin \
                --system-profile "$dry_profile" \
                --pre-switch-hook ${fatalLifecycleHook} \
                --post-switch-hook ${fatalLifecycleHook} \
                --restore-command "$fatal_restore" \
                --generation-command "$fatal_generation" \
                --switch-command "$fatal_switch" \
                --rollback-command "$fatal_rollback" \
                --reject-ssh-original-command \
                --dry-run < "$accepted"

              deployment_id=$(jq -r .deploymentId "$accepted")
              target="$state/targets/m3.json"
              desired="$state/desired/$deployment_id.json"
              current="$state/current/$deployment_id.json"
              converged="$state/converged/$deployment_id.json"
              cmp -s "$accepted" "$target"
              diff -u <(jq -S . "$accepted") <(jq -S . "$desired")
              jq -e '.currentState == "accepted" and .sequence == 6' "$current" >/dev/null
              jq -e \
                '.currentState == "succeeded"
                  and .sequence == 6
                  and .message == "Dry-run verified signed manifest."' \
                "$converged" >/dev/null
              validate_event_log "$events"
              jq -e -s \
                'length == 2
                  and .[0].phase == "activate-requested"
                  and .[1].phase == "complete"' \
                "$events" >/dev/null
              test "$(sha256sum "$status" | cut -d' ' -f1)" = "$status_sha"
              jq -e '.attempts == 41 and .maxAttempts == 42' "$status" >/dev/null
              test "$(sha256sum "$MCL_DARWIN_TEST_ROOT/activation-runs" | cut -d' ' -f1)" = "$activation_sha"
              test "$(sha256sum "$MCL_DARWIN_TEST_ROOT/active-generation" | cut -d' ' -f1)" = "$active_sha"
              test "$(sha256sum "$MCL_DARWIN_TEST_ROOT/success.pre" | cut -d' ' -f1)" = "$success_pre_sha"
              test "$(sha256sum "$MCL_DARWIN_TEST_ROOT/success.post" | cut -d' ' -f1)" = "$success_post_sha"
              test "$(readlink "$dry_profile")" = "$profile_link"
              test "$(readlink "$dry_profile-1-link")" = "$generation_link"

              target_sha=$(sha256sum "$target" | cut -d' ' -f1)
              desired_sha=$(sha256sum "$desired" | cut -d' ' -f1)
              current_sha=$(sha256sum "$current" | cut -d' ' -f1)
              converged_sha=$(sha256sum "$converged" | cut -d' ' -f1)
              events_sha=$(sha256sum "$events" | cut -d' ' -f1)

              set +e
              SSH_ORIGINAL_COMMAND= mcl-devops deploy-apply \
                --manifest - \
                --target m3 \
                --trusted-manifest-public-key ${pkgs.lib.escapeShellArg manifestPublicKey} \
                --state-dir "$state" \
                --event-log "$events" \
                --activation-mode nix-darwin \
                --system-profile "$dry_profile" \
                --pre-switch-hook ${fatalLifecycleHook} \
                --post-switch-hook ${fatalLifecycleHook} \
                --restore-command "$fatal_restore" \
                --generation-command "$fatal_generation" \
                --switch-command "$fatal_switch" \
                --rollback-command "$fatal_rollback" \
                --reject-ssh-original-command \
                --dry-run < "$rejected"
              exit_code=$?
              set -e
              if [ "$exit_code" -ne 76 ]; then
                echo "stdin $label equal-sequence collision exited $exit_code instead of 76" >&2
                exit 1
              fi

              test "$(sha256sum "$target" | cut -d' ' -f1)" = "$target_sha"
              test "$(sha256sum "$desired" | cut -d' ' -f1)" = "$desired_sha"
              test "$(sha256sum "$current" | cut -d' ' -f1)" = "$current_sha"
              test "$(sha256sum "$converged" | cut -d' ' -f1)" = "$converged_sha"
              test "$(sha256sum "$events" | cut -d' ' -f1)" = "$events_sha"
              test "$(sha256sum "$status" | cut -d' ' -f1)" = "$status_sha"
              jq -e '.attempts == 41 and .maxAttempts == 42' "$status" >/dev/null
              test "$(sha256sum "$MCL_DARWIN_TEST_ROOT/activation-runs" | cut -d' ' -f1)" = "$activation_sha"
              test "$(sha256sum "$MCL_DARWIN_TEST_ROOT/active-generation" | cut -d' ' -f1)" = "$active_sha"
              test "$(sha256sum "$MCL_DARWIN_TEST_ROOT/success.pre" | cut -d' ' -f1)" = "$success_pre_sha"
              test "$(sha256sum "$MCL_DARWIN_TEST_ROOT/success.post" | cut -d' ' -f1)" = "$success_post_sha"
              test "$(readlink "$dry_profile")" = "$profile_link"
              test "$(readlink "$dry_profile-1-link")" = "$generation_link"
              test ! -e "$state/failed/$deployment_id.json"
              test ! -e "$state/superseded/$deployment_id.json"
              for marker in \
                unexpected-lifecycle-hook \
                unexpected-restore \
                unexpected-generation \
                unexpected-switch \
                unexpected-rollback \
                unexpected-health
              do
                test ! -e "$MCL_DARWIN_TEST_ROOT/$marker"
              done
            }

            # Both possible first arrivals own sequence 6 by their exact bytes.
            assert_stdin_equal_sequence_identity \
              no-final-newline-first \
              "$stdin_compact" \
              "$stdin_compact_lf"
            assert_stdin_equal_sequence_identity \
              final-newline-first \
              "$stdin_crlf_lf" \
              "$stdin_crlf"

            # The same poison configuration without --dry-run is invalid for
            # native Darwin activation and must fail before state or events.
            non_dry_state="$MCL_DARWIN_TEST_ROOT/non-dry-poison-state"
            non_dry_events="$MCL_DARWIN_TEST_ROOT/non-dry-poison-events.jsonl"
            if mcl-devops deploy-apply \
              --manifest "$dry_manifest" \
              --target m3 \
              --trusted-manifest-public-key ${pkgs.lib.escapeShellArg manifestPublicKey} \
              --state-dir "$non_dry_state" \
              --event-log "$non_dry_events" \
              --activation-mode nix-darwin \
              --system-profile "$dry_profile" \
              --pre-switch-hook ${fatalLifecycleHook} \
              --post-switch-hook ${fatalLifecycleHook} \
              --restore-command "$fatal_restore" \
              --generation-command "$fatal_generation" \
              --switch-command "$fatal_switch" \
              --rollback-command "$fatal_rollback"; then
              echo "non-dry Darwin poison configuration unexpectedly ran" >&2
              exit 1
            fi
            test ! -e "$non_dry_state"
            test ! -e "$non_dry_events"
            test "$(readlink "$dry_profile")" = "$dry_profile_link"
            test "$(readlink "$dry_profile-1-link")" = "$dry_generation_link"
            for marker in \
              unexpected-lifecycle-hook \
              unexpected-restore \
              unexpected-generation \
              unexpected-switch \
              unexpected-rollback \
              unexpected-health
            do
              test ! -e "$MCL_DARWIN_TEST_ROOT/$marker"
            done

            mkdir -p "$out"
            printf '%s\n' 'deployment-darwin-activation-integration: passed' > "$out/result"
          '';
    };
}
