{ withSystem, ... }:
{
  # Runner-Fleet-Capability-Pools-And-Remote-Driving campaign, milestone RA5.
  #
  # `services.vm-harness-serve` — the DARWIN (nix-darwin / launchd) sibling of
  # the Linux `services.vm-harness-serve` systemd module. It runs the SAME RA1
  # `vm-harness serve` remoting daemon, but as a launchd system daemon rather
  # than a systemd unit, because nix-darwin has neither systemd, the NixOS
  # firewall, nor `LoadCredential`.
  #
  # Why a SIBLING module rather than one cross-platform module: the Linux module
  # is almost entirely systemd/firewall/user-database machinery
  # (`systemd.services`, `networking.firewall.interfaces`,
  # `users.users.<u>.isSystemUser`, `SupplementaryGroups`, `ProtectSystem`,
  # `LoadCredential`) — none of which exist on darwin. What the two share is the
  # CLI contract of the `serve` binary, not the deployment mechanism. This split
  # mirrors the repo's existing `deployment/{pull-agent,pull-agent-darwin}.nix`
  # and `mcl-reprobuild` nixos+darwin siblings.
  #
  # This is the GENERAL, company-agnostic machinery: it bakes in NO host list,
  # IPs, credentials, or Metacraft/tart specifics. The concrete instantiation
  # (which host, the overlay IP, the agenix token, the tart env + asuser worker
  # wrapper) lives in the private `infra` repo, which CONSUMES these options.
  #
  # Posture (campaign non-negotiable pattern (a) + serve.md "Auth & network
  # posture"): the control channel is authenticated (bearer token over the
  # NetBird overlay) and is NEVER exposed on a public interface. On darwin there
  # is no per-interface NixOS firewall to open a zone on, so the posture rests on
  # the single mechanism that IS available here: the listener binds ONE overlay
  # address (asserted to never be a wildcard). The token is read directly from
  # {option}`authTokenFile` (an agenix-darwin secret path) — launchd has no
  # `LoadCredential`, so the daemon reads the decrypted file, which must be
  # readable by {option}`user` (root by default).
  #
  # It is idle-cheap / scale-to-zero-friendly: one acceptor thread plus a small
  # bounded pool of request handlers, all parked in a blocking wait when idle —
  # no polling and no busy loop, so an idle daemon costs ~nothing.
  #
  # Runner-Fleet-M3-ARM-Wave MA12 — THE HEALTHCHECK WATCHDOG, and why it is a
  # SECOND launchd job rather than a unit setting. The daemon has twice gone
  # silently deaf in production: the process lives, its port listens, and it
  # answers nothing. launchd's `KeepAlive` cannot see that — it only reacts to
  # the process EXITING, so a wedged-but-alive daemon is invisible to it, and
  # launchd has no equivalent of systemd's `WatchdogSec` for a job to prove its
  # own liveness. The platform's only mechanism for "run this check
  # periodically" is a job with `StartInterval`, so that is what this is: the
  # launchd-native analogue of the Linux sibling's systemd timer, doing the
  # same probe and issuing `launchctl kickstart -k` where the Linux side issues
  # `systemctl restart`.
  #
  # Two darwin-specific corrections learned from the 2026-09-20..23 m3 outage
  # (serve down ~2 days, every central-GARM call `connection refused`):
  #
  #  * The probe cannot rely on connecting to the overlay address from the
  #    host itself — under userspace NetBird that never works, so the original
  #    watchdog "recovered" a healthy daemon every 10 minutes. A failed
  #    handshake is now judged by the kernel's accept queue instead.
  #  * Both jobs start through `/bin/wait4path /nix/store`, and the watchdog
  #    re-bootstraps (rather than kickstarts) a job launchd has stopped
  #    spawning, with every launchctl call time-bounded.
  flake.modules.darwin.vm-harness-serve =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.vm-harness-serve;
      inherit (lib)
        mkEnableOption
        mkIf
        mkOption
        types
        optionals
        ;

      # Default to this flake's vendored vm-harness package (its single binary
      # includes `vm-harness serve`), resolved for the host's system — mirrors
      # the Linux module and how `services.garm` defaults `package`.
      defaultPackage = withSystem pkgs.stdenv.hostPlatform.system (
        { config, ... }: config.packages.vm-harness
      );

      portFile = "${cfg.stateDir}/port";

      # ----- MA12 SERVE-LISTENER WATCHDOG ---------------------------------
      hcfg = cfg.healthcheck;

      # WHAT IS PROBED — identical reasoning to the Linux sibling, and it
      # matters more here, not less. An UNAUTHENTICATED GET /v1/info is answered
      # 401 by a live daemon; producing that 401 still requires accept →
      # dispatch → read → respond, the whole path that dies in the wedge, but
      # costs nothing because auth rejects before any dispatch work.
      #
      # The AUTHENTICATED form probes every registered hypervisor backend
      # synchronously. MEASURED 2026-09-18 on aarch64-darwin: 16.7s
      # authenticated versus 5ms unauthenticated. On a tart host that sweep also
      # shells out to `tart`, so probing it on a timer would put real periodic
      # load on the very host whose CI capacity this campaign is trying to add.
      #
      # It also keeps the watchdog credential-free: no bearer token is staged
      # into a root-run periodic job.
      healthProbeURL = "http://${cfg.listenAddress}:${toString cfg.port}/v1/info";

      # launchd's own `/nix/store` race. On nix-darwin `/nix` is a separate
      # APFS volume that `org.nixos.darwin-store` mounts DURING boot, while
      # every `RunAtLoad` daemon is spawned at the same time. A job whose
      # `ProgramArguments[0]` is a store path therefore loses the race: launchd
      # cannot find the executable, records `last exit code = 78: EX_CONFIG`,
      # puts the job in its penalty box, and NEVER spawns it again — KeepAlive
      # does not apply to a job that never ran. That is exactly what took m3's
      # serve down for two days after its 2026-09-21 reboot (`runs = 1`,
      # `state = spawn scheduled`, nothing in stderr.log because the binary
      # never started).
      #
      # nix-darwin's own `command`/`script` options avoid this by prefixing
      # `/bin/wait4path /nix/store`; a raw `serviceConfig.ProgramArguments`
      # does not get that for free, so do it explicitly. `sh -c '… exec "$@"'
      # <name> <argv…>` passes the argv through verbatim — no re-quoting, so
      # the posture assertions on individual flags still hold.
      waitForNixStore =
        name: argv:
        [
          "/bin/sh"
          "-c"
          ''/bin/wait4path /nix/store && exec "$@"''
          name
        ]
        ++ argv;

      # The launchd plist nix-darwin installs for the daemon. The watchdog
      # re-bootstraps from it when `kickstart` cannot help (see below).
      servePlist = "/Library/LaunchDaemons/${cfg.label}.plist";

      healthCheckScript = pkgs.writeShellApplication {
        name = "vm-harness-serve-healthcheck";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.curl
          pkgs.gawk
          pkgs.gnugrep
          pkgs.gnused
        ];
        text = ''
          set -euo pipefail

          url="${healthProbeURL}"
          # netstat -L prints a listening socket as `<addr>.<port>`.
          listen_socket=${lib.escapeShellArg "${cfg.listenAddress}.${toString cfg.port}"}
          state="${cfg.stateDir}/healthcheck"
          fail_file="$state/consecutive-failures"
          last_restart_file="$state/last-restart"
          threshold=${toString hcfg.failureThreshold}
          min_gap_s=${toString hcfg.minRestartIntervalSec}
          label=${lib.escapeShellArg cfg.label}
          plist=${lib.escapeShellArg servePlist}

          # Overridable ONLY so the posture check can drive every branch with
          # recording shims; launchd runs this with none of them set.
          launchctl_cmd="''${VMH_HC_LAUNCHCTL:-/bin/launchctl}"
          netstat_cmd="''${VMH_HC_NETSTAT:-/usr/sbin/netstat}"
          launchctl_timeout="''${VMH_HC_LAUNCHCTL_TIMEOUT:-30}"

          mkdir -p "$state"
          log() { echo "vm-harness-serve-healthcheck: $*"; }

          # EVERY launchctl call is bounded. On 2026-09-21 this watchdog issued
          # `kickstart -k` against a job launchd had penalty-boxed after a
          # spawn failure; kickstart blocked FOREVER, and because launchd never
          # starts a `StartInterval` job while its previous run is still alive,
          # the watchdog itself went silent for two days while the daemon it
          # supervises stayed down.
          lctl() { timeout "$launchctl_timeout" "$launchctl_cmd" "$@"; }

          healthy() {
            if [ -f "$fail_file" ] && [ "$(cat "$fail_file" 2>/dev/null || echo 0)" != "0" ]; then
              log "listener healthy again ($*) — resetting failure counter"
            fi
            printf '0' > "$fail_file"
            exit 0
          }

          # Only act if launchd believes the job is loaded. `launchctl print`
          # exits non-zero for an unknown/unloaded label, which is the darwin
          # analogue of the Linux sibling's `systemctl is-active` guard: a
          # deliberately unloaded daemon must not be "recovered".
          if ! job="$(lctl print "system/$label" 2>/dev/null)"; then
            log "launchd job $label is not loaded — no watchdog action"
            printf '0' > "$fail_file"
            exit 0
          fi

          running=1
          if ! grep -Eq '^[[:space:]]*state = running$' <<<"$job"; then
            running=0
            exit_line="$(grep -Em1 'last exit code' <<<"$job" | sed 's/^[[:space:]]*//' || true)"
            log "launchd job $label is loaded but NOT running (''${exit_line:-no exit recorded}) — launchd will not respawn a job it failed to spawn"
          else
            # Inspect the STATUS, not merely curl's exit code: a 503 means the
            # daemon is up but every request handler is busy, which is a real
            # degradation the watchdog must count as a failure rather than
            # wave through as "it answered". `%{time_connect}` separates "the
            # TCP handshake never completed" from "connected, then silence".
            probe="$(curl -s -o /dev/null -w '%{http_code} %{time_connect}' \
                       --max-time ${toString hcfg.probeTimeout} "$url" </dev/null \
                     || true)"
            code="''${probe%% *}"
            connect_s="''${probe#* }"
            code="''${code:-000}"

            case "$code" in
              401|200)
                healthy "HTTP $code from $url"
                ;;
              503)
                log "listener answered 503 — every request handler is busy (saturated)"
                ;;
              *)
                if [ "$code" != "000" ]; then
                  log "listener answered unexpected HTTP $code"
                elif awk -v t="''${connect_s:-0}" 'BEGIN { exit !(t + 0 > 0) }'; then
                  log "listener accepted the connection but did not answer within ${toString hcfg.probeTimeout}s — the wedge signature"
                else
                  # THE HANDSHAKE ITSELF FAILED. The daemon binds only its
                  # overlay address, and on a darwin host running NetBird in
                  # userspace mode that address is the PEER of a point-to-point
                  # utun, so a connection from the host to itself leaves
                  # through the tunnel and is dropped: it never reaches the
                  # local socket. Measured on m3 — 0 of 193 probes ever
                  # succeeded while the controller reached the same socket
                  # fine, and every "recovery" was a kickstart that killed a
                  # healthy daemon (and its in-flight creates) every 10min.
                  #
                  # So a failed connect alone proves nothing here. Ask the
                  # kernel instead: is the socket listening, and is its accept
                  # queue draining? A wedged daemon that stops calling accept()
                  # leaves completed connections piling up in `qlen`.
                  queue="$("$netstat_cmd" -Lan -p tcp 2>/dev/null \
                             | awk -v s="$listen_socket" '$2 == s { print $1; exit }' || true)"
                  if [ -z "$queue" ]; then
                    log "nothing is listening on $listen_socket (connect to $url failed)"
                  elif [ "''${queue%%/*}" -gt 0 ] 2>/dev/null; then
                    log "accept queue on $listen_socket is backed up (qlen/incqlen/maxqlen $queue) — the daemon is not accepting"
                  else
                    healthy "self-probe cannot reach $url on this host, but $listen_socket is listening with an empty accept queue ($queue)"
                  fi
                fi
                ;;
            esac
          fi

          fails=$(( $(cat "$fail_file" 2>/dev/null || echo 0) + 1 ))
          printf '%s' "$fails" > "$fail_file"
          log "probe failed; consecutive failures = $fails/$threshold"

          if [ "$fails" -lt "$threshold" ]; then
            exit 0
          fi

          now=$(date +%s)
          if [ -f "$last_restart_file" ]; then
            last=$(cat "$last_restart_file" 2>/dev/null || echo 0)
            if [ $(( now - last )) -lt "$min_gap_s" ]; then
              log "listener dead for $fails probes, but a watchdog restart happened $(( now - last ))s ago (< ''${min_gap_s}s) — RATE-LIMITED, not restarting"
              exit 0
            fi
          fi

          printf '%s' "$now" > "$last_restart_file"
          printf '0' > "$fail_file"

          # `kickstart -k` kills the running job and starts it again — the
          # launchd equivalent of `systemctl restart`. It is useless (and, on
          # a penalty-boxed job, blocks) when launchd has given up spawning
          # the job, so a job that is not running — or a kickstart that does
          # not return — is re-bootstrapped from its plist instead, which
          # resets launchd's spawn state.
          if [ "$running" = 1 ]; then
            log "listener dead for $fails consecutive probes — kickstarting $label (watchdog recovery)"
            if lctl kickstart -k "system/$label"; then
              log "$label kickstart issued"
              exit 0
            fi
            log "kickstart of $label failed or timed out — falling back to bootout + bootstrap"
          else
            log "$label not running for $fails consecutive probes — re-bootstrapping it from $plist (watchdog recovery)"
          fi
          lctl bootout "system/$label" || true
          lctl bootstrap system "$plist"
          log "$label re-bootstrapped"
        '';
      };
    in
    {
      options.services.vm-harness-serve = {
        enable = mkEnableOption ''
          the `vm-harness serve` remoting daemon on darwin (launchd) — an
          authenticated network front-end exposing this host's VM/container
          lifecycle ops to a remote controller over the NetBird overlay
        '';

        package = mkOption {
          type = types.package;
          default = defaultPackage;
          defaultText = lib.literalMD "this flake's `vm-harness` package";
          description = ''
            The vm-harness package whose `serve` subcommand is run. Its single
            binary includes both the daemon and the backend code it fronts.
          '';
        };

        listenAddress = mkOption {
          type = types.str;
          default = "127.0.0.1";
          example = "100.83.174.120";
          description = ''
            The single address the daemon binds to. This MUST be a NetBird
            overlay IP (or another private/overlay interface address) — NEVER a
            public interface and NEVER `0.0.0.0`. On darwin this single-address
            bind is the ONLY posture mechanism (there is no NixOS per-interface
            firewall to also gate the port), so it is load-bearing.

            The default `127.0.0.1` is a safe non-routable placeholder; a real
            deployment overrides it with the host's overlay IP.
          '';
        };

        port = mkOption {
          type = types.port;
          default = 8873;
          description = "TCP port the daemon listens on (vm-harness serve default).";
        };

        backend = mkOption {
          type = types.str;
          default = "auto";
          example = "tart-macos";
          description = ''
            The `--backend` the daemon reports/advertises on `GET /v1/info`
            (`auto` probes which backends are usable on this host). The
            per-request backend is chosen by the client's `run --backend <id>`
            argv, so this mainly seeds the capability report. On a tart host set
            it to `tart-macos` or `tart-linux-arm`.
          '';
        };

        authTokenFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          example = "/run/agenix/vm-harness-serve/token";
          description = ''
            Path to the file holding the bearer token (a decrypted agenix-darwin
            secret, e.g. `config.age.secrets."vm-harness-serve/token".path`).
            Passed to the daemon via `--auth-token-file`. launchd has no
            `LoadCredential`, so the daemon reads this path directly; it must be
            readable by {option}`user` (root by default). Required when
            {option}`enable` is true.
          '';
        };

        # ── RA6 enrollment (signed /v1/manifest) ──────────────────────────────
        enrollSecretFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          example = "/run/agenix/vm-harness-serve/enroll-secret";
          description = ''
            Path to the per-host RA6 enrollment secret (agenix-darwin). When set,
            the daemon signs `GET /v1/manifest` with an identity whose `keyId`
            derives from it (HMAC-SHA256). Passed via `--enroll-secret-file`;
            launchd has no LoadCredential, so the daemon reads it directly (must
            be readable by {option}`user`). Null leaves the daemon RA1-only.
          '';
        };
        identityTtlSec = mkOption {
          type = types.nullOr types.int;
          default = null;
          example = 3600;
          description = "Signed-identity lifetime in seconds (`--identity-ttl-sec`); only with {option}`enrollSecretFile`.";
        };
        hostId = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "m3";
          description = "Stable host identifier in the signed manifest (`--host-id`); only with {option}`enrollSecretFile`.";
        };

        extraPackages = mkOption {
          type = types.listOf types.package;
          default = [ ];
          example = lib.literalMD "`[ pkgs.tart pkgs.sshpass pkgs.qemu ]`";
          description = ''
            Extra packages placed on the daemon's `PATH`. The serve daemon shells
            out to the backend CLI it drives (e.g. `tart`, `sshpass`, `qemu`), so
            that CLI must be here. `coreutils` is always added (the tart backend
            uses `timeout`).
          '';
        };

        environment = mkOption {
          type = types.attrsOf types.str;
          default = { };
          example = lib.literalMD ''
            `{ VM_HARNESS_TART_STATE_DIR = "/private/var/lib/vm-harness/tart"; }`
          '';
          description = ''
            Extra environment variables for the launchd daemon (merged into
            `EnvironmentVariables`, and thus inherited by the worker it spawns).
            This is where a tart host supplies its state-dir / asuser knobs
            (`VM_HARNESS_TART_STATE_DIR`, `TART_HOME`,
            `VM_HARNESS_DARWIN_ASUSER_UID`, the shared-store paths) so the
            serve-driven backend path is byte-equivalent to the local GARM-driven
            one. Kept OUT of the general module: the specific variables and values
            are deployment policy (infra).
          '';
        };

        workerExe = mkOption {
          type = types.nullOr types.path;
          default = null;
          example = lib.literalMD "a `launchctl asuser` wrapper script";
          description = ''
            Optional `--worker-exe`: the executable the daemon prepends to every
            forwarded `run …` argv instead of running the `vm-harness` binary
            directly. Defaults to null (the daemon self-execs `vm-harness`).

            A macOS/tart deployment points this at a wrapper that re-execs the
            worker inside the console user's GUI session, e.g.
            `exec /bin/launchctl asuser <uid> /usr/bin/sudo -E -u #<uid> -- <vm-harness> "$@"`
            — the same asuser+`sudo -E` mechanism the local-exec
            `garm-provider-vmharness` uses, because Tart links AppKit even under
            `--no-graphics` and deadlocks if run as uid 0. The wrapper + uid are
            deployment-specific, so they live in infra, not here.
          '';
        };

        user = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "root";
          description = ''
            launchd `UserName` for the daemon. Default null runs it in the system
            domain (root), which is correct for a tart host that drops the WORKER
            to the console user via {option}`workerExe` (mirroring GARM's
            root-daemon + asuser-worker split). Set a non-root user only for a
            backend whose whole daemon can run unprivileged.
          '';
        };

        group = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "launchd `GroupName` for the daemon (default null → system default).";
        };

        stateDir = mkOption {
          type = types.str;
          default = "/private/var/lib/vm-harness-serve";
          description = ''
            Daemon working directory + where the `--port-file` readiness file is
            written. Created (root-owned, 0750) by an activation script.
          '';
        };

        standardOutLog = mkOption {
          type = types.str;
          default = "/var/log/vm-harness-serve/stdout.log";
          description = "launchd `StandardOutPath`. Its directory is created at activation.";
        };

        standardErrorLog = mkOption {
          type = types.str;
          default = "/var/log/vm-harness-serve/stderr.log";
          description = "launchd `StandardErrorPath`. Its directory is created at activation.";
        };

        label = mkOption {
          type = types.str;
          default = "org.metacraft-labs.vm-harness-serve";
          description = "launchd job Label.";
        };

        serveThreads = mkOption {
          type = types.nullOr types.int;
          default = null;
          example = 8;
          description = ''
            `serve --serve-threads <n>`: how many request-handler threads the
            daemon runs behind its single acceptor. Null uses the daemon's own
            auto-size, `max(4, CPU count)` capped at 32.

            Bounded deliberately: unbounded thread-per-connection would turn a
            burst of slow requests into a denial of service of its own, whereas
            a bounded pool plus the acceptor's 503 turns the same burst into an
            explicit, retryable answer.
          '';
        };

        execDeadlineSec = mkOption {
          type = types.nullOr types.int;
          default = null;
          example = 46800;
          description = ''
            `serve --exec-deadline-sec <n>`: wall-clock budget for a single
            `/v1/exec`, after which the worker is killed and the client told
            why. Null uses the daemon default (46800s = 13h).

            Keep it ABOVE the longest legitimate operation — the central GARM
            provider forwards `--timeout-sec 43200` (12h) on runner creates, so
            a shorter deadline would kill live CI runners. It bounds a LEAK, not
            latency; what bounds an OUTAGE is {option}`healthcheck`.
          '';
        };

        openFilesLimit = mkOption {
          type = types.int;
          default = 8192;
          example = 16384;
          description = ''
            Per-job soft `NumberOfFiles` limit (launchd `SoftResourceLimits`).

            macOS's default soft limit is **256**, and a launchd daemon inherits
            it — the interactive shell's much larger `ulimit -n` does not apply,
            because the daemon is not started from a shell. A concurrent serve
            exceeds 256 easily: every in-flight request holds a client socket
            plus the spawned worker's stdio pipes, and each `/v1/exec` that
            carries user-data opens a staging file.

            Measured on m3: the daemon sat at 258 open descriptors against the
            256 ceiling, and the resulting `EMFILE` surfaced on the CONTROLLER
            as `failed to start worker: Too many open files` / `failed to stage
            user-data: Too many open files` — provider errors that name the
            symptom and not the cause. Every central-GARM pool creation failed
            while the identical request through the per-host GARM kept working,
            because that path runs in a shell-descended process.

            8192 is far above any plausible concurrency here (the handler pool
            is CPU-sized, tens not thousands) and costs nothing when unused —
            this is a CEILING, not a reservation. The system-wide hard limit is
            already `unlimited`, so raising the soft one needs no other change.
          '';
        };

        # ── MA12 listener watchdog ────────────────────────────────────────────
        healthcheck = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Periodically probe the serve listener and `launchctl kickstart -k`
              the daemon when it stops answering.

              Default TRUE, unlike most `enable` options here, because the
              failure it recovers is invisible to everything else on this
              platform: launchd's `KeepAlive` reacts only to the process
              exiting, and a wedged daemon does not exit. It has happened twice
              in production, once for nineteen hours. An operator must opt OUT
              of supervision, not into it.
            '';
          };

          interval = mkOption {
            type = types.int;
            default = 60;
            description = ''
              Seconds between probes (launchd `StartInterval`, which takes a
              plain integer — there is no `systemd.time` span syntax here). The
              probe is a single unauthenticated request a healthy daemon answers
              in milliseconds, so a short interval is essentially free.
            '';
          };

          probeTimeout = mkOption {
            type = types.int;
            default = 5;
            description = ''
              Seconds one probe may take before it counts as failed. Set well
              above a healthy daemon's millisecond answer so ordinary host load
              — and on m3 that means real CI load — can never be mistaken for a
              wedge.
            '';
          };

          failureThreshold = mkOption {
            type = types.int;
            default = 3;
            description = ''
              How many CONSECUTIVE failed probes before the job is kickstarted.
              A single failure never acts; with the default {option}`interval`
              this means ~3 minutes unresponsive, which no healthy state
              produces.
            '';
          };

          minRestartIntervalSec = mkOption {
            type = types.int;
            default = 600;
            description = ''
              Minimum seconds between two watchdog-initiated kickstarts, so a
              daemon wedging for a systemic reason is not restart-stormed but
              left in a state an operator can inspect.
            '';
          };

          standardOutLog = mkOption {
            type = types.str;
            default = "/var/log/vm-harness-serve/healthcheck.log";
            description = ''
              Where the watchdog's own output goes. Deliberately a SEPARATE file
              from the daemon's: the whole point of this job is to say something
              when the daemon has gone quiet, and interleaving it with the log
              that just stopped moving would bury exactly that signal.
            '';
          };
        };
      };

      config = mkIf cfg.enable {
        assertions = [
          {
            assertion = pkgs.stdenv.hostPlatform.isDarwin;
            message = "services.vm-harness-serve (darwin) is only valid on a nix-darwin host.";
          }
          {
            assertion = cfg.authTokenFile != null;
            message = ''
              services.vm-harness-serve.authTokenFile must be set — the daemon
              refuses to start without a bearer token (an agenix secret path).
            '';
          }
          {
            assertion = cfg.listenAddress != "0.0.0.0" && cfg.listenAddress != "::";
            message = ''
              services.vm-harness-serve.listenAddress must be a single overlay
              address, never a wildcard (0.0.0.0 / ::) — on darwin the bind is
              the only thing keeping the control channel off a public interface.
            '';
          }
        ];

        # launchd cannot open StandardOut/StandardError paths, nor can the daemon
        # write the port file, unless these directories already exist. Create
        # them before nix-darwin reconciles the launchd jobs.
        system.activationScripts.preActivation.text = lib.mkAfter ''
          ${lib.getExe' pkgs.coreutils "install"} -d -m 0750 -o root -g wheel \
            ${lib.escapeShellArg cfg.stateDir} \
            ${lib.escapeShellArg (builtins.dirOf cfg.standardOutLog)} \
            ${lib.escapeShellArg (builtins.dirOf cfg.standardErrorLog)} \
            ${lib.escapeShellArg (builtins.dirOf hcfg.standardOutLog)}
        '';

        launchd.daemons.vm-harness-serve = {
          serviceConfig = {
            Label = cfg.label;
            ProgramArguments = waitForNixStore "vm-harness-serve" (
              [
                (lib.getExe cfg.package)
                "serve"
                "--listen"
                "${cfg.listenAddress}:${toString cfg.port}"
                "--backend"
                cfg.backend
                "--auth-token-file"
                (toString cfg.authTokenFile)
                "--port-file"
                portFile
              ]
              ++ optionals (cfg.workerExe != null) [
                "--worker-exe"
                (toString cfg.workerExe)
              ]
              # RA6: sign /v1/manifest when an enrollment secret is provided.
              ++ optionals (cfg.enrollSecretFile != null) [
                "--enroll-secret-file"
                (toString cfg.enrollSecretFile)
              ]
              ++ optionals (cfg.identityTtlSec != null) [
                "--identity-ttl-sec"
                (toString cfg.identityTtlSec)
              ]
              ++ optionals (cfg.hostId != null) [
                "--host-id"
                cfg.hostId
              ]
              # MA12: concurrency bound + per-exec deadline. Both null by default,
              # leaving the daemon's own documented defaults in force.
              ++ optionals (cfg.serveThreads != null) [
                "--serve-threads"
                (toString cfg.serveThreads)
              ]
              ++ optionals (cfg.execDeadlineSec != null) [
                "--exec-deadline-sec"
                (toString cfg.execDeadlineSec)
              ]
            );

            EnvironmentVariables = {
              PATH = lib.makeBinPath ([ cfg.package ] ++ cfg.extraPackages ++ [ pkgs.coreutils ]);
              HOME = cfg.stateDir;
              # Ownership records for kept ephemeral instances (see the Linux
              # module); launchd provides no $STATE_DIRECTORY, so name it.
              VMH_EPHEMERAL_LABEL_DIR = "${cfg.stateDir}/ephemeral-labels";
            }
            // cfg.environment;

            # Restart on failure/crash, never busy-loop on a clean exit — the
            # launchd analogue of the Linux unit's `Restart=on-failure`.
            KeepAlive = {
              SuccessfulExit = false;
              Crashed = true;
            };
            RunAtLoad = true;
            ThrottleInterval = 10;

            # THE macOS DEFAULT IS 256 AND IT IS NOT ENOUGH — measured, not
            # precautionary. `launchctl limit maxfiles` on m3 reports a SOFT
            # limit of 256, and a launchd daemon inherits it unless the plist
            # says otherwise; the shell's own `ulimit -n` of 1048576 is
            # irrelevant because the daemon is not started from a shell.
            #
            # A concurrent serve blows through that. Each in-flight request
            # holds the client socket plus the spawned worker's stdio pipes,
            # `--serve-threads` defaults to a pool sized from the CPU count, and
            # user-data staging opens a file per exec. m3's daemon sat at 258
            # open fds against the 256 ceiling, and the failure surfaced on the
            # CONTROLLER as provider errors that name the symptom without the
            # cause:
            #
            #   failed to start worker: Too many open files
            #   failed to stage user-data: Too many open files
            #
            # That is an EMFILE, not a permissions or path problem, and it made
            # every central-GARM pool creation fail while the identical request
            # through the per-host GARM kept working — because that path runs in
            # a shell-descended process with the large soft limit.
            #
            # `SoftResourceLimits` is what launchd honours per-job. The hard
            # limit is already `unlimited` system-wide, so raising the soft one
            # needs no other change.
            SoftResourceLimits = {
              NumberOfFiles = cfg.openFilesLimit;
            };

            StandardOutPath = cfg.standardOutLog;
            StandardErrorPath = cfg.standardErrorLog;
            WorkingDirectory = cfg.stateDir;
          }
          // lib.optionalAttrs (cfg.user != null) { UserName = cfg.user; }
          // lib.optionalAttrs (cfg.group != null) { GroupName = cfg.group; };
        };

        # ---- MA12 SERVE-LISTENER WATCHDOG (launchd StartInterval job) ------
        # The launchd-native analogue of the Linux sibling's systemd timer.
        # `StartInterval` is launchd's only "run this periodically" primitive,
        # and a separate job is the only way to supervise a daemon that is alive
        # but unresponsive — `KeepAlive` on the daemon itself cannot observe
        # that, and launchd has no `WatchdogSec`.
        #
        # It runs in the system domain (root) because `launchctl kickstart -k
        # system/<label>` requires it, and it is deliberately tiny: one curl,
        # one counter file, one kickstart.
        launchd.daemons.vm-harness-serve-healthcheck = lib.mkIf hcfg.enable {
          serviceConfig = {
            Label = "${cfg.label}-healthcheck";
            ProgramArguments = waitForNixStore "vm-harness-serve-healthcheck" [
              (lib.getExe healthCheckScript)
            ];
            StartInterval = hcfg.interval;
            # Do NOT RunAtLoad: the first probe should land one interval after
            # activation, not race the daemon's own startup and count a
            # not-yet-bound listener as a failure.
            RunAtLoad = false;
            StandardOutPath = hcfg.standardOutLog;
            StandardErrorPath = hcfg.standardOutLog;
            WorkingDirectory = cfg.stateDir;
          };
        };
      };
    };
}
