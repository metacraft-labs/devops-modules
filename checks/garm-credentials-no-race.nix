top@{ ... }:
{
  # Gate `t_garm_credentials_no_race` — garm.service must not carry the
  # systemd-documented credential race that produced 243/CREDENTIALS.
  #
  # ── THE INCIDENT ───────────────────────────────────────────────────────────
  #
  # garm.service died at startup with
  #   (garm)[PID]: garm.service: Failed to set up credentials: Protocol error
  #   (garm)[PID]: garm.service: Failed at step CREDENTIALS spawning …/garm: Protocol error
  #   systemd[1]: garm.service: Main process exited, code=exited, status=243/CREDENTIALS
  # 8 times on high-mem-server over three days, and 3 CONSECUTIVE times on
  # gpu-server-001 (a 3 min 36 s outage). `Restart=always` always got through
  # eventually, which is exactly why it survived so long unowned.
  #
  # ── WHAT IT WAS NOT ────────────────────────────────────────────────────────
  #
  # Not a missing or late credential source. `AssertPathExists=` on the exact
  # `LoadCredential` source paths was deployed and PASSED on all 8 occurrences —
  # the agenix symlink farm was fully materialised, the paths resolved, and the
  # READ still failed. Not activation-adjacent either: most occurrences follow a
  # health-watchdog restart hours after the last switch. So no ordering edge —
  # against agenix or anything else — could have fixed it.
  #
  # ── WHAT IT WAS ────────────────────────────────────────────────────────────
  #
  # systemd said so itself, once per start, in garm.service's own journal:
  #
  #   Service uses a combination of Type=simple, ExecStartPost=, and
  #   credentials. This could lead to race conditions. Continuing.
  #
  # With `Type=simple`, service_enter_start() forks the main process and
  # immediately calls service_enter_start_post() — for SERVICE_SIMPLE there is
  # no wait. The FU9 bind-verify ExecStartPost is therefore spawned while the
  # main child is still inside exec_child(), which runs exec_setup_credentials()
  # BEFORE the execve. Both then set up the same /run/credentials/garm.service —
  # the main one with EXEC_SETUP_CREDENTIALS_FRESH (umount the old store,
  # rebuild it, MS_MOVE it into place), the ExecStartPost one without — and the
  # loser dies at step CREDENTIALS. ("Protocol error" is not about protocols:
  # exec_setup_credentials() does the mount work in a
  # safe_fork("(sd-mkdcreds)", …|FORK_WAIT|…), and wait_for_terminate_and_check()
  # maps "that child exited non-zero" to -EPROTO. The underlying errno is logged
  # at LOG_DEBUG inside the child and never reaches the journal.)
  #
  # `Type=exec` makes systemd wait for the main process's execve before running
  # start-post, so the two credential setups can no longer overlap.
  #
  # ── HOW THIS GATE DISCRIMINATES ────────────────────────────────────────────
  #
  # Asserting `Type=exec` alone would be a tautology restating the diff. So:
  #
  #   * NOT VACUOUS. The gate first proves the unit under test really has all
  #     three legs of the dangerous triple — credentials AND an ExecStartPost —
  #     because with either leg missing there is nothing to race and a green
  #     result would mean nothing.
  #
  #   * THE NEGATIVE CONTROL IS THE DEFECT ITSELF. Node `racy` is the same
  #     configuration with `Type` forced back to `simple` — i.e. the module
  #     exactly as it shipped through the 8 failures. The gate asserts that
  #     systemd EMITS its race warning there, and that it does NOT on the fixed
  #     node. That warning is systemd's own detector for this exact
  #     combination (src/core/service.c service_verify(): SERVICE_SIMPLE &&
  #     exec_command[SERVICE_EXEC_START_POST] && exec_context_has_credentials),
  #     so it is a deterministic, upstream-authored discriminator rather than
  #     one this repo invented.
  #
  #   * THE SYMPTOM IS BOUNDED. Both nodes are restarted repeatedly with the
  #     credential store being torn down and rebuilt every time; the fixed node
  #     must reach zero 243/CREDENTIALS exits. The racy node's count is
  #     REPORTED, not asserted — see the next paragraph, which is the honest
  #     limit of this gate.
  #
  # ── THE CONTROL DOES LOSE THE RACE, JUST NOT ON DEMAND ─────────────────────
  #
  # The `racy` node has reproduced the production failure verbatim inside this
  # gate — same process, same two messages, same exit:
  #
  #   racy # (garm)[1574]: garm.service: Failed to set up credentials: Protocol error
  #   racy # (garm)[1574]: garm.service: Failed at step CREDENTIALS spawning …/garm: Protocol error
  #   racy # systemd[1]: garm.service: Main process exited, code=exited, status=243/CREDENTIALS
  #
  # Across four runs of otherwise identical nodes the control produced 0, 2, 10
  # and 0 such failure lines in 15 restarts; the fixed node produced 0 every time.
  # That spread is exactly why the control's count is PRINTED and not asserted —
  # a gate that required a race to be lost would be flaky in the other
  # direction. The deterministic assertion is on the CAUSE (systemd's own
  # detection of the combination); the count is the visible symptom.
  #
  # Two attempts to force it deterministically failed, recorded so nobody
  # spends the time again:
  #
  #   * ENLARGING the credentials (48 x 256 KiB) does not widen the window, it
  #     breaks setup outright: systemd caps the credential tmpfs at
  #     CREDENTIALS_TOTAL_SIZE_MAX (1 MiB), and overflowing it fails with the
  #     IDENTICAL `Failed to set up credentials: Protocol error` /
  #     243/CREDENTIALS signature — on BOTH nodes, for a reason with nothing to
  #     do with the race. (That the two are indistinguishable in the journal is
  #     itself the lesson: EPROTO here means only "the (sd-mkdcreds) helper
  #     child exited non-zero", so the message names no cause at all. Do not
  #     read a 243 as evidence of THIS race without checking which process and
  #     which step it came from.)
  #
  #   * SLOWING a credential source (an AF_UNIX `LoadCredential` source behind
  #     a 2 s responder, to park the main child mid-window) did not raise the
  #     rate either: 0 failures in 12 restarts on both nodes.
  #
  # The credential sources deliberately resolve through a symlink farm shaped
  # like agenix's (/run/gate-agenix -> /run/gate-agenix.d/1/…, materialised from
  # an ACTIVATION SCRIPT, no systemd unit), because that is the posture on all
  # three live hosts and it is what the earlier ordering hypothesis blamed.
  perSystem =
    {
      pkgs,
      lib,
      self',
      ...
    }:
    let
      flake = top.config.flake;

      secretsDir = "/run/gate-agenix";

      # agenix's activation-script mode, in miniature: a generation directory
      # plus an atomically-swapped symlink, populated before any unit starts and
      # with NO systemd unit to order against. The exact shape the 243s were
      # (wrongly) blamed on.
      fakeAgenix = {
        system.activationScripts.gateSecrets.text = ''
          mkdir -p /run/gate-agenix.d/1
          printf '%s' 'gate-jwt-secret-0123456789abcdef0123456789abcdef' \
            > /run/gate-agenix.d/1/jwt-secret
          printf '%s' 'gate-db-passphrase-0123456789abcdef0123456789ab' \
            > /run/gate-agenix.d/1/db-passphrase
          chmod 0400 /run/gate-agenix.d/1/*
          ln -sfT /run/gate-agenix.d/1 ${secretsDir}
        '';
      };

      baseNode =
        { ... }:
        {
          imports = [
            flake.modules.nixos.garm
            fakeAgenix
          ];
          environment.systemPackages = [ pkgs.curl ];

          services.garm = {
            enable = true;
            package = self'.packages.garm;
            apiServer = {
              bind = "0.0.0.0";
              port = 9997;
            };
            # The two legs that make this unit dangerous under Type=simple:
            #   (1) LoadCredential= sources ...
            jwtSecretFile = "${secretsDir}/jwt-secret";
            dbPassphraseFile = "${secretsDir}/db-passphrase";
            #   (2) ... and an ExecStartPost (FU9 bind-verify), on by default.
            healthcheck = {
              enable = true;
              startupBindVerify = true;
              startupBindTimeout = 30;
            };
          };
        };

      # How many times each node is restarted while counting credential
      # failures. Each restart tears down and rebuilds /run/credentials/garm.service.
      restarts = 15;

      # systemd's own detector for the defective combination.
      raceWarning = "Service uses a combination of Type=simple, ExecStartPost=, and credentials";
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_garm_credentials_no_race = pkgs.testers.nixosTest {
          name = "t_garm_credentials_no_race";

          nodes = {
            fixed = baseNode;

            # NEGATIVE CONTROL: the module exactly as it shipped through the 8
            # failures. One option differs.
            racy =
              { ... }:
              {
                imports = [ baseNode ];
                systemd.services.garm.serviceConfig.Type = lib.mkForce "simple";
              };
          };

          testScript = ''
            start_all()

            for m in (fixed, racy):
                m.wait_for_unit("multi-user.target")

            def restart_cycle(m):
                # `reset-failed` before every restart is NOT cosmetic. The loops
                # below restart as fast as the API rebinds, which is well inside
                # systemd's default start rate limit (5 starts / 10 s); without
                # the reset the unit lands in `start-limit-hit`, systemd stops
                # restarting it, and the next wait hangs until the test driver's
                # timeout. Observed exactly that on the CONTROL node, which
                # loses the race often enough to burn the whole budget in
                # seconds — so without this the gate would fail on the very
                # behaviour it exists to demonstrate. Resetting keeps these
                # loops measuring the credential race rather than systemd's
                # throttle.
                m.succeed("systemctl reset-failed garm.service || true")
                m.succeed("systemctl restart garm.service || true")
                m.wait_for_open_port(9997, timeout = 120)

            with subtest("the unit under test really carries the dangerous triple"):
                # If either leg were missing there would be nothing to race and
                # every assertion below would pass for the wrong reason.
                # `systemctl show -p LoadCredential` renders "[unprintable]", so
                # read the rendered unit itself.
                for m in (fixed, racy):
                    unit = m.succeed("systemctl cat garm.service")
                    creds = [l for l in unit.splitlines() if l.startswith("LoadCredential=")]
                    assert any("${secretsDir}/jwt-secret" in l for l in creds), f"LoadCredential={creds!r}"
                    assert any("${secretsDir}/db-passphrase" in l for l in creds), f"LoadCredential={creds!r}"
                    post = [l for l in unit.splitlines() if l.startswith("ExecStartPost=")]
                    assert any("garm-bind-verify" in l for l in post), f"ExecStartPost={post!r}"

                # ... and the credentials really resolve through an
                # agenix-shaped symlink farm with no unit behind it.
                fixed.succeed("test -L ${secretsDir}")
                fixed.fail("systemctl cat agenix-install-secrets.service")

            with subtest("garm.service is Type=exec (fixed) / Type=simple (control)"):
                unit_type = fixed.succeed("systemctl show -p Type --value garm.service").strip()
                assert unit_type == "exec", f"fixed node Type={unit_type!r}"
                unit_type = racy.succeed("systemctl show -p Type --value garm.service").strip()
                assert unit_type == "simple", f"negative control Type={unit_type!r}"

            # systemd emits the warning from service_verify(), i.e. every time
            # the unit fragment is LOADED. Force a load now rather than relying
            # on the boot-time one: at boot PID 1 logs before journald is
            # accepting, so the message is not indexed under the unit and
            # `journalctl -u garm.service` misses it. Grep the whole journal for
            # the unit-prefixed text instead (log_unit_warning prefixes the unit
            # id), which is what the live hosts show.
            for m in (fixed, racy):
                m.succeed("systemctl daemon-reload")

            with subtest("NEGATIVE CONTROL: systemd flags the racy combination by name"):
                # This is the discriminator the whole gate rests on — systemd's
                # own detector for exactly Type=simple + ExecStartPost= +
                # credentials. If it ever stops appearing, the assertion below
                # would pass vacuously, so failing HERE is the correct outcome.
                racy.succeed(
                    "journalctl --no-pager | grep -qF ${lib.escapeShellArg "garm.service: ${raceWarning}"}"
                )

            with subtest("the fixed unit does NOT carry that combination"):
                fixed.fail(
                    "journalctl --no-pager | grep -qF ${lib.escapeShellArg "garm.service: ${raceWarning}"}"
                )

            with subtest("both nodes start and serve"):
                for m in (fixed, racy):
                    restart_cycle(m)
                    m.wait_for_unit("garm.service")

            def credential_failures(m):
                out = m.succeed(
                    "journalctl -u garm.service --no-pager | "
                    "grep -c -e 243/CREDENTIALS -e 'Failed to set up credentials' || true"
                ).strip()
                return int(out or "0")

            with subtest("${toString restarts} restarts leave the fixed unit with zero 243/CREDENTIALS"):
                # Every restart tears the credential store down and rebuilds it,
                # which is the window the race lived in.
                for _ in range(${toString restarts}):
                    restart_cycle(fixed)
                failures = credential_failures(fixed)
                assert failures == 0, (
                    f"fixed node hit credential setup failures {failures} time(s) across "
                    "${toString restarts} restarts:\n"
                    + fixed.succeed(
                        "journalctl -u garm.service --no-pager | "
                        "grep -e 243/CREDENTIALS -e 'Failed to set up credentials' || true"
                    )
                )

            with subtest("the control's exposure is reported, never asserted"):
                # Deliberately NOT an assertion; see "THE CONTROL DOES LOSE THE
                # RACE" in the header, which records the observed spread. The
                # control does lose this race — just not on demand — so the
                # number is printed rather than made a pass condition.
                for _ in range(${toString restarts}):
                    restart_cycle(racy)
                print(
                    f"negative control: {credential_failures(racy)} credential-setup "
                    "failure line(s) across ${toString restarts} restarts under Type=simple"
                )
          '';
        };
      };
    };
}
