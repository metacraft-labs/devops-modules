{ withSystem, ... }:
{
  imports = [
    ./incus-runner-host.nix
  ];

  # Ephemeral-Windows-Runners-GARM M0 — host cloudbase/garm (the GitHub Actions
  # Runner Manager control plane) as an opt-in NixOS systemd service, mirroring
  # the shape of `services.mcl-repro-binary-cache`: a package option, a
  # `config.toml` generator, a durable StateDirectory for the SQLite DB, and a
  # hardened long-running unit modelled on GARM's own `contrib/garm.service`.
  #
  # M0 scope is DELIBERATELY forge-less and provider-less: GARM boots fine with
  # empty `[[provider]]`/`[[github]]` sections (see cmd/garm/main.go — providers
  # and forges are loaded lazily and an empty set is valid). The provider is
  # wired in M1 (`garm-provider-vmharness`) and the forge/pool in M4.
  #
  # EXP-MP (Production-Runners-And-Shared-Store): the module now supports
  # MULTIPLE named providers (`services.garm.providers.<name>`, each with its own
  # backend/image/sizing) and MULTIPLE GitHub App credentials
  # (`services.garm.github.<name>`), rendered as multiple `[[provider]]` +
  # `[[github]]` blocks (GARM supports both natively). The systemd sandbox
  # posture is the UNION across the enabled providers: if ANY provider is libvirt
  # the qemu relaxations + libvirtd/kvm groups apply; if ANY is incus the
  # incus-admin group is added; when NO provider is enabled the unit is the M0
  # strict DynamicUser sandbox, byte-unchanged. This is the foundation for
  # running Windows (libvirt) + Linux (incus) from one GARM and for all orgs.
  #
  # SECRETS. GARM's config validation requires TWO strong secrets:
  #   * database.passphrase — exactly 32 chars, zxcvbn score 4; encrypts
  #     sensitive columns in the DB. It MUST be stable across restarts or all
  #     encrypted rows become unreadable.
  #   * jwt_auth.secret — non-empty, zxcvbn score 4; signs API/instance JWTs.
  # Neither may live in the world-readable Nix store. So the config.toml is
  # rendered at RUNTIME by an ExecStartPre hook that either (a) reads operator
  # supplied secrets staged via systemd LoadCredential, or (b) generates strong
  # random secrets on first boot and persists them under the StateDirectory
  # (mode 0700) so subsequent restarts reuse them. The store only ever holds a
  # placeholder template with NO secret material.
  flake.modules.nixos.garm =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.garm;
      inherit (lib)
        mkEnableOption
        mkIf
        mkOption
        types
        optionalString
        ;

      # Default to this flake's `garm` package (garm daemon + garm-cli) built
      # for the host system. Consumers/tests may override `package`.
      defaultPackage = withSystem pkgs.stdenv.hostPlatform.system ({ config, ... }: config.packages.garm);

      # The RC1 `runner-label-tool` (manifest → label DERIVATION + `advertised ⊆
      # derived` linter) — the JIT-registration mechanism RC2 pools call at
      # reconcile time to compute a classic runner's capability-label array from
      # a host's RA6-verified `/v1/manifest`. Defaulted from this flake so the
      # module is self-contained; overridable by consumers/tests.
      defaultLabelTool = withSystem pkgs.stdenv.hostPlatform.system (
        { config, ... }: config.packages.runner-label-tool
      );

      # Default to this flake's `garm-provider-vmharness` package (M1). Consumers
      # may override `providers.<name>.package`.
      defaultVmharnessPackage = withSystem pkgs.stdenv.hostPlatform.system (
        { config, ... }: config.packages.garm-provider-vmharness
      );

      stateDir = cfg.stateDir;
      dbFile = "${stateDir}/garm.sqlite";
      renderedConfig = "${stateDir}/config.toml";

      # The enabled provider/credential sets. Each is an attrset keyed by the
      # instance NAME (the `[[provider]].name` / `[[github]].name`). Empty
      # (default) keeps the forge-less/provider-less M0 boot intact.
      enabledProviders = lib.filterAttrs (_: p: p.enable) cfg.providers;
      enabledGithub = lib.filterAttrs (_: g: g.enable) cfg.github;

      # Shell-safe token for a name (for sentinels / filenames).
      sanitizeName = name: lib.replaceStrings [ "-" "." "/" " " ":" ] [ "_" "_" "_" "_" "_" ] name;
      # TOML basic-string escape for a value interpolated into `key = "..."`.
      # A raw value breaks the file when it contains a backslash or quote: a
      # Windows golden path such as `D:\storage\g.vhdx` emits `\s`/`\g`, which
      # the provider binary rejects at startup with
      #   toml: invalid escape in string '\s'
      # so every CreateInstance fails before a clone can boot. Escape backslash
      # and quote (and the control chars TOML mandates). Byte-identical for
      # values with no special chars, so existing (POSIX-path) configs are
      # unchanged; use it wherever a value could carry a backslash or quote.
      tomlStr = s: lib.replaceStrings [ "\\" "\"" "\n" "\r" "\t" ] [ "\\\\" "\\\"" "\\n" "\\r" "\\t" ] s;
      # systemd LoadCredential id + on-disk staged path for a credential's PEM.
      appKeyCredName = name: "app-key-${name}";
      stagedPemPath = name: "${stateDir}/app-key-${sanitizeName name}.pem";

      # RB2: systemd LoadCredential id + on-disk staged path for a REMOTE
      # provider's `vm-harness serve` bearer token. Mirrors the App-PEM staging
      # exactly (LoadCredential source -> stable 0600 path under stateDir the
      # provider reads), so the central GARM's per-host serve token never enters
      # the store and is read from a path that is stable across the render ->
      # daemon boundary. A remote provider whose token comes from an ENV var
      # (`remote.authTokenFile == null`) is untouched by this — the env path is
      # the infra layer's responsibility (EnvironmentFile / LoadCredential value).
      serveTokenCredName = name: "serve-token-${name}";
      stagedServeTokenPath = name: "${stateDir}/serve-token-${sanitizeName name}";
      # Remote providers that stage their token from a FILE source (the central
      # topology's shape): backend = "remote" AND remote.authTokenFile set.
      enabledRemoteTokenProviders = lib.filterAttrs (
        _: p: providerIsRemote p && p.remote.authTokenFile != null
      ) enabledProviders;

      # ----- Per-provider config.toml (a DIFFERENT file from garm's config) ---
      # It holds NO secrets — only the virsh/qemu-img/vm-harness binary paths,
      # the libvirt URI/network OR the incus bridge + static-IPv4 params, the
      # OVMF firmware paths, the per-VM sizing, and the golden-image map — so it
      # is safe in the Nix store. Passed to the provider verbatim via
      # GARM_PROVIDER_CONFIG_FILE. Keys match
      # garm-provider-vmharness/internal/config.Config.
      # (Build the STRING first, then wrap with writeText — otherwise the
      # [images.*] blocks would be appended to the derivation's store PATH.)
      providerIsIncus = p: p.backend == "incus";
      providerIsLibvirt = p: p.backend == "libvirt";
      # RB1: remote-target mode — the provider is an RPC client to a remote
      # `vm-harness serve` daemon instead of a local-exec backend. It needs no
      # local hypervisor tools (no virsh/incus/kvm), only network reach to the
      # endpoint + the bearer token; the strict M0 sandbox posture already
      # permits outbound TCP, so a remote provider relaxes nothing.
      providerIsRemote = p: p.backend == "remote";
      # RE3/RE4: the AWS burst backend. `garm-provider-aws` is a pure-Go cloud
      # provider — it reaches EC2 over the network via the AWS SDK and needs NO
      # local hypervisor tools, socket groups, or /dev/kvm. Like `remote` it
      # relaxes NOTHING in the systemd sandbox (the strict M0 posture already
      # permits outbound TCP); it only needs its region/subnet config plus AWS
      # credentials, which the infra layer supplies via the forwarded env chain
      # (role/IMDS/EnvironmentFile) so no secret ever enters the Nix store.
      providerIsAws = p: p.backend == "aws";
      providerIsVMHarnessRun =
        p:
        builtins.elem p.backend [
          "tart-linux-arm"
          "tart-macos"
          "utm-windows-arm"
          "qemu-windows-arm"
        ];
      providerIsQemuWindowsArm = p: p.backend == "qemu-windows-arm";
      providerEnvVars =
        p:
        [
          "PATH"
        ]
        ++ lib.optional (providerIsIncus p) "HOME"
        # RB1: when the remote token is supplied via an environment variable
        # (not a file), the provider process must inherit that variable. GARM
        # forwards ONLY the vars listed here, so add the configured name. The
        # infra layer supplies its value (EnvironmentFile / systemd LoadCredential).
        ++ lib.optional (providerIsRemote p && p.remote.authTokenFile == null) p.remote.authTokenEnv
        # RE3: forward the AWS credential/region/TLS env-var NAMES the provider
        # needs. GARM propagates ONLY the vars listed here; their VALUES are
        # supplied by the infra layer (systemd EnvironmentFile / LoadCredential /
        # IMDS role), so no AWS secret is ever baked into the store.
        ++ lib.optionals (providerIsAws p) p.aws.forwardEnv
        ++ lib.optionals (providerIsVMHarnessRun p) [
          "MCL_RUNNER_SHARED_NIX_STORE"
          "MCL_RUNNER_SHARED_REPRO_STORE"
          "VM_HARNESS_TART_STATE_DIR"
          "TART_HOME"
          "VM_HARNESS_UTM_STATE_DIR"
          "VM_HARNESS_QEMU_WINDOWS_ARM_STATE_DIR"
          "VMH_QEMU_WINDOWS_ARM_SWTPM_CMD"
          "VM_HARNESS_DARWIN_ASUSER_UID"
        ];
      mkLibvirtKeys =
        p:
        ''
          virsh_path = "${p.virshPath}"
          qemu_img_path = "${p.qemuImgPath}"
          vm_harness_path = "${p.vmHarnessPath}"
          libvirt_uri = "${p.libvirtURI}"
          network = "${p.network}"
          pool_dir = "${p.poolDir}"
          uefi_loader = "${p.uefiLoader}"
          uefi_nvram_template = "${p.uefiNvramTemplate}"
          memory_mb = ${toString p.memoryMb}
          vcpus = ${toString p.vcpus}
        ''
        # Only emitted when a balloon floor is actually requested, so providers
        # that do not use one keep a byte-identical config.toml (and therefore a
        # byte-identical domain XML) to before this option existed.
        + optionalString (p.currentMemoryMb > 0) ''
          current_memory_mb = ${toString p.currentMemoryMb}
        '';
      mkIncusKeys =
        p:
        ''
          incus_path = "${p.incusPath}"
          incus_bridge = "${p.incusBridge}"
          incus_ipv4_cidr = "${p.incusIPv4CIDR}"
          incus_ipv4_gateway = "${p.incusIPv4Gateway}"
          incus_ipv4_range_start = "${p.incusIPv4RangeStart}"
          incus_ipv4_range_end = "${p.incusIPv4RangeEnd}"
          incus_nameservers = [${lib.concatMapStringsSep ", " (s: "\"${s}\"") p.incusNameservers}]
          incus_gpu_passthrough = ${lib.boolToString p.incusGpuPassthrough}
          incus_share_host_nix_store = ${lib.boolToString p.incusShareHostNixStore}
          incus_reprobuild_store = "${p.incusReprobuildStore}"
          incus_reprobuild_store_guest_path = "${p.incusReprobuildStoreGuestPath}"
          incus_security_nesting = ${lib.boolToString p.incusSecurityNesting}
          incus_nested_kvm = ${lib.boolToString p.incusNestedKvm}
        ''
        # Only emitted when a cap is actually requested, so a provider that
        # wants none keeps a byte-identical config.toml (and therefore a
        # byte-identical container) to before this option existed — the same
        # discipline `currentMemoryMb` follows in mkLibvirtKeys above.
        + optionalString (p.incusLimitsCpu != "") ''
          incus_limits_cpu = "${p.incusLimitsCpu}"
        '';
      mkVMHarnessRunKeys =
        p:
        ''
          vm_harness_path = "${p.vmHarnessPath}"
          state_dir = "${p.stateDir}"
        ''
        + optionalString (p.guestMetadataURL != null) ''
          guest_metadata_url = "${p.guestMetadataURL}"
        ''
        + optionalString (p.guestCallbackURL != null) ''
          guest_callback_url = "${p.guestCallbackURL}"
        '';
      # RB1: the [remote] section. COMPANY-AGNOSTIC — the endpoint + target
      # backend + how to obtain the bearer token, with NO baked-in host. The
      # token itself never enters the store: `auth_token_file` points at a path
      # (agenix / LoadCredential-staged) resolved at runtime, or the provider
      # reads `auth_token_env` from the environment (value supplied by infra).
      # The two optional Incus capability grants are likewise operator-owned:
      # they map to fixed, audited vm-harness flags and expose no raw config key,
      # device path, or mode to workflows, bootstrap/user-data, or guests.
      mkRemoteKeys =
        name: p:
        ''
          [remote]
          endpoint = "${p.remote.endpoint}"
          target_backend = "${p.remote.targetBackend}"
          guest_os = "${p.remote.guestOS}"
          auth_token_env = "${p.remote.authTokenEnv}"
        ''
        # RB2: when the token is staged from a FILE, the provider reads it from
        # the STABLE staged path under stateDir (the ExecStartPre copy of the
        # LoadCredential-mounted secret), NOT the agenix source directly — the
        # same indirection the App PEMs use. The token never enters the store.
        + optionalString (p.remote.authTokenFile != null) ''
          auth_token_file = "${stagedServeTokenPath name}"
        ''
        + optionalString (p.remote.requestTimeoutSec > 0) ''
          request_timeout_sec = ${toString p.remote.requestTimeoutSec}
        ''
        # Omit false values so every existing remote provider keeps a
        # byte-identical config.toml and, downstream, byte-identical create argv.
        + optionalString p.remote.incusSecurityNesting ''
          incus_security_nesting = true
        ''
        + optionalString p.remote.incusNestedKvm ''
          incus_nested_kvm = true
        '';
      # RE3: the `garm-provider-aws` config.toml (config/config.go). It carries
      # ONLY the region, the subnet, and the credential TYPE — never a secret.
      # `credential_type = "role"` (the default) makes the provider use the AWS
      # SDK default credential chain (forwarded env vars / shared-credentials
      # file / instance-profile IMDS), all supplied by infra. `static` is
      # accepted for completeness, but the access/secret keys are NOT rendered
      # here (that would leak them into the store); infra must instead supply
      # them through the same env chain (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
      # / AWS_SESSION_TOKEN) or a mounted shared-credentials file. NOTE: unlike
      # the vm-harness backends, this config carries NO golden-image map — the
      # AMI is a per-pool value (`burstPools.<name>.image`), not a provider one.
      mkAwsKeys = p: ''
        region = "${p.aws.region}"
        subnet_id = "${p.aws.subnetId}"

        [credentials]
        credential_type = "${p.aws.credentialType}"
      '';
      mkProviderConfigText =
        name: p:
        ''
          backend = "${p.backend}"
        ''
        + (
          if providerIsRemote p then
            mkRemoteKeys name p
          else if providerIsAws p then
            mkAwsKeys p
          else if providerIsIncus p then
            mkIncusKeys p
          else if providerIsVMHarnessRun p then
            mkVMHarnessRunKeys p
          else
            mkLibvirtKeys p
        )
        + lib.concatStrings (
          lib.mapAttrsToList (image: spec: ''

            [images."${image}"]
            source_image = "${tomlStr spec.sourceImage}"
            os_name = "${tomlStr spec.osName}"
            os_version = "${tomlStr spec.osVersion}"
          '') p.images
        );
      mkProviderConfigFile =
        name: p: pkgs.writeText "garm-provider-${sanitizeName name}.toml" (mkProviderConfigText name p);

      # The `[[provider]]` block per enabled provider. External-provider keys per
      # config/external.go: provider_executable / config_file / interface_version.
      mkProviderBlock = name: p: ''

        [[provider]]
        name = "${name}"
        provider_type = "external"
        description = "${
          if providerIsRemote p then
            "remote ephemeral runners via a vm-harness serve daemon (${p.remote.targetBackend})"
          else if providerIsAws p then
            "AWS EC2 burst ephemeral runners (garm-provider-aws, region ${p.aws.region})"
          else if providerIsIncus p then
            "incus Linux container ephemeral runners via vm-harness"
          else
            "libvirt/KVM Windows ephemeral runners via vm-harness"
        }"

          [provider.external]
          provider_executable = "${lib.getExe p.package}"
          config_file = "${mkProviderConfigFile name p}"
          interface_version = "v0.1.1"
          # GARM does NOT propagate its own environment to external providers,
          # so the provider inherits only the vars listed here.
          #   * PATH  — libvirt: the provider shells to genisoimage (config-drive)
          #     via LookPath (virsh/qemu-img are absolute); incus: incus_path is
          #     absolute but PATH still carries the incus client for robustness.
          #   * HOME  — incus ONLY: the `incus` CLI reads $HOME/.config/incus/…;
          #     without HOME (and with ProtectHome hiding /root) it errors
          #     "Unable to read the configuration file … permission denied". The
          #     unit's HOME is the garm StateDirectory (writable), so forward it.
          environment_variables = [${lib.concatMapStringsSep ", " (v: "\"${v}\"") (providerEnvVars p)}]
      '';
      providersBlock = lib.concatStrings (lib.mapAttrsToList mkProviderBlock enabledProviders);

      # ----- The GitHub App credentials — one `[[github]]` block each ----------
      # The App PEM never enters the store: private_key_path points at a stable
      # 0600 copy under stateDir (`<stateDir>/app-key-<name>.pem`), which the
      # ExecStartPre hook stages from the LoadCredential-mounted secret. Because
      # that path is deterministic there is no sentinel — it is baked directly.
      #
      # GARM CONSTRAINT: config `[[github]]` creds are imported into the DB only
      # by the legacy one-shot migrateCredentialsToDB, and ONLY on the first DB
      # open AND only if an admin user already exists then. GARM's first-run
      # creates the admin via the API after boot, so on a FRESH deploy the import
      # is skipped. This block is thus effective for UPGRADING a pre-existing
      # single-user GARM; for a greenfield install register the creds once via
      # `garm-cli github credentials add --private-key-path <stateDir>/app-key-<name>.pem`.
      mkGithubBlock = name: g: ''

        [[github]]
        name = "${g.credentialsName}"
        description = "${g.description}"
        auth_type = "app"

          [github.app]
          app_id = ${toString g.appId}
          installation_id = ${toString g.installationId}
          private_key_path = "${stagedPemPath name}"
      '';
      githubBlock = lib.concatStrings (lib.mapAttrsToList mkGithubBlock enabledGithub);

      # M6 controller URLs. GARM's guest-facing metadata/callback base URLs must
      # be reachable BY THE GUEST — on the libvirt NAT network that is the host's
      # bridge IP (virbr0 = 192.168.122.1) / the incus bridge gateway, NOT
      # localhost. Empty ⇒ omitted (keeps the forge-less M0 boot).
      controllerURLLines =
        optionalString (cfg.metadataURL != "") ''metadata_url = "${cfg.metadataURL}"''
        + optionalString (cfg.callbackURL != "") "\ncallback_url = \"${cfg.callbackURL}\"";

      # The config template written to the Nix store. The two secret fields carry
      # sentinel tokens that the ExecStartPre hook replaces with real secrets
      # from files (never present in the store). Everything else is resolved.
      #
      # Section order follows config/config.go: [default], [logging], [metrics],
      # [jwt_auth], [apiserver], [database], then optional [[provider]] blocks
      # and [[github]] blocks. With no provider/forge configured this reduces to
      # the forge-less M0 boot.
      #
      # NOTE the parenthesisation: function application binds tighter than `+`,
      # so the concatenation must happen on the STRING first, then be wrapped by
      # writeText — otherwise the derivation is coerced to its store PATH and the
      # TOML blocks leak into any `"${configTemplate}"` interpolation.
      configTemplateText = ''
        [default]
        ${controllerURLLines}

        [logging]
        log_level = "${cfg.logLevel}"
        log_format = "text"

        [metrics]
        enable = ${lib.boolToString cfg.metrics.enable}
        disable_auth = ${lib.boolToString cfg.metrics.disableAuth}
        period = "${cfg.metrics.period}"

        [jwt_auth]
        # Replaced at runtime with the real secret (never in the store).
        secret = "@JWT_SECRET@"
        time_to_live = "${cfg.jwtTimeToLive}"

        [apiserver]
        bind = "${cfg.apiServer.bind}"
        port = ${toString cfg.apiServer.port}
        use_tls = false

        [database]
        backend = "sqlite3"
        # Replaced at runtime with the real 32-char passphrase.
        passphrase = "@DB_PASSPHRASE@"

          [database.sqlite3]
          db_file = "${dbFile}"
      ''
      # EXP-MP: append every enabled provider's [[provider]] block. Empty (the
      # default) keeps the forge-less/provider-less M0 boot intact.
      + providersBlock
      # EXP-MP: append every enabled GitHub App credential's [[github]] block.
      + githubBlock;

      configTemplate = pkgs.writeText "garm-config.toml.tmpl" configTemplateText;

      # Per-credential App PEM staging (baked paths, no sentinels). Each enabled
      # credential's LoadCredential-mounted secret is copied to its stable 0600
      # path under stateDir. Failure to stage a declared credential is fatal.
      stageGithubPems = lib.concatStrings (
        lib.mapAttrsToList (name: g: ''
          if [ -n "$cred_dir" ] && [ -f "$cred_dir/${appKeyCredName name}" ]; then
            install -m 0600 /dev/null "${stagedPemPath name}"
            cat "$cred_dir/${appKeyCredName name}" > "${stagedPemPath name}"
          else
            echo "garm-render-config: services.garm.github.${name}.enable is set but the App key credential '${appKeyCredName name}' was not staged (set services.garm.github.${name}.appKeyFile)" >&2
            exit 1
          fi
        '') enabledGithub
      );

      # RB2: stage each remote provider's `vm-harness serve` bearer token from
      # its LoadCredential-mounted secret to a STABLE 0600 path under stateDir
      # (owned by the service user, outside the store), mirroring stageGithubPems
      # above. The provider config's `auth_token_file` points at this stable path
      # (see mkRemoteKeys), so the value survives the render -> daemon boundary
      # regardless of the tmpfs credentials dir's lifetime. Failure to stage a
      # declared token is fatal — the same posture as a missing App PEM.
      stageServeTokens = lib.concatStrings (
        lib.mapAttrsToList (name: _p: ''
          if [ -n "$cred_dir" ] && [ -f "$cred_dir/${serveTokenCredName name}" ]; then
            install -m 0600 /dev/null "${stagedServeTokenPath name}"
            tr -d '[:space:]' < "$cred_dir/${serveTokenCredName name}" > "${stagedServeTokenPath name}"
          else
            echo "garm-render-config: services.garm.providers.${name}.backend = \"remote\" sets remote.authTokenFile but the serve-token credential '${serveTokenCredName name}' was not staged" >&2
            exit 1
          fi
        '') enabledRemoteTokenProviders
      );

      # First-run/refresh renderer. Resolves the two secrets, then substitutes
      # them into the template to produce the runtime config under $STATE_DIR.
      #
      # Secret resolution per field:
      #   * If an operator secret file is configured, it is staged by
      #     LoadCredential at $CREDENTIALS_DIRECTORY/<name> and used verbatim
      #     (first line, whitespace-trimmed).
      #   * Otherwise a strong random secret is generated once and persisted at
      #     $STATE_DIR/<name>.secret (mode 0600) and reused thereafter.
      renderScript = pkgs.writeShellApplication {
        name = "garm-render-config";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.openssl
          pkgs.gnused
        ];
        text = ''
          set -euo pipefail

          state_dir="${stateDir}"
          cred_dir="''${CREDENTIALS_DIRECTORY:-}"

          resolve_secret() {
            # $1 = credential name (may be empty), $2 = persisted filename,
            # $3 = number of random bytes when generating.
            local cred_name="$1" persist="$2" nbytes="$3"
            local persist_path="$state_dir/$persist"
            if [ -n "$cred_name" ] && [ -n "$cred_dir" ] && [ -f "$cred_dir/$cred_name" ]; then
              # Operator-supplied secret (via LoadCredential). Trim whitespace.
              head -n1 "$cred_dir/$cred_name" | tr -d '[:space:]'
              return 0
            fi
            if [ ! -f "$persist_path" ]; then
              # Generate a strong random secret once and persist it.
              umask 077
              openssl rand -hex "$nbytes" > "$persist_path"
            fi
            head -n1 "$persist_path" | tr -d '[:space:]'
          }

          # DB passphrase must be EXACTLY 32 chars. 16 random bytes -> 32 hex.
          db_passphrase="$(resolve_secret "${cfg.dbPassphraseCredentialName}" db-passphrase.secret 16)"
          db_passphrase="''${db_passphrase:0:32}"
          # JWT secret: 32 random bytes -> 64 hex (strong).
          jwt_secret="$(resolve_secret "${cfg.jwtSecretCredentialName}" jwt-secret.secret 32)"

          umask 077
          # EXP-MP App PEMs. Each GitHub App private key is a MULTI-LINE PEM, so
          # it cannot be substituted inline — config.toml's private_key_path
          # points at an on-disk file. LoadCredential mounts it read-only at
          # $CREDENTIALS_DIRECTORY/<name>, but that tmpfs path is not guaranteed
          # stable across the render → daemon boundary, and GARM re-reads the key
          # when it re-authenticates. So copy each to a STABLE 0600 path under
          # stateDir (owned by the service user, outside the store).
          ${stageGithubPems}

          # RB2: stage the remote providers' serve bearer tokens (central GARM).
          ${stageServeTokens}

          tmp="$(mktemp "${renderedConfig}.XXXXXX")"
          sed \
            -e "s|@DB_PASSPHRASE@|$db_passphrase|" \
            -e "s|@JWT_SECRET@|$jwt_secret|" \
            "${configTemplate}" > "$tmp"
          mv -f "$tmp" "${renderedConfig}"
        '';
      };

      # ----- Declarative reconcile (PM5, pulled forward) ----------------------
      # The reconcile reads a Nix-rendered DESIRED-STATE manifest (JSON, no
      # secrets: credential NAMES + app ids + PEM paths + org/scale-set tuning)
      # and drives `garm-cli` to converge GARM's DB onto it. The manifest is a
      # store file (safe: no secret material — the PEM PATH is not the PEM), so
      # the reconcile logic is a pure function of `garm-cli list --format json`
      # vs this manifest. Idempotent by construction (every mutation is guarded
      # by a "does it already match?" check).
      rcfg = cfg.reconcile;

      # DESIRED credentials — one per ENABLED github.<name>. `credentialsName`
      # is the GARM `[[github]].name`; `pemPath` is the module-staged 0600 copy.
      desiredCreds = lib.mapAttrsToList (name: g: {
        name = g.credentialsName;
        description = g.description;
        appId = g.appId;
        installationId = g.installationId;
        pemPath = stagedPemPath name;
      }) enabledGithub;

      # DESIRED scale sets — one per scaleSets.<name> (the GARM-side NAME is
      # `scaleSetName`, decoupled from the attr key). Each carries its org +
      # credential + provider + tuning.
      desiredScaleSets = lib.mapAttrsToList (_: ss: {
        name = ss.scaleSetName;
        org = ss.org;
        credentials = ss.credentials;
        provider = ss.provider;
        image = ss.image;
        osType = ss.osType;
        osArch = ss.osArch;
        maxRunners = ss.maxRunners;
        minIdleRunners = ss.minIdleRunners;
        runnerBootstrapTimeout = ss.runnerBootstrapTimeout;
        enabled = ss.enabled;
        runnerGroup = ss.runnerGroup;
      }) cfg.scaleSets;

      # RE3/RE4: DESIRED burst pools — one per burstPools.<name>. The
      # floor-vs-lazy policy is resolved HERE: `lazy` forces the effective
      # min-idle to 0 (pure scale-to-zero) regardless of minIdleRunners, while
      # `floor` keeps minIdleRunners warm. The spot policy (RE4) is rendered
      # into a per-pool `extraSpecs` JSON string exactly as garm forwards it to
      # the provider (BootstrapInstance.ExtraSpecs), which the garm-provider-aws
      # spot patch consumes to set InstanceMarketOptions.
      desiredBurstPools = lib.mapAttrsToList (
        _: bp:
        let
          effectiveMinIdle = if bp.floorPolicy == "lazy" then 0 else bp.minIdleRunners;
          extraSpecs = lib.optionalAttrs bp.spot.enable (
            {
              market_type = "spot";
              spot_instance_type = bp.spot.instanceType;
              spot_instance_interruption_behavior = bp.spot.interruptionBehavior;
              on_demand_fallback = bp.spot.onDemandFallback;
            }
            // lib.optionalAttrs (bp.spot.maxPrice != "") { spot_max_price = bp.spot.maxPrice; }
          );
        in
        {
          name = bp.poolName;
          org = bp.org;
          credentials = bp.credentials;
          provider = bp.provider;
          image = bp.image;
          flavor = bp.flavor;
          osType = bp.osType;
          osArch = bp.osArch;
          labels = bp.labels;
          maxRunners = bp.maxRunners;
          minIdleRunners = effectiveMinIdle;
          floorPolicy = bp.floorPolicy;
          priority = bp.priority;
          jobAgeBackoff = bp.jobAgeBackoff;
          runnerBootstrapTimeout = bp.runnerBootstrapTimeout;
          ephemeral = bp.ephemeral;
          enabled = bp.enabled;
          # A JSON STRING (not an object) — this is passed to `garm-cli pool
          # add --extra-specs` verbatim and forwarded to the provider as
          # BootstrapInstance.ExtraSpecs. Empty ({}) for an on-demand pool.
          extraSpecs = builtins.toJSON extraSpecs;
        }
      ) cfg.burstPools;

      # The RA6-verified manifest file backing a named provider (empty when the
      # provider has none). Used to DERIVE a pool's capability-label tag set at
      # reconcile time (RC2 JIT label derivation) and to QUALIFY a provider for a
      # capability (RB3 placement).
      providerManifestOf =
        pname:
        let
          p = cfg.providers.${pname} or null;
        in
        if p != null && p.manifestFile != null then toString p.manifestFile else "";

      # RC2: DESIRED on-prem capability pools — one per pools.<name>. The tag set
      # is DERIVED at reconcile time from the backing provider's manifestFile
      # (emitted here); `labels` is the operator-declared advertised set the
      # reconcile LINTS ⊆ derived (fail-closed), and `policyLabels` are the
      # attested labels appended after derivation.
      desiredPools = lib.mapAttrsToList (_: pl: {
        name = pl.poolName;
        org = pl.org;
        credentials = pl.credentials;
        provider = pl.provider;
        manifestFile = providerManifestOf pl.provider;
        labels = pl.labels;
        policyLabels = pl.policyLabels;
        # RC5: legacy class names this pool also advertises during the cutover.
        aliasClasses = pl.aliasClasses;
        image = pl.image;
        flavor = pl.flavor;
        osType = pl.osType;
        osArch = pl.osArch;
        maxRunners = pl.maxRunners;
        minIdleRunners = pl.minIdleRunners;
        priority = pl.priority;
        runnerBootstrapTimeout = pl.runnerBootstrapTimeout;
        runnerGroup = pl.runnerGroup;
        enabled = pl.enabled;
        extraSpecs = "{}";
      }) cfg.pools;

      # RB3: DESIRED capability pools — one per capabilityPools.<name>, each
      # carrying its candidate providers (resolved to (name, manifestFile) pairs)
      # so the reconcile can QUALIFY each candidate against `requires` and expand
      # into one concrete GARM pool per qualifying host, priced by `balance`.
      # Candidates default to every enabled provider that has a manifestFile.
      desiredCapabilityPools = lib.mapAttrsToList (
        _: cp:
        let
          candidateNames =
            if cp.providers != [ ] then
              cp.providers
            else
              lib.attrNames (lib.filterAttrs (_: p: p.enable && p.manifestFile != null) cfg.providers);
        in
        {
          name = cp.name or "";
          requires = cp.requires;
          balance = cp.balance;
          basePriority = cp.basePriority;
          org = cp.org;
          credentials = cp.credentials;
          image = cp.image;
          flavor = cp.flavor;
          osType = cp.osType;
          osArch = cp.osArch;
          policyLabels = cp.policyLabels;
          maxRunners = cp.maxRunners;
          minIdleRunners = cp.minIdleRunners;
          runnerBootstrapTimeout = cp.runnerBootstrapTimeout;
          runnerGroup = cp.runnerGroup;
          enabled = cp.enabled;
          aliasClasses = cp.aliasClasses;
          # (provider, manifestFile) candidates, in a STABLE order (the balancer
          # steps priorities down this list under `pack`).
          candidates = map (pn: {
            provider = pn;
            manifestFile = providerManifestOf pn;
          }) candidateNames;
        }
      ) (lib.mapAttrs (n: cp: cp // { name = n; }) cfg.capabilityPools);

      # DESIRED orgs — the DISTINCT (org, credentials) pairs referenced by the
      # declared scale sets, burst pools, capability pools AND on-prem pools.
      # Each managed org is created against its credential.
      desiredOrgs =
        let
          pairs = lib.filter (o: o.name != "") (
            map (ss: {
              name = ss.org;
              credentials = ss.credentials;
            }) (desiredScaleSets ++ desiredBurstPools ++ desiredPools ++ desiredCapabilityPools)
          );
        in
        lib.unique pairs;

      # Controller URLs the reconcile must set BEFORE any org/scale-set op:
      # GARM guards the `/api/v1` router with `urlsRequired` (409 until
      # metadata + callback + agent URLs are all set). Derive them from the
      # module's guest-facing URLs, falling back to the local API base so the
      # reconcile can converge even when no guest-facing URL is configured
      # (the hermetic test) — the URLs need only be non-empty to pass the gate.
      localApiBase = "http://127.0.0.1:${toString cfg.apiServer.port}";
      ctrlMetadataURL =
        if cfg.metadataURL != "" then cfg.metadataURL else "${localApiBase}/api/v1/metadata";
      ctrlCallbackURL =
        if cfg.callbackURL != "" then cfg.callbackURL else "${localApiBase}/api/v1/callbacks";
      ctrlAgentURL = "${localApiBase}/agent";

      reconcileManifest = pkgs.writeText "garm-reconcile-manifest.json" (
        builtins.toJSON {
          endpoint = {
            name = rcfg.forgeEndpoint;
            apiBaseURL = rcfg.apiBaseURL;
            baseURL = rcfg.baseURL;
            uploadURL = rcfg.uploadURL;
          };
          controllerURLs = {
            metadata = ctrlMetadataURL;
            callback = ctrlCallbackURL;
            agent = ctrlAgentURL;
          };
          credentials = desiredCreds;
          orgs = desiredOrgs;
          scaleSets = desiredScaleSets;
          # RE3/RE4: the desired AWS burst pools, consumed by the RC2/RB3
          # pool-reconcile wiring via `garm-cli pool`.
          burstPools = desiredBurstPools;
          # RC2: on-prem capability pools (tags DERIVED from the backing
          # provider's manifestFile). RB3: capability pools expanded per
          # qualifying host with a pack/spread balancer.
          pools = desiredPools;
          capabilityPools = desiredCapabilityPools;
          # The declared provisioning model (informational — the reconcile
          # applies whatever is declared; see services.garm.mode).
          mode = cfg.mode;
          pruneUnmanaged = rcfg.pruneUnmanaged;
        }
      );

      # The macOS runner-install template body the reconcile registers when a
      # macOS pool is declared. See `ensure_macos_install_template` for why this
      # is a stub rather than a real bootstrap. It must parse as a Go
      # text/template (GARM runs `templates.ValidateTemplate` on create) — plain
      # shell with no `{{ }}` does.
      macosInstallTemplate = pkgs.writeText "garm-macos-compat-install-template.sh" ''
        #!/bin/sh
        set -eu

        echo "This GARM macOS install template is a compatibility stub for the external vm-harness provider." >&2
        echo "garm-provider-vmharness renders and executes the real macOS runner bootstrap inside the Tart guest." >&2
        exit 1
      '';

      reconcileScript = pkgs.writeShellApplication {
        name = "garm-reconcile";
        runtimeInputs = [
          cfg.package
          cfg.labelToolPackage
          pkgs.coreutils
          pkgs.jq
          pkgs.curl
          pkgs.openssl
        ];
        text = ''
          set -euo pipefail

          state_dir="${stateDir}"
          manifest="${reconcileManifest}"
          api_url="http://127.0.0.1:${toString cfg.apiServer.port}"
          endpoint_name="${rcfg.forgeEndpoint}"
          admin_user="${rcfg.adminUsername}"
          admin_email="${rcfg.adminEmail}"
          cred_dir="''${CREDENTIALS_DIRECTORY:-}"
          export HOME="$state_dir"

          log() { echo "garm-reconcile: $*"; }

          # ---- Admin password: operator-supplied (LoadCredential) or persisted.
          pw_persist="$state_dir/reconcile-admin-password.secret"
          # The operator-supplied password only lands in cred_dir when
          # adminPasswordFile is set (via LoadCredential), so the -f test below
          # already covers the null case — no Nix-level guard needed (a
          # `[ -n "1" ]` literal here trips shellcheck SC2157).
          if [ -n "$cred_dir" ] && [ -f "$cred_dir/reconcile-admin-password" ]; then
            admin_pw="$(head -n1 "$cred_dir/reconcile-admin-password" | tr -d '\n')"
          else
            if [ ! -f "$pw_persist" ]; then
              umask 077
              # zxcvbn score 4: long, mixed. Persisted 0600 under stateDir.
              openssl rand -base64 24 | tr -d '\n' | sed 's/$/-Grm9!/' > "$pw_persist"
            fi
            admin_pw="$(head -n1 "$pw_persist" | tr -d '\n')"
          fi

          gcli() { garm-cli --format json "$@"; }

          # ---- (0) Wait for the API + ensure first-run admin exists -----------
          # This endpoint requires authentication after first-run, so an existing
          # controller correctly returns 401. Any HTTP response proves the local
          # API is accepting requests; only curl's 000/no-response result means
          # it is not ready yet. Keep each probe bounded so a broken listener
          # cannot wedge the oneshot indefinitely.
          api_code=""
          for _ in $(seq 1 60); do
            api_code="$(curl --connect-timeout 1 --max-time 2 -sS -o /dev/null \
              -w '%{http_code}' "$api_url/api/v1/controller-info" 2>/dev/null || true)"
            if [ -n "$api_code" ] && [ "$api_code" != "000" ]; then
              log "controller API ready (HTTP $api_code)"
              break
            fi
            sleep 1
          done
          if [ -z "$api_code" ] || [ "$api_code" = "000" ]; then
            log "ERROR: controller API did not respond after 60 attempts"
            exit 1
          fi

          # first-run is idempotent enough: 200 on fresh, 409 if already done.
          fr_code="$(curl -s -o /tmp/garm-fr.json -w '%{http_code}' \
            -X POST "$api_url/api/v1/first-run" \
            -H 'Content-Type: application/json' \
            -d "$(jq -cn --arg u "$admin_user" --arg e "$admin_email" --arg p "$admin_pw" \
                  '{username:$u,email:$e,password:$p}')" || true)"
          case "$fr_code" in
            200) log "controller first-run complete (admin '$admin_user' created)";;
            409) log "controller already initialised";;
            *)   log "WARNING: first-run returned HTTP $fr_code (continuing; assuming pre-initialised)";;
          esac

          # Log the local garm-cli profile in (needed for every garm-cli call).
          # `init` writes the profile + logs in; if a profile already exists we
          # refresh the token via `profile login`.
          if ! garm-cli profile list --format json 2>/dev/null | jq -e '.[]?|select(.name=="reconcile")' >/dev/null 2>&1; then
            garm-cli init --name reconcile --url "$api_url" \
              --username "$admin_user" --email "$admin_email" --password "$admin_pw" \
              >/dev/null 2>&1 || \
              garm-cli profile add --name reconcile --url "$api_url" \
                --username "$admin_user" --password "$admin_pw" >/dev/null 2>&1 || true
          fi
          garm-cli profile switch reconcile >/dev/null 2>&1 || true
          # `profile login` MUST be given --username: without it garm-cli drops
          # into an interactive Username: prompt, which under systemd (no TTY)
          # reads EOF and fails. The failure is swallowed by `|| true`, so the
          # stale profile token is left in place — every subsequent garm-cli
          # call then 401s (existence checks silently return empty, and the
          # first un-guarded write, `credentials add`, aborts the reconcile).
          # This only surfaced after a garm restart invalidated the token that
          # the initial `init` (which does pass --username) had minted.
          garm-cli profile login reconcile --username "$admin_user" \
            --password "$admin_pw" >/dev/null 2>&1 || true

          # ---- (0.5) Controller URLs — REQUIRED before any /api/v1 op --------
          # GARM's apiRouter is guarded by `urlsRequired` (409 until metadata +
          # callback + agent URLs are all set). Set them idempotently (only if
          # any is currently empty) so org/credential/scale-set ops are allowed.
          md_url="$(jq -r '.controllerURLs.metadata' "$manifest")"
          cb_url="$(jq -r '.controllerURLs.callback' "$manifest")"
          ag_url="$(jq -r '.controllerURLs.agent' "$manifest")"
          ctrl="$(garm-cli controller show --format json 2>/dev/null || echo '{}')"
          have_md="$(echo "$ctrl" | jq -r '.metadata_url // ""')"
          have_cb="$(echo "$ctrl" | jq -r '.callback_url // ""')"
          have_ag="$(echo "$ctrl" | jq -r '.agent_url // ""')"
          if [ -z "$have_md" ] || [ -z "$have_cb" ] || [ -z "$have_ag" ]; then
            garm-cli controller update \
              --metadata-url "$md_url" --callback-url "$cb_url" --agent-url "$ag_url" \
              >/dev/null 2>&1 || true
            log "controller URLs set (metadata/callback/agent)"
          else
            log "controller URLs already set"
          fi

          # ---- (1) Forge endpoint (only for a NON-github.com endpoint) --------
          if [ "$endpoint_name" != "github.com" ]; then
            api_base="$(jq -r '.endpoint.apiBaseURL' "$manifest")"
            base_url="$(jq -r '.endpoint.baseURL' "$manifest")"
            upload_url="$(jq -r '.endpoint.uploadURL' "$manifest")"
            [ -n "$upload_url" ] || upload_url="$api_base"
            if gcli github endpoint list | jq -e --arg n "$endpoint_name" '.[]?|select(.name==$n)' >/dev/null; then
              garm-cli github endpoint update "$endpoint_name" \
                --api-base-url "$api_base" --base-url "$base_url" --upload-url "$upload_url" \
                >/dev/null 2>&1 || true
              log "endpoint '$endpoint_name' present (updated)"
            else
              garm-cli github endpoint create --name "$endpoint_name" \
                --api-base-url "$api_base" --base-url "$base_url" --upload-url "$upload_url" \
                >/dev/null
              log "endpoint '$endpoint_name' created"
            fi
          fi

          # ---- (2) Credentials: create-missing / update-drifted ---------------
          existing_creds="$(gcli github credentials list --long 2>/dev/null || echo '[]')"
          declared_cred_names="$(jq -r '.credentials[].name' "$manifest")"
          jq -c '.credentials[]' "$manifest" | while read -r c; do
            cname="$(echo "$c" | jq -r '.name')"
            cdesc="$(echo "$c" | jq -r '.description')"
            capp="$(echo "$c" | jq -r '.appId')"
            cinst="$(echo "$c" | jq -r '.installationId')"
            cpem="$(echo "$c" | jq -r '.pemPath')"
            if echo "$existing_creds" | jq -e --arg n "$cname" '.[]?|select(.name==$n)' >/dev/null; then
              # Present — reconcile app/installation ids + description + key.
              garm-cli github credentials update --name "$cname" \
                --description "$cdesc" --app-id "$capp" \
                --app-installation-id "$cinst" --private-key-path "$cpem" \
                >/dev/null 2>&1 || true
              log "credential '$cname' present (updated app-id=$capp inst=$cinst)"
            else
              garm-cli github credentials add --name "$cname" \
                --endpoint "$endpoint_name" --auth-type app --description "$cdesc" \
                --app-id "$capp" --app-installation-id "$cinst" \
                --private-key-path "$cpem" >/dev/null
              log "credential '$cname' created (app-id=$capp inst=$cinst)"
            fi
          done

          # ---- (3) Orgs: create-missing (idempotent) --------------------------
          # org-add does NOT call GitHub; it stores the org + starts a pool mgr.
          declared_org_names="$(jq -r '.orgs[].name' "$manifest" | sort -u)"
          # When a shared webhook secret is staged (reconcile.webhookSecretFile),
          # use it for BOTH create and drift-correction so a fresh/rebuilt DB
          # reproduces the exact secret GitHub already signs with. Otherwise fall
          # back to a per-org random secret (legacy behaviour).
          webhook_secret=""
          if [ -n "''${CREDENTIALS_DIRECTORY:-}" ] && [ -s "$CREDENTIALS_DIRECTORY/reconcile-webhook-secret" ]; then
            webhook_secret="$(tr -d '\n' < "$CREDENTIALS_DIRECTORY/reconcile-webhook-secret")"
          fi
          jq -c '.orgs[]' "$manifest" | while read -r o; do
            oname="$(echo "$o" | jq -r '.name')"
            ocreds="$(echo "$o" | jq -r '.credentials')"
            if gcli organization list --name "$oname" 2>/dev/null | jq -e --arg n "$oname" '.[]?|select(.name==$n)' >/dev/null; then
              log "org '$oname' present"
              # Drift-correct the webhook secret to the shared value (no-op if it
              # already matches; the API takes the secret write-only).
              if [ -n "$webhook_secret" ]; then
                oid="$(gcli organization list --name "$oname" 2>/dev/null | jq -r --arg n "$oname" '.[]?|select(.name==$n)|.id' | head -n1)"
                [ -n "$oid" ] && garm-cli organization update "$oid" --webhook-secret "$webhook_secret" >/dev/null 2>&1 \
                  && log "org '$oname' webhook secret aligned to the shared value"
              fi
            elif [ -n "$webhook_secret" ]; then
              garm-cli organization add --name "$oname" --credentials "$ocreds" \
                --webhook-secret "$webhook_secret" >/dev/null
              log "org '$oname' created (credentials=$ocreds, shared webhook secret)"
            else
              garm-cli organization add --name "$oname" --credentials "$ocreds" \
                --random-webhook-secret >/dev/null 2>&1 || \
                garm-cli organization add --name "$oname" --credentials "$ocreds" \
                  --webhook-secret "$(openssl rand -hex 16)" >/dev/null
              log "org '$oname' created (credentials=$ocreds, random webhook secret)"
            fi
          done

          # Map org NAME -> id for scale-set operations.
          org_id_for() {
            gcli organization list --name "$1" 2>/dev/null \
              | jq -r --arg n "$1" '.[]?|select(.name==$n)|.id' | head -n1
          }

          # ---- (4) Scale sets: create-missing / update-drifted ----------------
          jq -c '.scaleSets[]' "$manifest" | while read -r s; do
            sname="$(echo "$s" | jq -r '.name')"
            sorg="$(echo "$s" | jq -r '.org')"
            sprov="$(echo "$s" | jq -r '.provider')"
            simage="$(echo "$s" | jq -r '.image')"
            sos="$(echo "$s" | jq -r '.osType')"
            sarch="$(echo "$s" | jq -r '.osArch')"
            smax="$(echo "$s" | jq -r '.maxRunners')"
            smin="$(echo "$s" | jq -r '.minIdleRunners')"
            sboot="$(echo "$s" | jq -r '.runnerBootstrapTimeout')"
            senabled="$(echo "$s" | jq -r '.enabled')"
            # Runner group: empty (the default) means "do not pass the flag", so
            # GARM/GitHub keep placing the scale set in `Default` exactly as
            # before. Only honoured on CREATE — see the option's description for
            # why an existing scale set is not moved between groups.
            sgroup="$(echo "$s" | jq -r '.runnerGroup // ""')"
            if [ -n "$sgroup" ] && [ "$sgroup" != "null" ]; then
              group_flag="--runner-group=$sgroup"
              sgroup_log="$sgroup"
            else
              group_flag=""
              sgroup_log="Default"
            fi
            oid="$(org_id_for "$sorg")"
            if [ -z "$oid" ]; then
              log "WARNING: scale set '$sname' org '$sorg' has no id; skipping"
              continue
            fi
            cur="$(gcli scaleset list --org "$oid" 2>/dev/null \
              | jq -c --arg n "$sname" '.[]?|select(.name==$n)' | head -n1 || true)"
            # `--enabled` is a cobra BOOL flag: pass `--enabled=true` /
            # `--enabled=false` explicitly so a declared `enabled=false` scale
            # set actually gets DISABLED (a bare "" flag could never emit the
            # disable side, so a declared-disabled set stayed enabled forever).
            if [ "$senabled" = "true" ]; then
              enabled_flag="--enabled=true"
            else
              enabled_flag="--enabled=false"
            fi
            if [ -z "$cur" ]; then
              # shellcheck disable=SC2086
              garm-cli scaleset add --org "$oid" --provider-name "$sprov" \
                --image "$simage" --name "$sname" --flavor default $enabled_flag \
                --min-idle-runners "$smin" --max-runners "$smax" \
                --os-type "$sos" --os-arch "$sarch" $group_flag \
                --runner-bootstrap-timeout "$sboot" >/dev/null
              log "scale set '$sname' created in org '$sorg' (max=$smax min=$smin group=$sgroup_log)"
            else
              sid="$(echo "$cur" | jq -r '.id')"
              # Drift check: max/min/image/bootstrap/enabled.
              drift=0
              [ "$(echo "$cur" | jq -r '.max_runners // 0')" = "$smax" ] || drift=1
              [ "$(echo "$cur" | jq -r '.min_idle_runners // 0')" = "$smin" ] || drift=1
              [ "$(echo "$cur" | jq -r '.image // ""')" = "$simage" ] || drift=1
              [ "$(echo "$cur" | jq -r '.runner_bootstrap_timeout // 0')" = "$sboot" ] || drift=1
              [ "$(echo "$cur" | jq -r '.enabled // false')" = "$senabled" ] || drift=1
              if [ "$drift" = 1 ]; then
                # shellcheck disable=SC2086
                garm-cli scaleset update "$sid" --name "$sname" --image "$simage" \
                  $enabled_flag --min-idle-runners "$smin" --max-runners "$smax" \
                  --os-type "$sos" --os-arch "$sarch" \
                  --runner-bootstrap-timeout "$sboot" >/dev/null
                log "scale set '$sname' (id=$sid) drift-corrected (max=$smax min=$smin)"
              else
                log "scale set '$sname' (id=$sid) already converged"
              fi
            fi
          done

          # ---- (4b) POOLS (RC2) + CAPABILITY POOLS (RB3) ----------------------
          # GARM pools have NO name of their own (they are identified by a UUID
          # and MATCHED by tags), so the reconcile persists a logical-name →
          # pool-id map under stateDir and reconciles each declared/expanded pool
          # idempotently against it. Tags for a manifest-backed pool are DERIVED
          # from the RA6-verified manifest via `runner-label-tool` (RC1) — the
          # JIT-registration label array is proven hardware, not a hand-kept
          # class name.
          pool_state="$state_dir/managed-pool-ids.json"
          [ -f "$pool_state" ] || echo '{}' > "$pool_state"
          # Names we (re)applied THIS run — the prune boundary for pools.
          applied_pools="$(mktemp)"

          # ---- POOL-FAILURE ISOLATION -----------------------------------------
          # ONE BAD POOL MUST NOT TAKE THE CONTROL PLANE WITH IT. Before this,
          # every pool op ran under the script's `set -e` with its exit status
          # unchecked, so the FIRST pool GARM refused aborted the whole run: the
          # remaining pools were never created, the prune never ran, no summary
          # was printed, and systemd's Restart=on-failure re-ran the identical
          # doomed reconcile for ever. Observed live on high-mem-server
          # 2026-09-16: a `macos` pool hit GARM's pool-path OS allow-list
          # (`invalid OS type macos`, the gap packages/garm/patches/
          # allow-macos-pools.patch closes) and the reconcile restart-looped
          # past 65 attempts with the *-win-arm64/-linux/-gpu work behind it
          # never attempted.
          #
          # Now each pool is applied independently. A failure is recorded here —
          # with the forge's own message — and the run CONTINUES; the ledger is
          # re-printed as a loud, named summary at the end and decides the exit
          # code (see the epilogue).
          #
          # A FILE, not a variable: each pool loop below is the right-hand side
          # of a pipe and therefore runs in a SUBSHELL, so a counter would be
          # lost on every iteration. `applied_pools` already works this way.
          failed_pools="$(mktemp)"

          # pool_failed LNAME STAGE DETAIL — record one non-converged pool.
          #
          # It also marks the pool APPLIED. That is deliberate and is a prune
          # safety property, not bookkeeping: `pruneUnmanaged` deletes every
          # pool in the id-map that was not applied this run, so without this a
          # pool that merely FAILED TO UPDATE (its host briefly unreachable,
          # say) would be destroyed by the same run that failed to converge it.
          # A pool is pruned when its DECLARATION goes away, never because an
          # attempt to reconcile it errored.
          pool_failed() {
            local lname="$1" stage="$2" detail="$3"
            grep -qxF "$lname" "$applied_pools" 2>/dev/null || echo "$lname" >> "$applied_pools"
            # Flatten: the ledger is one line per failure.
            printf '%s\t%s\t%s\n' "$lname" "$stage" "$(printf '%s' "$detail" | tr '\n' ' ')" \
              >> "$failed_pools"
            log "ERROR: pool '$lname' NOT converged at stage '$stage': $detail"
            log "ERROR: pool '$lname' skipped — continuing with the remaining declarations"
          }

          # derive_tags MANIFEST_FILE DECLARED_CSV POLICY_CSV
          #   Compute a pool's classic-runner tag set. With a manifest: derive the
          #   proven hardware labels (RA6→RC1), LINT any declared set (advertised
          #   ⊆ derived, FAIL-CLOSED), then append policy labels. Without a
          #   manifest: the declared set verbatim + policy. Prints a CSV tag list;
          #   non-zero on a lint/derive failure (no pool for an over-advertised or
          #   unverifiable host — never a guessed label set).
          derive_tags() {
            local mf="$1" declared="$2" policy="$3" derived=""
            if [ -n "$mf" ]; then
              if [ ! -r "$mf" ]; then
                log "ERROR: manifest '$mf' not readable — cannot derive labels"
                return 1
              fi
              if ! derived="$(runner-label-tool derive -m "$mf" 2>/dev/null | paste -sd, -)"; then
                log "ERROR: runner-label-tool derive failed on '$mf' (fail-closed)"
                return 1
              fi
              if [ -n "$declared" ] && ! runner-label-tool lint -m "$mf" -a "$declared" >/dev/null 2>&1; then
                log "ERROR: declared labels ($declared) NOT proven by '$mf' (advertised ⊄ derived) — refusing pool"
                return 1
              fi
              printf '%s' "$derived''${policy:+,$policy}"
            else
              printf '%s' "$declared''${policy:+,$policy}"
            fi
          }

          # qualifies MANIFEST_FILE REQUIRES_CSV — RB3 placement predicate: the
          # host's derived label set must be a SUPERSET of the required labels.
          qualifies() {
            local mf="$1" req="$2" derived lbl
            { [ -n "$mf" ] && [ -r "$mf" ]; } || return 1
            derived="$(runner-label-tool derive -m "$mf" 2>/dev/null)" || return 1
            IFS=',' read -ra _reqs <<< "$req"
            for lbl in "''${_reqs[@]}"; do
              [ -z "$lbl" ] && continue
              echo "$derived" | grep -qxF "$lbl" || return 1
            done
            return 0
          }

          # ---- macOS runner-install template (the SECOND macOS pool gate) -----
          # Created ON DEMAND — only when a declared pool is actually macOS — so
          # a controller that never places macOS work keeps a 4-row template
          # table. Idempotent: create once, then update in place, keyed on the
          # name. Its BODY is a deliberate stub, and the same stub the m3
          # per-host GARM has served its macOS Tart scale sets with in
          # production (infra services/ephemeral-runner-host/darwin.nix):
          # garm-provider-vmharness renders the real macOS bootstrap INSIDE the
          # Tart guest (its own renderMacOSRunnerInstallScript + `osx` tool
          # mapping) and never reads this template, so anything else here would
          # be fiction. If some future macOS provider DOES consult it, exiting 1
          # with a named message is a loud failure rather than a silent wrong
          # boot — the campaign's fail-loud pattern.
          macos_template_name="garm-macos-compat"
          macos_template_file="${macosInstallTemplate}"
          ensure_macos_install_template() {
            local tid errf
            tid="$(gcli template list --forge-type github --os-type macos \
              --name "$macos_template_name" 2>/dev/null \
              | jq -r --arg n "$macos_template_name" \
                  'first(.[]? | select(.name==$n) | .id) // empty')"
            errf="$(mktemp)"
            if [ -z "$tid" ]; then
              if ! garm-cli template create --name "$macos_template_name" \
                --os-type macos --forge-type github \
                --description "Compatibility macOS runner-install template (the real bootstrap is rendered in-guest by the external provider)" \
                --path "$macos_template_file" >/dev/null 2>"$errf"; then
                log "ERROR: could not create the macOS runner-install template: $(cat "$errf")"
                log "ERROR: GARM only accepts os_type=macos on templates WITH packages/garm/patches/allow-macos-runner-install-templates.patch — check the deployed garm carries it"
                rm -f "$errf"
                return 1
              fi
              log "macOS runner-install template '$macos_template_name' created"
            else
              if ! garm-cli template update "$tid" --name "$macos_template_name" \
                --path "$macos_template_file" >/dev/null 2>"$errf"; then
                log "ERROR: could not update the macOS runner-install template (id=$tid): $(cat "$errf")"
                rm -f "$errf"
                return 1
              fi
              log "macOS runner-install template '$macos_template_name' (id=$tid) converged"
            fi
            rm -f "$errf"
            return 0
          }

          # pool_apply LNAME OID PROVIDER TAGS IMAGE FLAVOR OSTYPE OSARCH MIN MAX PRIO BOOT ENABLED GROUP EXTRAS
          pool_apply() {
            local lname="$1" oid="$2" prov="$3" tags="$4" image="$5" flavor="$6"
            local ostype="$7" osarch="$8" minr="$9" maxr="''${10}" prio="''${11}"
            local boot="''${12}" enabled="''${13}" group="''${14}" extras="''${15}"
            local group_flag="" enabled_flag extras_flag="" tpl_flag="" pid out tmp errf
            [ -n "$group" ] && [ "$group" != "null" ] && group_flag="--runner-group=$group"
            if [ "$enabled" = "true" ]; then enabled_flag="--enabled=true"; else enabled_flag="--enabled=false"; fi
            [ -n "$extras" ] && [ "$extras" != "{}" ] && extras_flag="--extra-specs=$extras"
            # macOS needs an EXPLICIT runner-install template; nothing else does.
            # GARM seeds exactly four system templates (linux/windows ×
            # github/gitea, database/sql/sql.go `ensureTemplates`), and pool
            # creation resolves the default by requiring
            # `OSType == pool.OSType && Owner == SystemUser` (runner/
            # repositories.go `findTemplate`). With no macOS row the org-pool
            # create fails `400 failed to find suitable template: no template ID
            # supplied and no default template can be found` — the SECOND macOS
            # pool gate, immediately behind the `invalid OS type macos` one that
            # packages/garm/patches/allow-macos-pools.patch closes. Passing the
            # id explicitly is the documented way out of the SystemUser rule.
            if [ "$ostype" = "macos" ]; then
              if ! ensure_macos_install_template; then
                pool_failed "$lname" "template" "could not ensure the macOS runner-install template '$macos_template_name'"
                return 1
              fi
              tpl_flag="--runner-install-template=$macos_template_name"
            fi
            echo "$lname" >> "$applied_pools"
            pid="$(jq -r --arg n "$lname" '.[$n] // ""' "$pool_state")"
            # garm-cli prints the forge/API refusal on STDERR ("Error: [POST
            # /organizations/{orgID}/pools][400] … invalid OS type macos"), and
            # that message is the ONLY thing that says WHY a pool was refused.
            # Capture it so pool_failed can name the reason instead of logging
            # an opaque exit status.
            errf="$(mktemp)"
            if [ -n "$pid" ] && gcli pool show "$pid" >/dev/null 2>&1; then
              # shellcheck disable=SC2086
              if ! garm-cli pool update "$pid" --image "$image" --flavor "$flavor" \
                --tags "$tags" $enabled_flag --min-idle-runners "$minr" \
                --max-runners "$maxr" --priority "$prio" \
                --runner-bootstrap-timeout "$boot" $group_flag $extras_flag $tpl_flag \
                >/dev/null 2>"$errf"; then
                pool_failed "$lname" "update" "$(cat "$errf")"
                rm -f "$errf"
                return 1
              fi
              rm -f "$errf"
              log "pool '$lname' (id=$pid) reconciled (provider=$prov tags=[$tags] prio=$prio max=$maxr min=$minr)"
            else
              # shellcheck disable=SC2086
              if ! out="$(garm-cli --format json pool add --org "$oid" --provider-name "$prov" \
                --image "$image" --flavor "$flavor" --tags "$tags" $enabled_flag \
                --min-idle-runners "$minr" --max-runners "$maxr" --priority "$prio" \
                --os-type "$ostype" --os-arch "$osarch" \
                --runner-bootstrap-timeout "$boot" $group_flag $extras_flag $tpl_flag 2>"$errf")"; then
                pool_failed "$lname" "add" "$(cat "$errf")"
                rm -f "$errf"
                return 1
              fi
              rm -f "$errf"
              pid="$(echo "$out" | jq -r '.id // empty')"
              if [ -z "$pid" ]; then
                pool_failed "$lname" "add" "the add succeeded but returned no pool id"
                return 1
              fi
              tmp="$(mktemp)"
              jq --arg n "$lname" --arg id "$pid" '.[$n]=$id' "$pool_state" > "$tmp" && mv "$tmp" "$pool_state"
              log "pool '$lname' created (id=$pid provider=$prov tags=[$tags] prio=$prio max=$maxr min=$minr)"
            fi
          }

          # (i) explicit on-prem capability pools (RC2)
          jq -c '.pools[]?' "$manifest" | while read -r pl; do
            plname="$(echo "$pl" | jq -r '.name')"
            plorg="$(echo "$pl" | jq -r '.org')"
            oid="$(org_id_for "$plorg")"
            if [ -z "$oid" ]; then
              pool_failed "$plname" "org" "org '$plorg' has no id in this controller"
              continue
            fi
            mf="$(echo "$pl" | jq -r '.manifestFile // ""')"
            declared="$(echo "$pl" | jq -r '.labels | join(",")')"
            policy="$(echo "$pl" | jq -r '.policyLabels | join(",")')"
            if ! tags="$(derive_tags "$mf" "$declared" "$policy")"; then
              pool_failed "$plname" "labels" "label derivation/lint failed against manifest '$mf' (fail-closed)"
              continue
            fi
            # RC5: append legacy alias class names verbatim (NOT linted — a name,
            # not a hardware claim). A job still using `runs-on: <legacy-class>`
            # then matches this pool by GitHub's subset rule. Dropping the alias
            # (empty aliasClasses) removes the tag, and the legacy-named job stays
            # queued — the deliberate end of the cutover bridge.
            aliases="$(echo "$pl" | jq -r '.aliasClasses | join(",")')"
            [ -n "$aliases" ] && tags="$tags,$aliases"
            # `|| true`: pool_apply has already recorded the failure through
            # pool_failed and named the pool. The run continues — see the
            # POOL-FAILURE ISOLATION note above.
            pool_apply "$plname" "$oid" \
              "$(echo "$pl" | jq -r '.provider')" "$tags" \
              "$(echo "$pl" | jq -r '.image')" "$(echo "$pl" | jq -r '.flavor')" \
              "$(echo "$pl" | jq -r '.osType')" "$(echo "$pl" | jq -r '.osArch')" \
              "$(echo "$pl" | jq -r '.minIdleRunners')" "$(echo "$pl" | jq -r '.maxRunners')" \
              "$(echo "$pl" | jq -r '.priority')" "$(echo "$pl" | jq -r '.runnerBootstrapTimeout')" \
              "$(echo "$pl" | jq -r '.enabled')" "$(echo "$pl" | jq -r '.runnerGroup // ""')" \
              "$(echo "$pl" | jq -r '.extraSpecs // "{}"')" || true
          done

          # (ii) capability pools (RB3): EXPAND per qualifying host + balance.
          jq -c '.capabilityPools[]?' "$manifest" | while read -r cp; do
            cpname="$(echo "$cp" | jq -r '.name')"
            cporg="$(echo "$cp" | jq -r '.org')"
            oid="$(org_id_for "$cporg")"
            if [ -z "$oid" ]; then
              pool_failed "$cpname" "org" "org '$cporg' has no id in this controller"
              continue
            fi
            req="$(echo "$cp" | jq -r '.requires | join(",")')"
            balance="$(echo "$cp" | jq -r '.balance')"
            base="$(echo "$cp" | jq -r '.basePriority')"
            policy="$(echo "$cp" | jq -r '.policyLabels | join(",")')"
            # Qualify each candidate (derived ⊇ requires), preserving order.
            idx=0
            echo "$cp" | jq -c '.candidates[]?' | while read -r cand; do
              prov="$(echo "$cand" | jq -r '.provider')"
              mf="$(echo "$cand" | jq -r '.manifestFile // ""')"
              if ! qualifies "$mf" "$req"; then
                # NOT a failure: a host that does not prove the required
                # capabilities is simply not a placement for this pool, and if
                # it used to be one, prune SHOULD remove that expansion. So this
                # path deliberately does not go through pool_failed.
                log "capabilityPool '$cpname': provider '$prov' does NOT prove [$req] — skipped"
                continue
              fi
              # tags = the host's FULL derived set (+ policy) — a qualifying host
              # advertises everything it proves, so narrower jobs match too.
              if ! tags="$(derive_tags "$mf" "" "$policy")"; then
                pool_failed "$cpname@$prov" "labels" "derive failed on manifest '$mf' for a provider that DID qualify"
                continue
              fi
              # RC5 transitional bridge: append legacy alias class names verbatim
              # (NOT linted — a name, not a proven capability) so a job still
              # written `runs-on: <legacy-class>` matches this expanded pool by
              # GitHub's subset rule while it migrates to capability labels.
              # Dropping the alias (empty aliasClasses) removes the tag.
              cpaliases="$(echo "$cp" | jq -r '(.aliasClasses // []) | join(",")')"
              [ -n "$cpaliases" ] && tags="$tags,$cpaliases"
              if [ "$balance" = "pack" ]; then
                prio=$(( base - idx )); [ "$prio" -lt 0 ] && prio=0
              else
                prio="$base"   # spread: equal priority ⇒ distribute across hosts
              fi
              pool_apply "$cpname@$prov" "$oid" "$prov" "$tags" \
                "$(echo "$cp" | jq -r '.image')" "$(echo "$cp" | jq -r '.flavor')" \
                "$(echo "$cp" | jq -r '.osType')" "$(echo "$cp" | jq -r '.osArch')" \
                "$(echo "$cp" | jq -r '.minIdleRunners')" "$(echo "$cp" | jq -r '.maxRunners')" \
                "$prio" "$(echo "$cp" | jq -r '.runnerBootstrapTimeout')" \
                "$(echo "$cp" | jq -r '.enabled')" "$(echo "$cp" | jq -r '.runnerGroup // ""')" \
                "{}" || true
              idx=$(( idx + 1 ))
            done
          done

          # (iii) AWS burst pools (RE3/RE4) — explicit labels + spot extra-specs.
          jq -c '.burstPools[]?' "$manifest" | while read -r bp; do
            bpname="$(echo "$bp" | jq -r '.name')"
            bporg="$(echo "$bp" | jq -r '.org')"
            oid="$(org_id_for "$bporg")"
            if [ -z "$oid" ]; then
              pool_failed "$bpname" "org" "org '$bporg' has no id in this controller"
              continue
            fi
            tags="$(echo "$bp" | jq -r '.labels | join(",")')"
            pool_apply "$bpname" "$oid" \
              "$(echo "$bp" | jq -r '.provider')" "$tags" \
              "$(echo "$bp" | jq -r '.image')" "$(echo "$bp" | jq -r '.flavor')" \
              "$(echo "$bp" | jq -r '.osType')" "$(echo "$bp" | jq -r '.osArch')" \
              "$(echo "$bp" | jq -r '.minIdleRunners')" "$(echo "$bp" | jq -r '.maxRunners')" \
              "$(echo "$bp" | jq -r '.priority')" "$(echo "$bp" | jq -r '.runnerBootstrapTimeout')" \
              "$(echo "$bp" | jq -r '.enabled')" "" \
              "$(echo "$bp" | jq -c '.extraSpecs // "{}"' | jq -r 'if type=="string" then . else tojson end')" || true
          done

          # ---- (5) Prune (GUARDED, opt-in) ------------------------------------
          prune="$(jq -r '.pruneUnmanaged' "$manifest")"
          if [ "$prune" = "true" ]; then
            log "prune enabled — removing undeclared scale sets in MANAGED orgs"
            # Only prune within the DECLARED org set (the reconcile-managed
            # boundary). Orgs GARM knows about but that this config never
            # declares are left entirely alone.
            for oname in $declared_org_names; do
              oid="$(org_id_for "$oname")"
              [ -n "$oid" ] || continue
              # Scale sets that DO exist in this managed org but are not declared.
              declared_in_org="$(jq -r --arg o "$oname" '.scaleSets[]|select(.org==$o)|.name' "$manifest")"
              gcli scaleset list --org "$oid" 2>/dev/null | jq -c '.[]?' | while read -r ex; do
                exname="$(echo "$ex" | jq -r '.name')"
                exid="$(echo "$ex" | jq -r '.id')"
                if ! echo "$declared_in_org" | grep -qxF "$exname"; then
                  # GARM refuses to delete an ENABLED scale set
                  # (`400: scale set is enabled; disable it first`). Disable it
                  # first (best-effort — a set already disabled makes this a
                  # no-op), THEN delete. Do NOT swallow a real delete failure:
                  # surface it and fail the reconcile so a stuck prune is loud
                  # rather than being falsely logged as "pruned".
                  garm-cli scaleset update "$exid" --enabled=false >/dev/null 2>&1 || true
                  if garm-cli scaleset delete "$exid" >/dev/null; then
                    log "pruned undeclared scale set '$exname' (id=$exid) from org '$oname'"
                  else
                    log "ERROR: failed to delete undeclared scale set '$exname' (id=$exid) in org '$oname'"
                    exit 1
                  fi
                fi
              done
            done
            # Prune undeclared POOLS: any logical name in the id-map that was NOT
            # (re)applied this run. Pools are matched via the persisted map (they
            # have no name), so a pool whose declaration/qualification vanished is
            # disabled and deleted, and dropped from the map.
            if [ -f "$pool_state" ]; then
              jq -r 'keys[]' "$pool_state" | while read -r lname; do
                if ! grep -qxF "$lname" "$applied_pools" 2>/dev/null; then
                  pid="$(jq -r --arg n "$lname" '.[$n] // ""' "$pool_state")"
                  [ -n "$pid" ] || continue
                  garm-cli pool update "$pid" --enabled=false >/dev/null 2>&1 || true
                  if garm-cli pool delete "$pid" >/dev/null 2>&1; then
                    log "pruned undeclared pool '$lname' (id=$pid)"
                  else
                    log "WARNING: could not delete undeclared pool '$lname' (id=$pid) — may still have runners"
                  fi
                  tmp="$(mktemp)"
                  jq --arg n "$lname" 'del(.[$n])' "$pool_state" > "$tmp" && mv "$tmp" "$pool_state"
                fi
              done
            fi
            # Prune undeclared credentials (only those we recognise as managed —
            # here: any credential not in the declared set is pruned ONLY when
            # prune is on, and never the built-in ones GARM seeds).
            gcli github credentials list 2>/dev/null | jq -r '.[]?.name' | while read -r exc; do
              if ! echo "$declared_cred_names" | grep -qxF "$exc"; then
                garm-cli github credentials delete "$exc" >/dev/null 2>&1 \
                  && log "pruned undeclared credential '$exc'" || true
              fi
            done
          else
            log "prune disabled (default) — undeclared entries left untouched"
          fi

          # ---- (6) EPILOGUE: the pool-failure ledger decides the exit code -----
          # Reached unconditionally now — before the failure-isolation change
          # the FIRST refused pool exited here-minus-everything, so this line
          # (and the prune above) never ran on a controller with one bad
          # declaration.
          #
          # THREE exit codes, and the distinction is what stops the restart
          # loop that motivated this:
          #
          #   0  everything converged.
          #   3  every pool that failed did so for a reason RE-RUNNING CANNOT
          #      FIX — the forge/controller returned a 4xx-class refusal of the
          #      DECLARATION itself. garm-reconcile.service pairs this with
          #      RestartPreventExitStatus=3, so systemd leaves the unit FAILED
          #      (loud: `systemctl --failed`, the deploy, any unit-state alert)
          #      and does NOT re-run it. Everything else on the controller is
          #      already converged, so a retry would only re-fail identically —
          #      which is exactly what 65 restarts on high-mem-server bought.
          #   1  at least one failure could plausibly be transient (5xx, a
          #      refused connection, a timeout, an unreadable manifest). Restart
          #      =on-failure retries, bounded by StartLimitBurst as before.
          #
          # UNSURE ⇒ TRANSIENT. Misreading a permanent error as transient costs
          # a bounded handful of retries; the other direction would silently
          # stop retrying something a retry would have fixed.
          if [ -s "$failed_pools" ]; then
            nfail="$(wc -l < "$failed_pools" | tr -d ' ')"
            permanent=1
            log "ERROR: ============================================================"
            log "ERROR: RECONCILE FINISHED WITH $nfail POOL(S) NOT CONVERGED."
            log "ERROR: Every OTHER declared entity WAS reconciled — a bad pool no"
            log "ERROR: longer aborts the run. Each failure, with the reason:"
            while IFS="$(printf '\t')" read -r f_name f_stage f_detail; do
              log "ERROR:   * $f_name [$f_stage]: $f_detail"
              case "$f_detail" in
                *"[400]"* | *"[404]"* | *"[409]"* | *"[422]"* \
                  | *"Bad Request"* | *"invalid OS type"* | *"invalid OS architecture"* \
                  | *"no such provider"* | *"no default template can be found"*) ;;
                *) permanent=0 ;;
              esac
            done < "$failed_pools"
            log "ERROR: ============================================================"
            if [ "$permanent" = 1 ]; then
              log "ERROR: every failure above is a DECLARATION error (4xx-class): re-running"
              log "ERROR: this reconcile cannot fix it, so systemd is told NOT to retry"
              log "ERROR: (exit 3 + RestartPreventExitStatus). Fix the declaration and deploy."
              exit 3
            fi
            log "ERROR: at least one failure may be transient — exiting 1 so systemd retries."
            exit 1
          fi

          log "reconcile complete"
        '';
      };

      # ----- FU9 GARM-API-WATCHDOG ------------------------------------------
      hcfg = cfg.healthcheck;
      # The probe address MUST match what garm binds and what reconcile uses:
      # loopback + the configured apiserver port. controller-info is a stable,
      # always-present route; a 200/401/409 all prove the LISTENER is bound and
      # serving (401 = auth required, 409 = init/urls required — the socket is
      # up either way). Only a connection-refused / timeout means the API died.
      healthProbeURL = "http://127.0.0.1:${toString cfg.apiServer.port}/api/v1/controller-info";

      # The ExecStartPost bind-verify: wait up to startupBindTimeout for the API
      # listener to answer, else exit non-zero so garm.service (Restart=always)
      # restarts. Catches the startup bind race directly.
      bindVerifyScript = pkgs.writeShellApplication {
        name = "garm-bind-verify";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.curl
        ];
        text = ''
          set -euo pipefail
          url="${healthProbeURL}"
          deadline=$(( $(date +%s) + ${toString hcfg.startupBindTimeout} ))
          while :; do
            # ANY HTTP response (curl exit 0, incl. 401/409) means bound+serving.
            if curl -s -o /dev/null --max-time ${toString hcfg.probeTimeout} "$url" </dev/null; then
              echo "garm-bind-verify: API listener is up ($url)"
              exit 0
            fi
            if [ "$(date +%s)" -ge "$deadline" ]; then
              echo "garm-bind-verify: API did NOT bind within ${toString hcfg.startupBindTimeout}s ($url) — failing start so systemd restarts garm" >&2
              exit 1
            fi
            sleep 1
          done
        '';
      };

      # The periodic health-check: one probe per timer tick. Persists a
      # consecutive-failure counter + the last watchdog-restart timestamp under
      # stateDir. Restarts garm.service ONLY when the API has been refused
      # `failureThreshold` times in a row AND garm.service is active AND we have
      # not restarted within `minRestartInterval` — no false positives, no
      # storms.
      healthCheckScript = pkgs.writeShellApplication {
        name = "garm-healthcheck";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.curl
          pkgs.systemd
          pkgs.gnused
        ];
        text = ''
          set -euo pipefail

          url="${healthProbeURL}"
          # The watchdog runs as root; its counter/timestamp live in ITS OWN
          # state dir (/var/lib/garm-healthcheck), NOT garm's StateDirectory.
          # Sharing garm's StateDirectory made systemd re-chown /var/lib/garm to
          # root:root on every timer run (~1/min), so garm — which runs as the
          # non-root `garm` user — lost access to its own SQLite DB and could
          # manage no runners (whole ephemeral fleet stalled).
          fail_file="/var/lib/garm-healthcheck/healthcheck-consecutive-failures"
          last_restart_file="/var/lib/garm-healthcheck/healthcheck-last-restart"
          threshold=${toString hcfg.failureThreshold}

          log() { echo "garm-healthcheck: $*"; }

          # Probe. curl exit 0 for ANY HTTP status (incl. 401/409) ⇒ the
          # listener is BOUND and serving. Non-zero (connection-refused, timeout,
          # reset) ⇒ the API is dead.
          if curl -s -o /dev/null --max-time ${toString hcfg.probeTimeout} "$url" </dev/null; then
            # Healthy: reset the consecutive-failure counter.
            if [ -f "$fail_file" ] && [ "$(cat "$fail_file" 2>/dev/null || echo 0)" != "0" ]; then
              log "API healthy again ($url) — resetting failure counter"
            fi
            printf '0' > "$fail_file"
            exit 0
          fi

          # Failed probe. Only act if garm.service is actually meant to be up:
          # a stopped/failed garm is systemd's job (Restart=always), and probing
          # a deliberately-stopped garm must not trigger a spurious "restart".
          if [ "$(systemctl is-active garm.service 2>/dev/null || true)" != "active" ]; then
            log "API probe failed but garm.service is not active — leaving to systemd (no watchdog action)"
            printf '0' > "$fail_file"
            exit 0
          fi

          fails=$(( $(cat "$fail_file" 2>/dev/null || echo 0) + 1 ))
          printf '%s' "$fails" > "$fail_file"
          log "API probe failed ($url); consecutive failures = $fails/$threshold"

          if [ "$fails" -lt "$threshold" ]; then
            exit 0
          fi

          # Threshold reached. Rate-limit: refuse to restart if we restarted
          # within minRestartInterval. `systemd-analyze timespan` normalises any
          # span to a "μs: <N>" line; convert that to whole seconds. Fall back to
          # 600s (10min) if parsing ever fails, so the rate-limit is never a
          # no-op that would let a storm through.
          now=$(date +%s)
          min_gap_us=$(systemd-analyze timespan "${hcfg.minRestartInterval}" 2>/dev/null \
            | sed -n 's/^[^0-9]*μs:[[:space:]]*\([0-9]\+\).*/\1/p' | head -n1)
          if [ -n "''${min_gap_us:-}" ]; then
            min_gap_s=$(( min_gap_us / 1000000 ))
          else
            min_gap_s=600
          fi

          if [ -f "$last_restart_file" ]; then
            last=$(cat "$last_restart_file" 2>/dev/null || echo 0)
            if [ $(( now - last )) -lt "$min_gap_s" ]; then
              log "API dead for $fails probes, but a watchdog restart happened $(( now - last ))s ago (< ''${min_gap_s}s) — RATE-LIMITED, not restarting"
              exit 0
            fi
          fi

          log "API dead for $fails consecutive probes — restarting garm.service (watchdog recovery)"
          printf '%s' "$now" > "$last_restart_file"
          # Reset the counter so post-restart probes start fresh.
          printf '0' > "$fail_file"
          systemctl restart garm.service
          log "garm.service restart issued"
        '';
      };

      # ----- RE2 CENTRAL-GARM RECOVERY / DB BACKUP --------------------------
      # The Runner-Fleet campaign collapses the per-host GARMs into ONE central
      # controller (RB2). That controller is a deliberate SPOF for provisioning,
      # bought back (campaign :architecture_decision:) with alerting (RE1/RE1b)
      # + this recovery posture. GARM is DB-as-truth: on start it reconciles
      # desired-vs-actual against GitHub, and GitHub re-queues any job whose
      # runner vanished — so NO job is permanently lost across a controller
      # crash as long as (a) the process comes back fast and (b) the SQLite DB
      # under `stateDir` survives. This block hardens both.
      rcvcfg = cfg.recovery;
      bcfg = cfg.backup;

      # The live GARM DB (SQLite) + its WAL sidecars, all under the persistent
      # StateDirectory. `.backup` produces a CONSISTENT online snapshot even
      # while garm holds the DB open (it copies committed pages under a shared
      # lock — unlike `cp`, which can catch a torn WAL write).
      dbBackupScript = pkgs.writeShellApplication {
        name = "garm-db-backup";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.sqlite
          pkgs.gzip
        ];
        text = ''
          set -euo pipefail

          db="${dbFile}"
          out_dir="${bcfg.dir}"
          retain=${toString bcfg.retain}

          log() { echo "garm-db-backup: $*"; }

          if [ ! -f "$db" ]; then
            log "no DB at $db yet (garm never initialised its store) — nothing to back up"
            exit 0
          fi

          mkdir -p "$out_dir"
          ts="$(date -u +%Y%m%dT%H%M%SZ)"
          work="$(mktemp -d "$out_dir/.snap-$ts.XXXXXX")"
          trap 'rm -rf "$work"' EXIT
          snap="$work/garm.sqlite"

          # Consistent online snapshot: sqlite's own backup API, not `cp`.
          sqlite3 "$db" ".backup '$snap'"
          # Prove it is a well-formed DB before we publish it as a restore point.
          if ! sqlite3 "$snap" 'PRAGMA integrity_check;' | grep -qx 'ok'; then
            log "ERROR: snapshot failed integrity_check — discarding" >&2
            exit 1
          fi

          final="$out_dir/garm-$ts.sqlite"
          ${optionalString bcfg.compress ''
            gzip -c "$snap" > "$work/garm.sqlite.gz"
            final="$out_dir/garm-$ts.sqlite.gz"
          ''}
          ${optionalString (!bcfg.compress) ''
            cp "$snap" "$work/garm.sqlite.plain"
          ''}
          # Publish atomically (rename within the same dir).
          ${
            if bcfg.compress then
              ''mv "$work/garm.sqlite.gz" "$final"''
            else
              ''mv "$work/garm.sqlite.plain" "$final"''
          }
          log "wrote snapshot $final"

          # Rotate: keep the newest `retain` snapshots, delete older ones.
          # shellcheck disable=SC2012
          ls -1t "$out_dir"/garm-*.sqlite* 2>/dev/null \
            | tail -n +$(( retain + 1 )) \
            | while IFS= read -r old; do log "rotating out $old"; rm -f "$old"; done

          ${optionalString (bcfg.remoteCommand != null) ''
            # Operator-supplied off-host ship (binary cache / sibling / standby).
            # It receives the snapshot path as $1 and in $GARM_DB_SNAPSHOT.
            log "shipping $final via remoteCommand"
            export GARM_DB_SNAPSHOT="$final"
            ${bcfg.remoteCommand} "$final"
            log "remoteCommand completed"
          ''}
        '';
      };

      # Emergency DB restore. NOT a systemd unit — an operator tool (documented
      # in the runbook). Stops garm, swaps a chosen snapshot into place under
      # stateDir, then restarts. A cross-host restore requires the SAME database
      # passphrase the snapshot was encrypted with (`database.passphraseFile`),
      # since GARM field-encrypts the DB — the restore refuses to guess.
      dbRestoreScript = pkgs.writeShellApplication {
        name = "garm-db-restore";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.sqlite
          pkgs.gzip
          pkgs.systemd
        ];
        text = ''
          set -euo pipefail

          db="${dbFile}"
          usage() { echo "usage: garm-db-restore <snapshot.sqlite[.gz]>" >&2; exit 2; }
          [ "$#" -eq 1 ] || usage
          src="$1"
          [ -f "$src" ] || { echo "garm-db-restore: no such snapshot: $src" >&2; exit 2; }

          echo "garm-db-restore: stopping garm.service"
          systemctl stop garm.service || true

          tmp="$(mktemp)"
          case "$src" in
            *.gz) gzip -dc "$src" > "$tmp" ;;
            *)    cp "$src" "$tmp" ;;
          esac
          if ! sqlite3 "$tmp" 'PRAGMA integrity_check;' | grep -qx 'ok'; then
            echo "garm-db-restore: snapshot failed integrity_check — refusing to restore" >&2
            rm -f "$tmp"; exit 1
          fi

          # Move aside any stale WAL/SHM so the restored file is authoritative.
          rm -f "$db-wal" "$db-shm"
          install -o ${cfg.user} -g ${cfg.group} -m 0600 "$tmp" "$db"
          rm -f "$tmp"
          echo "garm-db-restore: restored $src -> $db"

          echo "garm-db-restore: starting garm.service"
          systemctl start garm.service
          echo "garm-db-restore: done (garm will reconcile the restored DB against the forge)"
        '';
      };

      # ----- The reusable provider submodule ---------------------------------
      # One named instance per `services.garm.providers.<name>`; the attr name is
      # the GARM `[[provider]].name` referenced by scale sets.
      providerModule =
        { ... }:
        {
          options = {
            enable = mkOption {
              type = types.bool;
              default = true;
              description = ''
                Whether this provider instance is enabled (emitted as a
                `[[provider]]` block and factored into the sandbox posture).
                Defaults to true — merely declaring the instance turns it on;
                set false to keep the config but disable it.
              '';
            };

            package = mkOption {
              type = types.package;
              default = defaultVmharnessPackage;
              defaultText = lib.literalMD "this flake's `garm-provider-vmharness` package";
              description = "Package providing the `garm-provider-vmharness` binary.";
            };

            backend = mkOption {
              type = types.enum [
                "libvirt"
                "incus"
                "tart-linux-arm"
                "tart-macos"
                "utm-windows-arm"
                "qemu-windows-arm"
                "remote"
                "aws"
              ];
              default = "libvirt";
              description = ''
                vm-harness backend the provider drives. `remote` (RB1) makes the
                provider an RPC CLIENT to a remote `vm-harness serve` daemon
                (configured under `remote.*`) instead of a local-exec backend —
                the foundation for the central-GARM topology where one controller
                drives every host's VMs/containers over the network. All other
                values are LOCAL-exec backends. `libvirt` boots per-job
                Windows-11 VMs from a golden qcow2 (the Ephemeral-Windows-Runners
                path); `incus` launches per-job Linux SYSTEM CONTAINERS from a
                runner image (the Ephemeral-Linux-Runners path);
                `tart-linux-arm`, `tart-macos`, `utm-windows-arm`, and
                `qemu-windows-arm` shell to vm-harness's Apple-silicon backends
                for m3. The backend also
                contributes to the systemd sandbox posture UNION: `incus` needs
                only `incus-admin` socket-group access and no /dev/kvm (keeps the
                STRICT knobs), whereas `libvirt` relaxes them for qemu
                (libvirtd/kvm groups + DeviceAllow /dev/kvm + ProtectSystem=full).
              '';
            };

            virshPath = mkOption {
              type = types.str;
              default = "${pkgs.libvirt}/bin/virsh";
              defaultText = lib.literalMD "`\${pkgs.libvirt}/bin/virsh`";
              description = "Path to the `virsh` binary the provider shells to.";
            };

            qemuImgPath = mkOption {
              type = types.str;
              default = "${pkgs.qemu}/bin/qemu-img";
              defaultText = lib.literalMD "`\${pkgs.qemu}/bin/qemu-img`";
              description = ''
                Path to the `qemu-img` binary the provider uses to create the
                per-job CoW overlay over the golden (`qemu-img create -b`).
              '';
            };

            uefiLoader = mkOption {
              type = types.str;
              default = "/run/libvirt/nix-ovmf/edk2-x86_64-code.fd";
              description = ''
                OVMF read-only code firmware for the per-job Windows-11 domain
                (`uefi_loader`). On NixOS with libvirtd this is the symlink farm
                under /run/libvirt/nix-ovmf.
              '';
            };

            uefiNvramTemplate = mkOption {
              type = types.str;
              default = "/run/libvirt/nix-ovmf/edk2-i386-vars.fd";
              description = ''
                OVMF vars template copied into a per-job writable nvram file
                (`uefi_nvram_template`).
              '';
            };

            memoryMb = mkOption {
              type = types.ints.positive;
              default = 4096;
              description = ''
                Per-job guest RAM (MiB), emitted as `memory_mb`. Also an input to
                the eval-time resource-guard assertion
                (`maxRunners * memoryMb <= hostBudget.memoryMb`).
              '';
            };

            currentMemoryMb = mkOption {
              type = types.ints.unsigned;
              default = 0;
              example = 8192;
              description = ''
                Virtio-balloon BOOT TARGET (MiB) for the per-job libvirt domain,
                emitted as `current_memory_mb` and rendered as
                `<currentMemory>` directly below `<memory>` in the domain XML.
                `0` (the default) omits it entirely.

                What it does: `memoryMb` becomes the CEILING the guest may ever
                reach, and this becomes the amount it is asked to hold at
                power-on — the difference is parked in the virtio balloon until
                the guest asks for it back. That is what makes a large ceiling
                affordable: an idle job costs the floor, not the ceiling, so a
                burst of runners cannot pin the host's whole RAM indefinitely.

                Two caveats, both important:

                - It is a REQUEST, not a cap. `<currentMemory>` is honoured only
                  by a guest running the virtio-balloon driver; a guest without
                  it silently ignores the target and boots with the full
                  `memoryMb`. On Windows that means `balloon.sys` plus a running
                  `BLNSVR` service. Setting this against a guest that lacks them
                  is inert — it changes the XML and nothing else. Verify with
                  `virsh dommemstat <domain>`: a guest that is actually
                  ballooning reports `unused`/`available`, not just
                  `actual`/`rss`.
                - It does not relax the resource guard. The eval-time assertion
                  still budgets `maxRunners * memoryMb`, i.e. the WORST case, on
                  purpose: the floor is what the host usually pays, but the
                  ceiling is what it must be able to survive if every runner
                  fills up at once.

                Must be strictly below `memoryMb` when set (a target at or above
                the ceiling means an empty balloon); the provider drops such a
                value and the module asserts against it.
              '';
            };

            vcpus = mkOption {
              type = types.ints.positive;
              default = 4;
              description = ''
                Per-job guest vCPUs, emitted as `vcpus`. Also an input to the
                resource-guard assertion.
              '';
            };

            vmHarnessPath = mkOption {
              type = types.str;
              default = "vm-harness";
              description = "Path to the `vm-harness` binary used for per-job clone + config-drive injection.";
            };

            stateDir = mkOption {
              type = types.str;
              default = "/var/lib/garm-provider-vmharness";
              description = ''
                State directory used by vm-harness-run providers
                (`tart-linux-arm`, `tart-macos`, `utm-windows-arm`,
                `qemu-windows-arm`) for pid and instance metadata files.
                Contains no secrets.
              '';
            };

            guestMetadataURL = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "http://10.0.2.2:9997/api/v1/metadata";
              description = ''
                Optional provider-local override for the GARM metadata URL
                rendered into guest bootstrap scripts for vm-harness-run
                backends. Leave null to use `services.garm.metadataURL`.
              '';
            };

            guestCallbackURL = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "http://10.0.2.2:9997/api/v1/callbacks";
              description = ''
                Optional provider-local override for the GARM callback URL
                rendered into guest bootstrap scripts for vm-harness-run
                backends. Leave null to use `services.garm.callbackURL`.
              '';
            };

            libvirtURI = mkOption {
              type = types.str;
              default = "qemu:///system";
              description = "libvirt connection URI passed to virsh.";
            };

            network = mkOption {
              type = types.str;
              default = "default";
              description = "libvirt network the per-job domains attach to.";
            };

            # ---- Incus backend --------------------------------------------
            incusPath = mkOption {
              type = types.str;
              default = "${pkgs.incus}/bin/incus";
              defaultText = lib.literalMD "`\${pkgs.incus}/bin/incus`";
              description = ''
                Path to the `incus` client binary the provider shells to (the
                incus backend). GARM runs as the `garm` user in the `incus-admin`
                group, which can reach the incus daemon socket directly.
              '';
            };

            incusBridge = mkOption {
              type = types.str;
              default = "incusbr0";
              description = ''
                The managed incus bridge the per-job containers attach to. Also
                the interface trusted for the GARM callback/metadata port when
                `services.garm.openIncusBridgeFirewall` is set.
              '';
            };

            incusIPv4CIDR = mkOption {
              type = types.str;
              default = "";
              example = "10.0.100.0/24";
              description = ''
                The incus bridge subnet in a.b.c.d/nn form. The provider injects
                a STATIC IPv4 into each container via cloud-init.network-config
                because incusbr0's DHCP does not lease on this host. Required when
                backend = "incus".
              '';
            };
            incusIPv4Gateway = mkOption {
              type = types.str;
              default = "";
              example = "10.0.100.1";
              description = ''
                The default route for per-job containers (the incus bridge host
                IP). Also the host IP the guest reaches GARM's metadata/callback
                endpoint on. Required when backend = "incus".
              '';
            };
            incusIPv4RangeStart = mkOption {
              type = types.str;
              default = "";
              example = "10.0.100.200";
              description = ''
                Lower bound (inclusive, dotted) of the static-IPv4 pool the
                provider allocates per container. Empty ⇒ the provider defaults
                to the .200 host of the /24.
              '';
            };
            incusIPv4RangeEnd = mkOption {
              type = types.str;
              default = "";
              example = "10.0.100.250";
              description = ''
                Upper bound (inclusive, dotted) of the static-IPv4 pool. Empty ⇒
                the provider defaults to the .250 host of the /24.
              '';
            };
            incusNameservers = mkOption {
              type = types.listOf types.str;
              default = [
                "1.1.1.1"
                "8.8.8.8"
              ];
              description = "Resolvers written into each container's netplan.";
            };

            incusGpuPassthrough = mkOption {
              type = types.bool;
              default = false;
              description = ''
                When true (incus backend only), the provider attaches an NVIDIA
                GPU to every per-job container before start:
                `incus config device add <name> gpu gpu` plus
                `incus config set <name> nvidia.runtime=true`. The host must have
                `hardware.nvidia-container-toolkit.enable = true` (the CDI/runtime
                toolkit Incus uses to expose the GPU + userspace driver into the
                container). Backs a GPU runner class (`runs-on: incus-gpu`): a
                fresh container gets a GPU, runs one job, is destroyed. Ignored by
                non-incus providers.
              '';
            };

            incusShareHostNixStore = mkOption {
              type = types.bool;
              default = false;
              description = ''
                When true (incus backend only), the provider wires every per-job
                container into the HOST's shared `/nix/store` as a build-farm
                participant (the multi-user-Nix model: build once, cache-hit for
                every later guest/host). Before start it mounts `/nix/store`
                READ-ONLY (the guest reads prebuilt paths directly — instant
                cache hits) and the host nix-daemon socket directory
                (`/nix/var/nix/daemon-socket`) so all guest WRITES/builds go
                through the HOST daemon (`NIX_REMOTE=daemon`): a novel derivation
                built in a guest lands in the shared host store (validated +
                content-addressed by the daemon) and is a cache hit for later
                guests.

                SECURITY POSTURE (writable-by-design and SAFE): incus's default
                idmap shifts guest root to an unprivileged host uid that is NOT
                in nix `trusted-users`, so the daemon treats the guest as
                UNTRUSTED (`Trusted: 0`). An untrusted client can build + add
                CONTENT-ADDRESSED paths but CANNOT set substituters/trusted-keys
                or import unsigned NARs as trusted (those settings are ignored
                with a warning); a malicious path content-addresses to a
                different hash than anything production resolves, so it cannot
                poison the cache; and the raw store bytes are read-only from the
                guest. The residual risk is disk-DoS (a guest filling the store),
                contained by ephemeral one-job guests + store quotas. Default
                false ⇒ the container is byte-unchanged. Ignored by non-incus
                providers. Backs PM2 (Production-Runners shared nix store).
              '';
            };

            incusReprobuildStore = mkOption {
              type = types.str;
              default = "";
              example = "/var/lib/reprobuild/shared-store";
              description = ''
                When set (incus backend only), the HOST path of the reprobuild
                content-addressed store (`repro_local_store`) mounted READ-WRITE
                into every per-job container before start. The CAS is
                BLAKE3-content-addressed (hash-on-read), so writes are
                self-verifying: a guest ADDS content-addressed entries that
                PERSIST to the shared store for later guests, and CANNOT corrupt
                an existing entry (a tampered blob hashes to a different digest).
                A job resolves prebuilt artifacts locally (no HTTP round-trip) by
                pointing reprobuild at the mount (`REPRO_STORE_ROOT`). Empty ⇒ no
                reprobuild share. Ignored by non-incus providers. Backs PM3.
              '';
            };

            incusReprobuildStoreGuestPath = mkOption {
              type = types.str;
              default = "";
              example = "/srv/repro-store";
              description = ''
                In-guest mount point for the `incusReprobuildStore` share. Empty
                ⇒ mirrors the host path. Only consulted when
                `incusReprobuildStore` is set.
              '';
            };

            incusSecurityNesting = mkOption {
              type = types.bool;
              default = false;
              description = ''
                When true (incus backend only), the provider enables NESTED
                containerisation on every per-job container before start so an
                in-guest Docker/Podman daemon can run (the `runs-on: incus`
                nested-Docker path):
                `incus config set <name> security.nesting true` plus the two
                syscall intercepts fuse-overlayfs needs to build images
                UNPRIVILEGED —
                `security.syscalls.intercept.mknod true` (mknod device-node
                image layers) and `security.syscalls.intercept.setxattr true`
                (overlayfs `trusted.overlay.*` xattrs). `security.nesting` lets
                the guest create its own namespaces/cgroups + mount an overlay.
                The runner image must ship docker/moby + fuse-overlayfs and be
                configured for the fuse-overlayfs storage driver (an
                unprivileged nested container cannot use the kernel overlay2
                driver). Default false ⇒ the container is byte-unchanged (the
                live runners are untouched). Ignored by non-incus providers.
                Backs HR1 (Production-Runners nested Docker).
              '';
            };

            incusNestedKvm = mkOption {
              type = types.bool;
              default = false;
              description = ''
                When true (incus backend only), the provider exposes the host
                `/dev/kvm` into every per-job container and ensures
                `security.nesting=true` before start so an in-guest
                `qemu-system-* -enable-kvm` gets HARDWARE-ACCELERATED nested
                virtualisation (the `runs-on: incus` nested-VM path):
                `incus config set <name> security.nesting true` plus
                `incus config device add <name> kvm unix-char
                source=/dev/kvm path=/dev/kvm mode=0666`. The permissive mode
                is confined to the dedicated ephemeral guest so its
                unprivileged runner can use KVM. The host must itself expose
                `/dev/kvm` with nested virtualisation enabled
                (`kvm_intel.nested=Y` / `kvm_amd.nested=Y`), and the runner
                image must ship qemu/kvm. Default false ⇒ the container is
                byte-unchanged (the live runners are untouched). Ignored by
                non-incus providers. Backs HR2 (Production-Runners nested KVM).
              '';
            };

            incusLimitsCpu = mkOption {
              # Constrained rather than free-form `str` for two reasons. It is
              # rendered into TOML by string interpolation, so a value carrying
              # a quote would emit syntactically invalid config and fail at
              # provider start-up rather than at eval. And a typo that incus
              # rejects (`"eight"`, `"8 "`) is only discovered on the first
              # container Create, i.e. on a real job. The shapes incus accepts
              # are a count or a cpuset; empty means "no cap".
              type = types.strMatching "([0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*)?";
              default = "";
              example = "8";
              description = ''
                When non-empty (incus backend only), the provider sets
                `limits.cpu` on every per-job container BEFORE start:
                `incus config set <name> limits.cpu <value>`. Incus accepts a
                COUNT (`"8"`) or an explicit CPU SET (`"0-7"`, `"0,2,4"`); a
                count is a DYNAMIC pin — incusd picks that many host CPUs and
                re-balances as containers come and go.

                This bounds the DEMAND a per-job container generates, not just
                the share it is scheduled at. An uncapped container inherits
                `cpuset.cpus=0-N` and therefore reports every host thread to
                `nproc`, so `make -j$(nproc)` / `cargo build` /
                `nix build --cores 0` each size themselves to the WHOLE
                machine; several such containers put the host into a
                multi-hundred runnable-task overhang that starves every other
                workload on the box, including co-resident libvirt guests.

                Chosen over a `limits.cpu.allowance` CFS quota deliberately: an
                allowance sized for the worst case idles host CPUs whenever
                fewer than the worst-case number of containers are running,
                whereas a cpuset count caps peak parallelism while still
                letting a lone container use its full allotment.

                Default `""` ⇒ the key is not emitted at all, the provider sets
                nothing, and the container is byte-identical to before this
                option existed. Ignored by non-incus providers.
              '';
            };

            poolDir = mkOption {
              type = types.str;
              default = "/var/lib/garm/pool";
              description = ''
                Directory where the (libvirt) provider writes per-job artifacts
                (the CoW overlay + the config-drive ISO + the OVMF nvram). The
                module provisions it via systemd-tmpfiles owned `garm:libvirtd`
                (0771). NOTE: if MULTIPLE libvirt providers are enabled, give each
                a DISTINCT poolDir. The incus backend writes NO host pool dir
                (the incus daemon owns container storage).
              '';
            };

            images = mkOption {
              default = { };
              description = ''
                Map of pool image identifier (BootstrapInstance.image) to a golden
                source. If a pool's image is absent here, the raw image string is
                used as the source directly.
              '';
              type = types.attrsOf (
                types.submodule {
                  options = {
                    sourceImage = mkOption {
                      type = types.str;
                      description = ''
                        Golden qcow2/volume (libvirt) or incus image alias (incus)
                        the per-job instance is cloned from. For libvirt the
                        golden AND every parent directory must be READABLE +
                        TRAVERSABLE by the `garm` user.
                      '';
                    };
                    osName = mkOption {
                      type = types.str;
                      default = "windows";
                      description = "Reported OS name (surfaced in ProviderInstance.os_name).";
                    };
                    osVersion = mkOption {
                      type = types.str;
                      default = "";
                      description = "Reported OS version (surfaced in ProviderInstance.os_version).";
                    };
                  };
                }
              );
            };

            # ----- RB1 remote-target mode -------------------------------------
            # Consulted only when `backend = "remote"`. COMPANY-AGNOSTIC: an
            # endpoint + how to obtain the bearer token + the vm-harness backend
            # the REMOTE host drives — no Metacraft host or secret is baked in.
            # The concrete endpoint/token wiring (NetBird IPs, agenix secrets)
            # is an infra-layer concern that CONSUMES these options.
            remote = mkOption {
              default = { };
              description = ''
                Remote-target mode configuration (RB1). Only used when
                `backend = "remote"`, in which case the provider is an RPC client
                to a remote `vm-harness serve` daemon instead of a local backend.
              '';
              type = types.submodule {
                options = {
                  endpoint = mkOption {
                    type = types.str;
                    default = "";
                    example = "100.72.0.5:8873";
                    description = ''
                      Remote `vm-harness serve` address as host:port — typically a
                      NetBird overlay IP (the control channel is NEVER exposed on
                      the public internet). Required when `backend = "remote"`.
                    '';
                  };
                  targetBackend = mkOption {
                    type = types.enum [
                      "incus"
                      "libvirt"
                      "hyperv"
                      "tart-macos"
                      "tart-linux-arm"
                      "qemu-windows-arm"
                      "noop"
                    ];
                    default = "incus";
                    description = ''
                      vm-harness backend id the REMOTE host drives (forwarded as
                      the remote `--backend`). `noop` is the sanctioned test
                      backend used by the `t_garm_provider_remote` gate.

                      This is a SUBSET of the local `backend` enum above, and
                      deliberately so: a backend belongs here only once a remote
                      `vm-harness serve` is known to drive it. `qemu-windows-arm`
                      qualified when m3 began serving Windows-ARM guests to the
                      central controller; `utm-windows-arm` has not, and stays
                      local-only until something serves it.
                    '';
                  };
                  authTokenFile = mkOption {
                    type = types.nullOr types.path;
                    default = null;
                    description = ''
                      Path the provider reads the bearer token from
                      (`auth_token_file`). Point it at an agenix secret path or a
                      systemd `LoadCredential`-staged file — the token NEVER enters
                      the Nix store. When null, the provider reads the token from
                      the `authTokenEnv` environment variable instead.
                    '';
                  };
                  authTokenEnv = mkOption {
                    type = types.str;
                    default = "VMH_SERVE_TOKEN";
                    description = ''
                      Environment variable the bearer token is read from when
                      `authTokenFile` is null (`auth_token_env`). Its value is
                      supplied by the infra layer (systemd `EnvironmentFile` /
                      `LoadCredential`); this module only forwards the variable
                      name to the provider process. Matches the variable
                      `vm-harness serve` itself documents, so one per-host secret
                      serves both ends.
                    '';
                  };
                  guestOS = mkOption {
                    type = types.str;
                    default = "linux";
                    description = ''
                      Reported guest OS for instances created through this remote
                      when the golden-image map carries no os_name (`guest_os`).
                    '';
                  };
                  requestTimeoutSec = mkOption {
                    type = types.ints.unsigned;
                    default = 0;
                    description = ''
                      Bounds a single non-streaming RPC (`/v1/info`).
                      0 (default) uses a built-in timeout. The create/delete
                      streams are bounded by the remote worker's own
                      `--timeout-sec`, not this.
                    '';
                  };
                  incusSecurityNesting = mkOption {
                    type = types.bool;
                    default = false;
                    description = ''
                      Trusted operator grant for a remote Incus provider. When
                      true, the provider appends only vm-harness's fixed
                      `--incus-security-nesting` flag before guest start. It
                      does not expose arbitrary Incus configuration to pools,
                      workflows, bootstrap/user-data, or guests. Rejected for
                      non-remote providers and non-Incus remote targets.
                    '';
                  };
                  incusNestedKvm = mkOption {
                    type = types.bool;
                    default = false;
                    description = ''
                      Trusted operator grant for a remote Incus provider. When
                      true, the provider appends only vm-harness's fixed
                      `--incus-nested-kvm` flag; vm-harness maps the fixed host
                      `/dev/kvm` to guest `/dev/kvm`, verifies exact mode 0666,
                      and opens it read-write. No path or mode is configurable.
                      Rejected for non-remote providers and non-Incus targets.
                    '';
                  };
                };
              };
            };

            # RC2/RB3: the RA6-verified capability manifest for the HOST this
            # provider drives. When a `pools`/`capabilityPools` entry is backed
            # by this provider, the reconcile reads this file, runs
            # `runner-label-tool derive` on it, and uses the proven labels as the
            # pool's classic-runner tag set (JIT label DERIVATION — ties RC1 to
            # RA6). COMPANY-AGNOSTIC: the path is an infra concern — infra points
            # it at the file its `garm-serve-manifest-verify` oneshot writes
            # after fetching + verifying the host's signed `GET /v1/manifest`.
            # null (default) ⇒ pools backed by this provider must declare their
            # labels explicitly (no derivation).
            manifestFile = mkOption {
              type = types.nullOr types.path;
              default = null;
              example = "/run/garm/manifests/hms.json";
              description = ''
                Path to the host's RA6-verified capability manifest JSON (the
                `GET /v1/manifest` payload, already signature-verified by the
                controller). The pool reconcile derives this provider-backed
                pool's capability labels from it via `runner-label-tool derive`.
                The manifest is a store-safe, secret-free artifact (hardware
                facts, not credentials). null ⇒ no derivation for pools on this
                provider; they must set their labels explicitly.
              '';
            };

            # ----- RE3 AWS burst backend --------------------------------------
            # Consulted only when `backend = "aws"`. COMPANY-AGNOSTIC: the
            # region + subnet + credential TYPE and the names of the env vars
            # that carry the credentials — with NO Metacraft account, region,
            # AMI, or secret baked in. The concrete AWS account/region/subnet/AMI
            # + agenix-staged credentials are an infra-layer concern that
            # CONSUMES these options (a HELD prerequisite: the operator must
            # provision the AWS account + a runner AMI + the CI IAM role/creds).
            aws = mkOption {
              default = { };
              description = ''
                AWS burst backend configuration (RE3). Only used when
                `backend = "aws"`, in which case the provider is
                `garm-provider-aws` provisioning ephemeral EC2 runners. The
                instance type, AMI, and spot policy are PER-POOL values (see
                `services.garm.burstPools`), not provider-wide — this block holds
                only the account-scoped region/subnet/credentials.
              '';
              type = types.submodule {
                options = {
                  region = mkOption {
                    type = types.str;
                    default = "";
                    example = "eu-central-1";
                    description = ''
                      AWS region the burst runners launch in (`region`). Pick one
                      close to the artifact caches / NetBird gateway. Required
                      when `backend = "aws"`.
                    '';
                  };
                  subnetId = mkOption {
                    type = types.str;
                    default = "";
                    example = "subnet-0123456789abcdef0";
                    description = ''
                      Default VPC subnet the runners are placed in (`subnet_id`).
                      A per-pool `subnet_id` extra-spec can override it. Required
                      when `backend = "aws"`.
                    '';
                  };
                  credentialType = mkOption {
                    type = types.enum [
                      "role"
                      "static"
                    ];
                    default = "role";
                    description = ''
                      How `garm-provider-aws` obtains AWS credentials
                      (`credentials.credential_type`). `role` (the default and
                      recommended) uses the AWS SDK default credential chain —
                      the forwarded env vars, a mounted shared-credentials file,
                      or the instance-profile IMDS — so NO secret enters the Nix
                      store. `static` is accepted for completeness, but the
                      access/secret keys are deliberately NOT rendered into the
                      store config; supply them to the same env chain instead
                      (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` /
                      `AWS_SESSION_TOKEN`) via the infra layer.
                    '';
                  };
                  forwardEnv = mkOption {
                    type = types.listOf types.str;
                    default = [
                      "AWS_ACCESS_KEY_ID"
                      "AWS_SECRET_ACCESS_KEY"
                      "AWS_SESSION_TOKEN"
                      "AWS_REGION"
                      "AWS_DEFAULT_REGION"
                      "AWS_SHARED_CREDENTIALS_FILE"
                      "AWS_WEB_IDENTITY_TOKEN_FILE"
                      "AWS_ROLE_ARN"
                      "AWS_CONTAINER_CREDENTIALS_FULL_URI"
                      "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI"
                      "SSL_CERT_FILE"
                      "SSL_CERT_DIR"
                    ];
                    description = ''
                      Environment-variable NAMES forwarded to the
                      `garm-provider-aws` process (GARM propagates only the vars
                      it is told to). Their VALUES are supplied by the infra
                      layer (systemd `EnvironmentFile` / `LoadCredential` / an
                      instance-profile), so credentials never enter the store.
                      The default set covers the AWS SDK default credential chain
                      plus the TLS CA-bundle vars the SDK needs to reach the EC2
                      API. Override to narrow or extend it.
                    '';
                  };
                };
              };
            };
          };
        };

      # ----- The reusable GitHub App credential submodule --------------------
      githubModule =
        { name, ... }:
        {
          options = {
            enable = mkOption {
              type = types.bool;
              default = true;
              description = ''
                Whether this GitHub App credential is enabled (emitted as a
                `[[github]]` block and its PEM staged via LoadCredential).
                Defaults to true.
              '';
            };

            credentialsName = mkOption {
              type = types.str;
              default = name;
              defaultText = lib.literalMD "the attribute name";
              description = ''
                The `[[github]].name` — the credential name an org/scale set
                references (`garm-cli organization add --credentials <name>`).
                Defaults to the attribute name.
              '';
            };

            description = mkOption {
              type = types.str;
              default = "GARM GitHub App credentials (${name})";
              defaultText = lib.literalMD "`GARM GitHub App credentials (<name>)`";
              description = "Human-readable `[[github]].description`.";
            };

            appId = mkOption {
              type = types.ints.positive;
              example = 123456;
              description = "GitHub App ID (`[github.app].app_id`).";
            };

            installationId = mkOption {
              type = types.ints.positive;
              example = 7654321;
              description = "GitHub App installation ID (`[github.app].installation_id`).";
            };

            appKeyFile = mkOption {
              type = types.nullOr types.path;
              default = null;
              example = "/run/agenix/garm/github-app-key";
              description = ''
                Path to the GitHub App private-key PEM, staged via LoadCredential
                (agenix-managed on the real host) so it is NOT world-readable and
                NEVER enters the Nix store. At render time it is copied to a
                stable 0600 path under `stateDir` and `private_key_path` points
                there. Required when the credential is enabled.
              '';
            };
          };
        };
    in
    {
      options.services.garm = {
        enable = mkEnableOption "the GARM (GitHub Actions Runner Manager) control-plane daemon";

        package = mkOption {
          type = types.package;
          default = defaultPackage;
          defaultText = lib.literalMD "this flake's `garm` package (garm daemon + garm-cli)";
          description = "Package providing the `garm` daemon and `garm-cli` binaries.";
        };

        labelToolPackage = mkOption {
          type = types.package;
          default = defaultLabelTool;
          defaultText = lib.literalMD "this flake's `runner-label-tool` package";
          description = ''
            The RC1 `runner-label-tool` package (manifest → label derivation +
            `advertised ⊆ derived` linter). The pool reconcile (RC2/RB3) runs its
            `derive`/`lint` subcommands to compute a classic runner's capability
            labels from a host's RA6-verified `/v1/manifest`. Company-agnostic.
          '';
        };

        mode = mkOption {
          type = types.enum [
            "scaleSets"
            "pools"
          ];
          default = "scaleSets";
          description = ''
            The runner-provisioning MODEL this controller advertises. This is a
            DECLARATION of intent for the Phase-C cutover, NOT a hard switch:
            both `scaleSets` and `pools`/`capabilityPools` reconcile ADDITIVELY
            whenever they are non-empty, so a controller can run scale sets and
            capability pools side by side during the migration (RC5 retires the
            scale sets). Concretely:

            - `scaleSets` (default): single-name scale sets — a job names exactly
              one class (`runs-on: eph-linux-x64`). The historical model.
            - `pools`: GARM POOLS + classic runners advertising RC1 CAPABILITY
              LABEL SETS (`runs-on: [self-hosted, linux, x64, x86-64-v3]` matches
              any runner proving all those labels). Set this once a host's pools
              are declared so the intent is legible and tooling/alerts can key on
              `garm_pool_*` rather than `garm_scaleset_*`.

            The value gates NOTHING structurally — declaring `services.garm.pools`
            provisions pools regardless — but it records which model is
            authoritative for a host and is the flag infra flips at cutover.
          '';
        };

        stateDir = mkOption {
          type = types.str;
          default = "/var/lib/garm";
          description = ''
            Durable state root, provisioned as a systemd StateDirectory. Holds
            the SQLite database, the runtime-rendered `config.toml`, and (unless
            operator secrets are provided) the auto-generated DB passphrase and
            JWT secret. Must be stable: the DB passphrase persisted here
            encrypts data in the database.
          '';
        };

        controllerName = mkOption {
          type = types.str;
          default = "garm";
          description = ''
            Human-readable controller name. GARM assigns the controller its own
            UUID on first run (stored in the DB); this is only a label.
          '';
        };

        logLevel = mkOption {
          type = types.enum [
            "debug"
            "info"
            "warn"
            "error"
          ];
          default = "info";
          description = "GARM log level (`[logging].log_level`).";
        };

        jwtTimeToLive = mkOption {
          type = types.str;
          default = "24h";
          description = ''
            JWT token lifetime (`[jwt_auth].time_to_live`), a Go duration
            string. GARM clamps values below its 24h minimum up to 24h.
          '';
        };

        apiServer = {
          bind = mkOption {
            type = types.str;
            default = "0.0.0.0";
            description = ''
              IP address the API server binds (`[apiserver].bind`). Must be a
              valid IP literal. Defaults to all interfaces; the infra layer
              restricts this to an overlay/LAN interface in production.
            '';
          };
          port = mkOption {
            type = types.port;
            default = 9997;
            description = "TCP port the API server listens on (`[apiserver].port`).";
          };
        };

        metrics = {
          enable = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Enable the Prometheus `/metrics` endpoint (`[metrics].enable`).
            '';
          };
          disableAuth = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Serve `/metrics` without JWT auth (`[metrics].disable_auth`).
              Only meaningful when `metrics.enable` is true. Keep this endpoint
              on a trusted/overlay interface (see `apiServer.bind`).
            '';
          };
          period = mkOption {
            type = types.str;
            default = "60s";
            description = ''
              Snapshot-metrics refresh interval (`[metrics].period`, a Go
              duration). 60s matches GARM's default.
            '';
          };
        };

        # Optional operator-supplied secrets. When unset (default), the service
        # generates strong random secrets on first boot and persists them under
        # stateDir. When set, the referenced files are staged via LoadCredential
        # and used verbatim.
        jwtSecretFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            Optional path to a file containing the `[jwt_auth].secret`. Staged
            via systemd LoadCredential. Null (default) ⇒ a strong secret is
            generated on first boot and persisted under stateDir.
          '';
        };

        dbPassphraseFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            Optional path to a file containing the `[database].passphrase`
            (must be a strong secret; the first 32 chars are used). Staged via
            LoadCredential. Null (default) ⇒ generated + persisted on first
            boot. NOTE: changing this after the DB has encrypted data
            invalidates that data.
          '';
        };

        openFirewall = mkOption {
          type = types.bool;
          default = false;
          description = "Open the API server `port` in the host firewall.";
        };

        # ---- FU9 GARM-API-WATCHDOG: health supervision ------------------------
        # GARM runs Type=simple + Restart=always. That only recovers a CRASH
        # (main-process exit). It does NOT recover the failure mode observed live
        # on high-mem-server: the garm PROCESS came up and its pool managers ran,
        # but the HTTP API listener on :9997 NEVER BOUND (a bind race on a fast
        # restart — the old instance's socket still held). The process stayed
        # alive, so Restart=always never fired, and systemd had no visibility
        # into the dead API → a ~3h silent outage that crash-looped
        # garm-reconcile with connection-refused to 127.0.0.1:9997.
        #
        # This adds process-independent health supervision on the SAME address
        # garm binds and reconcile probes (loopback 127.0.0.1:<apiServer.port>):
        #   * a periodic health-check (systemd service+timer) that probes
        #     GET /api/v1/controller-info — a 200/401/409 proves the listener is
        #     BOUND + serving (401 = auth required, but the socket is up); a
        #     connection-refused / timeout means the API is dead — and restarts
        #     garm.service after N CONSECUTIVE failed probes (safe: a single
        #     momentarily-busy probe never restarts), rate-limited so it can
        #     never restart-storm;
        #   * an ExecStartPost bind-verify on garm.service that waits up to
        #     `startupBindTimeout` for the API to bind and FAILS (→ Restart=always
        #     restarts garm) if it never does — catching the bind race AT
        #     STARTUP, before the periodic probe would.
        healthcheck = {
          enable =
            mkEnableOption "the GARM API health-check watchdog (auto-recover a process-alive-but-API-dead garm)"
            // {
              default = true;
              example = false;
            };

          interval = mkOption {
            type = types.str;
            default = "1min";
            description = ''
              How often the health-check probes the GARM API
              (`OnUnitActiveSec` / `OnBootSec` of the `garm-healthcheck.timer`,
              a systemd time span). One probe per interval.
            '';
          };

          failureThreshold = mkOption {
            type = types.ints.positive;
            default = 3;
            description = ''
              Number of CONSECUTIVE failed probes (connection-refused/timeout)
              before the watchdog restarts `garm.service`. A single failing
              probe (a momentarily-busy garm) never triggers a restart; the
              failure counter is persisted under `stateDir` and RESET to zero on
              the first successful probe. With the default 1min interval and a
              threshold of 3, a genuinely dead API is recovered within ~3-4min.
            '';
          };

          minRestartInterval = mkOption {
            type = types.str;
            default = "10min";
            description = ''
              Minimum wall-clock time between two watchdog-initiated restarts (a
              `systemd-analyze timestamp`-parseable span). After the watchdog
              restarts garm it will NOT restart again until this much time has
              elapsed, even if probes keep failing — so a garm that is dead for
              a deeper reason (bad config, disk full) is restarted at most once
              per window instead of storming. The restart timestamp is persisted
              under `stateDir`.
            '';
          };

          probeTimeout = mkOption {
            type = types.ints.positive;
            default = 5;
            description = ''
              Per-probe curl timeout in seconds (`curl --max-time`). A probe
              that neither connects nor responds within this window counts as a
              failure. Keep it well below `interval`.
            '';
          };

          startupBindVerify = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Add an `ExecStartPost` to `garm.service` that waits up to
              `startupBindTimeout` for the API listener to bind and FAILS the
              start (so `Restart=always` restarts garm) if it never binds within
              that window. Catches the startup bind race directly; the periodic
              health-check catches later deaths. The probe is against the local
              loopback API, so it never depends on external forge/GitHub state.
            '';
          };

          startupBindTimeout = mkOption {
            type = types.ints.positive;
            default = 30;
            description = ''
              Seconds the `ExecStartPost` bind-verify waits for the API to bind
              before failing the start (only used when `startupBindVerify` is
              true).
            '';
          };
        };

        # ---- RE2 central-GARM RECOVERY posture (fast declarative restart) -----
        # The Runner-Fleet campaign (RB2) collapses the fleet onto ONE central
        # GARM — a deliberate provisioning SPOF. GARM is DB-as-truth: on start it
        # reconciles desired-vs-actual against GitHub, and GitHub re-queues any
        # job whose runner disappeared. So the pragmatic recovery mechanism for a
        # DB-as-truth single controller is a FAST, MONITORED declarative restart
        # with the DB on persistent storage — a crashed controller is back in
        # seconds and reconciles the surviving DB, losing no jobs. This block
        # tunes that restart and records the RTO the `t_central_garm_recovery`
        # gate measures against.
        #
        # This is COMPLEMENTARY to `healthcheck` (which recovers a
        # process-ALIVE-but-API-DEAD garm via an external probe): `recovery`
        # governs the ordinary crash path (main process exits) that
        # `Restart=always` already handles — it makes that path FAST and, above
        # all, makes it never permanently give up on the SPOF.
        recovery = {
          enable = mkEnableOption "the RE2 fast-restart recovery posture for the central GARM" // {
            default = true;
            example = false;
          };

          restartSec = mkOption {
            type = types.str;
            default = "5s";
            description = ''
              `RestartSec` for `garm.service` — how long systemd waits after a
              crash before respawning. Kept short so the DB-as-truth reconcile
              resumes quickly; a fresh garm rebinds the API and reconciles the
              persistent SQLite DB in seconds.
            '';
          };

          startLimitIntervalSec = mkOption {
            type = types.str;
            default = "300s";
            description = ''
              `StartLimitIntervalSec` for `garm.service`. systemd's DEFAULT
              (10s / 5 bursts) would put a briefly crash-looping garm into a
              PERMANENT `failed` state and stop restarting it — unacceptable for
              a fleet SPOF. This widens the window so a transient loop keeps
              being recovered; only a garm that exceeds `startLimitBurst` starts
              in this window is genuinely broken (bad config, disk full) and is
              then LEFT failed on purpose, so `up==0`/`GarmControllerDown`
              (RE1) pages a human instead of hiding a hard fault behind an
              endless restart.
            '';
          };

          startLimitBurst = mkOption {
            type = types.ints.positive;
            default = 50;
            description = ''
              `StartLimitBurst` for `garm.service` — how many restarts are
              allowed within `startLimitIntervalSec` before systemd gives up and
              pages (see above). Generous by design: transient recovery must
              never hit the ceiling; a real fault will.
            '';
          };

          targetRecoverySeconds = mkOption {
            type = types.ints.positive;
            default = 30;
            description = ''
              The documented RECOVERY-TIME OBJECTIVE (RTO) for a crashed central
              GARM: the wall-clock budget from process death to a re-bound,
              serving API on the persistent DB. Informational for operators + the
              runbook, and the bound the `t_central_garm_recovery` gate asserts
              the measured single-crash recovery stays within.
            '';
          };

          warmStandby = {
            enable = mkEnableOption ''
              a documented WARM-STANDBY posture for the central GARM. NOTE the
              trade-off: GARM is DB-as-truth and reconciles against GitHub, so
              running a SECOND live controller against the same forge risks a
              split-brain double-provision. Warm standby here therefore does
              NOT mean two live controllers — it means the DB backup
              (`services.garm.backup`) is continuously shipped to a standby
              host, which can be PROMOTED by restoring that DB + starting garm
              (a documented, seconds-to-minutes manual/scripted step in the
              runbook). It is heavier than fast-restart and only pays off when
              the whole HOST is lost, not merely the process — most deploys
              should leave this off and rely on fast-restart + backup
            '';

            host = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = ''
                Informational: the standby host the DB backup is shipped to
                (surfaced in the runbook / promotion step). The actual shipping
                is `backup.remoteCommand`; this only records the intent.
              '';
            };
          };
        };

        # ---- RE2 GARM DB backup (online SQLite snapshot + off-host ship) ------
        # Fast-restart (above) covers a crashed PROCESS on a live host — the DB
        # survives on `stateDir`. This covers the DB itself: periodic CONSISTENT
        # snapshots (sqlite `.backup`, not `cp`) rotated locally and optionally
        # shipped off-host, so a corrupted DB or a lost host is recoverable with
        # `garm-db-restore`. Opt-in (needs a destination); disabled by default.
        backup = {
          enable = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Enable periodic online backups of the GARM SQLite DB via a
              `garm-db-backup` systemd oneshot + timer. Consistent snapshots
              (sqlite's own `.backup`, integrity-checked) are written to
              `backup.dir`, rotated to `backup.retain`, and optionally shipped
              off-host by `backup.remoteCommand`. Restore with the installed
              `garm-db-restore <snapshot>` tool.
            '';
          };

          interval = mkOption {
            type = types.str;
            default = "15min";
            description = ''
              How often the backup timer fires (`OnUnitActiveSec` / `OnBootSec`,
              a systemd time span). One consistent snapshot per interval.
            '';
          };

          dir = mkOption {
            type = types.path;
            default = "/var/backup/garm";
            description = ''
              Directory the local rotated snapshots are written to. Should live
              on PERSISTENT storage (ideally a different filesystem than
              `stateDir`, so a lost/corrupted DB volume does not take the backups
              with it). Created 0700, owned by the garm user.
            '';
          };

          retain = mkOption {
            type = types.ints.positive;
            default = 24;
            description = ''
              Number of newest local snapshots to keep; older ones are rotated
              out on each run. With the default 15min interval, 24 covers ~6h.
            '';
          };

          compress = mkOption {
            type = types.bool;
            default = true;
            description = "gzip each snapshot (`garm-<ts>.sqlite.gz`).";
          };

          remoteCommand = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "rsync -a \"$1\" backup-host:/srv/garm-db/";
            description = ''
              Optional operator-supplied command run after each successful local
              snapshot to ship it OFF-HOST (a sibling host, the binary cache, an
              object store — the warm-standby feed). It receives the snapshot
              path as `$1` and in `$GARM_DB_SNAPSHOT`, and runs as the garm user
              from the backup service (so any credentials it needs must be
              reachable there — e.g. a `LoadCredential` you add via
              `systemd.services.garm-db-backup`). Company-agnostic: the module
              ships no transport, only the hook.
            '';
          };
        };

        # ---- Declarative reconcile (PM5 "declarative reconcile", pulled fwd) --
        # A post-boot systemd oneshot that makes GARM's DB-resident state (forge
        # endpoints, credentials, orgs, scale sets) track the module's declared
        # `github` + `scaleSets` shape. Scale sets, orgs, and credentials are DB
        # state (a scale set registers a GitHub runner-scale-set and gets an id),
        # so `config.toml` alone cannot converge them — the reconcile drives
        # `garm-cli` idempotently to create-missing / update-drifted, and
        # (GUARDED) prune-undeclared. See `reconcile.enable`.
        reconcile = {
          enable = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Enable the `garm-reconcile` systemd oneshot: after `garm.service`
              is up, idempotently sync GARM's DB (forge endpoint + credentials +
              orgs + scale sets) to the declared `services.garm.github` +
              `services.garm.scaleSets`. A second run with unchanged config is a
              no-op. Unrelated runtime state (runners, other controllers) is
              never touched. Default false — declaring the shape does NOT enable
              the reconcile, so enabling it on a host with a live DB is a
              deliberate step. Prove it hermetically (the `t_garm_reconcile` VM
              test) before enabling against a live GARM DB.
            '';
          };

          pruneUnmanaged = mkOption {
            type = types.bool;
            default = false;
            description = ''
              CONSERVATIVE, OPT-IN pruning. When true, the reconcile DELETES
              scale sets it manages (those whose org is one of the declared
              `scaleSets.*.org` values) that are no longer declared, and
              likewise undeclared orgs/credentials it recognises as managed.
              Default false so the reconcile can NEVER accidentally delete the
              live mcl/blocksense/agent-harbor scale sets: with pruning off, a
              scale set dropped from the Nix config is simply left in the DB
              (logged as "unmanaged, kept"). Only the reconcile-managed set is
              ever eligible for pruning — a scale set in an org GARM knows about
              but that this config never declares an org for is left alone even
              with pruning on.
            '';
          };

          adminUsername = mkOption {
            type = types.str;
            default = "admin";
            description = ''
              Administrative username the reconcile uses (creating it via
              first-run if the controller is un-initialised, then logging the
              local garm-cli profile in as it). Only meaningful for the
              reconcile's own garm-cli session.
            '';
          };

          adminEmail = mkOption {
            type = types.str;
            default = "garm-reconcile@localhost";
            description = "Email used when the reconcile performs the first-run admin init.";
          };

          adminPasswordFile = mkOption {
            type = types.nullOr types.path;
            default = null;
            description = ''
              Optional path to a file holding the admin password the reconcile
              uses for first-run + garm-cli login (staged via LoadCredential).
              Null (default) ⇒ a strong password is generated once and persisted
              under stateDir (mode 0600). Changing an already-initialised
              controller's admin password is NOT attempted.
            '';
          };

          webhookSecretFile = mkOption {
            type = types.nullOr types.path;
            default = null;
            description = ''
              Optional path to a file holding the org webhook HMAC secret
              (staged via LoadCredential). When set, the reconcile creates each
              org with THIS secret (`--webhook-secret`) instead of a per-org
              random one, so a rebuilt/fresh controller DB reproduces the exact
              secret GitHub already signs deliveries with — no manual
              `organization update --webhook-secret` afterwards. Null (default)
              ⇒ the legacy `--random-webhook-secret` behaviour.
            '';
          };

          forgeEndpoint = mkOption {
            type = types.str;
            default = "github.com";
            description = ''
              The GARM forge endpoint name the reconcile associates credentials
              + orgs with. Defaults to GARM's built-in `github.com`. Set to a
              custom name (with `apiBaseURL`/`baseURL`) to point GARM at a
              non-github.com GitHub (GitHub Enterprise) — or, in the hermetic
              test, at an in-VM mock GitHub API.
            '';
          };

          apiBaseURL = mkOption {
            type = types.str;
            default = "";
            example = "http://127.0.0.1:8081";
            description = ''
              When `forgeEndpoint` is NOT `github.com`, the API base URL of that
              endpoint (created/updated via `garm-cli github endpoint`). Empty
              for the built-in github.com endpoint (GARM already knows it).
            '';
          };

          baseURL = mkOption {
            type = types.str;
            default = "";
            example = "http://127.0.0.1:8081";
            description = ''
              When `forgeEndpoint` is NOT `github.com`, the (web) base URL of the
              custom endpoint. Empty for the built-in github.com endpoint.
            '';
          };

          uploadURL = mkOption {
            type = types.str;
            default = "";
            description = ''
              Optional upload URL for a custom `forgeEndpoint`. Empty ⇒ reuse
              `apiBaseURL`.
            '';
          };
        };

        openIncusBridgeFirewall = mkOption {
          type = types.bool;
          default = false;
          description = ''
            When an incus-backend provider is used, trust its incus bridge
            (`providers.<name>.incusBridge`) for the GARM API/metadata/callback
            port, so per-job CONTAINERS can reach the host GARM endpoint. Wires
            `networking.firewall.interfaces.<bridge>.allowedTCPPorts =
            [ apiServer.port ]` for every enabled incus provider's bridge.

            This ONLY opens the container->host GARM path, and ONLY on the bridge
            interface (never the public firewall). Container->internet EGRESS
            needs NO host change: incus's own `inet incus` nftables table already
            NATs + forwards the bridge.
          '';
        };

        # The guest-facing controller URLs. GARM hands these to the runner
        # instance; the guest fetches its JIT config from metadataURL and reports
        # status to callbackURL. They MUST be reachable from the guest — the host
        # bridge IP on the provider network, never localhost.
        metadataURL = mkOption {
          type = types.str;
          default = "";
          example = "http://192.168.122.1:9997/api/v1/metadata";
          description = ''
            `[default].metadata_url` — the base URL the runner fetches its
            JIT/instance metadata from. Must be guest-reachable.
          '';
        };
        callbackURL = mkOption {
          type = types.str;
          default = "";
          example = "http://192.168.122.1:9997/api/v1/callbacks";
          description = ''
            `[default].callback_url` — the base URL the runner posts status
            reports back to. Must be guest-reachable.
          '';
        };

        # Run GARM as a dedicated system user (default) instead of a DynamicUser
        # whenever a provider is enabled. The libvirt provider needs the `garm`
        # user to be in the libvirtd/kvm groups; the incus provider needs
        # incus-admin — a DynamicUser (fresh uid each boot) cannot be a stable
        # group member.
        user = mkOption {
          type = types.str;
          default = "garm";
          description = "System user the garm daemon runs as (created by the module).";
        };
        group = mkOption {
          type = types.str;
          default = "garm";
          description = "Primary group for the garm daemon user (created by the module).";
        };

        # Extra supplementary groups for the service user. The module adds the
        # provider-required groups automatically (libvirtd/kvm for any libvirt
        # provider, incus-admin for any incus provider); this lets a host add
        # more (e.g. a storage group for a shared pool dir).
        extraGroups = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Additional supplementary groups for the garm service user.";
        };

        # EXP-MP — the GitHub App forge credentials, wired DECLARATIVELY, as an
        # attrset of named credentials (each a `[[github]]` block). OPT-IN
        # (default {}) so M0/M5 boots are unaffected. Each App PEM is supplied
        # via LoadCredential (agenix at runtime) and NEVER enters the store.
        # Orgs + scale sets remain runtime/DB state (provisioned via garm-cli),
        # since they carry GitHub-side state — only the credentials are
        # declarative here.
        github = mkOption {
          default = { };
          description = ''
            GitHub App forge credentials, keyed by credential name. Each entry is
            emitted as a `[[github]]` block (imported into GARM's DB on first
            boot) and its App PEM staged via LoadCredential. Multiple entries
            support multiple orgs. Empty (default) keeps the forge-less M0 boot.
          '';
          type = types.attrsOf (types.submodule githubModule);
        };

        # EXP-MP — declared HOST RESOURCE BUDGET for the eval-time autoscale
        # guard. A bad config fails to EVAL, long before anything boots.
        hostBudget = {
          memoryMb = mkOption {
            type = types.ints.positive;
            default = 65536;
            description = ''
              Total guest RAM (MiB) the host is willing to commit to ephemeral
              runner VMs. The assertion requires the sum over all scale sets of
              `maxRunners * <its provider>.memoryMb <= hostBudget.memoryMb`.
            '';
          };
          vcpus = mkOption {
            type = types.ints.positive;
            default = 32;
            description = ''
              Total guest vCPUs the host is willing to commit. The assertion
              requires the sum over all scale sets of
              `maxRunners * <its provider>.vcpus <= hostBudget.vcpus`.
            '';
          };
        };

        # Internal: credential names used by LoadCredential. Not user-facing.
        jwtSecretCredentialName = mkOption {
          type = types.str;
          default = "jwt-secret";
          internal = true;
          visible = false;
          description = "LoadCredential name for the JWT secret file.";
        };
        dbPassphraseCredentialName = mkOption {
          type = types.str;
          default = "db-passphrase";
          internal = true;
          visible = false;
          description = "LoadCredential name for the DB passphrase file.";
        };

        # EXP-MP — the vm-harness external providers, an attrset of named
        # instances (each a `[[provider]]` block). OPT-IN (default {}) so M0's
        # forge-less/provider-less boot is unaffected. Multiple entries let a
        # single GARM drive Windows (libvirt) + Linux (incus) — and, on m3, macOS
        # (tart) — from one control plane.
        providers = mkOption {
          default = { };
          description = ''
            Named vm-harness external provider instances, keyed by provider name
            (the `[[provider]].name` referenced by scale sets). Each has its own
            backend (libvirt|incus), image map, network, and per-VM sizing, and
            is rendered as a distinct GARM `[[provider]]` block. The systemd
            sandbox posture is the UNION across the enabled instances.
          '';
          type = types.attrsOf (types.submodule providerModule);
        };

        # M5 autoscale tuning for scale sets. Scale sets are NOT part of garm's
        # `config.toml`: GitHub owns the scheduling and each scale set carries
        # GitHub-side state, so they are provisioned at runtime via `garm-cli
        # scaleset add/update`. This option captures the DECLARATIVE tuning shape
        # + ties each scale set to a named provider + org credential.
        scaleSets = mkOption {
          default = { };
          description = ''
            Declarative autoscale tuning for GARM scale sets, keyed by scale-set
            name (the workflow `runs-on:` selector). Records the intended
            concurrency policy (concurrency cap, warm-pool size, bootstrap
            timeout, labels), the backing `provider`, and the `org`/`credentials`
            the scale set is created against. Applied at runtime via `garm-cli
            scaleset` since scale sets carry GitHub-side state.
          '';
          type = types.attrsOf (
            types.submodule (
              { name, ... }:
              {
                options = {
                  provider = mkOption {
                    type = types.str;
                    default = "vmharness";
                    description = "The named `services.garm.providers.<provider>` that backs this scale set.";
                  };
                  org = mkOption {
                    type = types.str;
                    default = "";
                    example = "my-org";
                    description = ''
                      The GitHub organization the scale set belongs to (the
                      `garm-cli organization add --name <org>` target). Recorded
                      for the runtime/reconcile `garm-cli scaleset add --org`.
                    '';
                  };
                  credentials = mkOption {
                    type = types.str;
                    default = "";
                    example = "my-app";
                    description = ''
                      The `services.garm.github.<name>.credentialsName` the
                      scale set's org authenticates with. Ties the scale set to
                      one App credential.
                    '';
                  };
                  image = mkOption {
                    type = types.str;
                    default = "golden";
                    description = ''
                      Image identifier resolved against the backing provider's
                      `images` map to pick the golden the per-job instances clone
                      from.
                    '';
                  };
                  osType = mkOption {
                    type = types.enum [
                      "windows"
                      "linux"
                      "macos"
                    ];
                    default = "windows";
                    description = "Runner OS type reported to GARM/GitHub.";
                  };
                  osArch = mkOption {
                    type = types.str;
                    default = "amd64";
                    description = "Runner OS architecture.";
                  };
                  maxRunners = mkOption {
                    type = types.ints.positive;
                    default = 2;
                    description = ''
                      Concurrency CAP: the maximum number of ephemeral instances
                      GARM runs concurrently for this scale set. The primary host
                      resource guard — keep `maxRunners * <provider>.memoryMb`
                      within host RAM headroom.
                    '';
                  };
                  minIdleRunners = mkOption {
                    type = types.ints.unsigned;
                    default = 0;
                    description = ''
                      Warm-pool size: pre-booted idle runners kept ready and
                      refilled after consumption. 0 (default) == scale-to-zero.
                      Must be <= maxRunners.
                    '';
                  };
                  runnerBootstrapTimeout = mkOption {
                    type = types.ints.positive;
                    default = 20;
                    description = ''
                      Minutes before a runner that has not joined GitHub is
                      considered failed and replaced (`--runner-bootstrap-timeout`).
                    '';
                  };
                  labels = mkOption {
                    type = types.listOf types.str;
                    default = [ ];
                    description = ''
                      Optional extra runner labels (immutable after creation).
                      The scale-set NAME is the primary `runs-on` selector.
                    '';
                  };
                  enabled = mkOption {
                    type = types.bool;
                    default = true;
                    description = "Whether the scale set is enabled.";
                  };
                  scaleSetName = mkOption {
                    type = types.str;
                    default = name;
                    defaultText = lib.literalMD "the attribute name";
                    description = "The scale-set name (defaults to the attribute name).";
                  };
                  runnerGroup = mkOption {
                    type = types.str;
                    default = "";
                    example = "gpu-hosts";
                    description = ''
                      The GitHub **runner group** this scale set's runners are
                      created in (`garm-cli scaleset add --runner-group`). Empty
                      (the default) leaves it unset, so GARM/GitHub place the
                      scale set in the `Default` group — the historical
                      behaviour, byte-unchanged for every existing caller.

                      Runner groups are an ACCESS-CONTROL primitive: they scope
                      which repositories may use a set of runners. They are not
                      a job-targeting mechanism, and workflows do not normally
                      name them — `runs-on:` still takes the scale-set name.

                      The reason to set one here is a NAMING constraint. A
                      runner scale-set name must be unique *within its runner
                      group*, not within the org: GitHub's docs state that to
                      deploy several scale sets sharing a name, "they must
                      belong to different runner groups". With everything
                      defaulting to `Default`, a second GARM instance declaring
                      an existing name fails its reconcile with a hard
                      `400 RunnerScaleSetExistsException` — which is why one
                      `runs-on:` class has so far been pinned to exactly one
                      host. Giving each host's scale set its own group is what
                      makes a shared class name across hosts expressible at all.

                      UNVERIFIED, and the reason this option alone is not a
                      solution: how `runs-on: <name>` RESOLVES when a repository
                      can see two identically-named scale sets in two groups is
                      not documented. It may load-balance across them (the
                      desirable outcome), bind deterministically to one, or be
                      rejected. Prove it on a scratch repository before relying
                      on it for capacity.

                      Only passed at scale-set CREATION. GARM also accepts it on
                      `scaleset update`, but whether GitHub permits moving an
                      existing scale set between groups is untested here, so
                      changing this on a live scale set is not reconciled —
                      delete and recreate it instead.
                    '';
                  };
                };
              }
            )
          );
        };

        # RE3/RE4: AWS BURST pools. Unlike scale sets (single-name, GitHub-owned
        # scheduling), burst uses GARM POOLS in `pack`+`--priority` mode so the
        # cloud tier fills ONLY after the higher-priority on-prem pools are
        # saturated (spill). Each pool keeps an always-warm FLOOR
        # (`min-idle-runners`), a hard ceiling (`max-runners`), one-job
        # `--ephemeral` auto-terminate, and an anti-overprovision backoff. RE4
        # adds an optional spot policy whose fields are rendered into the pool's
        # `extra_specs` and consumed by the garm-provider-aws spot patch.
        #
        # Like scale sets, pools carry GitHub-side state and are applied at
        # runtime via `garm-cli pool` (the RC2 pool-reconcile wiring); this
        # option captures the DECLARATIVE desired state, emitted into the
        # reconcile manifest as `burstPools`. COMPANY-AGNOSTIC: no account,
        # region, or AMI is baked in — those come from the `aws` provider block
        # and per-pool `image`/`flavor`, all set by infra.
        burstPools = mkOption {
          default = { };
          description = ''
            Declarative AWS burst pools keyed by pool name. Each binds an
            `aws`-backed `provider` + a label set + a warm floor
            (`minIdleRunners`) + a ceiling (`maxRunners`) + a spill `priority` +
            an optional `spot` policy. Applied at runtime via `garm-cli pool`
            since pools carry GitHub-side state.
          '';
          type = types.attrsOf (
            types.submodule (
              { name, ... }:
              {
                options = {
                  provider = mkOption {
                    type = types.str;
                    default = "aws";
                    description = "The named `services.garm.providers.<provider>` (backend = \"aws\") that backs this burst pool.";
                  };
                  poolName = mkOption {
                    type = types.str;
                    default = name;
                    defaultText = lib.literalMD "the attribute name";
                    description = "The GARM pool name (defaults to the attribute name).";
                  };
                  org = mkOption {
                    type = types.str;
                    default = "";
                    example = "my-org";
                    description = "The GitHub organization the pool belongs to (the `garm-cli pool add --org` target).";
                  };
                  credentials = mkOption {
                    type = types.str;
                    default = "";
                    example = "my-app";
                    description = "The `services.garm.github.<name>.credentialsName` the pool's org authenticates with.";
                  };
                  image = mkOption {
                    type = types.str;
                    default = "";
                    example = "ami-0123456789abcdef0";
                    description = ''
                      The runner AMI id passed as the pool `--image`. A HELD infra
                      concern — the operator bakes/points at a runner AMI in their
                      account. Required for a live pool.
                    '';
                  };
                  flavor = mkOption {
                    type = types.str;
                    default = "";
                    example = "m6i.large";
                    description = "The EC2 instance type passed as the pool `--flavor`.";
                  };
                  osType = mkOption {
                    type = types.enum [
                      "linux"
                      "windows"
                    ];
                    default = "linux";
                    description = "Runner OS type reported to GARM/GitHub.";
                  };
                  osArch = mkOption {
                    type = types.str;
                    default = "amd64";
                    description = "Runner OS architecture.";
                  };
                  labels = mkOption {
                    type = types.listOf types.str;
                    default = [ ];
                    example = [
                      "self-hosted"
                      "linux"
                      "x64"
                      "aws"
                      "x86-64-v3"
                    ];
                    description = ''
                      The capability label set runners in this pool advertise
                      (`--tags`). A `runs-on` whose labels are a subset matches.
                      Include an `aws` label so cloud-burst jobs can be targeted
                      or observed distinctly.
                    '';
                  };
                  maxRunners = mkOption {
                    type = types.ints.positive;
                    default = 4;
                    description = ''
                      Hard ceiling on concurrent EC2 runners in this pool
                      (`--max-runners`). The primary AWS spend bound; pair with an
                      AWS budget alarm as a backstop.
                    '';
                  };
                  minIdleRunners = mkOption {
                    type = types.ints.unsigned;
                    default = 1;
                    description = ''
                      The always-warm FLOOR (`--min-idle-runners`): idle runners
                      GARM keeps pre-booted and refills after consumption. This is
                      the part you pay for 24/7 — keep it small (1-2). See
                      `floorPolicy`: when set to `lazy` the EFFECTIVE floor is 0
                      regardless of this value. Must be <= maxRunners.
                    '';
                  };
                  floorPolicy = mkOption {
                    type = types.enum [
                      "floor"
                      "lazy"
                    ];
                    default = "floor";
                    description = ''
                      The floor-vs-pure-lazy policy knob. `floor` (default) keeps
                      `minIdleRunners` warm at all times (fast first job, small
                      standing cost). `lazy` forces the effective min-idle to 0 —
                      pure scale-to-zero, pay-per-job, cold start on the first
                      queued job. This is the single knob that flips the pool
                      between "keep N warm always" and "cost nothing when idle".
                    '';
                  };
                  priority = mkOption {
                    type = types.ints.unsigned;
                    default = 10;
                    description = ''
                      Pool priority for the controller's `pack` balancer
                      (`--priority`). GARM sorts matching pools in DESCENDING
                      priority order, so HIGHER numbers are tried FIRST — give the
                      on-prem pools a HIGHER priority than this cloud pool and AWS
                      becomes the SPILL tier, provisioned only once the local
                      fleet is saturated. Smaller == later == cloud-last, which is
                      why the default (10) sits below the RB3 `basePriority`
                      default (100).

                      (This description used to say the opposite — "LOWER numbers
                      fill first". The VALUES were right and the prose was
                      inverted, so following it would have made the cloud tier
                      fill BEFORE the free on-prem fleet. GARM's own source is
                      unambiguous: `params/params.go` — "the higher the number,
                      the higher the priority … sorted in descending order of
                      priority" — backed by `Order("priority desc")` in
                      `database/sql/pools.go` and `sort.Slice(… Priority > …)` in
                      `runner/pool/cache.go`.)

                      Priority orders POOLS, never JOBS, and only takes full
                      effect under the `pack` balancer — which GARM sets per ORG
                      (`garm-cli organization update --pool-balancer-type pack`),
                      defaults to `roundrobin`, and this module does NOT configure.
                      See modules/garm/README.md, "What `priority` is".
                    '';
                  };
                  jobAgeBackoff = mkOption {
                    type = types.ints.unsigned;
                    default = 30;
                    description = ''
                      Seconds GARM waits after a `workflow_job` queued event
                      before creating a NEW runner (`--minimum-job-age-backoff`),
                      giving an existing idle runner a chance to grab the job
                      first — the anti-overprovision guard that keeps a burst from
                      launching more EC2 than the queue truly needs.
                    '';
                  };
                  runnerBootstrapTimeout = mkOption {
                    type = types.ints.positive;
                    default = 20;
                    description = "Minutes before a runner that has not joined GitHub is considered failed and replaced (`--runner-bootstrap-timeout`). Raise for slow AMIs.";
                  };
                  ephemeral = mkOption {
                    type = types.bool;
                    default = true;
                    description = ''
                      One-job `--ephemeral` runners: each EC2 instance runs
                      exactly one job then GARM terminates it, so there is no idle
                      burn beyond the floor. Default true — the whole cost model
                      depends on it; leave it on.
                    '';
                  };
                  enabled = mkOption {
                    type = types.bool;
                    default = true;
                    description = "Whether the burst pool is enabled.";
                  };
                  spot = mkOption {
                    default = { };
                    description = ''
                      RE4 spot policy. When `enable` is true the pool's
                      `extra_specs` request EC2 spot (InstanceMarketOptions),
                      cutting burst cost; the garm-provider-aws spot patch
                      consumes them. Leave disabled for on-demand burst.
                    '';
                    type = types.submodule {
                      options = {
                        enable = mkOption {
                          type = types.bool;
                          default = false;
                          description = "Launch this pool's burst runners as EC2 spot instances.";
                        };
                        maxPrice = mkOption {
                          type = types.str;
                          default = "";
                          example = "0.05";
                          description = ''
                            Maximum hourly USD price for a spot runner
                            (`spot_max_price`). Empty (recommended) caps at the
                            on-demand price. Only consulted when `enable`.
                          '';
                        };
                        instanceType = mkOption {
                          type = types.enum [
                            "one-time"
                            "persistent"
                          ];
                          default = "one-time";
                          description = ''
                            Spot request type (`spot_instance_type`). `one-time`
                            (default) suits ephemeral one-job runners; the pool
                            re-requests fresh anyway, so `persistent` is rarely
                            needed. Only consulted when `enable`.
                          '';
                        };
                        interruptionBehavior = mkOption {
                          type = types.enum [
                            "terminate"
                            "stop"
                            "hibernate"
                          ];
                          default = "terminate";
                          description = ''
                            What EC2 does to an interrupted spot runner
                            (`spot_instance_interruption_behavior`). `terminate`
                            (default) is correct for ephemeral runners — the
                            interrupted instance is torn down, GitHub re-queues the
                            job, and GARM's reconcile drops the vanished runner and
                            spills/refills. Only consulted when `enable`.
                          '';
                        };
                        onDemandFallback = mkOption {
                          type = types.bool;
                          default = true;
                          description = ''
                            When a spot request fails with a capacity/price error,
                            retry the SAME launch on-demand (`on_demand_fallback`)
                            rather than starving the queue — the burst still lands,
                            at on-demand cost. Default true. Only consulted when
                            `enable`.
                          '';
                        };
                      };
                    };
                  };
                };
              }
            )
          );
        };

        # RC2: on-prem capability POOLS. A pool = provider + capability label set
        # + min-idle + max + priority (the campaign's pool definition). Unlike a
        # scale set — which names ONE class and is pinned to ONE host — a pool
        # registers CLASSIC runners advertising an RC1 CAPABILITY LABEL SET, so
        # `runs-on: [self-hosted, linux, x64, x86-64-v3]` matches ANY runner that
        # proves all those labels. The tag set is DERIVED at reconcile time from
        # the backing provider's RA6-verified `manifestFile` (JIT label
        # derivation — RC1 mechanism over RA6 manifest), not hand-maintained;
        # `policyLabels` adds the attested labels the manifest cannot prove
        # (`ephemeral`, `org:<name>`, `dev-env-ready`). If the provider has no
        # manifestFile, the explicit `labels` set is used verbatim (escape hatch).
        #
        # Pools carry GitHub-side state, so they are applied at RUNTIME via
        # `garm-cli pool` by the reconcile (idempotent, id-tracked — GARM pools
        # have no name, so the reconcile persists a logical-name → pool-id map).
        # Emitted into the reconcile manifest as `pools`. ADDITIVE: declaring
        # pools does not touch `scaleSets`, so both models run in parallel for
        # the RC5 cutover.
        pools = mkOption {
          default = { };
          description = ''
            Declarative on-prem capability pools keyed by pool name. Each binds a
            `provider` + a capability label set (DERIVED from the provider's
            RA6-verified `manifestFile`, or the explicit `labels` when none) + a
            warm floor (`minIdleRunners`) + a ceiling (`maxRunners`) + a match
            `priority`. Applied at runtime via `garm-cli pool` since pools carry
            GitHub-side state. Coexists with `scaleSets` (RC5 retires those).
          '';
          type = types.attrsOf (
            types.submodule (
              { name, ... }:
              {
                options = {
                  provider = mkOption {
                    type = types.str;
                    default = "vmharness";
                    description = "The named `services.garm.providers.<provider>` that backs this pool (typically a `backend = \"remote\"` provider targeting a host's `vm-harness serve`).";
                  };
                  poolName = mkOption {
                    type = types.str;
                    default = name;
                    defaultText = lib.literalMD "the attribute name";
                    description = ''
                      The LOGICAL pool name. GARM pools have no name of their own
                      (they are identified by UUID + matched by tags); the
                      reconcile persists a logical-name → pool-id map under
                      stateDir so this pool is reconciled idempotently and pruned
                      when removed. Defaults to the attribute name.
                    '';
                  };
                  org = mkOption {
                    type = types.str;
                    default = "";
                    example = "my-org";
                    description = "The GitHub organization the pool belongs to (the `garm-cli pool add --org` target).";
                  };
                  credentials = mkOption {
                    type = types.str;
                    default = "";
                    example = "my-app";
                    description = "The `services.garm.github.<name>.credentialsName` the pool's org authenticates with.";
                  };
                  image = mkOption {
                    type = types.str;
                    default = "golden";
                    description = "Image identifier resolved against the backing provider's `images` map (`--image`).";
                  };
                  flavor = mkOption {
                    type = types.str;
                    default = "default";
                    description = "Provider flavor passed as `--flavor` (the vm-harness backends ignore it; kept for parity with the GARM CLI).";
                  };
                  osType = mkOption {
                    type = types.enum [
                      "windows"
                      "linux"
                      "macos"
                    ];
                    default = "linux";
                    description = "Runner OS type reported to GARM/GitHub.";
                  };
                  osArch = mkOption {
                    type = types.str;
                    default = "amd64";
                    description = "Runner OS architecture.";
                  };
                  labels = mkOption {
                    type = types.listOf types.str;
                    default = [ ];
                    example = [
                      "self-hosted"
                      "linux"
                      "x64"
                      "x86-64-v3"
                    ];
                    description = ''
                      The capability label set. When the backing provider has a
                      `manifestFile`, the reconcile DERIVES the tag set from it
                      (`runner-label-tool derive`) and this list, if non-empty, is
                      LINTED against the derived set (`advertised ⊆ derived`,
                      fail-closed) — so a pool can never advertise a capability
                      the host has not proven. When the provider has NO
                      manifestFile, this list IS the tag set, verbatim.
                    '';
                  };
                  policyLabels = mkOption {
                    type = types.listOf types.str;
                    default = [ ];
                    example = [
                      "ephemeral"
                      "org:metacraft-labs"
                    ];
                    description = ''
                      Attested / policy labels APPENDED to the derived hardware
                      labels. The RA6 manifest cannot prove these (they are
                      policy, not hardware): `ephemeral`, `org:<name>`,
                      `dev-env-ready`, etc. Outside the manifest-governed
                      vocabulary, so they are never linted away.
                    '';
                  };
                  aliasClasses = mkOption {
                    type = types.listOf types.str;
                    default = [ ];
                    example = [ "eph-linux-x64" ];
                    description = ''
                      RC5 CUTOVER ALIASES — legacy single-name scale-set class
                      names this pool ALSO advertises so a consumer still naming
                      `runs-on: eph-linux-x64` keeps routing to the pool until it
                      migrates to a capability label set. Each alias is appended
                      verbatim to the pool's tags (a classic runner in the pool
                      registers with both its derived capability labels AND these
                      legacy names), so GitHub's subset match serves a legacy-named
                      job from the aliased pool.

                      This is NOT a hardware capability, so — like `policyLabels` —
                      an alias is NEVER linted against the manifest (it is a name,
                      not a claim). It is the transitional bridge that lets the
                      scale-set→pool migration proceed class-by-class instead of as
                      a flag day: keep the alias while any consumer still names the
                      old class, then DROP it (empty this list) as the FINAL RC5
                      step. Once dropped, a job still naming the retired class
                      matches no pool and stays queued — the intended, visible end
                      of the alias.
                    '';
                  };
                  maxRunners = mkOption {
                    type = types.ints.positive;
                    default = 2;
                    description = "Concurrency CAP — the maximum concurrent runners in this pool (`--max-runners`). Keep `maxRunners * <provider>.memoryMb` within the backing host's RAM headroom.";
                  };
                  minIdleRunners = mkOption {
                    type = types.ints.unsigned;
                    default = 0;
                    description = "Warm-pool size (`--min-idle-runners`): pre-booted idle runners kept ready. 0 (default) == scale-to-zero. Must be <= maxRunners.";
                  };
                  priority = mkOption {
                    type = types.ints.unsigned;
                    default = 0;
                    description = ''
                      GARM pool match priority (`--priority`). When multiple pools
                      match the same labels, GARM tries them in DESCENDING
                      priority order (higher = tried first). The RB3
                      `capabilityPools` balancer sets this automatically across
                      equivalent hosts; for a hand-declared pool leave it 0 unless
                      you want a specific host preferred.

                      It orders POOLS, not JOBS — it decides where a new runner is
                      CREATED, never which queued job is served first, and it
                      cannot reserve capacity. If you are reaching for it to keep
                      a latency-critical job off the back of the queue, you want
                      `runnerGroup` instead. See modules/garm/README.md, "What
                      `priority` is — and, more importantly, what it is not".
                    '';
                  };
                  runnerBootstrapTimeout = mkOption {
                    type = types.ints.positive;
                    default = 20;
                    description = "Minutes before a runner that has not joined GitHub is considered failed and replaced (`--runner-bootstrap-timeout`).";
                  };
                  runnerGroup = mkOption {
                    type = types.str;
                    default = "";
                    description = ''
                      Optional GitHub runner group (`--runner-group`); empty
                      leaves the pool's runners in `Default`.

                      THIS IS THE ONLY WAY TO RESERVE CAPACITY. A runner group
                      with `restricted_to_workflows` refuses its runners to any
                      job whose workflow is not on the group's admission list,
                      whatever that job asks for in `runs-on` — the one admission
                      control in the system that is not label-based. Labels cannot
                      do it: `runs-on` matches by SUBSET, so a pool on the same
                      hardware advertises a superset of what ordinary jobs request
                      and is eligible for them, and it cannot advertise less
                      because GitHub attaches `self-hosted`, the OS and the arch
                      to every self-hosted runner itself. `priority` cannot do it
                      either — it orders pools, not jobs.

                      Pair it with `minIdleRunners >= 1`. Admission control alone
                      reserves nothing under saturation: with no idle runner the
                      admitted job queues for a slot like everyone else. The WARM
                      runner is the reservation; the group is what stops anything
                      else draining it.

                      The group must already exist in the org — GARM does not
                      create it, and `garm-cli pool add --runner-group` fails if
                      it does not. Its admission list is GitHub-side state
                      (`selected_workflows`), governed separately; the
                      `terraform/github/governance.nix` engine renders it.
                    '';
                  };
                  enabled = mkOption {
                    type = types.bool;
                    default = true;
                    description = "Whether the pool is enabled.";
                  };
                };
              }
            )
          );
        };

        # RB3: fleet-aware placement + capability→host mapping. A capabilityPool
        # is a LOGICAL, host-agnostic pool declaration: "provision runners with
        # capability X on EVERY host that PROVES X, balanced by policy Y". The
        # reconcile EXPANDS it into one concrete GARM pool per QUALIFYING provider
        # — a candidate provider qualifies iff its RA6-verified `manifestFile`
        # derives a label set ⊇ `requires`. This is the structural fix for the
        # "GPU servers 95% idle vs hms saturated" imbalance: a generic Linux
        # capabilityPool expands across ALL qualifying Linux hosts, so a job is no
        # longer pinned to one host — GitHub/GARM place it on whichever qualifying
        # host is free, per the `balance` policy.
        capabilityPools = mkOption {
          default = { };
          description = ''
            Declarative CAPABILITY pools keyed by name. Each names the capability
            labels a host must PROVE (`requires`), the candidate `providers` to
            consider, and a `balance` policy (`pack`/`spread`). The reconcile
            expands it into one concrete GARM pool per qualifying provider (host),
            each advertising THAT host's derived label set, with `priority`
            assigned by the balancer. Placement is driven entirely by the RA6
            capability manifests.
          '';
          type = types.attrsOf (
            types.submodule (
              { name, ... }:
              {
                options = {
                  requires = mkOption {
                    type = types.listOf types.str;
                    default = [ ];
                    example = [
                      "linux"
                      "x64"
                      "gpu"
                    ];
                    description = ''
                      The capability labels a candidate host must PROVE (its
                      derived manifest labels must be a superset) to back this
                      pool. E.g. `[ "gpu" ]` restricts placement to GPU hosts;
                      `[ "x86-64-v3" ]` to v3-capable hosts; `[ ]` matches every
                      candidate (a generic pool).
                    '';
                  };
                  providers = mkOption {
                    type = types.listOf types.str;
                    default = [ ];
                    description = ''
                      Candidate `services.garm.providers.<name>` to consider for
                      placement. Empty (default) ⇒ every enabled provider that has
                      a `manifestFile` is a candidate. A candidate that does not
                      PROVE `requires` is skipped (no pool created for it).
                    '';
                  };
                  balance = mkOption {
                    type = types.enum [
                      "spread"
                      "pack"
                    ];
                    default = "spread";
                    description = ''
                      Balancing policy across the qualifying hosts:

                      - `spread` (default): every qualifying host's pool gets the
                        SAME `basePriority`, so GARM/GitHub distribute jobs across
                        equivalent hosts rather than hammering one. This is what
                        keeps the idle GPU/second-Linux hosts in rotation.
                      - `pack`: qualifying hosts get DESCENDING priorities in a
                        stable order, so one host fills to capacity before the
                        next is touched (bin-packing — useful to keep as many
                        hosts idle/powered-down as possible).
                    '';
                  };
                  basePriority = mkOption {
                    type = types.ints.unsigned;
                    default = 100;
                    description = ''
                      The priority assigned to qualifying pools under `spread`, or
                      the HIGHEST priority (first host) under `pack` (subsequent
                      hosts step down by one). Give a more-specific capabilityPool
                      (e.g. gpu) a HIGHER basePriority than a generic one so a
                      specialised job prefers a specialised host.
                    '';
                  };
                  org = mkOption {
                    type = types.str;
                    default = "";
                    description = "The GitHub organization the expanded pools belong to.";
                  };
                  credentials = mkOption {
                    type = types.str;
                    default = "";
                    description = "The `services.garm.github.<name>.credentialsName` the expanded pools authenticate with.";
                  };
                  aliasClasses = mkOption {
                    type = types.listOf types.str;
                    default = [ ];
                    example = [ "eph-linux-x64" ];
                    description = ''
                      RC5 transitional legacy class names appended VERBATIM as tags
                      to every pool this capabilityPool expands into (same semantics
                      as `pools.<name>.aliasClasses`). A job still written
                      `runs-on: <legacy-class>` then matches an expanded pool by
                      GitHub's subset rule while it migrates to a capability label
                      set. NEVER linted against the manifest (it is a name, not a
                      proven capability). Keep while any consumer still names the
                      legacy class; empty it to end the bridge.
                    '';
                  };
                  image = mkOption {
                    type = types.str;
                    default = "golden";
                    description = "Image identifier for the expanded pools (`--image`).";
                  };
                  flavor = mkOption {
                    type = types.str;
                    default = "default";
                    description = "Provider flavor for the expanded pools (`--flavor`).";
                  };
                  osType = mkOption {
                    type = types.enum [
                      "windows"
                      "linux"
                      "macos"
                    ];
                    default = "linux";
                    description = "Runner OS type for the expanded pools.";
                  };
                  osArch = mkOption {
                    type = types.str;
                    default = "amd64";
                    description = "Runner OS architecture for the expanded pools.";
                  };
                  policyLabels = mkOption {
                    type = types.listOf types.str;
                    default = [ ];
                    description = "Attested/policy labels appended to each expanded pool's derived labels (see `pools.<name>.policyLabels`).";
                  };
                  maxRunners = mkOption {
                    type = types.ints.positive;
                    default = 2;
                    description = "Per-host concurrency cap for each expanded pool (`--max-runners`).";
                  };
                  minIdleRunners = mkOption {
                    type = types.ints.unsigned;
                    default = 0;
                    description = "Per-host warm floor for each expanded pool (`--min-idle-runners`). Must be <= maxRunners.";
                  };
                  runnerBootstrapTimeout = mkOption {
                    type = types.ints.positive;
                    default = 20;
                    description = "Runner bootstrap timeout (minutes) for each expanded pool.";
                  };
                  runnerGroup = mkOption {
                    type = types.str;
                    default = "";
                    description = "Optional GitHub runner group for the expanded pools.";
                  };
                  enabled = mkOption {
                    type = types.bool;
                    default = true;
                    description = "Whether the expanded pools are enabled.";
                  };
                };
              }
            )
          );
        };
      };

      config = mkIf cfg.enable (
        let
          # THE EXP-MP CENTERPIECE — the UNION sandbox posture across the enabled
          # providers.
          #
          # M0's forge-less boot ran GARM under a DynamicUser with a MAXIMAL
          # sandbox (ProtectSystem=strict, PrivateDevices, DeviceAllow=[] via an
          # empty CapabilityBoundingSet, a restricted syscall filter). That is
          # perfect for a pure-Go API daemon but FATAL for the libvirt provider,
          # which needs the qemu:///system libvirt socket, a real PATH to
          # genisoimage, write access to the VM pool dir, /dev/kvm, and a
          # NON-ephemeral uid in the libvirtd/kvm groups. The incus provider is
          # gentler: it only needs incus-admin socket-group access.
          #
          # So the posture is the UNION across the enabled providers:
          #   * NO provider (M0/boot-gate): unchanged — DynamicUser + full
          #     sandbox, BYTE-FOR-BYTE. The M0 boot gate keeps passing.
          #   * ANY libvirt provider ON: a dedicated `garm` system user in
          #     libvirtd+kvm (+ incus-admin if any incus provider is also on),
          #     with the qemu relaxations (ProtectSystem=full, DeviceAllow=
          #     /dev/kvm, ReadWritePaths for the pool dirs, no PrivateDevices/
          #     MDWE/syscall-filter). Everything else stays on.
          #   * INCUS provider(s) ONLY: a dedicated `garm` system user in
          #     `incus-admin` ONLY. Keeps the STRICT M0 knobs (PrivateDevices,
          #     MemoryDenyWriteExecute, ProtectSystem=strict, the @system-service
          #     syscall filter) and relaxes ONLY the user/group.
          providerList = lib.attrValues enabledProviders;
          providerOn = enabledProviders != { };
          anyIncus = lib.any (p: providerIsIncus p) providerList;
          anyLibvirt = lib.any (p: providerIsLibvirt p) providerList;
          anyQemuWindowsArm = lib.any (p: providerIsQemuWindowsArm p) providerList;
          # The libvirt (Windows VM) posture forces the qemu relaxations; the
          # incus (Linux container) posture does not.
          libvirtProviderOn = anyLibvirt;

          incusProviders = lib.filter (p: providerIsIncus p) providerList;
          libvirtProviders = lib.filter (p: providerIsLibvirt p) providerList;
          # Distinct pool dirs across the enabled libvirt providers.
          libvirtPoolDirs = lib.unique (map (p: p.poolDir) libvirtProviders);

          # The UNION of supplementary groups across the enabled providers.
          supplementaryGroups =
            lib.optionals anyLibvirt [
              "libvirtd"
              "kvm"
            ]
            ++ lib.optional anyIncus "incus-admin"
            ++ cfg.extraGroups;

          # LoadCredential list: the two M0 secrets (optional) + one App PEM per
          # enabled GitHub credential. All staged read-only under
          # $CREDENTIALS_DIRECTORY; never in the store.
          loadCredential =
            lib.optional (
              cfg.jwtSecretFile != null
            ) "${cfg.jwtSecretCredentialName}:${toString cfg.jwtSecretFile}"
            ++ lib.optional (
              cfg.dbPassphraseFile != null
            ) "${cfg.dbPassphraseCredentialName}:${toString cfg.dbPassphraseFile}"
            ++ lib.mapAttrsToList (name: g: "${appKeyCredName name}:${toString g.appKeyFile}") (
              lib.filterAttrs (_: g: g.appKeyFile != null) enabledGithub
            )
            # RB2: one serve-token credential per remote provider that sources
            # its bearer token from a file (the central GARM topology).
            ++ lib.mapAttrsToList (
              name: p: "${serveTokenCredName name}:${toString p.remote.authTokenFile}"
            ) enabledRemoteTokenProviders;

          # The bare on-disk SOURCE paths behind `loadCredential` (the `path`
          # halves, without the `id:` prefixes). On the real hosts the App-PEM
          # entries resolve through the agenix symlink farm
          # (`/run/agenix/github-runners/*-app-key`), which agenix (re)materialises
          # from an ACTIVATION SCRIPT — there is no `agenix-install-secrets.service`
          # to order against on these hosts (sysusers/userborn are off; agenix runs
          # `system.activationScripts.agenix*`, not a systemd unit). Credential
          # setup happens in the forked child before any Exec*, so a source that is
          # absent when a start job runs fails the unit with the opaque
          # `status=243/CREDENTIALS`. Asserting the same paths turns that into an
          # explicit, greppable `AssertPathExists=… failed`, one phase earlier, with
          # the same self-heal (`Restart=always` retries). It is a strict superset
          # of `LoadCredential`'s own precondition, so it cannot reject a start that
          # `LoadCredential` would have accepted.
          #
          # IT IS A DIAGNOSTIC, NOT THE FIX, AND THE DISTINCTION IS LOAD-BEARING.
          # This assertion was deployed to high-mem-server and PASSED on all 8 of
          # the observed 243/CREDENTIALS failures — the sources existed every time
          # and the READ still failed. That is what ruled out the "agenix races
          # LoadCredential" hypothesis and pointed at the real cause, which is
          # local to this unit's own shape: see `Type = "exec"` below. Keep the
          # assertion (it is free and it is what makes a genuinely missing secret
          # legible), but do not mistake it for the repair.
          credentialSourcePaths =
            lib.optional (cfg.jwtSecretFile != null) (toString cfg.jwtSecretFile)
            ++ lib.optional (cfg.dbPassphraseFile != null) (toString cfg.dbPassphraseFile)
            ++ lib.mapAttrsToList (_: g: toString g.appKeyFile) (
              lib.filterAttrs (_: g: g.appKeyFile != null) enabledGithub
            )
            # RB2: the serve-token source paths, asserted present (AssertPathExists)
            # so a genuinely missing token is a legible failure one phase earlier.
            ++ lib.mapAttrsToList (_: p: toString p.remote.authTokenFile) enabledRemoteTokenProviders;

          # The dedicated-user base (shared by both provider postures).
          userBaseServiceConfig = {
            User = cfg.user;
            Group = cfg.group;
            SupplementaryGroups = supplementaryGroups;
          };

          # The qemu relaxations (any libvirt provider ON — the Windows VM path).
          libvirtRelaxServiceConfig = userBaseServiceConfig // {
            # RELAXATION 1: ProtectSystem=full (not strict) so the provider can
            # write its pool dir + the libvirt runtime socket; /usr,/boot,/etc
            # stay read-only.
            ProtectSystem = "full";
            # RELAXATION 2: explicit ReadWritePaths for the VM pool dir(s) +
            # libvirt runtime. StateDirectory already grants stateDir rw.
            ReadWritePaths = libvirtPoolDirs ++ [
              "/var/lib/libvirt"
              "/run/libvirt"
            ];
            # RELAXATION 3: NO PrivateDevices — the libvirt path needs device
            # access. Scope it to exactly the devices needed via DeviceAllow.
            DeviceAllow = [
              "/dev/kvm rw"
              "/dev/null rw"
              "/dev/zero rw"
              "/dev/full rw"
              "/dev/random r"
              "/dev/urandom r"
              "/dev/ptmx rw"
            ];
            # RELAXATION 4: NO SystemCallFilter (added below only for the
            # non-libvirt postures) — the provider execs cdrkit's mkisofs which
            # is SIGSYS-killed under @system-service.
            # RELAXATION 5: NO MemoryDenyWriteExecute (qemu JIT) — dropped by
            # simply not setting it here (M0/incus set it below).
          };

          # The incus posture (incus provider(s) ONLY — the Linux container
          # path). Relaxes ONLY the user/group vs M0: a dedicated `garm` user in
          # `incus-admin`. Keeps ProtectSystem=strict, PrivateDevices,
          # MemoryDenyWriteExecute, and the @system-service filter (added below).
          incusStrictServiceConfig = userBaseServiceConfig // {
            ProtectSystem = "strict";
            PrivateDevices = true;
            MemoryDenyWriteExecute = true;
          };

          # The strict M0 posture fragment (provider OFF) — verbatim from M0.
          m0ServiceConfig = {
            DynamicUser = true;
            ProtectSystem = "strict";
            PrivateDevices = true;
            MemoryDenyWriteExecute = true;
          };

          # The reconcile needs a STABLE uid it can share with garm (both read
          # the same stateDir + garm-cli HOME). A DynamicUser gets a fresh uid
          # per boot, so when the reconcile is enabled WITHOUT any provider we
          # keep the strict M0 sandbox but pin garm to the dedicated `garm`
          # system user instead of DynamicUser. (With a provider on, garm ALREADY
          # runs as the dedicated user, so no change.)
          staticStrictServiceConfig = userBaseServiceConfig // {
            ProtectSystem = "strict";
            PrivateDevices = true;
            MemoryDenyWriteExecute = true;
          };

          # A dedicated static `garm` user is required whenever a provider is on
          # OR the reconcile is enabled OR the RE2 DB backup is enabled — the
          # backup oneshot runs as a STABLE user that owns the rotated snapshots
          # and reads garm's StateDirectory, and the restore tool re-owns the
          # restored DB to it; a DynamicUser (the bare forge-less M0 boot) has no
          # stable uid for either. The central GARM always has providers, so this
          # only matters for a provider-less controller that still wants backups.
          needsDedicatedUser = providerOn || rcfg.enable || bcfg.enable;

          # Posture selector: strict M0 DynamicUser (nothing on), the strict
          # static-user posture (reconcile on, no provider), libvirt relaxations
          # (any libvirt), or the strict incus posture (incus only). libvirt
          # "wins" the relaxations; its group set is unioned with incus-admin
          # when both are on.
          postureServiceConfig =
            if !providerOn then
              (if rcfg.enable || bcfg.enable then staticStrictServiceConfig else m0ServiceConfig)
            else if anyLibvirt then
              libvirtRelaxServiceConfig
            else
              incusStrictServiceConfig;
        in
        {
          assertions =
            # M5 invariant: a warm pool can never exceed the concurrency cap.
            lib.mapAttrsToList (n: ss: {
              assertion = ss.minIdleRunners <= ss.maxRunners;
              message = "services.garm.scaleSets.${n}: minIdleRunners (${toString ss.minIdleRunners}) must be <= maxRunners (${toString ss.maxRunners}).";
            }) cfg.scaleSets
            # EXP-MP: a scale set must reference a declared provider.
            ++ lib.mapAttrsToList (n: ss: {
              assertion = cfg.providers ? ${ss.provider};
              message = "services.garm.scaleSets.${n}.provider = \"${ss.provider}\" does not name a declared services.garm.providers.<name> (have: ${lib.concatStringsSep ", " (lib.attrNames cfg.providers)}).";
            }) cfg.scaleSets
            # RC2: a pool's warm floor can never exceed its concurrency cap.
            ++ lib.mapAttrsToList (n: pl: {
              assertion = pl.minIdleRunners <= pl.maxRunners;
              message = "services.garm.pools.${n}: minIdleRunners (${toString pl.minIdleRunners}) must be <= maxRunners (${toString pl.maxRunners}).";
            }) cfg.pools
            # RC2: a pool must reference a declared provider.
            ++ lib.mapAttrsToList (n: pl: {
              assertion = cfg.providers ? ${pl.provider};
              message = "services.garm.pools.${n}.provider = \"${pl.provider}\" does not name a declared services.garm.providers.<name> (have: ${lib.concatStringsSep ", " (lib.attrNames cfg.providers)}).";
            }) cfg.pools
            # RB3: a capabilityPool's per-host floor can never exceed its cap.
            ++ lib.mapAttrsToList (n: cp: {
              assertion = cp.minIdleRunners <= cp.maxRunners;
              message = "services.garm.capabilityPools.${n}: minIdleRunners (${toString cp.minIdleRunners}) must be <= maxRunners (${toString cp.maxRunners}).";
            }) cfg.capabilityPools
            # RB3: every named candidate provider must be declared.
            ++ lib.concatMap (
              n:
              let
                cp = cfg.capabilityPools.${n};
              in
              map (prov: {
                assertion = cfg.providers ? ${prov};
                message = "services.garm.capabilityPools.${n}.providers: \"${prov}\" does not name a declared services.garm.providers.<name> (have: ${lib.concatStringsSep ", " (lib.attrNames cfg.providers)}).";
              }) cp.providers
            ) (lib.attrNames cfg.capabilityPools)
            # W1: a balloon floor must sit strictly BELOW the ceiling it floors,
            # and only the libvirt backend renders a domain XML to put it in.
            # Both are eval-time failures rather than silent no-ops: the provider
            # drops a degenerate value, which would otherwise look like a
            # working memory floor while every VM quietly boots at its ceiling.
            ++ lib.mapAttrsToList (n: p: {
              assertion = p.currentMemoryMb == 0 || p.currentMemoryMb < p.memoryMb;
              message = "services.garm.providers.${n}: currentMemoryMb (${toString p.currentMemoryMb}) must be strictly below memoryMb (${toString p.memoryMb}) — a balloon boot target at or above the ceiling leaves the balloon empty and is ignored by the provider. Use 0 to disable ballooning.";
            }) cfg.providers
            ++ lib.mapAttrsToList (n: p: {
              assertion = p.currentMemoryMb == 0 || providerIsLibvirt p;
              message = "services.garm.providers.${n}: currentMemoryMb is only honoured by the libvirt backend (this provider's backend = \"${p.backend}\"); it has no effect on incus containers or vm-harness-run VMs.";
            }) cfg.providers
            # RB1: a remote-target provider needs an endpoint. (The token is
            # resolved at runtime — file or env — so it cannot be asserted here.)
            ++ lib.mapAttrsToList (n: p: {
              assertion = !(providerIsRemote p) || p.remote.endpoint != "";
              message = "services.garm.providers.${n}: backend = \"remote\" requires remote.endpoint (host:port of the vm-harness serve daemon).";
            }) cfg.providers
            # Remote Incus capability grants are deliberately narrow and
            # provider-admin controlled. Refuse configurations whose target
            # cannot honour them instead of silently ignoring a privilege grant.
            ++ lib.mapAttrsToList (n: p: {
              assertion =
                !p.remote.incusSecurityNesting || (providerIsRemote p && p.remote.targetBackend == "incus");
              message = "services.garm.providers.${n}.remote.incusSecurityNesting requires backend = \"remote\" and remote.targetBackend = \"incus\"; it maps only to vm-harness --incus-security-nesting.";
            }) cfg.providers
            ++ lib.mapAttrsToList (n: p: {
              assertion = !p.remote.incusNestedKvm || (providerIsRemote p && p.remote.targetBackend == "incus");
              message = "services.garm.providers.${n}.remote.incusNestedKvm requires backend = \"remote\" and remote.targetBackend = \"incus\"; it maps only to vm-harness --incus-nested-kvm with the fixed /dev/kvm device contract.";
            }) cfg.providers
            # Resource-guard (eval time): the sum over all scale sets of
            # maxRunners * (its provider's per-VM RAM) must fit the declared host
            # RAM budget, and likewise vCPUs. A bad config FAILS TO EVAL instead
            # of OOM-ing the host at runtime.
            ++ [
              {
                assertion =
                  let
                    totalMb = lib.foldlAttrs (
                      acc: _: ss:
                      acc + ss.maxRunners * (cfg.providers.${ss.provider}.memoryMb or 0)
                    ) 0 cfg.scaleSets;
                  in
                  totalMb <= cfg.hostBudget.memoryMb;
                message =
                  let
                    totalMb = lib.foldlAttrs (
                      acc: _: ss:
                      acc + ss.maxRunners * (cfg.providers.${ss.provider}.memoryMb or 0)
                    ) 0 cfg.scaleSets;
                  in
                  "services.garm: worst-case ephemeral guest RAM (sum of maxRunners * provider.memoryMb = ${toString totalMb} MiB) exceeds hostBudget.memoryMb (${toString cfg.hostBudget.memoryMb} MiB). Lower maxRunners/memoryMb or raise hostBudget.memoryMb.";
              }
              {
                assertion =
                  let
                    totalVcpu = lib.foldlAttrs (
                      acc: _: ss:
                      acc + ss.maxRunners * (cfg.providers.${ss.provider}.vcpus or 0)
                    ) 0 cfg.scaleSets;
                  in
                  totalVcpu <= cfg.hostBudget.vcpus;
                message =
                  let
                    totalVcpu = lib.foldlAttrs (
                      acc: _: ss:
                      acc + ss.maxRunners * (cfg.providers.${ss.provider}.vcpus or 0)
                    ) 0 cfg.scaleSets;
                  in
                  "services.garm: worst-case ephemeral guest vCPUs (sum of maxRunners * provider.vcpus = ${toString totalVcpu}) exceeds hostBudget.vcpus (${toString cfg.hostBudget.vcpus}). Lower maxRunners/vcpus or raise hostBudget.vcpus.";
              }
            ]
            # EXP-MP: each enabled App credential needs its PEM + ids.
            ++ lib.mapAttrsToList (name: g: {
              assertion = g.appKeyFile != null;
              message = "services.garm.github.${name} requires appKeyFile (the App PEM, staged via LoadCredential).";
            }) enabledGithub
            # EXP-MP: each enabled incus provider injects a static IPv4 per
            # container (incusbr0 DHCP does not lease), so a subnet + gateway are
            # required. Mirrors the provider's own Validate().
            ++ lib.mapAttrsToList (name: p: {
              assertion = p.backend != "incus" || (p.incusIPv4CIDR != "" && p.incusIPv4Gateway != "");
              message = "services.garm.providers.${name}.backend = \"incus\" requires incusIPv4CIDR and incusIPv4Gateway (incusbr0 DHCP does not lease; the provider injects a static IPv4 per container).";
            }) enabledProviders
            # RE2: warm standby is a DB-shipping posture, not a second live
            # controller — so it is meaningless without the backup feed. Fail
            # eval rather than silently promise an HA that ships nothing.
            ++ [
              {
                assertion = !rcvcfg.warmStandby.enable || (bcfg.enable && bcfg.remoteCommand != null);
                message = ''
                  services.garm.recovery.warmStandby.enable requires
                  services.garm.backup.enable = true AND a
                  services.garm.backup.remoteCommand that ships the DB snapshot to
                  the standby host — warm standby here means "the standby carries a
                  current DB it can be promoted from", not a second live GARM.
                '';
              }
            ];

          environment.systemPackages = [
            cfg.package
          ]
          # RE2: the emergency DB restore tool ships wherever backup is enabled.
          ++ lib.optional bcfg.enable dbRestoreScript;

          networking.firewall = {
            allowedTCPPorts = mkIf cfg.openFirewall [ cfg.apiServer.port ];
            # EXP-MP declarative egress: trust each enabled incus provider's
            # bridge for the GARM API/metadata/callback port so per-job
            # CONTAINERS can reach the host GARM endpoint. Only the bridge
            # interface (never the public firewall).
            interfaces = mkIf cfg.openIncusBridgeFirewall (
              lib.listToAttrs (
                map (
                  p: lib.nameValuePair p.incusBridge { allowedTCPPorts = [ cfg.apiServer.port ]; }
                ) incusProviders
              )
            );
          };

          # Dedicated system user for the provider posture. Created
          # unconditionally-when-any-provider-on so the socket-group membership
          # (libvirtd+kvm for the VM path; incus-admin for the container path) is
          # stable across boots (a DynamicUser cannot be a persistent member).
          users.users = mkIf needsDedicatedUser {
            ${cfg.user} = {
              isSystemUser = true;
              group = cfg.group;
              description = "GARM (GitHub Actions Runner Manager) service user";
              home = stateDir;
            };
          };
          users.groups = mkIf needsDedicatedUser { ${cfg.group} = { }; };

          # Each enabled libvirt provider writes per-job artifacts into its
          # poolDir; provision each owned garm:libvirtd (0771). The incus daemon
          # owns container storage, so incus providers need no host pool dir.
          systemd.tmpfiles.rules =
            map (dir: "d ${dir} 0771 ${cfg.user} libvirtd - -") libvirtPoolDirs
            # RE2: the DB snapshot dir, garm-owned + private.
            ++ lib.optional bcfg.enable "d ${bcfg.dir} 0700 ${cfg.user} ${cfg.group} - -";

          systemd.services.garm = {
            description = "GitHub Actions Runner Manager (garm)";
            documentation = [ "https://github.com/cloudbase/garm" ];
            # GARM reads the external-provider executable and config paths only
            # at daemon startup.  Keep those paths tied to the declarative
            # template so a provider package/config change cannot leave the
            # old provider live after a system switch.
            restartTriggers = [ configTemplate ];
            after = [
              "network.target"
            ]
            # Ordering edge against agenix's systemd-unit mode — emitted ONLY
            # when that unit actually exists in this configuration.
            #
            # An unconditional `After=agenix-install-secrets.service` used to
            # sit here, justified as an inert forward-compatible no-op. It is
            # inert (`After=` neither pulls a unit in nor orders against one
            # absent from the transaction), but "inert" and "harmless" are not
            # the same thing: on hosts where agenix installs secrets from an
            # ACTIVATION SCRIPT (sysusers/userborn off — all three garm hosts)
            # the unit does not exist, and the unit file nonetheless READ as
            # though credential ordering were handled. It is what a 243/
            # CREDENTIALS investigation looked at first, and it cost time,
            # because the real cause was elsewhere entirely (see `Type=` below).
            # A dependency you cannot see is worse than no dependency.
            #
            # So: declare it when it is real, and say nothing when it is not.
            # `systemd.services ? …` reads only the attribute NAMES, which are
            # static across every definition, so this cannot recurse into this
            # unit's own value.
            ++ lib.optional (config.systemd.services ? agenix-install-secrets) "agenix-install-secrets.service"
            ++ lib.optional anyLibvirt "libvirtd.service"
            ++ lib.optional anyIncus "incus.service";
            wants = lib.optional anyLibvirt "libvirtd.service" ++ lib.optional anyIncus "incus.service";
            wantedBy = [ "multi-user.target" ];

            # Fail fast + legibly if a LoadCredential source is genuinely absent,
            # instead of the opaque 243/CREDENTIALS. A DIAGNOSTIC, not the fix for
            # the observed 243s — it passed on all 8 of them. See
            # `credentialSourcePaths` above, and `Type = "exec"` below for the
            # actual repair.
            unitConfig = {
              AssertPathExists = credentialSourcePaths;
            }
            # RE2 recovery posture: widen the start-limit window so a briefly
            # crash-looping central GARM (the fleet SPOF) is never dropped into a
            # permanent `failed` state by systemd's default 10s/5-burst limiter —
            # it keeps being restarted until it either recovers or exceeds the
            # generous burst, at which point it is LEFT failed so RE1's
            # `up==0`/GarmControllerDown pages a human instead of a hard fault
            # hiding behind an endless loop.
            // lib.optionalAttrs rcvcfg.enable {
              StartLimitIntervalSec = rcvcfg.startLimitIntervalSec;
              StartLimitBurst = rcvcfg.startLimitBurst;
            };

            # The provider child inherits the unit PATH (GARM forwards PATH via
            # environment_variables). libvirt: cdrkit(genisoimage)+qemu+libvirt
            # for the config-drive/clone path. incus: the `incus` client.
            # qemu-windows-arm: swtpm for the Windows ARM TPM emulator.
            path =
              lib.optionals anyLibvirt [
                pkgs.cdrkit
                pkgs.qemu
                pkgs.libvirt
              ]
              ++ lib.optional anyIncus pkgs.incus
              ++ lib.optional anyQemuWindowsArm pkgs.swtpm;

            serviceConfig = {
              # `exec`, NOT `simple`. THIS IS THE 243/CREDENTIALS FIX.
              #
              # THE FAILURE. On all three garm hosts the unit intermittently
              # died at startup with
              #   (garm)[PID]: garm.service: Failed to set up credentials: Protocol error
              #   (garm)[PID]: garm.service: Failed at step CREDENTIALS spawning …/garm: Protocol error
              #   systemd[1]: garm.service: Main process exited, code=exited, status=243/CREDENTIALS
              # 8 times on high-mem-server between 2026-08-18 and 2026-08-20,
              # and 3 CONSECUTIVE times on gpu-server-001 for a 3 min 36 s
              # outage. `Restart=always` eventually got through, so it looked
              # like a transient nobody had to own.
              #
              # WHAT IT IS NOT. It is not a missing/late credential source.
              # `AssertPathExists=` on the exact `LoadCredential` source paths
              # was deployed and PASSED on every one of the 8 occurrences: the
              # agenix symlink farm was fully materialised and the paths
              # resolved. It is also not activation-adjacent — most occurrences
              # follow a health-watchdog restart hours after the last switch,
              # with no agenix activity anywhere near them.
              #
              # WHAT IT IS. systemd names it itself, once per start, in this
              # unit's own journal:
              #
              #   garm.service: Service uses a combination of Type=simple,
              #   ExecStartPost=, and credentials. This could lead to race
              #   conditions. Continuing.
              #
              # (src/core/service.c, service_verify(): Type=simple +
              # ExecStartPost= + exec_context_has_credentials().) With
              # `Type=simple`, service_enter_start() forks the main process and
              # IMMEDIATELY calls service_enter_start_post() — the switch has no
              # wait for SERVICE_SIMPLE. The bind-verify ExecStartPost below is
              # therefore spawned while the main child is still inside
              # exec_child(), which runs exec_setup_credentials() BEFORE the
              # execve. Both children then set up the SAME
              # /run/credentials/garm.service: the main one with
              # EXEC_SETUP_CREDENTIALS_FRESH (it umounts the existing store and
              # rebuilds it: tmpfs on a workspace, write, remount ro, MS_MOVE
              # into place), the ExecStartPost one without. They race, and the
              # loser dies at step CREDENTIALS.
              #
              # "Protocol error" is not a hint about protocols; it is
              # exec_setup_credentials()'s helper child failing.
              # exec_setup_credentials() does the mount work in a
              # `safe_fork("(sd-mkdcreds)", …|FORK_WAIT|FORK_NEW_MOUNTNS)`, and
              # wait_for_terminate_and_check() maps "child exited non-zero" to
              # -EPROTO. The real errno is logged at LOG_DEBUG inside that child
              # and never reaches the journal — which is why the message is
              # opaque and why the observed PIDs are consecutive
              # (main=N, bind-verify=N+1).
              #
              # THE FIX. `Type=exec` keeps everything else identical but makes
              # systemd wait for the main process's execve — it watches the
              # exec_fd and only then runs service_enter_start_post()
              # (service.c: `if (s->type == SERVICE_EXEC && s->state ==
              # SERVICE_START) service_enter_start_post(s)`). Credential setup
              # completes strictly before that fd closes, so the two credential
              # setups can no longer overlap. It also removes the systemd
              # warning above, which is the machine-checkable statement that the
              # defective combination is gone (see t_garm_credentials_no_race).
              #
              # Ordering against agenix would NOT have fixed this, and neither
              # would any amount of retrying: the sources were always present.
              #
              # Type=exec also tightens startup semantics in a way this unit
              # wants anyway — a garm binary that cannot even execve now fails
              # the start instead of being reported "Started" and dying a moment
              # later. The start-job timeout is unchanged: under Type=simple the
              # main command already ran with no timeout and TimeoutStartSec
              # applied to the START_POST phase, which is where the bind-verify
              # (`healthcheck.startupBindTimeout`, 30 s by default) lives.
              Type = "exec";

              ExecStartPre = lib.getExe renderScript;
              ExecStart = lib.escapeShellArgs [
                (lib.getExe cfg.package)
                "--config"
                renderedConfig
              ];
              # FU9 startup bind-verify: wait for the API listener to bind and
              # FAIL the start (→ Restart=always restarts garm) if it never does
              # within startupBindTimeout — catching the bind race at startup.
              # A failing ExecStartPost marks the unit failed and triggers the
              # Restart policy. Opt-outable via healthcheck.startupBindVerify.
              ExecStartPost = lib.optional (hcfg.enable && hcfg.startupBindVerify) (lib.getExe bindVerifyScript);
              ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
              # Restart=always: the DB-as-truth central GARM always comes back and
              # reconciles the persistent DB (RE2). RestartSec is the recovery
              # posture's fast-respawn knob.
              Restart = "always";
              RestartSec = if rcvcfg.enable then rcvcfg.restartSec else "5s";

              StateDirectory = "garm";
              StateDirectoryMode = "0700";
              WorkingDirectory = stateDir;

              LoadCredential = loadCredential;

              # ---- Hardening COMMON to every posture --------------------------
              # These do NOT interfere with any provider and stay on everywhere
              # (a superset of upstream contrib/garm.service).
              NoNewPrivileges = true;
              ProtectHome = true;
              PrivateTmp = true;
              ProtectKernelTunables = true;
              ProtectKernelModules = true;
              ProtectKernelLogs = true;
              ProtectControlGroups = true;
              ProtectClock = true;
              ProtectHostname = true;
              ProtectProc = "invisible";
              ProcSubset = "pid";
              RestrictNamespaces = true;
              RestrictRealtime = true;
              RestrictSUIDSGID = true;
              LockPersonality = true;
              RemoveIPC = true;
              RestrictAddressFamilies = [
                "AF_INET"
                "AF_INET6"
                "AF_UNIX"
              ];
              SystemCallArchitectures = "native";
              CapabilityBoundingSet = [ "" ];
              AmbientCapabilities = [ "" ];
              UMask = "0077";
            }
            # Posture-specific fragment: strict M0 sandbox (provider off), the
            # strict-but-incus-admin sandbox (incus only), or the qemu
            # relaxations (any libvirt provider).
            // postureServiceConfig
            # The strict @system-service syscall filter is kept for EVERY posture
            # EXCEPT the libvirt one — the libvirt path execs cdrkit's mkisofs
            # which is SIGSYS-killed under it. M0 (pure Go daemon) and the incus
            # path (Go daemon + the `incus` Go CLI) both pass it.
            // lib.optionalAttrs (!libvirtProviderOn) {
              SystemCallFilter = [
                "@system-service"
                "~@privileged"
                "~@resources"
              ];
            };
          };

          # ---- The declarative reconcile oneshot ----------------------------
          # Ordered after garm.service's first start attempt, converges GARM's DB
          # onto the declared github creds + orgs + scale sets, then exits
          # (RemainAfterExit so a re-switch re-runs it). The dependency is a Want,
          # not a Require: a startup bind-verification failure intentionally makes
          # systemd restart GARM, and a hard Require would leave this oneshot in a
          # permanent dependency-failed state even after that restart succeeds.
          # The script's bounded API-readiness loop spans the restart and its own
          # Restart=on-failure policy handles a genuinely unavailable controller.
          # Idempotent: a second run with unchanged config makes no changes. It
          # runs as the SAME user as garm (so it reads the module-staged PEM copies
          # under stateDir + shares the garm-cli HOME) and, like garm, may stage an
          # operator admin password via LoadCredential. Enabling it is OPT-IN
          # (`reconcile.enable`).
          systemd.services.garm-reconcile = mkIf rcfg.enable {
            description = "Reconcile GARM DB state (orgs/credentials/scale sets) to the declared config";
            documentation = [ "https://github.com/cloudbase/garm" ];
            after = [ "garm.service" ];
            wants = [ "garm.service" ];
            wantedBy = [ "multi-user.target" ];

            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = lib.getExe reconcileScript;
              # Run as the garm user so it reads the staged PEMs + shares HOME.
              User = cfg.user;
              Group = cfg.group;
              StateDirectory = "garm";
              WorkingDirectory = stateDir;
              LoadCredential =
                lib.optional (
                  rcfg.adminPasswordFile != null
                ) "reconcile-admin-password:${toString rcfg.adminPasswordFile}"
                ++ lib.optional (
                  rcfg.webhookSecretFile != null
                ) "reconcile-webhook-secret:${toString rcfg.webhookSecretFile}";
              # Retry a few times if garm is still coming up.
              Restart = "on-failure";
              RestartSec = "5s";
              # …but NEVER retry a DECLARATION error. Exit 3 is the reconcile's
              # "I converged everything I could; the pools listed in the ERROR
              # summary were refused by the controller for a reason a retry
              # cannot change" (see the script's epilogue). Without this the
              # unit re-runs the identical doomed reconcile until the start
              # limit trips — measured on high-mem-server 2026-09-16 at 65
              # restarts over ~40 minutes for ONE mis-declared macOS pool. The
              # unit still ends in `failed`, so the condition stays loud; it
              # just stops costing a full forge-hitting reconcile every 5s.
              RestartPreventExitStatus = [ 3 ];
            };
            unitConfig = {
              StartLimitIntervalSec = "120";
              StartLimitBurst = 6;
            };
          };

          # ---- FU9 GARM-API-WATCHDOG: health-check service + timer -----------
          # A periodic oneshot that probes the GARM API on the SAME loopback
          # address+port garm binds (and reconcile probes). It restarts
          # garm.service ONLY after `failureThreshold` CONSECUTIVE
          # connection-refused/timeout probes, and never more often than
          # `minRestartInterval` — recovering a process-alive-but-API-dead garm
          # without ever restarting a healthy-but-busy one or restart-storming.
          #
          # It runs as ROOT (needs `systemctl restart garm.service`) but does
          # only a loopback curl + a counter file under stateDir + one restart;
          # the heavy sandbox is unnecessary for a tiny probe and would block
          # the `systemctl` D-Bus call, so it is intentionally minimal.
          systemd.services.garm-healthcheck = mkIf hcfg.enable {
            description = "GARM API health-check watchdog (auto-recover a process-alive-but-API-dead garm)";
            documentation = [ "https://github.com/cloudbase/garm" ];
            # Probe only once garm is (meant to be) up. Not a hard requires: the
            # timer keeps probing across garm restarts.
            after = [ "garm.service" ];
            serviceConfig = {
              Type = "oneshot";
              ExecStart = lib.getExe healthCheckScript;
              # Use the watchdog's OWN state dir — NOT garm's. This root-run
              # oneshot with StateDirectory="garm" made systemd re-chown
              # /var/lib/garm to root on every run, breaking garm's DB access.
              StateDirectory = "garm-healthcheck";
              # Hardening: read-only system, no new privs. It still needs D-Bus
              # to systemctl-restart garm, so keep the sandbox light.
              ProtectSystem = "strict";
              NoNewPrivileges = true;
              ProtectHome = true;
              PrivateTmp = true;
            };
          };

          systemd.timers.garm-healthcheck = mkIf hcfg.enable {
            description = "Periodic GARM API health-check (FU9 watchdog)";
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnBootSec = hcfg.interval;
              OnUnitActiveSec = hcfg.interval;
              # If the machine was asleep, do not fire a burst of catch-up runs.
              AccuracySec = "10s";
              Unit = "garm-healthcheck.service";
            };
          };

          # ---- RE2 DB BACKUP: online SQLite snapshot oneshot + timer ---------
          # Runs as the garm user (reads the 0700 stateDir DB), writes a
          # consistent, integrity-checked, rotated snapshot to backup.dir, and
          # optionally ships it off-host via remoteCommand. It is a SEPARATE unit
          # from garm.service, so its lighter sandbox never touches the
          # controller's hardening; it only needs read of stateDir + write of
          # backup.dir.
          systemd.services.garm-db-backup = mkIf bcfg.enable {
            description = "Online backup of the GARM SQLite DB (RE2 recovery)";
            documentation = [ "https://github.com/cloudbase/garm" ];
            # Only meaningful once garm has created its store; not a hard require
            # (the timer keeps taking snapshots regardless, and the script no-ops
            # if the DB is not there yet).
            after = [ "garm.service" ];
            serviceConfig = {
              Type = "oneshot";
              ExecStart = lib.getExe dbBackupScript;
              User = cfg.user;
              Group = cfg.group;
              # Snapshot the live DB under stateDir; write the snapshot dir.
              # stateDir is READ-WRITE (not read-only): a WAL-mode SQLite source
              # needs to touch the `-shm`/`-wal` sidecars to take even a read
              # lock, and the garm user owns stateDir already — sqlite's own
              # locking makes the concurrent `.backup` connection safe.
              ProtectSystem = "strict";
              ReadWritePaths = [
                stateDir
                bcfg.dir
              ];
              NoNewPrivileges = true;
              ProtectHome = true;
              PrivateTmp = true;
              ProtectKernelTunables = true;
              ProtectKernelModules = true;
              ProtectControlGroups = true;
              RestrictSUIDSGID = true;
              LockPersonality = true;
              UMask = "0077";
            };
          };

          systemd.timers.garm-db-backup = mkIf bcfg.enable {
            description = "Periodic GARM DB backup (RE2 recovery)";
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnBootSec = bcfg.interval;
              OnUnitActiveSec = bcfg.interval;
              AccuracySec = "1min";
              Persistent = true;
              Unit = "garm-db-backup.service";
            };
          };
        }
      );
    };
}
