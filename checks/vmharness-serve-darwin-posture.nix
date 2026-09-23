top@{ ... }:
{
  # Two properties of the darwin `vm-harness serve` daemon that are invisible
  # until production breaks, and that no existing check covers: the launchd
  # file-descriptor ceiling, and the watchdog's probe→action decisions.
  #
  # WHY THESE TWO TOGETHER. Both are ways the daemon fails while LOOKING
  # healthy. The fd ceiling makes it accept connections and then fail every
  # exec; the watchdog is what is supposed to notice a daemon that answers
  # nothing. Neither shows up in `launchctl print`, and both were found only
  # from the controller's side, reading provider errors.
  #
  # Mock policy: the watchdog assertions RUN the real rendered script against a
  # REAL HTTP responder (curl is not shimmed). Only the two macOS system tools
  # the sandbox cannot provide are replaced, through the script's own
  # `VMH_HC_LAUNCHCTL` / `VMH_HC_NETSTAT` hooks: a `launchctl` shim that
  # reports a scripted job state and RECORDS the argv it was asked to run, and
  # a `netstat` shim that prints a scripted listen-queue table. Justification:
  # launchd and the kernel listen queue do not exist in a Nix build sandbox,
  # and the decisions under test (what to count, and whether to kickstart or
  # re-bootstrap) are made entirely from what those two tools report. The
  # branching, the counter file, the rate limit and the launchctl timeout are
  # the production code. Asserting on the script's TEXT instead would pass
  # against a script that reads correctly and behaves wrongly, which is the
  # specific failure this tier exists to catch.
  #
  # A third property joined them after the 2026-09-21 m3 reboot: both launchd
  # jobs must start through `/bin/wait4path /nix/store`, or launchd loses the
  # boot-time race with the /nix volume mount and never spawns them again.
  perSystem =
    {
      pkgs,
      lib,
      self',
      ...
    }:
    let
      darwinCfg =
        (top.inputs.nix-darwin.lib.darwinSystem {
          inherit (pkgs.stdenv.hostPlatform) system;
          modules = [
            top.config.flake.modules.darwin.vm-harness-serve
            (
              { ... }:
              {
                networking.hostName = "vmh-serve-posture-fixture";
                system.stateVersion = 6;
                services.vm-harness-serve = {
                  enable = true;
                  # Loopback + a fixed port so the check can stand a REAL
                  # HTTP responder at the probe URL. The script bakes the
                  # URL in at build time, so this is how the probe is driven.
                  listenAddress = "127.0.0.1";
                  port = fixturePort;
                  authTokenFile = "/run/agenix/vm-harness-serve/token";
                  backend = "tart-macos";
                  # The watchdog script bakes stateDir in at build time and
                  # mkdir's it at runtime, so the fixture must name a path the
                  # build sandbox can create. This is the ONLY fixture-only
                  # value here; every other input is the module's own default.
                  stateDir = fixtureStateDir;
                };
              }
            )
          ];
        }).config;

      serveJob = darwinCfg.launchd.daemons.vm-harness-serve.serviceConfig;
      healthJob = darwinCfg.launchd.daemons.vm-harness-serve-healthcheck.serviceConfig;
      fdLimit = serveJob.SoftResourceLimits.NumberOfFiles or null;

      # The macOS default. A daemon left on it is the bug, so the check states
      # the number rather than only "greater than zero".
      macosDefaultMaxFiles = 256;

      fixtureStateDir = "/tmp/vmh-serve-posture-fixture";
      fixturePort = 18873;
    in
    {
      checks.vmharness-serve-darwin-posture =
        pkgs.runCommand "vmharness-serve-darwin-posture"
          {
            nativeBuildInputs = [
              pkgs.coreutils
              pkgs.python3
            ];
            # The job execs `/bin/sh -c 'wait4path … && exec "$@"' <name> <script>`,
            # so the rendered script is the LAST argv element.
            healthScript = lib.last healthJob.ProgramArguments;
            serveArgv = builtins.toJSON serveJob.ProgramArguments;
            healthArgv = builtins.toJSON healthJob.ProgramArguments;
            inherit fdLimit;
          }
          ''
            fail=0
            note() { echo "  $*"; }
            bad() { echo "  FAIL: $*" >&2; fail=1; }

            echo "== launchd fd ceiling =="
            ${
              if fdLimit == null then
                ''bad "SoftResourceLimits.NumberOfFiles is unset — the daemon inherits macOS's ${toString macosDefaultMaxFiles}-fd soft limit, and a concurrent serve exhausts it (EMFILE surfaces on the CONTROLLER as 'Too many open files' when staging user-data or starting a worker)"''
              else if fdLimit <= macosDefaultMaxFiles then
                ''bad "NumberOfFiles=${toString fdLimit} is not above the macOS default of ${toString macosDefaultMaxFiles}; measured on m3 the daemon sat at 258 open fds"''
              else
                ''note "ok: NumberOfFiles=${toString fdLimit} (> macOS default ${toString macosDefaultMaxFiles})"''
            }

            echo "== launchd jobs wait for /nix/store =="
            for job in serve health; do
              if [ "$job" = serve ]; then argv="$serveArgv"; else argv="$healthArgv"; fi
              if python3 -c '
            import json, sys
            a = json.loads(sys.argv[1])
            ok = (len(a) >= 5 and a[0] == "/bin/sh" and a[1] == "-c"
                  and a[2].startswith("/bin/wait4path /nix/store && exec ")
                  and a[4].startswith("/nix/store/"))
            sys.exit(0 if ok else 1)' "$argv"; then
                note "ok: $job job execs through /bin/wait4path /nix/store"
              else
                bad "$job job does not wait for /nix/store before exec'ing a store path (argv: $argv) — launchd spawns it before the /nix volume is mounted at boot, records EX_CONFIG and never retries"
              fi
            done

            echo "== watchdog probe -> action =="
            mkdir -p work state shims

            # Stand a REAL responder at the probe URL rather than shimming curl.
            # `writeShellApplication` puts its own `runtimeInputs` curl first on
            # PATH, so a PATH shim would be silently ignored.
            serve_code() {
              # stdout/stderr MUST be detached from the command substitution that
              # captures the pid: a backgrounded child inheriting that pipe keeps
              # it open, and `pid=$(serve_code …)` then blocks until the server
              # exits — i.e. forever.
              python3 - "$1" >/dev/null 2>&1 <<'PY' &
            import sys, http.server
            code = int(sys.argv[1])
            class H(http.server.BaseHTTPRequestHandler):
                def do_GET(self):
                    self.send_response(code); self.end_headers()
                def log_message(self, *a): pass
            http.server.HTTPServer(("127.0.0.1", ${toString fixturePort}), H).serve_forever()
            PY
              echo $!
            }

            # launchctl shim: `print` reports $SHIM_JOB (running | stuck |
            # unloaded); every call is appended to work/launchctl.log;
            # `kickstart` sleeps when SHIM_KICKSTART_HANGS=1, reproducing the
            # 2026-09-21 hang against a penalty-boxed job.
            cat > shims/launchctl <<'SH'
            #!/bin/sh
            echo "$*" >> "$SHIM_LOG"
            case "$1" in
              print)
                case "$SHIM_JOB" in
                  unloaded) exit 113 ;;
                  running) printf 'system/x = {\n\tstate = running\n\tpid = 4242\n\t\tstate = active\n}\n' ;;
                  stuck) printf 'system/x = {\n\tstate = spawn scheduled\n\tlast exit code = 78: EX_CONFIG\n\t\tstate = active\n}\n' ;;
                esac ;;
              kickstart) [ "''${SHIM_KICKSTART_HANGS:-0}" = 1 ] && sleep 30 ;;
            esac
            exit 0
            SH
            # netstat shim: prints the scripted listen-queue table.
            cat > shims/netstat <<'SH'
            #!/bin/sh
            echo 'Current listen queue sizes (qlen/incqlen/maxqlen)'
            echo 'Listen         Local Address'
            [ -n "''${SHIM_QUEUE:-}" ] && echo "$SHIM_QUEUE        127.0.0.1.${toString fixturePort}"
            exit 0
            SH
            # ps shim: prints $SHIM_PS verbatim (ppid stat etime rows).
            cat > shims/ps <<'SH'
            #!/bin/sh
            printf '%b' "''${SHIM_PS:-}"
            exit 0
            SH
            chmod +x shims/launchctl shims/netstat shims/ps

            reset_state() { rm -rf "$PWD/state" work/launchctl.log; mkdir -p "$PWD/state/healthcheck"; : > work/launchctl.log; }
            counter() { cat "$PWD/state/healthcheck/consecutive-failures" 2>/dev/null || echo missing; }
            actions() { grep -v '^print' work/launchctl.log | tr '\n' ';' || true; }

            # Rewrite the baked-in state dir to a BUILD-LOCAL one (the script
            # resolves stateDir at nix-eval time).
            sed "s#${fixtureStateDir}#$PWD/state#g" "$healthScript" > work/healthcheck
            chmod +x work/healthcheck

            probe() {  # $1 = label; runs one watchdog pass with the shims
              set +e
              SHIM_LOG="$PWD/work/launchctl.log" \
                VMH_HC_LAUNCHCTL="$PWD/shims/launchctl" \
                VMH_HC_NETSTAT="$PWD/shims/netstat" \
                VMH_HC_PS="$PWD/shims/ps" \
                VMH_HC_LAUNCHCTL_TIMEOUT=2 \
                "$PWD/work/healthcheck" >"work/out.$1" 2>&1
              echo "$?" > "work/rc.$1"
              set -e
            }

            expect() {  # $1 label, $2 expected counter, $3 expected actions, $4 what
              local got act
              got=$(counter); act=$(actions)
              if [ "$(cat "work/rc.$1")" != 0 ]; then
                bad "$4: watchdog exited $(cat "work/rc.$1"): $(cat "work/out.$1")"
              elif [ "$got" != "$2" ]; then
                bad "$4: counter '$got', expected '$2': $(cat "work/out.$1")"
              elif [ "$act" != "$3" ]; then
                bad "$4: launchctl actions '$act', expected '$3': $(cat "work/out.$1")"
              else
                note "ok: $4"
              fi
            }

            export SHIM_JOB=running SHIM_QUEUE="" SHIM_KICKSTART_HANGS=0

            # --- a serving listener must be left alone -----------------------
            for code in 200 401; do
              reset_state
              pid=$(serve_code "$code"); sleep 1
              probe "ok$code"
              kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
              expect "ok$code" 0 "" "HTTP $code -> no action, counter reset"
            done

            # --- 503 is saturation: a real failure, not an answer ------------
            reset_state
            pid=$(serve_code 503); sleep 1
            probe busy
            kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
            expect busy 1 "" "HTTP 503 counted as a failure"

            # --- THE m3 REGRESSION: the host cannot reach its own overlay
            # address, but the socket is listening and draining. This must NOT
            # count — the original watchdog restarted a healthy daemon every
            # 10 minutes for exactly this.
            reset_state
            printf '2' > state/healthcheck/consecutive-failures
            SHIM_QUEUE="0/0/128" probe hairpin
            expect hairpin 0 "" "failed self-connect + listening socket with empty accept queue -> healthy"

            # --- THE m3 503 WEDGE: listener fine, handlers leaking -----------
            # Four workers of the serve pid (4242 in the launchctl shim) dead
            # for over an hour and never reaped: a failure even though the
            # socket drains. Two stale + one fresh zombie is below threshold.
            reset_state
            SHIM_QUEUE="0/0/128" \
              SHIM_PS='4242 Z 01:16:00\n4242 Z 58:50\n4242 Z 1-02:00:00\n4242 Z 12:00\n999 Z 99:00\n4242 S 80:00\n' \
              probe stuck_handlers
            expect stuck_handlers 1 "" "4 long-dead unreaped workers count as a failure despite a draining listener"
            reset_state
            SHIM_QUEUE="0/0/128" \
              SHIM_PS='4242 Z 01:16:00\n4242 Z 58:50\n4242 Z 00:05\n999 Z 99:00\n999 Z 99:00\n' \
              probe few_stuck
            expect few_stuck 0 "" "stale zombies below the threshold (and other parents' zombies) are tolerated"
            reset_state
            pid=$(serve_code 401); sleep 1
            SHIM_PS='4242 Z 01:16:00\n4242 Z 58:50\n4242 Z 1-02:00:00\n4242 Z 12:00\n' probe stuck_401
            kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
            expect stuck_401 1 "" "an answering daemon with leaked handlers still counts as a failure"

            # --- nothing listening at all ------------------------------------
            reset_state
            SHIM_QUEUE="" probe dead
            expect dead 1 "" "failed connect + no listening socket counted as a failure"

            # --- listening but not accepting (the wedge) ---------------------
            reset_state
            SHIM_QUEUE="7/0/128" probe backlog
            expect backlog 1 "" "failed connect + backed-up accept queue counted as a failure"

            # --- the counter must ACCUMULATE toward the threshold ------------
            reset_state
            probe d1; probe d2
            expect d2 2 "" "consecutive failures accumulate"

            # --- threshold, job running: kickstart -k ------------------------
            reset_state
            printf '2' > state/healthcheck/consecutive-failures
            probe kick
            expect kick 0 "kickstart -k system/org.metacraft-labs.vm-harness-serve;" "threshold on a running job -> kickstart -k"

            # --- threshold, kickstart hangs: bounded, then re-bootstrap ------
            reset_state
            printf '2' > state/healthcheck/consecutive-failures
            SHIM_KICKSTART_HANGS=1 probe hang
            expect hang 0 "kickstart -k system/org.metacraft-labs.vm-harness-serve;bootout system/org.metacraft-labs.vm-harness-serve;bootstrap system /Library/LaunchDaemons/org.metacraft-labs.vm-harness-serve.plist;" \
              "a kickstart that never returns is timed out and replaced by bootout + bootstrap"

            # --- THE m3 BOOT FAILURE: loaded, never spawned (EX_CONFIG) ------
            reset_state
            printf '2' > state/healthcheck/consecutive-failures
            SHIM_JOB=stuck probe stuck
            expect stuck 0 "bootout system/org.metacraft-labs.vm-harness-serve;bootstrap system /Library/LaunchDaemons/org.metacraft-labs.vm-harness-serve.plist;" \
              "a loaded-but-not-running job is re-bootstrapped, never kickstarted"

            # --- rate limit ---------------------------------------------------
            reset_state
            printf '2' > state/healthcheck/consecutive-failures
            date +%s > state/healthcheck/last-restart
            probe limited
            expect limited 3 "" "a second recovery inside minRestartIntervalSec is rate-limited"

            # --- a deliberately unloaded daemon is never "recovered" ---------
            reset_state
            printf '2' > state/healthcheck/consecutive-failures
            SHIM_JOB=unloaded probe unloaded
            expect unloaded 0 "" "unloaded job -> no action"

            if [ "$fail" -eq 0 ]; then
              echo "vmharness-serve-darwin-posture OK"
              touch $out
            else
              echo "vmharness-serve-darwin-posture FAILED" >&2
              exit 1
            fi
          '';
    };
}
