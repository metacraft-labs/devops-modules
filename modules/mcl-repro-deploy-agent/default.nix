{ inputs, withSystem, ... }:
{
  # Windows-Runner-Binary-Cache-Deploy M7 prereq (c) — the reprobuild-native
  # analog of `services.mcl-deploy-agent` (nixos-modules deployment-pull-agent).
  #
  # A oneshot + timer that runs `repro deploy-agent` for a target against one or
  # more signed desired-state manifest sources (HTTP(S) URLs or local paths).
  # Each tick polls every source, verifies each candidate manifest against an
  # `--allowed-signers` allowlist (the cache's trust-anchor format: one 130-char
  # hex ECDSA-P256 pubkey per line — reprobuild's OWN signing scheme, NOT the
  # OpenSSH allowed-signers model the Linux agent uses), and applies the highest
  # valid sequence via the M4 `runInfraApply` path (build-action outputs
  # substituted from the binary cache when `REPRO_BINARY_CACHE_URL` is set).
  #
  # For HTTPS manifest / cache sources the agent's `defaultHttpGet` +
  # `http_pool` TLS paths verify the server certificate against the CA in
  # `REPRO_BINARY_CACHE_CA_FILE` (M7 prereq b) — this module exports that env
  # var when `caFile` is set. Opt-in (enable default off); hardened like the
  # sibling `mcl-repro-binary-cache` unit.
  flake.modules.nixos.mcl-repro-deploy-agent =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.mcl-repro-deploy-agent;
      inherit (lib)
        escapeShellArg
        getExe
        mkEnableOption
        mkIf
        mkOption
        types
        ;

      # Default to the reprobuild flake's `repro` binary (the `default`/
      # `reprobuild` package, mainProgram=repro) built for this host's system.
      # That binary carries the `deploy-agent` verb (M5) and, since M7 prereq
      # (a), is compiled `-d:ssl` so its cache-consumer paths can speak https://.
      defaultPackage = withSystem pkgs.stdenv.hostPlatform.system (
        { inputs', ... }: inputs'.reprobuild.packages.reprobuild
      );

      # The apply path shells out to `repro __repro-compile-profile`, which
      # compiles the desired-state profile with Nim. The current reprobuild
      # release looks Nim up on PATH and fails the tick outright when it is
      # absent ("vendored-Nim auto-bootstrap is deferred to a later phase"), so
      # supplying it is the consumer's job. Take the same Nim reprobuild builds
      # itself with, plus the C toolchain Nim drives to link the profile.
      defaultProfileCompilerPath = withSystem pkgs.stdenv.hostPlatform.system (
        { inputs', ... }:
        [
          inputs'.reprobuild.packages.nim-fork
          pkgs.gcc
          pkgs.binutils
        ]
      );

      # The allowlist may be provided inline (a list of 130-char hex pubkeys) or
      # as an out-of-store path. Inline keys are rendered to a store file.
      inlineAllowedSigners = pkgs.writeText "mcl-repro-deploy-agent-allowed-signers" (
        lib.concatMapStringsSep "\n" (k: k) cfg.allowedSigners + "\n"
      );
      allowedSignersFile =
        if cfg.allowedSignersFile != null then cfg.allowedSignersFile else inlineAllowedSigners;

      agentArgs = lib.escapeShellArgs (
        [
          "deploy-agent"
          "--target"
          cfg.targetName
          "--allowed-signers"
          "${allowedSignersFile}"
          "--state-dir"
          cfg.stateDir
          "--fetch-timeout-ms"
          (toString cfg.fetchTimeoutMs)
        ]
        ++ lib.concatMap (s: [
          "--manifest"
          s
        ]) cfg.manifestSources
        ++ lib.optionals (cfg.cacheRoot != null) [
          "--cache-root"
          cfg.cacheRoot
        ]
        ++ lib.optionals (cfg.hostIdentity != null) [
          "--host"
          cfg.hostIdentity
        ]
      );

      agentCommand = "${getExe cfg.package} ${agentArgs}";
    in
    {
      options.services.mcl-repro-deploy-agent = {
        enable = mkEnableOption "the reprobuild signed desired-state pull agent (repro deploy-agent)";

        package = mkOption {
          type = types.package;
          default = defaultPackage;
          defaultText = lib.literalMD "the reprobuild flake's `reprobuild` (`repro`) package";
          description = "Package providing the `repro` binary (with the `deploy-agent` verb).";
        };

        repoRoot = mkOption {
          type = types.str;
          default = "${inputs.reprobuild}";
          defaultText = lib.literalMD "the reprobuild flake input's source tree";
          description = ''
            Value for `$REPROBUILD_REPO_ROOT`. `repro`'s profile compiler
            resolves reprobuild's Nim library sources beneath this path and
            runs `nim` with it as the working directory.
          '';
        };

        profileCompilerPath = mkOption {
          type = types.listOf types.package;
          default = defaultProfileCompilerPath;
          defaultText = lib.literalMD "the reprobuild flake's `nim-fork`, plus `gcc` and `binutils`";
          description = ''
            Packages placed on the unit's PATH so that `repro`'s apply path can
            compile the desired-state profile. The current reprobuild release
            requires `nim` on PATH and fails the tick with
            `profile compilation failed` without it.
          '';
        };

        targetName = mkOption {
          type = types.str;
          default = config.networking.hostName;
          description = "Expected manifest target name. The agent ignores every other target.";
        };

        manifestSources = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "https://cache.example.com/deployments/host/latest.rdm" ];
          description = ''
            Signed desired-state manifest sources polled each tick. Each is a
            local path or an HTTP(S) URL. For https:// sources the certificate
            is verified against `caFile` (`REPRO_BINARY_CACHE_CA_FILE`).
          '';
        };

        allowedSigners = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "0466620ee5...(130 hex chars)" ];
          description = ''
            Inline allowlist of trusted producer public keys: one 130-char hex
            uncompressed ECDSA-P256 pubkey per entry (the cache's trust-anchor
            format). Rendered to a store file and passed as `--allowed-signers`.
            Ignored when `allowedSignersFile` is set.
          '';
        };

        allowedSignersFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            Path to an allowed-signers file (one 130-char hex ECDSA-P256 pubkey
            per line). Takes precedence over `allowedSigners`. Use this for a
            secret-managed anchor file (e.g. agenix) rather than a store path.
          '';
        };

        stateDir = mkOption {
          type = types.str;
          default = "/var/lib/repro-deploy-agent";
          description = ''
            Durable per-target agent state directory (holds the monotonic
            last-applied-sequence floor under `deploy-agent/<target>.seq` and,
            unless `cacheRoot` overrides it, the apply-scoped engine cache).
            Provisioned as a systemd StateDirectory.
          '';
        };

        cacheRoot = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Optional apply-scoped engine/binary-cache-substitute cache root
            (`--cache-root`). Null lets the agent default it to
            `<stateDir>/cache`.
          '';
        };

        hostIdentity = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Optional host identity passed to the apply hook (`--host`).";
        };

        binaryCacheUrl = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "https://cache.example.com:7878";
          description = ''
            Binary-cache URL exported as `REPRO_BINARY_CACHE_URL` so converged
            build-action outputs are substituted from the cache instead of
            being built locally. Null ⇒ the substitute path is a no-op (apply
            builds locally). https:// requires `caFile` (or `tlsInsecure`).
          '';
        };

        caFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            PEM CA/self-signed certificate the agent verifies https:// manifest
            and cache endpoints against, exported as `REPRO_BINARY_CACHE_CA_FILE`.
            Loaded via systemd LoadCredential so it need not be world-readable.
          '';
        };

        tlsInsecure = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Disable TLS peer verification for https:// sources
            (`REPRO_BINARY_CACHE_TLS_INSECURE=1`). For debugging only; prefer
            `caFile`. Ignored when `caFile` is set to a real anchor.
          '';
        };

        fetchTimeoutMs = mkOption {
          type = types.ints.positive;
          default = 30000;
          description = "Per-source manifest fetch timeout in milliseconds (`--fetch-timeout-ms`).";
        };

        interval = mkOption {
          type = types.str;
          default = "15min";
          description = "systemd OnUnitActiveSec interval for polling desired state.";
        };

        jitter = mkOption {
          type = types.str;
          default = "5min";
          description = "systemd RandomizedDelaySec for polling.";
        };

        timeoutStartSec = mkOption {
          type = types.ints.positive;
          default = 3600;
          description = ''
            Bound on a single apply tick (TimeoutStartSec). Leaves headroom for a
            cold closure substitute; a wedged apply fails and retries next tick
            instead of blocking all deploys forever (mirrors the mcl-deploy-agent
            bound added for the switch-to-configuration hang class).
          '';
        };

        runOnBoot = mkOption {
          type = types.bool;
          default = true;
          description = "Also trigger a tick shortly after boot (timer OnActiveSec).";
        };
      };

      config = mkIf cfg.enable {
        assertions = [
          {
            assertion = cfg.manifestSources != [ ];
            message = "services.mcl-repro-deploy-agent.manifestSources must not be empty.";
          }
          {
            assertion = cfg.allowedSigners != [ ] || cfg.allowedSignersFile != null;
            message =
              "services.mcl-repro-deploy-agent needs allowedSigners (inline) or " + "allowedSignersFile.";
          }
        ];

        environment.systemPackages = [ cfg.package ];

        systemd.services.mcl-repro-deploy-agent = {
          description = "Pull + apply signed reprobuild desired-state manifests for ${cfg.targetName}";
          documentation = [ "https://github.com/metacraft-labs/reprobuild" ];
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];

          # `repro` compiles the desired-state profile with Nim during apply;
          # systemd units get an empty PATH, so it has to be handed one.
          path = cfg.profileCompilerPath;

          serviceConfig = {
            Type = "oneshot";
            ExecStart = agentCommand;

            # Durable per-target floor + apply state.
            StateDirectory = "repro-deploy-agent";
            StateDirectoryMode = "0700";

            # M7 prereq (b): the deploy-agent's TLS paths verify against this CA.
            # Staged via LoadCredential so a secret-managed CA path is readable
            # by the sandboxed unit without being world-readable.
            LoadCredential = lib.optional (cfg.caFile != null) "ca:${cfg.caFile}";

            Environment =
              lib.optional (cfg.binaryCacheUrl != null) "REPRO_BINARY_CACHE_URL=${cfg.binaryCacheUrl}"
              ++ lib.optional (cfg.caFile != null) "REPRO_BINARY_CACHE_CA_FILE=%d/ca"
              ++ lib.optional (cfg.tlsInsecure && cfg.caFile == null) "REPRO_BINARY_CACHE_TLS_INSECURE=1"
              # NOTE: the packaged `repro` dlopen()s libclingo.so + libzstd.so.1
              # (repro_solver + the binary-cache streaming path) but is now
              # SELF-CONTAINED — reprobuild's flake.nix postFixup bakes both into
              # the binary's DT_RPATH, so no LD_LIBRARY_PATH is needed here.
              # The apply path shells out to `repro` for profile compilation; give
              # it a writable HOME/cache under the runtime dir.
              ++ [
                "HOME=%S/repro-deploy-agent"
                "XDG_CACHE_HOME=%S/repro-deploy-agent/.cache"
                # The profile compiler resolves reprobuild's own Nim libraries
                # relative to $REPROBUILD_REPO_ROOT, falling back to a path
                # baked in at reprobuild build time — which, in reprobuild's
                # own words, "is NOT guaranteed to exist on installed
                # deployments". On a NixOS host it does not, so `nim` was
                # spawned with a working directory that is not there and the
                # apply died in setCurrentDir with ENOENT. reprobuild's wrapper
                # already pins the packaged tree as $REPROBUILD_SOURCE_ROOT for
                # its other entry points but never feeds it to this one; point
                # it at the same source.
                "REPROBUILD_REPO_ROOT=${cfg.repoRoot}"
              ];

            TimeoutStartSec = cfg.timeoutStartSec;

            # Hardening — mirror the mcl-repro-binary-cache sibling. The apply
            # path may need to spawn build actions, so this is intentionally a
            # touch looser than the daemon (no MemoryDenyWriteExecute), matching
            # the mcl-deploy-agent posture.
            NoNewPrivileges = true;
            ProtectSystem = "strict";
            ReadWritePaths = [ cfg.stateDir ];
            ProtectHome = true;
            PrivateTmp = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectKernelLogs = true;
            ProtectControlGroups = true;
            ProtectHostname = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            LockPersonality = true;
            RestrictAddressFamilies = [
              "AF_INET"
              "AF_INET6"
              "AF_UNIX"
            ];
            RestrictNamespaces = true;
            SystemCallArchitectures = "native";
            UMask = "0077";
          };
        };

        systemd.timers.mcl-repro-deploy-agent = {
          description = "Poll signed reprobuild desired-state manifests for ${cfg.targetName}";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnUnitActiveSec = cfg.interval;
            RandomizedDelaySec = cfg.jitter;
            Persistent = true;
          }
          // lib.optionalAttrs cfg.runOnBoot { OnActiveSec = cfg.interval; };
        };
      };
    };
}
