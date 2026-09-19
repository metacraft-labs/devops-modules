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
  # Mock policy: the watchdog assertions RUN the real rendered script with
  # `curl` and `launchctl` replaced by shims that record their argv. Nothing
  # else is stubbed — the branching, the counter file and the rate limit are
  # the production code. Asserting on the script's TEXT instead would pass
  # against a script that reads correctly and behaves wrongly, which is the
  # specific failure this tier exists to catch.
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
            # ProgramArguments is a list; its head is the rendered script.
            healthScript = builtins.head healthJob.ProgramArguments;
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

            echo "== watchdog probe -> action =="
            mkdir -p work state

            # Stand a REAL responder at the probe URL rather than shimming curl.
            # `writeShellApplication` puts its own `runtimeInputs` curl first on
            # PATH, so a PATH shim is silently ignored — which is exactly how an
            # earlier revision of this check passed while asserting nothing.
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

            reset_state() { rm -rf "$PWD/state"; mkdir -p "$PWD/state"; }

            # Rewrite the baked-in state dir to a BUILD-LOCAL one. The script
            # resolves stateDir at nix-eval time, so a fixed absolute path is
            # unavoidable in the fixture — but a shared /tmp path leaks between
            # builds and is owned by whichever nix build user got there first.
            # Redirecting the copy keeps this hermetic while still running the
            # real script.
            sed "s#${fixtureStateDir}#$PWD/state#g" "$healthScript" > work/healthcheck
            chmod +x work/healthcheck
            healthScript="$PWD/work/healthcheck"

            probe() {  # $1 = label; runs one watchdog pass, records rc + output
              set +e
              sh "$healthScript" >"work/out.$1" 2>&1
              echo "$?" > "work/rc.$1"
              set -e
            }

            # --- a serving listener must be left alone -----------------------
            for code in 200 401; do
              reset_state
              pid=$(serve_code "$code"); sleep 1
              probe "ok$code"
              kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
              rc=$(cat "work/rc.ok$code")
              fails=$(cat $PWD/state/healthcheck/consecutive-failures 2>/dev/null || echo missing)
              if [ "$rc" != "0" ]; then
                bad "HTTP $code should be a clean no-op but exited $rc: $(cat "work/out.ok$code")"
              elif [ "$fails" != "0" ]; then
                bad "HTTP $code left the failure counter at '$fails', expected 0"
              else
                note "ok: HTTP $code -> exit 0, counter reset"
              fi
            done

            # --- 503 is saturation: a real failure, not an answer ------------
            reset_state
            pid=$(serve_code 503); sleep 1
            probe busy
            kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
            fails=$(cat $PWD/state/healthcheck/consecutive-failures 2>/dev/null || echo missing)
            if [ "$fails" = "1" ] && grep -qi "busy\|saturat" "work/out.busy"; then
              note "ok: HTTP 503 counted as a failure (counter=1)"
            else
              bad "HTTP 503 not counted as saturation (counter='$fails'): $(cat work/out.busy)"
            fi

            # --- no listener at all: the wedge signature ---------------------
            reset_state
            probe dead
            fails=$(cat $PWD/state/healthcheck/consecutive-failures 2>/dev/null || echo missing)
            if [ "$fails" = "1" ] && grep -qi "wedge signature\|did not answer" "work/out.dead"; then
              note "ok: no answer counted as a failure (counter=1)"
            else
              bad "an unreachable listener was not counted (counter='$fails'): $(cat work/out.dead)"
            fi

            # --- the counter must ACCUMULATE toward the threshold ------------
            # A watchdog that resets on every pass never reaches its threshold
            # and so never recovers anything.
            reset_state
            probe d1; probe d2
            fails=$(cat $PWD/state/healthcheck/consecutive-failures 2>/dev/null || echo missing)
            if [ "$fails" = "2" ]; then
              note "ok: consecutive failures accumulate (counter=2)"
            else
              bad "failure counter did not accumulate across probes (got '$fails')"
            fi

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
