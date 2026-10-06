top@{ ... }:
{
  # Sovereign-CI-Fleet AH3 gates for `garm-provider-agentharbor`, GARM's
  # stateless external provider over agent-harbor's REST direct-sandbox-launch
  # endpoints (agent-harbor specs/REST-Service/Direct-Sandbox-Launch.md).
  #
  # t_garm_provider_agentharbor — HERMETIC behaviour gate (no agent-harbor
  # server, no GitHub, no GARM daemon; loopback HTTP only):
  #   (1) the behavioural matrix (internal/agentharbor): create hands the JIT
  #       runner-install script to the launch as stdin; Get/List map every ah
  #       job state to its GARM status; Delete is idempotent and 404 is
  #       success, with a cleanup-token fallback; ttlSeconds is always sent
  #       and a job without a cleanupToken is refused; retried creates never
  #       double-launch (Idempotency-Key + 409 name-conflict adoption); the
  #       spec's error model maps onto GARM's error kinds / exit codes; the
  #       Ed25519 capability manifest gates launches; no provider-side state.
  #   (2) the END-TO-END protocol gate (internal/protocoltest): the PACKAGED
  #       binary, driven over GARM's real v0.1.1 protocol, launches a runner
  #       whose payload really executes, registers (JIT credentials into
  #       RUNNER_ROOT + idle), serves a job, is reported stopped, is reaped,
  #       and leaves no process, workspace or provider file behind; a second
  #       runner is reaped mid-job; a stale Nix runner is refused. Then the
  #       REAL nixpkgs github-runner runs through the same payload inside this
  #       build sandbox (no /bin/bash, no FHS libraries: the environment that
  #       defeated the upstream tarball on NixOS), proves it loaded the JIT
  #       credentials (a JWT signed with the JIT key), exits with its own
  #       TerminatedError, and is reported to GARM as a crash (error + reason)
  #       rather than a clean stop.
  #   (3) NEGATIVE CONTROLS: the end-to-end gate is re-run against eight
  #       single-line mutations of the provider source and MUST fail each time
  #       with a test failure (not a build failure), plus once against the
  #       unmutated source copy, which MUST pass — so a control cannot fail
  #       for an environmental reason and be mistaken for a real catch.
  #   The mocks each test file uses are justified in its header comment.
  #
  # t_garm_provider_agentharbor_module — EVAL-ONLY config example: a
  # services.garm host with an agentharbor provider + a scale set on it. It
  # renders the units (nothing is deployed), asserts the provider block,
  # the store-safe config.toml, the LoadCredential staging of the API key,
  # and then feeds the module-rendered config.toml to the real binary so a
  # module/provider key drift fails here. It also checks the module's
  # assertions reject a provider without an endpoint.
  perSystem =
    {
      pkgs,
      lib,
      self',
      ...
    }:
    let
      flake = top.config.flake;
      provider = self'.packages.garm-provider-agentharbor;

      # ---- The eval-only example (also the README's example) --------------
      exampleGarm = {
        enable = true;
        reconcile.enable = true;
        github.ci-app = {
          appId = 100042;
          installationId = 200042;
          appKeyFile = "/run/agenix/garm/ci-app-key";
        };
        providers.ah-sandbox = {
          backend = "agentharbor";
          agentharbor = {
            endpoint = "https://ah-ci.example.net:8443";
            authTokenFile = "/run/agenix/garm/ah-api-key";
            substrate = "local-sandbox";
            ttlSeconds = 7200;
            sandbox = {
              memoryMax = "8G";
              pidsMax = 4096;
              cpuMax = "400000 100000";
            };
            # Pin the host's manifest key (example key: bytes 0..31).
            capabilities = {
              keyId = "ahcap-630dcd2966c43366";
              publicKey = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";
            };
            env.RUNNER_ALLOW_RUNASROOT = "0";
            # The sandbox payload execs the same Nix runner the host's
            # services.github-runners use.
            runner = {
              package = pkgs.github-runner;
              extraPackages = [ pkgs.jq ];
              extraEnvironment.ACTIONS_RUNNER_HOOK_JOB_STARTED = "/etc/runner-hook.sh";
            };
          };
        };
        scaleSets.ah-linux = {
          provider = "ah-sandbox";
          org = "example-org";
          credentials = "ci-app";
          image = "host";
          osType = "linux";
          maxRunners = 4;
          minIdleRunners = 0;
          scaleSetName = "ah-sandbox-linux-x64";
        };
      };

      evalHost =
        garmCfg:
        pkgs.nixos (
          { ... }:
          {
            imports = [ flake.modules.nixos.garm ];
            boot.loader.grub.enable = false;
            fileSystems."/" = {
              device = "/dev/vda";
              fsType = "ext4";
            };
            system.stateVersion = "24.11";
            services.garm = garmCfg;
          }
        );

      exampleHost = evalHost exampleGarm;
      garmUnit = exampleHost.config.systemd.units."garm.service".unit;

      # Module assertions for a provider with no endpoint (pure eval).
      badHost = evalHost (
        lib.recursiveUpdate exampleGarm {
          providers.ah-sandbox.agentharbor.endpoint = "";
        }
      );
      failedAssertions = lib.concatMapStringsSep "\n" (a: a.message) (
        lib.filter (a: !a.assertion) badHost.config.assertions
      );
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_garm_provider_agentharbor =
          pkgs.runCommand "t_garm_provider_agentharbor"
            {
              nativeBuildInputs = [
                pkgs.go
                pkgs.bash
                pkgs.curl
                pkgs.gnutar
                pkgs.gzip
                pkgs.coreutils
                pkgs.gnused
                pkgs.gnugrep
                pkgs.perl
              ];
              src = ../packages/garm-provider-vmharness/src;
              providerBin = lib.getExe provider;
              # The real Nix runner the sandbox payload execs (the module's
              # default `runner.package`).
              githubRunner = pkgs.github-runner;
              githubRunnerVersion = pkgs.github-runner.version;
            }
            ''
              set -euo pipefail
              fail() { echo "[t_garm_provider_agentharbor][FAIL] $1" >&2; exit 1; }

              export HOME="$PWD/home"; mkdir -p "$HOME"
              export GOCACHE="$PWD/gocache"; mkdir -p "$GOCACHE"
              export GOPATH="$PWD/gopath"; mkdir -p "$GOPATH"
              export GOFLAGS=-mod=vendor GOTOOLCHAIN=local CGO_ENABLED=0

              cp -r "$src" base && chmod -R u+w base

              # ---- (1) behavioural matrix -----------------------------------
              (cd base && go test -count=1 -v ./internal/agentharbor/) 2>&1 | tee unit.log \
                || fail "behavioural matrix failed"
              grep -q '^ok' unit.log || fail "behavioural matrix did not report ok"
              for t in \
                TestCreateHandsRunnerInstallScriptToLaunch \
                TestCreatePassesTTLAndRequiresCleanupToken \
                TestCreateRefusesJobWithoutCleanupToken \
                TestGetAndListMapJobStates \
                TestDeleteIsIdempotentAndNotFoundIsSuccess \
                TestDeleteFallsBackToCleanupToken \
                TestRetriedCreateNeverDoubleLaunches \
                TestNameConflictAdoptsOwnJobAndRejectsForeign \
                TestErrorMappingFollowsSpecErrorModel \
                TestFailedLaunchReportsErrorInstance \
                TestCapabilityManifestGatesLaunch \
                TestProviderKeepsNoState \
                TestNixRunnerVersionGuard \
                TestSandboxPayloadRequiresNixRunner \
                TestExitedJobDistinguishesCrashFromCleanExit; do
                grep -q -- "--- PASS: $t " unit.log || fail "$t did not run and pass"
              done

              # ---- (2) end-to-end gate against the PACKAGED binary ---------
              export GARM_AH_E2E_GITHUB_RUNNER="$githubRunner"
              export GARM_AH_E2E_GITHUB_RUNNER_VERSION="$githubRunnerVersion"
              [ ! -e /bin/bash ] || fail "this build sandbox has /bin/bash: it no longer reproduces a NixOS ah host"
              (cd base && GARM_PROVIDER_AGENTHARBOR_BIN="$providerBin" \
                go test -count=1 -v -run 'TestAgentharborGate' ./internal/protocoltest/) 2>&1 | tee e2e.log \
                || fail "end-to-end gate failed against the packaged binary"
              for t in TestAgentharborGateEphemeralRunnerLifecycle TestAgentharborGateRealNixRunner; do
                grep -q -- "--- PASS: $t " e2e.log || fail "$t did not run and pass"
              done

              # ---- (3) negative controls ------------------------------------
              # run_gate <dir> <log>: the e2e gate against a binary built from
              # <dir>'s source (GARM_PROVIDER_AGENTHARBOR_BIN unset).
              run_gate() {
                (cd "$1" && go test -count=1 -v -run 'TestAgentharborGate' ./internal/protocoltest/) >"$2" 2>&1
              }

              # The control of the controls: the unmutated source must PASS, so
              # a mutant's failure is attributable to its mutation.
              cp -r base ctl-clean
              run_gate ctl-clean ctl-clean.log || { cat ctl-clean.log; fail "the unmutated source copy fails the gate: negative controls would be vacuous"; }

              # mutate <name> <file> <from> <to>: literal, single-occurrence.
              mutate() {
                local name="$1" file="$2" from="$3" to="$4" dir="ctl-$1"
                cp -r base "$dir"
                local n
                n=$(grep -cF -- "$from" "$dir/$file" || true)
                [ "$n" = 1 ] || fail "negative control $name: anchor matched $n times in $file (source drifted?)"
                FROM="$from" TO="$to" perl -0pi -e 's/\Q$ENV{FROM}\E/$ENV{TO}/' "$dir/$file"
                grep -qF -- "$to" "$dir/$file" || fail "negative control $name: mutation not applied"
                if run_gate "$dir" "$dir.log"; then
                  cat "$dir.log"
                  fail "negative control $name: the gate PASSED against the mutant — it cannot detect this defect"
                fi
                grep -q -- '--- FAIL: TestAgentharborGate' "$dir.log" \
                  || { cat "$dir.log"; fail "negative control $name: failed for a reason other than a gate assertion"; }
                echo "[t_garm_provider_agentharbor] negative control $name: gate FAILED as required"
              }

              P=internal/agentharbor/provider.go
              C=internal/agentharbor/client.go
              # 404 is no longer recognised: idempotent delete / NotFound break.
              mutate notfound "$C" \
                'return errors.As(err, &apiErr) && apiErr.Status == http.StatusNotFound' \
                'return errors.As(err, &apiErr) && apiErr.Status == -1'
              # A finished (exited) job is reported as still running.
              mutate status "$P" \
                'return commonParams.InstanceStopped' \
                'return commonParams.InstanceRunning'
              # The TTL is no longer sent with the launch.
              mutate ttl "$P" \
                'TTLSeconds:         &ttl,' \
                'TTLSeconds:         func() *uint64 { _ = ttl; return nil }(),'
              # The runner-install script is not handed to the sandbox.
              mutate stdin "$P" \
                'Stdin:              &stdin,' \
                'Stdin:              func() *string { _ = stdin; return nil }(),'
              N=internal/agentharbor/nixrunner.go
              # A runner crash is reported to GARM as a clean stop.
              mutate crash "$P" \
                'inst.Status = commonParams.InstanceError' \
                'inst.Status = commonParams.InstanceStopped'
              # The payload leaks the ah host user's XDG_RUNTIME_DIR into the runner.
              mutate runtimedir "$N" \
                'unset XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS' \
                'unset DBUS_SESSION_BUS_ADDRESS'
              # The payload does not point the runner at its JIT state.
              mutate runnerroot "$N" \
                'export RUNNER_ROOT="$STATE_DIRECTORY"' \
                'export RUNNER_ROOT_UNSET="$STATE_DIRECTORY"'
              # The stale-runner guard never fires.
              mutate guard "$N" \
                'if lag >= maxMinorLag {' \
                'if false && lag >= maxMinorLag {'

              echo "[t_garm_provider_agentharbor][PASS] behaviour matrix + end-to-end runner lifecycle + real Nix runner crash path + 8/8 negative controls"
              touch "$out"
            '';

        t_garm_provider_agentharbor_module =
          pkgs.runCommand "t_garm_provider_agentharbor_module"
            {
              nativeBuildInputs = [
                pkgs.coreutils
                pkgs.gnugrep
                pkgs.gnused
              ];
              inherit garmUnit failedAssertions;
              providerBin = lib.getExe provider;
              githubRunner = pkgs.github-runner;
              githubRunnerVersion = pkgs.github-runner.version;
              bash = pkgs.bashInteractive;
              jq = lib.getBin pkgs.jq;
            }
            ''
              set -euo pipefail
              fail() { echo "[t_garm_provider_agentharbor_module][FAIL] $1" >&2; exit 1; }
              garm="$garmUnit/garm.service"

              pre=$(grep '^ExecStartPre=' "$garm" | head -1 | cut -d= -f2-)
              [ -f "$pre" ] || fail "render script not found at $pre"
              tmpl=$(grep -ohE '/nix/store/[a-z0-9]+-garm-config.toml.tmpl' "$pre" | head -1)
              [ -f "$tmpl" ] || fail "config template not found"
              grep -q 'name = "ah-sandbox"' "$tmpl" || fail "[[provider]] ah-sandbox missing"
              grep -q "provider_executable = \"$providerBin\"" "$tmpl" \
                || fail "backend = agentharbor did not default the package to garm-provider-agentharbor"
              grep -q 'environment_variables = \["PATH", "SSL_CERT_FILE", "SSL_CERT_DIR"\]' "$tmpl" \
                || fail "unexpected forwarded env (a file-staged token must not add AH_API_TOKEN)"

              cfg=$(grep -ohE '/nix/store/[a-z0-9]+-garm-provider-ah_sandbox\.toml' "$tmpl" | head -1)
              [ -f "$cfg" ] || fail "agentharbor provider config not found"
              cat "$cfg"
              for line in \
                'backend = "agentharbor"' \
                'endpoint = "https://ah-ci.example.net:8443"' \
                'auth_scheme = "apikey"' \
                'auth_token_file = "/var/lib/garm/ah-token-ah_sandbox"' \
                'substrate = "local-sandbox"' \
                'ttl_seconds = 7200' \
                'allow_network = true' \
                'memory_max = "8G"' \
                'pids_max = 4096' \
                'key_id = "ahcap-630dcd2966c43366"' \
                'RUNNER_ALLOW_RUNASROOT = "0"' \
                "command = [\"$bash/bin/bash\", \"-s\"]" \
                '[runner]' \
                "listener = \"$githubRunner/bin/Runner.Listener\"" \
                "version = \"$githubRunnerVersion\"" \
                'max_minor_lag = 2' \
                '[runner.env]' \
                'ACTIONS_RUNNER_HOOK_JOB_STARTED = "/etc/runner-hook.sh"'; do
                grep -qxF "$line" "$cfg" || fail "provider config lacks: $line"
              done
              grep -q "^path = \[\"$bash/bin\", .*\"$jq/bin\"\]\$" "$cfg" \
                || fail "the runner PATH is not the module's path + extraPackages"
              # NixOS's default service path (what the systemd runners get for
              # free): a job script calling grep/find must work in the sandbox.
              for tool in grep find xargs systemctl sed; do
                found=0
                for d in $(sed -n 's/^path = \[\(.*\)\]$/\1/p' "$cfg" | tr -d '"' | tr ',' ' '); do
                  [ -x "$d/$tool" ] && found=1
                done
                [ "$found" = 1 ] || fail "the runner PATH lacks $tool (NixOS's default systemd service path)"
              done
              # `command` must be a top-level key, i.e. before the first table.
              first_table=$(grep -n '^\[' "$cfg" | head -1 | cut -d: -f1)
              cmd_line=$(grep -n '^command = ' "$cfg" | cut -d: -f1)
              [ "$cmd_line" -lt "$first_table" ] || fail "command is rendered inside a TOML table"
              ! grep -q 'images' "$cfg" || fail "a golden-image map leaked into the agentharbor config"
              ! grep -q '/run/agenix' "$cfg" || fail "provider config points at the agenix source instead of the staged copy"

              grep -q '^LoadCredential=ah-token-ah-sandbox:/run/agenix/garm/ah-api-key' "$garm" \
                || fail "API key not staged via LoadCredential"
              grep -q 'ah-token-ah-sandbox' "$pre" || fail "render script does not stage the API key"

              # The module-rendered config must parse in the REAL provider
              # (strict: unknown keys are errors). Point the staged-token path
              # at a scratch file; nothing contacts the endpoint.
              echo 'not-a-real-key' > token
              sed "s|/var/lib/garm/ah-token-ah_sandbox|$PWD/token|" "$cfg" > provider.toml
              env -i GARM_COMMAND=GetVersion GARM_INTERFACE_VERSION=v0.1.1 \
                GARM_PROVIDER_CONFIG_FILE="$PWD/provider.toml" GARM_CONTROLLER_ID=ctl \
                "$providerBin" > version.out || fail "the provider rejected the module-rendered config"
              grep -q '^v' version.out || fail "GetVersion printed $(cat version.out)"
              env -i GARM_COMMAND=ValidatePoolInfo GARM_INTERFACE_VERSION=v0.1.1 \
                GARM_PROVIDER_CONFIG_FILE="$PWD/provider.toml" GARM_CONTROLLER_ID=ctl \
                GARM_POOL_EXTRASPECS='{"ttl_seconds": 3600}' \
                "$providerBin" >/dev/null 2>validate.err || { cat validate.err; fail "ValidatePoolInfo failed on the rendered config"; }

              printf '%s\n' "$failedAssertions" | grep -q 'requires agentharbor.endpoint' \
                || fail "the module accepted an agentharbor provider without an endpoint"

              echo "[t_garm_provider_agentharbor_module][PASS] eval-only agentharbor GARM host renders a config the provider accepts"
              touch "$out"
            '';
      };
    };
}
