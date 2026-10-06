top@{ ... }:
{
  # Runner-Fleet-Capability-Pools-And-Remote-Driving campaign, milestone RE2.
  #
  # gate: t_central_garm_recovery
  #
  # Proves the RE2 recovery posture for the CENTRAL GARM (the Phase-B fleet SPOF):
  # killing the controller (1) makes the RE1 down-signal alert fire, (2) recovers
  # the controller within a bounded window via the fast declarative restart, and
  # (3) loses NO state — the DB-as-truth SQLite store survives the crash, and even
  # a DESTROYED DB is recoverable from the online backup. GARM re-queues nothing
  # itself; GitHub does — this gate proves the controller-side half: the process
  # comes back fast and reconciles a surviving DB.
  #
  # ONE VM, forge-less (the M0 boot — no [[github]], no scale sets), running THIS
  # flake's `services.garm` module with the RE2 `recovery` + `backup` blocks on.
  # No GitHub, no hypervisor — the DB state we protect is the first-run admin row,
  # an unambiguous DB-as-truth fact: POST /api/v1/first-run returns 200 on a fresh
  # DB and 409 ("already initialised") once the admin row exists. That 200-vs-409
  # is the hermetic no-data-loss oracle used throughout.
  #
  # ASSERTIONS:
  #   (1) ALERT INPUT fires (reuses the RE1 rule LIBRARY verbatim): promtool
  #       replays the exact down signal a killed controller produces —
  #       `up{job="garm"}==0` and `garm_health==0` — against the rendered RE1
  #       rules and asserts GarmControllerDown + GarmControllerUnhealthy fire.
  #   (2) FAST RESTART: SIGKILL the garm main process (a genuine crash); MEASURE
  #       the wall-clock from death to a re-bound serving API; assert it is within
  #       `recovery.targetRecoverySeconds`; assert the MainPID changed (a real
  #       restart, not a fluke) and the StartLimit window is the tuned RE2 one
  #       (systemd would otherwise drop the SPOF into a permanent `failed` state).
  #   (3) NO DATA LOSS across the crash: after recovery the DB still carries the
  #       admin (first-run == 409). A fresh DB would answer 200.
  #   (4) BACKUP is a real, integrity-checked restore point, and RESTORE recovers
  #       from TOTAL DB LOSS: take a snapshot; DESTROY the live DB and restart →
  #       first-run == 200 (state genuinely lost — the non-vacuity control); then
  #       `garm-db-restore <snapshot>` → first-run == 409 (state recovered from
  #       the backup, no data loss).
  perSystem =
    {
      config,
      pkgs,
      lib,
      self',
      ...
    }:
    let
      flake = top.config.flake;

      # The RE1 alert-rule LIBRARY, rendered at default thresholds — the SAME
      # store artifact checks/fleet-alerting.nix and infra's `just
      # check-alert-rules` consume. Reused verbatim so this gate cannot drift
      # from the rules that actually ship.
      alertRules = config.packages.garm-fleet-alert-rules;

      # promtool test: replay a killed controller's down signal and assert the two
      # RE1 controller alerts fire. Default thresholds: GarmControllerDown for=2m,
      # GarmControllerUnhealthy for=5m.
      recoveryAlertTest = pkgs.writeText "central-recovery-alerts.test.yml" ''
        rule_files:
          - garm-fleet-alerts.yml

        evaluation_interval: 1m

        tests:
          - interval: 1m
            name: 'a killed central GARM fires GarmControllerDown + GarmControllerUnhealthy'
            input_series:
              - series: 'up{job="garm", instance="central"}'
                values: '0x10'
              - series: 'garm_health{controller_id="central"}'
                values: '0x10'
            alert_rule_test:
              # for: windows not yet elapsed -> silent.
              - eval_time: 1m
                alertname: GarmControllerDown
                exp_alerts: []
              - eval_time: 3m
                alertname: GarmControllerUnhealthy
                exp_alerts: []
              # sustained down past both windows -> both page.
              - eval_time: 6m
                alertname: GarmControllerDown
                exp_alerts:
                  - exp_labels:
                      severity: critical
                      component: garm-fleet
                      job: garm
                      instance: central
                    exp_annotations:
                      summary: 'GARM controller unreachable (central)'
                      description: 'Prometheus cannot scrape GARM at central (job garm) for 2m. No runners can be created or reaped while the controller is down — check the garm.service unit and the host.'
              - eval_time: 6m
                alertname: GarmControllerUnhealthy
                exp_alerts:
                  - exp_labels:
                      severity: critical
                      component: garm-fleet
                      controller_id: central
                    exp_annotations:
                      summary: 'GARM controller reports unhealthy (central)'
                      description: 'garm_health for controller central has been 0 for 5m — the process is up but degraded. Check the garm.service journal.'
      '';

      # Test-friendly recovery + backup config: a short RTO budget and a fast
      # respawn, backup on a long timer (triggered manually so it never races the
      # DB-loss subtest).
      targetRTO = 30;
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_central_garm_recovery = pkgs.testers.nixosTest {
          name = "t_central_garm_recovery";

          nodes.central =
            { ... }:
            {
              imports = [ flake.modules.nixos.garm ];
              virtualisation.memorySize = 2048;
              environment.systemPackages = [
                self'.packages.garm
                pkgs.curl
                pkgs.jq
                pkgs.sqlite
                pkgs.prometheus.cli
              ];
              services.garm = {
                enable = true;
                package = self'.packages.garm;
                apiServer = {
                  bind = "0.0.0.0";
                  port = 9997;
                };
                recovery = {
                  enable = true;
                  restartSec = "2s";
                  # The tuned SPOF start-limit window (asserted below).
                  startLimitIntervalSec = "300s";
                  startLimitBurst = 50;
                  targetRecoverySeconds = targetRTO;
                };
                backup = {
                  enable = true;
                  # Long timer: the DB-loss subtest triggers backups manually, so
                  # an auto-run can never race the rm-DB step.
                  interval = "1h";
                  dir = "/var/backup/garm";
                  retain = 5;
                  compress = true;
                };
                # A frozen/killed garm's stop job must be quick so the restart
                # completes well inside the RTO.
                healthcheck.enable = false;
              };
            };

          testScript = ''
            import json, time

            target_rto = ${toString targetRTO}

            def first_run(node, user="admin"):
                # POST /api/v1/first-run: 200 on a FRESH DB (admin created), 409
                # once the admin row exists. The hermetic DB-as-truth oracle.
                body = json.dumps({
                    "username": user,
                    "email": f"{user}@example.invalid",
                    # GARM's first-run requires a zxcvbn score-4 password; a long
                    # high-entropy string with no dictionary words / leetspeak.
                    "password": "7k#Rq2wZx9mP4vL8nB6cD3fJ0aH5gT1yQ",
                })
                node.succeed(f"cat > /tmp/first-run.json <<'EOF'\n{body}\nEOF")
                return node.succeed(
                    "curl -s -o /dev/null -w '%{http_code}' "
                    "-X POST http://127.0.0.1:9997/api/v1/first-run "
                    "-H 'Content-Type: application/json' "
                    "-d @/tmp/first-run.json"
                ).strip()

            def api_bound(node):
                # curl exit 0 for ANY served HTTP status => listener bound.
                return node.execute(
                    "curl -s -o /dev/null --max-time 2 "
                    "http://127.0.0.1:9997/api/v1/controller-info"
                )[0] == 0

            def garm_pid(node):
                return node.succeed(
                    "systemctl show -p MainPID --value garm.service"
                ).strip()

            central.wait_for_unit("multi-user.target")
            central.wait_for_unit("garm.service")
            central.wait_for_open_port(9997)

            # --- (1) the RE1 down-signal alerts fire (rules reused verbatim) ---
            with subtest("RE1 GarmControllerDown + GarmControllerUnhealthy fire on the kill signal"):
                central.succeed("cp ${alertRules} /tmp/garm-fleet-alerts.yml")
                central.succeed("cp ${recoveryAlertTest} /tmp/central-recovery-alerts.test.yml")
                central.succeed(
                    "cd /tmp && promtool check rules garm-fleet-alerts.yml"
                )
                central.succeed(
                    "cd /tmp && promtool test rules central-recovery-alerts.test.yml"
                )

            # --- establish DB state: create the first-run admin ----------------
            with subtest("baseline: a fresh forge-less garm first-runs (200), then re-first-run is 409"):
                assert api_bound(central), "API not bound at baseline"
                code = first_run(central)
                assert code == "200", f"fresh first-run expected 200, got {code}"
                # The admin row is now persisted; a second first-run is a 409.
                code = first_run(central)
                assert code == "409", f"second first-run expected 409, got {code}"

            with subtest("the RE2 start-limit window is the tuned SPOF one"):
                iv = central.succeed(
                    "systemctl show -p StartLimitIntervalUSec --value garm.service"
                ).strip()
                burst = central.succeed(
                    "systemctl show -p StartLimitBurst --value garm.service"
                ).strip()
                # 300s = 300000000us (systemd renders it as e.g. "5min").
                assert iv in ("5min", "300000000"), f"StartLimitIntervalUSec={iv!r} (expected 300s)"
                assert burst == "50", f"StartLimitBurst={burst!r} (expected 50)"

            # --- (2) FAST RESTART: kill the controller, MEASURE recovery -------
            with subtest("SIGKILL the controller; it recovers within the RTO with a new PID"):
                old_pid = garm_pid(central)
                assert old_pid not in ("", "0"), "no MainPID before the crash"
                central.succeed(f"kill -9 {old_pid}")

                t0 = time.time()
                deadline = t0 + target_rto
                recovered = False
                while time.time() < deadline:
                    if api_bound(central) and garm_pid(central) not in ("", "0", old_pid):
                        recovered = True
                        break
                    time.sleep(0.5)
                elapsed = time.time() - t0
                assert recovered, (
                    f"central GARM did NOT recover a serving API within {target_rto}s (RTO breach)"
                )
                new_pid = garm_pid(central)
                assert new_pid not in ("", "0", old_pid), (
                    f"MainPID unchanged after the crash (was {old_pid}, now {new_pid}) — no real restart"
                )
                print(f"[recovery] central GARM recovered in {elapsed:.1f}s "
                      f"(RTO {target_rto}s), PID {old_pid} -> {new_pid}")

            # --- (3) NO DATA LOSS across the crash -----------------------------
            with subtest("the DB survived the crash: first-run is still 409"):
                central.wait_until_succeeds(
                    "curl -s -o /dev/null --max-time 2 "
                    "http://127.0.0.1:9997/api/v1/controller-info",
                    timeout=20,
                )
                code = first_run(central)
                assert code == "409", (
                    f"after the crash first-run expected 409 (admin survived), got {code} — DATA LOSS"
                )

            # --- (4) BACKUP + RESTORE recover from TOTAL DB LOSS ---------------
            with subtest("garm-db-backup writes an integrity-checked snapshot"):
                central.succeed("systemctl start garm-db-backup.service")
                snaps = central.succeed(
                    "ls -1 /var/backup/garm/garm-*.sqlite.gz 2>/dev/null | sort"
                ).split()
                assert len(snaps) >= 1, "no DB snapshot was written"
                snap = snaps[-1]
                # The snapshot decompresses to a well-formed, admin-bearing DB.
                central.succeed(
                    f"gzip -dc {snap} > /tmp/snap.sqlite && "
                    "sqlite3 /tmp/snap.sqlite 'PRAGMA integrity_check;' | grep -qx ok"
                )
                print(f"[backup] snapshot OK: {snap}")

            with subtest("NON-VACUITY: destroying the DB genuinely loses state (first-run 200)"):
                central.succeed("systemctl stop garm.service")
                central.succeed("rm -f /var/lib/garm/garm.sqlite /var/lib/garm/garm.sqlite-wal /var/lib/garm/garm.sqlite-shm")
                central.succeed("systemctl start garm.service")
                central.wait_for_open_port(9997)
                central.wait_until_succeeds(
                    "curl -s -o /dev/null --max-time 2 "
                    "http://127.0.0.1:9997/api/v1/controller-info",
                    timeout=30,
                )
                code = first_run(central)
                assert code == "200", (
                    f"a wiped DB should first-run fresh (200); got {code} — the DB-loss "
                    "control is vacuous"
                )

            with subtest("garm-db-restore recovers the admin from the backup (409 again)"):
                # Restore the pre-loss snapshot; the tool stops garm, swaps the DB
                # in, and restarts it.
                central.succeed(f"garm-db-restore {snap}")
                central.wait_for_open_port(9997)
                central.wait_until_succeeds(
                    "curl -s -o /dev/null --max-time 2 "
                    "http://127.0.0.1:9997/api/v1/controller-info",
                    timeout=30,
                )
                code = first_run(central)
                assert code == "409", (
                    f"after restore first-run expected 409 (admin recovered from backup), got {code}"
                )

            print("[t_central_garm_recovery] PASS")
          '';
        };
      };
    };
}
