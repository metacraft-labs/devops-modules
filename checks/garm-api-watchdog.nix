top@{ ... }:
{
  # FU9 GARM-API-WATCHDOG gate: t_garm_api_watchdog.
  #
  # Proves the health-check watchdog auto-recovers a GARM whose PROCESS is alive
  # but whose HTTP API on :9997 has gone dead — the exact failure mode observed
  # live on high-mem-server (garm up, pool managers running, API listener never
  # bound / stopped serving, process never exited, so Restart=always never
  # fired). systemd has no visibility into an internal API death; the periodic
  # health-check gives it that visibility.
  #
  # The fault we inject: SIGSTOP the garm main process. This is a FAITHFUL
  # stand-in for "process alive, API dead":
  #   * the process is FROZEN, so it accepts no connections — curl to :9997
  #     hangs/fails exactly like a dead listener (connection-refused/timeout);
  #   * systemd still reports garm.service ActiveState=active with the SAME
  #     MainPID — from Restart=always's point of view NOTHING is wrong (the
  #     main process has not exited), so absent the watchdog it stays dead
  #     forever;
  #   * the ONLY thing that recovers it is a `systemctl restart garm.service`,
  #     which is precisely what the watchdog issues after N consecutive failed
  #     probes. The restart reaps the frozen process (systemd's stop job sends
  #     SIGCONT+SIGTERM/SIGKILL) and spawns a FRESH garm that rebinds :9997.
  #
  # Two nodes prove NON-VACUITY without editing the module:
  #   * `withwatchdog`  — healthcheck.enable = true (default). Freeze garm →
  #     assert the watchdog restarts it (a NEW MainPID) and the API (401 =
  #     bound+serving) recovers. FAILS if the watchdog does nothing.
  #   * `nowatchdog`    — healthcheck.enable = false. Freeze garm → assert the
  #     API STAYS dead (no restart, same frozen MainPID) for the same window.
  #     This is the control: it demonstrates the fault genuinely wedges garm
  #     and that ONLY the watchdog recovers it. If the "API recovered"
  #     assertion could pass without the watchdog, this node would catch it.
  perSystem =
    {
      pkgs,
      lib,
      self',
      ...
    }:
    let
      flake = top.config.flake;

      # Short, test-friendly cadence: probe every 3s, restart after 2 consecutive
      # failures, allow a restart at most once per 15s. A frozen garm is thus
      # recovered within ~10s, well inside the test's poll budget, while the
      # rate-limit + consecutive-failure semantics are still exercised.
      commonGarm = {
        environment.systemPackages = [
          pkgs.curl
          self'.packages.garm
        ];
        services.garm = {
          enable = true;
          package = self'.packages.garm;
          apiServer = {
            bind = "0.0.0.0";
            port = 9997;
          };
        };
        # A frozen process is SIGKILLed by the stop job; keep that fast so a
        # watchdog restart completes quickly in the test.
        systemd.services.garm.serviceConfig.TimeoutStopSec = lib.mkForce "5s";
      };
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_garm_api_watchdog = pkgs.testers.nixosTest {
          name = "t_garm_api_watchdog";

          nodes.withwatchdog =
            { ... }:
            {
              imports = [ flake.modules.nixos.garm ];
              config = lib.mkMerge [
                commonGarm
                {
                  services.garm.healthcheck = {
                    enable = true;
                    interval = "3s";
                    failureThreshold = 2;
                    minRestartInterval = "15s";
                    probeTimeout = 2;
                    # Exercise the startup bind-verify too (default on).
                    startupBindVerify = true;
                    startupBindTimeout = 30;
                  };
                }
              ];
            };

          nodes.nowatchdog =
            { ... }:
            {
              imports = [ flake.modules.nixos.garm ];
              config = lib.mkMerge [
                commonGarm
                { services.garm.healthcheck.enable = false; }
              ];
            };

          testScript = ''
            import time

            def garm_pid(node):
                return node.succeed(
                    "systemctl show -p MainPID --value garm.service"
                ).strip()

            def api_up(node):
                # curl returns 0 for ANY HTTP status (401/409/200) => listener
                # is bound + serving. Non-zero => connection-refused/timeout.
                code = node.execute(
                    "curl -s -o /dev/null --max-time 2 "
                    "http://127.0.0.1:9997/api/v1/controller-info"
                )[0]
                return code == 0

            start_all()

            for node in (withwatchdog, nowatchdog):
                node.wait_for_unit("multi-user.target")
                node.wait_for_unit("garm.service")
                node.wait_for_open_port(9997)

            with subtest("the startup bind-verify ran and passed (ExecStartPost)"):
                # garm.service reached active with an ExecStartPost that only
                # succeeds once the API bound — so an active unit proves it.
                st = withwatchdog.succeed(
                    "systemctl show -p ActiveState --value garm.service"
                ).strip()
                assert st == "active", f"garm.service not active: {st!r}"
                withwatchdog.succeed(
                    "systemctl list-units --all 'garm-healthcheck.timer' "
                    "| grep -q garm-healthcheck.timer"
                )

            with subtest("baseline: the API is bound + serving on both nodes"):
                # A fresh, un-initialised garm answers 409 (init_required); a
                # first-run'd one answers 401 (auth). BOTH prove the listener is
                # up — which is exactly the watchdog's health criterion (curl
                # exit 0 for any HTTP status). Assert a served HTTP status.
                for node in (withwatchdog, nowatchdog):
                    code = node.succeed(
                        "curl -s -o /dev/null -w '%{http_code}' "
                        "http://127.0.0.1:9997/api/v1/controller-info"
                    ).strip()
                    assert code in ("200", "401", "409"), (
                        f"baseline controller-info={code!r} (expected a served status)"
                    )

            # ---- Inject the fault on BOTH nodes: freeze garm (process alive,
            #      API dead). SIGSTOP the whole service cgroup's main process.
            frozen_pid = {}
            for name, node in (("withwatchdog", withwatchdog), ("nowatchdog", nowatchdog)):
                pid = garm_pid(node)
                assert pid not in ("", "0"), f"{name}: no MainPID"
                frozen_pid[name] = pid
                node.succeed(f"kill -STOP {pid}")

            with subtest("the frozen garm's API is dead but the process is still 'active'"):
                for name, node in (("withwatchdog", withwatchdog), ("nowatchdog", nowatchdog)):
                    # Give it a moment; a frozen listener no longer answers.
                    node.wait_until_fails(
                        "curl -s -o /dev/null --max-time 2 "
                        "http://127.0.0.1:9997/api/v1/controller-info",
                        timeout=20,
                    )
                    st = node.succeed(
                        "systemctl show -p ActiveState --value garm.service"
                    ).strip()
                    assert st == "active", (
                        f"{name}: frozen garm.service ActiveState={st!r} "
                        "(expected active — Restart=always cannot see the dead API)"
                    )

            with subtest("WITHOUT the watchdog the API STAYS dead (control / non-vacuity)"):
                # No watchdog: nothing restarts garm. Same frozen MainPID, API
                # refused, for the full window the watchdog would have acted in.
                deadline = time.time() + 25
                while time.time() < deadline:
                    assert not api_up(nowatchdog), (
                        "nowatchdog: API recovered without a watchdog — the fault "
                        "did not wedge garm, so the recovery test would be vacuous"
                    )
                    time.sleep(2)
                assert garm_pid(nowatchdog) == frozen_pid["nowatchdog"], (
                    "nowatchdog: MainPID changed with no watchdog — unexpected restart"
                )
                # Recover the control node so it does not leave a wedged unit.
                nowatchdog.succeed(f"kill -CONT {frozen_pid['nowatchdog']} || true")
                nowatchdog.succeed("systemctl restart garm.service")

            with subtest("WITH the watchdog the API RECOVERS via an automatic restart"):
                # The health-check probes every 3s and restarts after 2 failures.
                # Poll for the API to come back AND the MainPID to change (proving
                # a genuine restart, not a fluke unfreeze).
                withwatchdog.wait_until_succeeds(
                    "curl -s -o /dev/null --max-time 2 "
                    "http://127.0.0.1:9997/api/v1/controller-info",
                    timeout=60,
                )
                new_pid = garm_pid(withwatchdog)
                assert new_pid not in ("", "0"), "withwatchdog: no MainPID after recovery"
                assert new_pid != frozen_pid["withwatchdog"], (
                    "withwatchdog: MainPID unchanged — the API came back WITHOUT a "
                    f"restart (was {frozen_pid['withwatchdog']}, now {new_pid})"
                )
                # The recovered API serves an HTTP status again (bound listener).
                code = withwatchdog.succeed(
                    "curl -s -o /dev/null -w '%{http_code}' "
                    "http://127.0.0.1:9997/api/v1/controller-info"
                ).strip()
                assert code in ("200", "401", "409"), (
                    f"recovered controller-info={code!r} (expected a served status)"
                )

            with subtest("the watchdog logged the recovery"):
                withwatchdog.succeed(
                    "journalctl -u garm-healthcheck.service | "
                    "grep -q 'restarting garm.service'"
                )

            with subtest("the failure counter reset to 0 after recovery"):
                # After a healthy probe the persisted counter is 0 again. The
                # watchdog deliberately owns a private StateDirectory; reading
                # garm's StateDirectory here would miss the file and regress the
                # permission boundary that prevents the root-run oneshot from
                # re-chowning GARM's SQLite state.
                withwatchdog.wait_until_succeeds(
                    "test \"$(cat /var/lib/garm-healthcheck/healthcheck-consecutive-failures)\" = 0",
                    timeout=15,
                )
          '';
        };
      };
    };
}
