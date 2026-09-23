{ withSystem, ... }:
{
  flake.modules.darwin.deployment-pull-agent =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    let
      cfg = config.services.mcl-deploy-agent;
      defaultPackage = withSystem pkgs.stdenv.hostPlatform.system (
        { config, ... }: config.packages.mcl-devops
      );
      inherit (lib)
        concatMapStringsSep
        escapeShellArg
        escapeShellArgs
        getExe
        hasInfix
        hasPrefix
        hasSuffix
        mkEnableOption
        mkIf
        mkOption
        removePrefix
        splitString
        types
        ;

      allowedSigners = pkgs.writeText "mcl-deployment-agent-allowed-signers" (
        concatMapStringsSep "\n" (key: "${cfg.manifestPrincipal} ${key}") cfg.manifestPublicKeys + "\n"
      );

      agentArguments = [
        "--target"
        cfg.targetName
        "--allowed-signers"
        allowedSigners
        "--state-dir"
        cfg.stateDir
        "--event-log"
        cfg.eventLog
        "--max-attempts"
        (toString cfg.maxAttempts)
        "--fetch-timeout-seconds"
        (toString cfg.fetchTimeoutSeconds)
        "--activation-mode"
        "nix-darwin"
        "--system-profile"
        cfg.systemProfile
      ]
      ++ lib.concatMap (source: [
        "--manifest"
        source
      ]) cfg.manifestSources
      ++ lib.concatMap (dir: [
        "--manifest-dir"
        dir
      ]) cfg.manifestDirectories
      ++ lib.optionals cfg.dryRun [ "--dry-run" ]
      ++ lib.optionals (cfg.preSwitchHook != "") [
        "--pre-switch-hook"
        cfg.preSwitchHook
      ]
      ++ lib.optionals (cfg.postSwitchHook != "") [
        "--post-switch-hook"
        cfg.postSwitchHook
      ]
      ++ lib.optionals (cfg.alreadyCurrentRecoveryHook != "") [
        "--already-current-recovery-hook"
        cfg.alreadyCurrentRecoveryHook
      ];

      stableEntrypoint = "/run/current-system/sw/bin/mcl-deploy-agent";
      # nix-darwin loads a newly declared LaunchDaemon before it advances
      # /run/current-system. Naming the stable link directly therefore makes a
      # true first enable fail with ENOENT. Keep the plist stable across agent
      # upgrades, but make its executable an already-realised immutable store
      # launcher. The launcher waits only for the bounded activation window;
      # later polls continue to resolve the active generation through the
      # stable entrypoint, so an agent can activate its own replacement without
      # launchd unloading it merely because the wrapped package changed.
      launchdLauncherPackage = pkgs.writeShellApplication {
        name = "mcl-deploy-agent-launcher";
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          set -euo pipefail

          if [[ $# -ne 3 ]]; then
            echo "mcl-deploy-agent-launcher: expected ENTRYPOINT ATTEMPTS DELAY_SECONDS" >&2
            exit 64
          fi
          entrypoint="$1"
          attempts="$2"
          delay_seconds="$3"
          if [[ "$entrypoint" != /* || "$entrypoint" == *$'\n'* \
            || ! "$attempts" =~ ^[1-9][0-9]{0,3}$ \
            || ! "$delay_seconds" =~ ^(0\.[0-9]{1,3}|[1-9][0-9]{0,2}(\.[0-9]{1,3})?)$ ]]; then
            echo "mcl-deploy-agent-launcher: invalid bounded-wait arguments" >&2
            exit 64
          fi

          for ((attempt = 1; attempt <= attempts; attempt++)); do
            if [[ -f "$entrypoint" && -x "$entrypoint" ]]; then
              exec "$entrypoint"
            fi
            if (( attempt < attempts )); then
              sleep "$delay_seconds"
            fi
          done
          printf 'mcl-deploy-agent-launcher: entrypoint unavailable after %s attempts: %s\n' \
            "$attempts" "$entrypoint" >&2
          exit 75
        '';
      };
      entrypointPackage = pkgs.writeShellApplication {
        name = "mcl-deploy-agent";
        runtimeInputs = [
          cfg.package
          pkgs.coreutils
          pkgs.curl
          pkgs.nix
          pkgs.openssh
          pkgs.util-linux
        ];
        text = ''
          umask 0027
          ${lib.optionalString (cfg.runtimePrerequisite != "") ''
            ${escapeShellArg cfg.runtimePrerequisite}
          ''}
          # macOS empties /private/var/run at every boot, and the lock file's
          # directory lives there. The activation-time preparation that
          # creates it does not run again until the NEXT deployment — which
          # this agent is the only thing that performs — so after a reboot
          # every poll died at `flock: cannot open lock file … No such file or
          # directory` (EX_NOINPUT) and the host silently stopped converging
          # (m3, 2026-09-21). Re-run the same canonical, idempotent
          # preparation when the directory is missing — after the runtime
          # prerequisite, so a failing prerequisite still touches nothing.
          if [ ! -d ${escapeShellArg (builtins.dirOf cfg.lockFile)} ]; then
            ${getExe preparationPackage}
          fi
          exec flock -n ${escapeShellArg cfg.lockFile} ${
            escapeShellArgs (
              [
                (getExe cfg.package)
                "deploy-agent"
              ]
              ++ agentArguments
            )
          }
        '';
      };

      durableLeafDirectories = lib.unique (
        [
          cfg.stateDir
          (builtins.dirOf cfg.eventLog)
          (builtins.dirOf cfg.standardOutLog)
          (builtins.dirOf cfg.standardErrorLog)
          (builtins.dirOf cfg.lockFile)
        ]
        ++ cfg.manifestDirectories
      );

      durableLogFiles = lib.unique [
        cfg.eventLog
        cfg.standardOutLog
        cfg.standardErrorLog
      ];

      isNormalizedAbsolute =
        path:
        hasPrefix "/" path
        && path != "/"
        && !hasInfix "//" path
        && !hasInfix "/./" path
        && !hasInfix "/../" path
        && !hasSuffix "/." path
        && !hasSuffix "/.." path
        && !hasSuffix "/" path;

      allowedRootFor =
        path:
        lib.findFirst (root: path != root && hasPrefix "${root}/" path) null cfg.preparationAllowedRoots;

      isDedicatedPath =
        path:
        let
          root = allowedRootFor path;
          relative = if root == null then "" else removePrefix "${root}/" path;
        in
        root != null && hasInfix "/" relative;

      managedAncestors =
        path:
        let
          root = allowedRootFor path;
          components = if root == null then [ ] else splitString "/" (removePrefix "${root}/" path);
        in
        lib.imap0 (
          index: _component: "${root}/${lib.concatStringsSep "/" (lib.take (index + 1) components)}"
        ) components;

      managedDirectories = lib.unique (lib.concatMap managedAncestors durableLeafDirectories);

      fileChownOwnership =
        if cfg.preparationOwner != null && cfg.preparationGroup != null then
          "${cfg.preparationOwner}:${cfg.preparationGroup}"
        else if cfg.preparationOwner != null then
          cfg.preparationOwner
        else if cfg.preparationGroup != null then
          ":${cfg.preparationGroup}"
        else
          "";

      chownCommand =
        if cfg.preparationFixtureChownCommand == null then
          "${pkgs.coreutils}/bin/chown"
        else
          cfg.preparationFixtureChownCommand;

      preparationPackage = pkgs.writeShellApplication {
        name = "mcl-deploy-agent-prepare-paths";
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          set -euo pipefail
          export LC_ALL=C
          umask 0027

          declare -a original_paths=()
          declare -a original_kinds=()
          declare -a original_identities=()
          declare -a original_modes=()
          declare -a original_uids=()
          declare -a original_gids=()
          declare -a created_paths=()
          declare -a created_kinds=()
          declare -a created_identities=()
          mutation_started=0
          transaction_complete=0
          directory_create_count=0
          log_create_count=0
          chmod_count=0

          fail() {
            printf 'mcl deployment path preparation: %s\n' "$*" >&2
            exit 1
          }

          runtime_path() {
            local configured="$1"
            ${lib.optionalString cfg.preparationAllowTestOverrides ''
              if [ -n "''${MCL_DEPLOY_PREP_ROOT:-}" ]; then
                printf '%s%s\n' "$MCL_DEPLOY_PREP_ROOT" "$configured"
                return
              fi
            ''}
            printf '%s\n' "$configured"
          }

          validate_component_chain() {
            local path="$1"
            local remaining="''${path#/}"
            local current=""
            local component
            while [ -n "$remaining" ]; do
              component="''${remaining%%/*}"
              if [ "$remaining" = "$component" ]; then
                remaining=""
              else
                remaining="''${remaining#*/}"
              fi
              current="$current/$component"
              if [ -L "$current" ]; then
                fail "refusing symlink path component: $current"
              fi
              if [ -e "$current" ] && [ ! -d "$current" ]; then
                fail "path component is not a directory: $current"
              fi
            done
          }

          expected_uid=${
            if cfg.preparationExpectedUid == null then
              ''"$(${pkgs.coreutils}/bin/id -u)"''
            else
              toString cfg.preparationExpectedUid
          }
          expected_gid=${
            if cfg.preparationExpectedGid == null then
              ''"$(${pkgs.coreutils}/bin/id -g)"''
            else
              toString cfg.preparationExpectedGid
          }
          ${lib.optionalString cfg.preparationAllowTestOverrides ''
            expected_uid="''${MCL_DEPLOY_PREP_EXPECTED_UID:-$expected_uid}"
            expected_gid="''${MCL_DEPLOY_PREP_EXPECTED_GID:-$expected_gid}"
            expected_log_uid="''${MCL_DEPLOY_PREP_EXPECTED_LOG_UID:-$expected_uid}"
            expected_log_gid="''${MCL_DEPLOY_PREP_EXPECTED_LOG_GID:-$expected_gid}"
          ''}
          ${lib.optionalString (!cfg.preparationAllowTestOverrides) ''
            expected_log_uid="$expected_uid"
            expected_log_gid="$expected_gid"
          ''}

          path_exists() {
            [ -e "$1" ] || [ -L "$1" ]
          }

          inode_identity() {
            ${pkgs.coreutils}/bin/stat -c '%d:%i' -- "$1"
          }

          remember_original() {
            local kind="$1"
            local configured="$2"
            local path
            path="$(runtime_path "$configured")"
            path_exists "$path" || return 0
            original_paths+=("$path")
            original_kinds+=("$kind")
            original_identities+=("$(inode_identity "$path")")
            original_modes+=("$(${pkgs.coreutils}/bin/stat -c %a -- "$path")")
            original_uids+=("$(${pkgs.coreutils}/bin/stat -c %u -- "$path")")
            original_gids+=("$(${pkgs.coreutils}/bin/stat -c %g -- "$path")")
          }

          remember_created() {
            local kind="$1"
            local path="$2"
            created_paths+=("$path")
            created_kinds+=("$kind")
            created_identities+=("$(inode_identity "$path")")
            mutation_started=1
          }

          safe_identity() {
            local path="$1"
            local kind="$2"
            local identity="$3"
            local uid="$4"
            local gid="$5"
            path_exists "$path" || return 1
            [ ! -L "$path" ] || return 1
            [ "$(inode_identity "$path")" = "$identity" ] || return 1
            [ "$(${pkgs.coreutils}/bin/stat -c %u -- "$path")" = "$uid" ] || return 1
            [ "$(${pkgs.coreutils}/bin/stat -c %g -- "$path")" = "$gid" ] || return 1
            case "$kind" in
              directory)
                [ "$(${pkgs.coreutils}/bin/stat -c %F -- "$path")" = directory ]
                ;;
              log)
                case "$(${pkgs.coreutils}/bin/stat -c %F -- "$path")" in
                  "regular file"|"regular empty file") ;;
                  *) return 1 ;;
                esac
                [ "$(${pkgs.coreutils}/bin/stat -c %h -- "$path")" = 1 ]
                ;;
              *) return 1 ;;
            esac
          }

          verify_original_identity() {
            local path="$1"
            local kind="$2"
            local index
            for ((index=0; index<''${#original_paths[@]}; index++)); do
              if [ "''${original_paths[$index]}" = "$path" ]; then
                [ "''${original_kinds[$index]}" = "$kind" ] \
                  || fail "snapshotted managed object changed kind: $path"
                safe_identity "$path" "$kind" "''${original_identities[$index]}" \
                  "''${original_uids[$index]}" "''${original_gids[$index]}" \
                  || fail "snapshotted managed object changed identity: $path"
                return 0
              fi
            done
            return 1
          }

          verify_created_identity() {
            local path="$1"
            local kind="$2"
            local index uid gid
            for ((index=0; index<''${#created_paths[@]}; index++)); do
              if [ "''${created_paths[$index]}" = "$path" ]; then
                [ "''${created_kinds[$index]}" = "$kind" ] \
                  || fail "created managed object changed kind: $path"
                if [ "$kind" = log ]; then
                  uid="$expected_log_uid"
                  gid="$expected_log_gid"
                else
                  uid="$expected_uid"
                  gid="$expected_gid"
                fi
                safe_identity "$path" "$kind" "''${created_identities[$index]}" "$uid" "$gid" \
                  || fail "created managed object changed identity: $path"
                return 0
              fi
            done
            return 1
          }

          verify_tracked_identity() {
            local kind="$1"
            local configured="$2"
            local path
            path="$(runtime_path "$configured")"
            verify_original_identity "$path" "$kind" && return 0
            verify_created_identity "$path" "$kind" && return 0
            fail "managed object is not bound to this transaction: $path"
          }

          verify_all_snapshotted_identities() {
            local index
            for ((index=0; index<''${#original_paths[@]}; index++)); do
              safe_identity "''${original_paths[$index]}" "''${original_kinds[$index]}" \
                "''${original_identities[$index]}" "''${original_uids[$index]}" \
                "''${original_gids[$index]}" \
                || fail "snapshotted managed object changed identity: ''${original_paths[$index]}"
            done
          }

          verify_all_created_identities() {
            local index uid gid
            for ((index=0; index<''${#created_paths[@]}; index++)); do
              if [ "''${created_kinds[$index]}" = log ]; then
                uid="$expected_log_uid"
                gid="$expected_log_gid"
              else
                uid="$expected_uid"
                gid="$expected_gid"
              fi
              safe_identity "''${created_paths[$index]}" "''${created_kinds[$index]}" \
                "''${created_identities[$index]}" "$uid" "$gid" \
                || fail "created managed object changed identity: ''${created_paths[$index]}"
            done
          }

          rollback_transaction() {
            local rollback_failed=0
            local index path kind identity original_mode current_mode target_mode

            ${lib.optionalString cfg.preparationAllowTestOverrides ''
              if [ "''${MCL_DEPLOY_PREP_INJECT_ROLLBACK_FAILURE:-0}" = 1 ]; then
                    printf '%s\n' 'mcl deployment path preparation: injected rollback failure' >&2
                    rollback_failed=1
                  fi
            ''}

            # Restore pre-existing inodes before removing new children. Refuse to
            # chmod a replaced inode or one whose mode changed to a third value
            # after our repair; that object belongs to the racing writer.
            for ((index=''${#original_paths[@]} - 1; index >= 0; index--)); do
              path="''${original_paths[$index]}"
              kind="''${original_kinds[$index]}"
              identity="''${original_identities[$index]}"
              original_mode="''${original_modes[$index]}"
              if ! safe_identity "$path" "$kind" "$identity" \
                "''${original_uids[$index]}" "''${original_gids[$index]}"; then
                printf 'mcl deployment path preparation: rollback preserved raced object: %s\n' "$path" >&2
                rollback_failed=1
                continue
              fi
              current_mode="$(${pkgs.coreutils}/bin/stat -c %a -- "$path")"
              if [ "$kind" = directory ]; then
                target_mode=750
              else
                target_mode=640
              fi
              if [ "$current_mode" != "$original_mode" ] && [ "$current_mode" != "$target_mode" ]; then
                printf 'mcl deployment path preparation: rollback preserved externally remoded object: %s\n' "$path" >&2
                rollback_failed=1
                continue
              fi
              if [ "$current_mode" != "$original_mode" ] \
                && ! ${pkgs.coreutils}/bin/chmod "$original_mode" -- "$path"; then
                printf 'mcl deployment path preparation: could not restore original mode: %s\n' "$path" >&2
                rollback_failed=1
              fi
            done

            # New objects are removed in exact reverse creation order. A fixture
            # hook can deterministically replace one after the transaction has
            # failed; the identity check then proves the replacement is preserved.
            for ((index=''${#created_paths[@]} - 1; index >= 0; index--)); do
              path="''${created_paths[$index]}"
              kind="''${created_kinds[$index]}"
              identity="''${created_identities[$index]}"
              ${lib.optionalString cfg.preparationAllowTestOverrides ''
                if [ -n "''${MCL_DEPLOY_PREP_ROLLBACK_HOOK:-}" ]; then
                  "$MCL_DEPLOY_PREP_ROLLBACK_HOOK" "$kind" "$path" "$index" || rollback_failed=1
                fi
              ''}
              if ! safe_identity "$path" "$kind" "$identity" "$expected_uid" "$expected_gid"; then
                printf 'mcl deployment path preparation: rollback preserved raced object: %s\n' "$path" >&2
                rollback_failed=1
                continue
              fi
              if [ "$kind" = log ]; then
                if ! ${pkgs.coreutils}/bin/rm -f -- "$path"; then
                  printf 'mcl deployment path preparation: could not remove created log: %s\n' "$path" >&2
                  rollback_failed=1
                fi
              elif ! ${pkgs.coreutils}/bin/rmdir -- "$path"; then
                printf 'mcl deployment path preparation: could not remove created directory: %s\n' "$path" >&2
                rollback_failed=1
              fi
            done
            return "$rollback_failed"
          }

          on_exit() {
            local status=$?
            local rollback_status=0
            trap - EXIT
            if [ "$status" -ne 0 ] && [ "$mutation_started" -eq 1 ] \
              && [ "$transaction_complete" -eq 0 ]; then
              set +e
              rollback_transaction
              rollback_status=$?
              set -e
            fi
            if [ "$rollback_status" -ne 0 ]; then
              printf 'mcl deployment path preparation: transactional rollback was incomplete\n' >&2
              [ "$status" -ne 0 ] || status=1
            fi
            exit "$status"
          }
          trap on_exit EXIT

          validate_existing_directory() {
            local configured="$1"
            local path
            path="$(runtime_path "$configured")"
            validate_component_chain "$path"
            path_exists "$path" || return 0
            [ "$(${pkgs.coreutils}/bin/stat -c %F -- "$path")" = directory ] \
              || fail "managed path is not a directory: $path"
            [ "$(${pkgs.coreutils}/bin/stat -c %u -- "$path")" = "$expected_uid" ] \
              || fail "managed directory has wrong owner: $path"
            [ "$(${pkgs.coreutils}/bin/stat -c %g -- "$path")" = "$expected_gid" ] \
              || fail "managed directory has wrong group: $path"
          }

          validate_existing_log_file() {
            local configured="$1"
            local path
            path="$(runtime_path "$configured")"
            validate_component_chain "$(${pkgs.coreutils}/bin/dirname -- "$path")"
            path_exists "$path" || return 0
            [ ! -L "$path" ] || fail "managed log is a symlink: $path"
            case "$(${pkgs.coreutils}/bin/stat -c %F -- "$path")" in
              "regular file"|"regular empty file") ;;
              *) fail "managed log is not a regular file: $path" ;;
            esac
            [ "$(${pkgs.coreutils}/bin/stat -c %h -- "$path")" = 1 ] \
              || fail "managed log has multiple hard links: $path"
            [ "$(${pkgs.coreutils}/bin/stat -c %u -- "$path")" = "$expected_log_uid" ] \
              || fail "managed log has wrong owner: $path"
            [ "$(${pkgs.coreutils}/bin/stat -c %g -- "$path")" = "$expected_log_gid" ] \
              || fail "managed log has wrong group: $path"
          }

          create_directory_if_missing() {
            local configured="$1"
            local path
            path="$(runtime_path "$configured")"
            if ! path_exists "$path"; then
              ${lib.optionalString cfg.preparationAllowTestOverrides ''
                if [ "''${MCL_DEPLOY_PREP_INJECT_FAILURE:-}" = late-directory-create ] \
                  && [ "$directory_create_count" -ge 2 ]; then
                  fail "injected late directory creation failure: $path"
                fi
                if [ -n "''${MCL_DEPLOY_PREP_BEFORE_CREATE_HOOK:-}" ]; then
                  "$MCL_DEPLOY_PREP_BEFORE_CREATE_HOOK" directory "$path"
                fi
              ''}
              if ${pkgs.coreutils}/bin/mkdir -m 0750 -- "$path"; then
                remember_created directory "$path"
                directory_create_count=$((directory_create_count + 1))
                ${lib.optionalString (fileChownOwnership != "") ''
                  ${chownCommand} -h ${escapeShellArg fileChownOwnership} -- "$path" \
                    || fail "could not set managed directory ownership: $path"
                ''}
              else
                fail "managed directory appeared during creation: $path"
              fi
            fi
            validate_existing_directory "$configured"
          }

          create_log_file_if_missing() {
            local configured="$1"
            local path
            path="$(runtime_path "$configured")"
            if ! path_exists "$path"; then
              ${lib.optionalString cfg.preparationAllowTestOverrides ''
                if [ -n "''${MCL_DEPLOY_PREP_BEFORE_CREATE_HOOK:-}" ]; then
                  "$MCL_DEPLOY_PREP_BEFORE_CREATE_HOOK" log "$path"
                fi
              ''}
              if ( set -o noclobber; umask 0137; : > "$path" ) 2>/dev/null; then
                remember_created log "$path"
                log_create_count=$((log_create_count + 1))
                ${lib.optionalString cfg.preparationAllowTestOverrides ''
                  if [ "''${MCL_DEPLOY_PREP_INJECT_FAILURE:-}" = late-log-create ] \
                    && [ "$log_create_count" -ge 2 ]; then
                    fail "injected late log creation/chown failure: $path"
                  fi
                ''}
                ${lib.optionalString (fileChownOwnership != "") ''
                  ${chownCommand} -h ${escapeShellArg fileChownOwnership} -- "$path" \
                    || fail "could not set managed log ownership: $path"
                ''}
              else
                fail "managed log appeared during creation: $path"
              fi
            fi
            validate_existing_log_file "$configured"
          }

          repair_directory_mode() {
            local configured="$1"
          local path
          path="$(runtime_path "$configured")"
            validate_existing_directory "$configured"
            verify_tracked_identity directory "$configured"
            mutation_started=1
            ${pkgs.coreutils}/bin/chmod 0750 -- "$path" \
              || fail "could not repair managed directory mode: $path"
            chmod_count=$((chmod_count + 1))
            validate_existing_directory "$configured"
            [ "$(${pkgs.coreutils}/bin/stat -c %a -- "$path")" = 750 ] \
              || fail "managed directory has wrong mode: $path"
            ${lib.optionalString cfg.preparationAllowTestOverrides ''
              if [ "''${MCL_DEPLOY_PREP_INJECT_FAILURE:-}" = late-chmod ] \
                && [ "$chmod_count" -ge 2 ]; then
                fail "injected late chmod failure: $path"
              fi
            ''}
          }

          repair_log_mode() {
            local configured="$1"
          local path
          path="$(runtime_path "$configured")"
            validate_existing_log_file "$configured"
            verify_tracked_identity log "$configured"
            mutation_started=1
            ${pkgs.coreutils}/bin/chmod 0640 -- "$path" \
              || fail "could not repair managed log mode: $path"
            chmod_count=$((chmod_count + 1))
            validate_existing_log_file "$configured"
            [ "$(${pkgs.coreutils}/bin/stat -c %a -- "$path")" = 640 ] \
              || fail "managed log has wrong mode: $path"
            ${lib.optionalString cfg.preparationAllowTestOverrides ''
              if [ "''${MCL_DEPLOY_PREP_INJECT_FAILURE:-}" = late-chmod ] \
                && [ "$chmod_count" -ge 2 ]; then
                fail "injected late chmod failure: $path"
              fi
            ''}
          }

          # First validate every pre-existing managed path. No chmod, chown,
          # install, mkdir, or file creation occurs until this complete pass has
          # rejected wrong owners, groups, types, symlinks, and hard links.
          ${concatMapStringsSep "\n" (dir: ''
            validate_existing_directory ${escapeShellArg dir}
          '') managedDirectories}
          ${concatMapStringsSep "\n" (file: ''
            validate_existing_log_file ${escapeShellArg file}
          '') durableLogFiles}
          ${concatMapStringsSep "\n" (dir: ''
            remember_original directory ${escapeShellArg dir}
          '') managedDirectories}
          ${concatMapStringsSep "\n" (file: ''
            remember_original log ${escapeShellArg file}
          '') durableLogFiles}
          ${lib.optionalString cfg.preparationAllowTestOverrides ''
            if [ -n "''${MCL_DEPLOY_PREP_AFTER_SNAPSHOT_HOOK:-}" ]; then
              "$MCL_DEPLOY_PREP_AFTER_SNAPSHOT_HOOK"
            fi
          ''}

          # Missing paths are created in parent-first order. Ownership is set
          # only for an inode this invocation created; existing ownership is
          # never normalized.
          ${concatMapStringsSep "\n" (dir: ''
            create_directory_if_missing ${escapeShellArg dir}
          '') managedDirectories}
          ${concatMapStringsSep "\n" (file: ''
            create_log_file_if_missing ${escapeShellArg file}
          '') durableLogFiles}

          # Revalidate the complete set after creation and before the first mode
          # repair, then repair only the modes of validated managed paths.
          ${lib.optionalString cfg.preparationAllowTestOverrides ''
            if [ "''${MCL_DEPLOY_PREP_INJECT_FAILURE:-}" = revalidation ]; then
              fail "injected complete-set revalidation failure"
            fi
          ''}
          verify_all_snapshotted_identities
          verify_all_created_identities
          ${concatMapStringsSep "\n" (dir: ''
            validate_existing_directory ${escapeShellArg dir}
          '') managedDirectories}
          ${concatMapStringsSep "\n" (file: ''
            validate_existing_log_file ${escapeShellArg file}
          '') durableLogFiles}
          ${concatMapStringsSep "\n" (dir: ''
            repair_directory_mode ${escapeShellArg dir}
          '') managedDirectories}
          ${concatMapStringsSep "\n" (file: ''
            repair_log_mode ${escapeShellArg file}
          '') durableLogFiles}
          # Do not disarm rollback unless every pre-existing and invocation-
          # created object is still the exact device:inode bound to this
          # transaction after the final metadata repair.
          verify_all_snapshotted_identities
          verify_all_created_identities
          transaction_complete=1
        '';
      };
    in
    {
      options.services.mcl-deploy-agent = {
        enable = mkEnableOption "root nix-darwin pull agent for signed mcl deployment manifests";

        package = mkOption {
          type = types.package;
          default = defaultPackage;
          description = "Package providing the mcl-devops binary used by the generation-stable wrapper.";
        };

        targetName = mkOption {
          type = types.str;
          default = config.networking.hostName;
          description = "Expected manifest target name. The agent rejects every other target.";
        };

        stateDir = mkOption {
          type = types.str;
          default = "/private/var/lib/mcl/deployments";
          description = "Target-local durable deployment state directory.";
        };

        eventLog = mkOption {
          type = types.str;
          default = "/private/var/log/mcl/deployments/${cfg.targetName}.jsonl";
          description = "Target-side deployment event JSONL log path.";
        };

        standardOutLog = mkOption {
          type = types.str;
          default = "/private/var/log/mcl/deployments/${cfg.targetName}-agent.stdout.log";
          description = "Durable stdout log for the launchd job.";
        };

        standardErrorLog = mkOption {
          type = types.str;
          default = "/private/var/log/mcl/deployments/${cfg.targetName}-agent.stderr.log";
          description = "Durable stderr log for the launchd job.";
        };

        manifestPrincipal = mkOption {
          type = types.str;
          default = "mcl-deployment";
          description = "OpenSSH allowed-signers principal for deployment manifest signatures.";
        };

        manifestPublicKeys = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "OpenSSH public keys trusted to sign deployment manifests.";
        };

        manifestSources = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Exact signed manifest files or HTTP(S) URLs polled by the agent.";
        };

        manifestDirectories = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Directories containing signed manifests for this target only.";
        };

        maxAttempts = mkOption {
          type = types.ints.positive;
          default = 3;
          description = "Maximum apply attempts for one deployment before marking it non-retryable.";
        };

        fetchTimeoutSeconds = mkOption {
          type = types.ints.positive;
          default = 30;
          description = "Timeout used when fetching HTTP(S) manifest sources.";
        };

        intervalSeconds = mkOption {
          type = types.ints.positive;
          default = 15 * 60;
          description = "launchd StartInterval, in seconds, for polling desired state.";
        };

        lockFile = mkOption {
          type = types.str;
          default = "/private/var/run/mcl/deployments/${cfg.targetName}.lock";
          description = "Non-blocking flock file that prevents overlapping polls for this target.";
        };

        systemProfile = mkOption {
          type = types.str;
          default = "/nix/var/nix/profiles/system";
          description = "nix-darwin system profile selected atomically before activation.";
        };

        preSwitchHook = mkOption {
          type = types.coercedTo types.package toString types.str;
          default = "";
          description = "Optional executable readiness hook called with DESIRED PREVIOUS.";
        };

        postSwitchHook = mkOption {
          type = types.coercedTo types.package toString types.str;
          default = "";
          description = "Optional executable cleanup hook called with DESIRED PREVIOUS OUTCOME.";
        };

        alreadyCurrentRecoveryHook = mkOption {
          type = types.coercedTo types.package toString types.str;
          default = "";
          description = ''
            Recovery-only executable called with DESIRED CURRENT when the
            authenticated desired generation is already selected. It must verify that
            lifecycle state is clean or complete retained recovery without
            starting a new deployment transaction.
          '';
        };

        runtimePrerequisite = mkOption {
          type = types.coercedTo types.package toString types.str;
          default = "";
          description = ''
            Optional executable invoked before every poll. A non-zero exit
            fails closed before manifest retrieval or closure restoration.
          '';
        };

        dryRun = mkOption {
          type = types.bool;
          default = false;
          description = "Verify manifests and write state/events without restore or activation.";
        };

        preparationPackage = mkOption {
          type = types.package;
          readOnly = true;
          internal = true;
          description = "Executable that safely prepares and verifies dedicated durable paths.";
        };

        preparationOwner = mkOption {
          type = types.nullOr types.str;
          default = "root";
          internal = true;
          description = "Owner applied by the durable-path preparation executable.";
        };

        preparationGroup = mkOption {
          type = types.nullOr types.str;
          default = "wheel";
          internal = true;
          description = "Group applied by the durable-path preparation executable.";
        };

        preparationExpectedUid = mkOption {
          type = types.nullOr types.int;
          default = 0;
          internal = true;
          description = "Numeric UID required after durable-path preparation.";
        };

        preparationExpectedGid = mkOption {
          type = types.nullOr types.int;
          default = 0;
          internal = true;
          description = "Numeric GID required after durable-path preparation.";
        };

        preparationAllowedRoots = mkOption {
          type = types.listOf types.str;
          default = [
            "/private/var/lib"
            "/private/var/log"
            "/private/var/run"
          ];
          internal = true;
          description = "Shared roots beneath which dedicated paths may be prepared.";
        };

        preparationAllowTestOverrides = mkOption {
          type = types.bool;
          default = false;
          internal = true;
          description = "Enable fixture-only root and ownership overrides in the preparation executable.";
        };

        preparationFixtureChownCommand = mkOption {
          type = types.nullOr types.str;
          default = null;
          internal = true;
          description = "Nix-evaluation-only fixture chown executable; production must use coreutils chown.";
        };
      };

      config = mkIf cfg.enable {
        assertions = [
          {
            assertion = cfg.manifestPublicKeys != [ ];
            message = "services.mcl-deploy-agent.manifestPublicKeys must not be empty.";
          }
          {
            assertion = cfg.manifestSources != [ ] || cfg.manifestDirectories != [ ];
            message = "services.mcl-deploy-agent needs at least one manifest source or directory.";
          }
          {
            assertion = lib.all isNormalizedAbsolute (
              durableLeafDirectories ++ durableLogFiles ++ [ cfg.systemProfile ]
            );
            message = "services.mcl-deploy-agent paths must be absolute and lexically normalized.";
          }
          {
            assertion = lib.all isDedicatedPath durableLeafDirectories;
            message = "services.mcl-deploy-agent durable directories must be dedicated paths nested beneath approved roots.";
          }
          {
            assertion = lib.all (dir: hasPrefix "${cfg.stateDir}/" dir) cfg.manifestDirectories;
            message = "services.mcl-deploy-agent manifestDirectories must be nested beneath stateDir.";
          }
          {
            assertion = lib.all (file: isDedicatedPath (builtins.dirOf file)) durableLogFiles;
            message = "services.mcl-deploy-agent logs must live in dedicated directories beneath approved roots.";
          }
          {
            assertion =
              cfg.preparationAllowTestOverrides
              || (
                cfg.preparationOwner == "root"
                && cfg.preparationGroup == "wheel"
                && cfg.preparationExpectedUid == 0
                && cfg.preparationExpectedGid == 0
                &&
                  cfg.preparationAllowedRoots == [
                    "/private/var/lib"
                    "/private/var/log"
                    "/private/var/run"
                  ]
                && cfg.preparationFixtureChownCommand == null
              );
            message = "services.mcl-deploy-agent production path preparation is fixed to canonical /private/var roots and root:wheel (0:0).";
          }
          {
            assertion = cfg.preparationFixtureChownCommand == null || cfg.preparationAllowTestOverrides;
            message = "services.mcl-deploy-agent fixture chown command requires test-only preparation overrides.";
          }
          {
            assertion =
              (cfg.preSwitchHook == "" && cfg.postSwitchHook == "") || cfg.alreadyCurrentRecoveryHook != "";
            message = "services.mcl-deploy-agent lifecycle hooks require alreadyCurrentRecoveryHook for safe exact-current convergence.";
          }
        ];

        services.mcl-deploy-agent.preparationPackage = preparationPackage;

        environment.systemPackages = [
          cfg.package
          launchdLauncherPackage
          entrypointPackage
        ];

        # This runs before nix-darwin reconciles launchd jobs, so launchd can
        # open its stdout/stderr paths on the first load. The executable only
        # normalizes dedicated MCL paths and refuses every symlink component.
        system.activationScripts.preActivation.text = lib.mkAfter ''
          ${getExe preparationPackage}
        '';

        launchd.daemons.mcl-deploy-agent = {
          serviceConfig = {
            Label = "org.metacraft-labs.mcl-deploy-agent";
            # `/bin/wait4path /nix/store` first: at boot launchd spawns
            # RunAtLoad jobs before the /nix APFS volume is mounted, and a job
            # whose executable is a store path then fails with EX_CONFIG and
            # is never spawned again (m3, 2026-09-21: no poll for two days).
            # nix-darwin's `command` option adds this; raw ProgramArguments
            # must do it explicitly. `exec "$@"` keeps the argv verbatim.
            ProgramArguments = [
              "/bin/sh"
              "-c"
              ''/bin/wait4path /nix/store && exec "$@"''
              "mcl-deploy-agent"
              (getExe launchdLauncherPackage)
              stableEntrypoint
              "120"
              "1"
            ];
            UserName = "root";
            GroupName = "wheel";
            RunAtLoad = true;
            StartInterval = cfg.intervalSeconds;
            StandardOutPath = cfg.standardOutLog;
            StandardErrorPath = cfg.standardErrorLog;
            ProcessType = "Background";
            ThrottleInterval = 10;
          };
        };
      };
    };
}
