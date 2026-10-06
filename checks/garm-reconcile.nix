top@{ ... }:
{
  # Declarative GARM Reconcile — the KEY gate: t_garm_reconcile.
  #
  # Boots a NixOS VM with `services.garm` + the reconcile oneshot
  # (`services.garm.reconcile.enable`) + declared `github` credentials, orgs
  # (derived from scale sets), and `scaleSets`, pointed at an IN-VM MOCK GITHUB
  # API that serves ONLY the management endpoints garm-cli drives when creating
  # a runner scale set:
  #
  #   App auth (ghinstallation transport):
  #     POST /app/installations/{id}/access_tokens   -> installation token
  #   Org + runner-group + registration-token:
  #     GET  /orgs/{org}                              -> org object
  #     GET  /orgs/{org}/actions/runner-groups        -> [{Default,id:1}]
  #     POST /orgs/{org}/actions/runners/registration-token -> reg token
  #   ADO runner-scale-set protocol (what actually creates the scale set):
  #     POST /actions/runner-registration             -> {url:<ado>, token:<jwt>}
  #     GET  <ado>/_apis/runtime/runnerscalesets?...  -> {count, value:[...]}
  #     POST <ado>/_apis/runtime/runnerscalesets      -> created scale set + id
  #     DELETE <ado>/_apis/runtime/runnerscalesets/{id}
  #
  # The mock is stateful for scale sets (an in-memory registry keyed by name)
  # so GARM's create/list/delete against GitHub round-trip correctly — GARM's
  # OWN DB then mirrors that. It does NOT run a real runner picking up a job
  # (that is the live e2e, out of scope here) — only the management API.
  #
  # Assertions (the milestone's a–e):
  #   (a0) STARTUP-RESTART — force GARM's first post-start check to fail;
  #                 systemd restarts GARM while reconcile's own readiness loop
  #                 spans the gap and still converges successfully.
  #   (a) APPLY   — after activation the reconcile ran and GARM's DB holds
  #                 EXACTLY the declared orgs/creds/scale-sets (garm-cli list).
  #   (b) IDEMPOTENT — a SECOND `systemctl start garm-reconcile` makes ZERO
  #                 changes (the DB is byte-identical: same ids, same counts).
  #   (c) DRIFT   — mutate the DB (garm-cli scaleset update to a wrong
  #                 maxRunners) → re-run the oneshot → declared state restored.
  #   (d) PRUNE ON — add an EXTRA scale set to the DB then re-run with the
  #                 prune flag ON → the extra is removed.
  #   (e) PRUNE OFF (default) — an extra unmanaged scale set is LEFT ALONE.
  #
  # (d)/(e) use TWO nodes (prune off = the default node; prune on = a second
  # node) so both postures are proven from a clean declared baseline.
  perSystem =
    {
      pkgs,
      lib,
      self',
      ...
    }:
    let
      flake = top.config.flake;

      # A throwaway App PEM (NOT a real key — the mock never verifies the JWT
      # signature, it only needs a parseable RSA key so ghinstallation can mint
      # the client-assertion JWT). Generated at test build time.
      appPem = pkgs.runCommand "garm-reconcile-test-app.pem" { nativeBuildInputs = [ pkgs.openssl ]; } ''
        openssl genrsa -traditional 2048 > $out
      '';

      mockPort = 8099;

      # ---- The mock GitHub management API (stdlib http.server) --------------
      mockGithub = pkgs.writeText "mock-github.py" ''
        import json, time, threading, base64, uuid
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

        PORT = ${toString mockPort}
        LOCK = threading.Lock()
        # In-memory runner-scale-set registry, keyed by name -> full object.
        SCALESETS = {}
        NEXT_ID = [1000]

        def now_plus(secs):
            return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + secs))

        def _b64(obj):
            return base64.urlsafe_b64encode(json.dumps(obj).encode()).rstrip(b"=").decode()

        def fake_jwt(ttl=3600):
            # Unsigned JWT (GARM parses it with ParseUnverified — signature is
            # never checked). Carries a far-future exp so the message-session
            # never needs a refresh during the test.
            hdr = _b64({"alg": "none", "typ": "JWT"})
            pl = _b64({"exp": int(time.time()) + ttl, "iat": int(time.time())})
            return "%s.%s." % (hdr, pl)

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _send(self, code, obj):
                body = json.dumps(obj).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def _read(self):
                n = int(self.headers.get("Content-Length", "0") or "0")
                if n == 0:
                    return {}
                raw = self.rfile.read(n)
                try:
                    return json.loads(raw)
                except Exception:
                    return {}

            def do_GET(self):
                p = self.path.split("?")[0]
                # Org lookup.
                if p.startswith("/orgs/") and p.count("/") == 2:
                    org = p.split("/")[2]
                    return self._send(200, {"login": org, "id": 42, "url": "http://127.0.0.1:%d%s" % (PORT, p)})
                # Runner groups (GetEntityRunnerGroupIDByName -> "Default").
                if p.startswith("/orgs/") and p.endswith("/actions/runner-groups"):
                    return self._send(200, {"total_count": 1, "runner_groups": [
                        {"id": 1, "name": "Default", "default": True, "visibility": "all"}]})
                # ADO: list runner scale sets (by name/runnerGroupId).
                if p.endswith("/_apis/runtime/runnerscalesets"):
                    from urllib.parse import urlparse, parse_qs
                    q = parse_qs(urlparse(self.path).query)
                    name = (q.get("name") or [""])[0]
                    with LOCK:
                        if name and name in SCALESETS:
                            return self._send(200, {"count": 1, "value": [SCALESETS[name]]})
                        return self._send(200, {"count": 0, "value": []})
                # ADO: long-poll the message queue — block briefly, return no
                # message (keeps GARM's scale-set listener alive without a real
                # runner/job). GARM treats a 200 with an empty/So-far body or a
                # timeout as "no messages".
                if "/messages" in p or "/ado/mq" in p:
                    time.sleep(2)
                    # 202 Accepted == "no messages available" (GARM treats this
                    # as an empty long-poll and loops — no job is ever handed
                    # out, keeping this a management-API-only gate).
                    self.send_response(202)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                # ADO: get scale set by id (…/runnerscalesets/<id>, NOT a
                # sub-resource like …/<id>/sessions).
                if "/_apis/runtime/runnerscalesets/" in p:
                    tail = p.split("/_apis/runtime/runnerscalesets/", 1)[1]
                    if tail.isdigit():
                        sid = int(tail)
                        with LOCK:
                            for v in SCALESETS.values():
                                if v["id"] == sid:
                                    return self._send(200, v)
                        return self._send(404, {"message": "not found"})
                if p == "/app":
                    return self._send(200, {"id": 1, "slug": "mock-app"})
                return self._send(200, {})

            def do_POST(self):
                p = self.path.split("?")[0]
                # App installation token.
                if p.startswith("/app/installations/") and p.endswith("/access_tokens"):
                    return self._send(201, {"token": "ghs_mock_installation_token",
                                            "expires_at": now_plus(3600),
                                            "permissions": {"actions": "write", "organization_self_hosted_runners": "write"}})
                # Runner registration token (org).
                if p.endswith("/actions/runners/registration-token"):
                    return self._send(201, {"token": "mock_reg_token", "expires_at": now_plus(3600)})
                # ADO service admin info: hand back OUR OWN base as the pipeline URL.
                if p == "/actions/runner-registration":
                    return self._send(200, {"url": "http://127.0.0.1:%d/ado" % PORT,
                                            "token": "mock_ado_jwt"})
                # ADO: create a message session for a scale set. GARM's
                # scale-set LISTENER (a background goroutine) opens this right
                # after the scale set exists; if the session is incomplete GARM
                # panics on a nil SessionID. Return a COMPLETE session (uuid +
                # message-queue url + a far-future unsigned JWT + the scale set)
                # so the listener stays alive — long-polling our /messages
                # endpoint, which never yields a job (management-API-only gate).
                if "/_apis/runtime/runnerscalesets/" in p and p.endswith("/sessions"):
                    mid = p.split("/_apis/runtime/runnerscalesets/", 1)[1].split("/")[0]
                    sset = None
                    if mid.isdigit():
                        with LOCK:
                            for v in SCALESETS.values():
                                if v["id"] == int(mid):
                                    sset = v
                    return self._send(200, {
                        "sessionId": str(uuid.uuid4()),
                        "ownerName": "garm",
                        "runnerScaleSet": sset,
                        "messageQueueUrl": "http://127.0.0.1:%d/ado/mq" % PORT,
                        "messageQueueAccessToken": fake_jwt(),
                        "statistics": {},
                    })
                # ADO: create a runner scale set.
                if p.endswith("/_apis/runtime/runnerscalesets"):
                    body = self._read()
                    name = body.get("name", "unknown")
                    with LOCK:
                        if name in SCALESETS:
                            obj = SCALESETS[name]
                        else:
                            sid = NEXT_ID[0]; NEXT_ID[0] += 1
                            obj = {
                                "id": sid,
                                "name": name,
                                "runnerGroupId": body.get("runnerGroupId", 1),
                                "runnerGroupName": "Default",
                                "labels": body.get("labels", []),
                                "enabled": body.get("enabled", True),
                                "runnerSetting": body.get("RunnerSetting", {}),
                                "runnerJitConfigUrl": "http://127.0.0.1:%d/ado/jit" % PORT,
                            }
                            SCALESETS[name] = obj
                    return self._send(200, obj)
                if p == "/status" or p == "/system-info/":
                    return self._send(200, {})
                return self._send(200, {})

            def do_PATCH(self):
                p = self.path.split("?")[0]
                # ADO: refresh a message session — return a fresh JWT + the same
                # session shape (keeps the listener's token alive).
                if "/sessions/" in p:
                    return self._send(200, {
                        "sessionId": p.rstrip("/").rsplit("/", 1)[1],
                        "ownerName": "garm",
                        "messageQueueUrl": "http://127.0.0.1:%d/ado/mq" % PORT,
                        "messageQueueAccessToken": fake_jwt(),
                    })
                return self._send(200, {})

            def do_DELETE(self):
                p = self.path.split("?")[0]
                # Session delete (…/sessions/<uuid>) — just ack.
                if "/sessions/" in p:
                    return self._send(204, {})
                # Scale-set delete (…/runnerscalesets/<id>).
                if "/_apis/runtime/runnerscalesets/" in p:
                    tail = p.split("/_apis/runtime/runnerscalesets/", 1)[1]
                    if tail.isdigit():
                        sid = int(tail)
                        with LOCK:
                            for k, v in list(SCALESETS.items()):
                                if v["id"] == sid:
                                    del SCALESETS[k]
                    return self._send(204, {})
                return self._send(204, {})

        ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
      '';

      # A KNOWN admin password (zxcvbn score 4) for the adopt-existing node, so
      # the test can drive garm-cli directly (first-run + login) to pre-populate
      # the DB BEFORE the reconcile ever runs. Only used by the adopt node.
      adminPw = "correct-horse-battery-staple-9!";
      adminPwFile = pkgs.writeText "garm-reconcile-admin-pw" adminPw;

      # Deterministically exercise the production startup recovery contract on
      # one node. The first ExecStartPost fails after the GARM process launches;
      # Restart=always then starts it again and this check succeeds thereafter.
      failInitialGarmStartOnce = pkgs.writeShellScript "garm-test-fail-initial-start-once" ''
        marker=/var/lib/garm/test-failed-initial-start
        if [ ! -e "$marker" ]; then
          : > "$marker"
          echo "garm-test: deliberately failing first post-start check"
          exit 1
        fi
      '';

      # Common node config: garm + reconcile pointed at the mock endpoint.
      mkNode =
        {
          pruneUnmanaged,
          failInitialGarmStart ? false,
          # When true the reconcile oneshot is NOT wanted by multi-user.target
          # (it does not auto-run at boot) and a KNOWN admin password is staged,
          # so the test can pre-populate GARM's DB by hand and then start the
          # reconcile explicitly to prove it ADOPTS the pre-existing entities.
          adoptExisting ? false,
        }:
        { lib, ... }:
        {
          imports = [ flake.modules.nixos.garm ];
          environment.systemPackages = [
            pkgs.curl
            pkgs.jq
            self'.packages.garm
            (pkgs.python3.withPackages (_: [ ]))
          ];

          # Run the mock GitHub API as a system service.
          systemd.services.mock-github = {
            description = "Mock GitHub management API for the garm reconcile gate";
            wantedBy = [ "multi-user.target" ];
            before = [ "garm-reconcile.service" ];
            serviceConfig = {
              ExecStart = "${pkgs.python3}/bin/python3 ${mockGithub}";
              Restart = "always";
            };
          };

          # Adopt node: keep the reconcile oneshot from auto-running at boot so
          # the test can pre-populate the DB by hand FIRST, then trigger the
          # reconcile explicitly to prove it treats the pre-existing entities as
          # a no-op (mirrors the live high-mem-server case: EXP2/3/4 state was
          # created outside the reconcile).
          systemd.services.garm-reconcile.wantedBy = lib.mkIf adoptExisting (lib.mkForce [ ]);

          # The reconcile must survive GARM's supported Restart=always path. Put
          # the fail-once hook before the real API bind verification so the
          # second start still proves the production post-start check.
          systemd.services.garm.serviceConfig.ExecStartPost = lib.mkIf failInitialGarmStart (
            lib.mkBefore [ failInitialGarmStartOnce ]
          );

          services.garm = {
            enable = true;
            package = self'.packages.garm;
            apiServer = {
              bind = "0.0.0.0";
              port = 9997;
            };

            reconcile = {
              enable = true;
              inherit pruneUnmanaged;
              # Point GARM at the mock via a custom forge endpoint.
              forgeEndpoint = "mock-github";
              apiBaseURL = "http://127.0.0.1:${toString mockPort}";
              baseURL = "http://127.0.0.1:${toString mockPort}";
              # Adopt node: pin a known admin password so the test can log in +
              # pre-populate the DB before the (manually-triggered) reconcile.
              adminPasswordFile = lib.mkIf adoptExisting adminPwFile;
            };

            github.mcl-app = {
              appId = 111;
              installationId = 222;
              appKeyFile = appPem;
            };

            # A dummy provider (no real hypervisor needed — the reconcile only
            # NAMES the provider when creating the scale set; GARM stores the
            # provider name from config.toml, no provider daemon is contacted
            # for a create/list/delete operation). Use a vm-harness-run backend
            # (qemu-windows-arm) so the module's sandbox posture adds NO
            # supplementary groups (libvirtd/kvm/incus-admin), which would need
            # their host daemons enabled just to exist. This keeps the node a
            # pure garm+reconcile boot with the strict sandbox.
            providers.vmharness = {
              backend = "qemu-windows-arm";
              vmHarnessPath = "/nonexistent/vm-harness";
              stateDir = "/var/lib/garm-provider-vmharness";
              images.linux-runner.sourceImage = "/nonexistent/golden";
            };

            scaleSets.incus = {
              provider = "vmharness";
              org = "metacraft-labs";
              credentials = "mcl-app";
              image = "linux-runner";
              osType = "linux";
              maxRunners = 4;
              minIdleRunners = 0;
              scaleSetName = "incus";
            };

            # A DECLARED-DISABLED scale set: proves the reconcile emits
            # `--enabled=false` on create (the latent `enabled_flag=""` bug let
            # a declared-disabled set come up enabled). Same managed org, a
            # distinct GARM-side name.
            scaleSets.incus-disabled = {
              provider = "vmharness";
              org = "metacraft-labs";
              credentials = "mcl-app";
              image = "linux-runner";
              osType = "linux";
              maxRunners = 2;
              minIdleRunners = 0;
              enabled = false;
              scaleSetName = "incus-disabled";
            };
          };
        };
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_garm_reconcile = pkgs.testers.nixosTest {
          name = "t_garm_reconcile";

          nodes.pruneoff = mkNode { pruneUnmanaged = false; };
          nodes.pruneon = mkNode {
            pruneUnmanaged = true;
            failInitialGarmStart = true;
          };
          nodes.adopt = mkNode {
            pruneUnmanaged = false;
            adoptExisting = true;
          };

          testScript = ''
            start_all()
            import json as J

            def gcli(node, args):
                # Run garm-cli as the garm user (shares HOME + the logged-in
                # reconcile profile) and return JSON stdout.
                return node.succeed(
                    f"sudo -u garm env HOME=/var/lib/garm garm-cli --format json {args}"
                )

            def org_id(node, name):
                orgs = J.loads(gcli(node, f"organization list --name {name}"))
                for o in orgs:
                    if o.get("name") == name:
                        return o["id"]
                raise Exception(f"org {name} not found")

            def scaleset_by_name(node, oid, name):
                for s in J.loads(gcli(node, f"scaleset list --org {oid}")):
                    if s.get("name") == name:
                        return s
                return None

            for node in (pruneoff, pruneon):
                node.wait_for_unit("multi-user.target")
                node.wait_for_unit("mock-github.service")
                node.wait_for_unit("garm.service")
                node.wait_for_open_port(${toString mockPort})
                node.wait_for_open_port(9997)
                # A failed initial GARM bind verification is recovered by
                # Restart=always. Reconcile must wait through that recovery,
                # rather than inherit a permanent dependency failure.
                wants = node.succeed(
                    "systemctl show garm-reconcile.service -p Wants --value"
                ).split()
                requires = node.succeed(
                    "systemctl show garm-reconcile.service -p Requires --value"
                ).split()
                assert "garm.service" in wants, f"reconcile does not want GARM: {wants}"
                assert "garm.service" not in requires, \
                    f"reconcile still hard-requires GARM and cannot span a startup restart: {requires}"
                # The reconcile oneshot is wanted by multi-user.target.
                node.wait_for_unit("garm-reconcile.service")

            with subtest("(a0) STARTUP-RESTART: reconcile spans GARM's recovered first start"):
                pruneon.succeed("test -e /var/lib/garm/test-failed-initial-start")
                injected_failures = int(pruneon.succeed(
                    "journalctl -u garm.service --no-pager "
                    "| grep -c 'garm-test: deliberately failing first post-start check'"
                ).strip())
                assert injected_failures == 1, \
                    f"expected exactly one injected GARM start failure, got {injected_failures}"
                restarts = int(pruneon.succeed(
                    "systemctl show garm.service -p NRestarts --value"
                ).strip())
                assert restarts >= 1, f"GARM did not take Restart=always path: {restarts}"
                assert pruneon.succeed("systemctl is-active garm.service").strip() == "active"
                assert pruneon.succeed(
                    "systemctl show garm.service -p Result --value"
                ).strip() == "success"
                assert pruneon.succeed(
                    "systemctl is-active garm-reconcile.service"
                ).strip() == "active"
                assert pruneon.succeed(
                    "systemctl show garm-reconcile.service -p Result --value"
                ).strip() == "success"

                reconcile_started = int(pruneon.succeed(
                    "systemctl show garm-reconcile.service "
                    "-p ExecMainStartTimestampMonotonic --value"
                ).strip())
                garm_active = int(pruneon.succeed(
                    "systemctl show garm.service -p ActiveEnterTimestampMonotonic --value"
                ).strip())
                assert 0 < reconcile_started < garm_active, \
                    f"reconcile did not span GARM restart: reconcile={reconcile_started}, garm={garm_active}"

                startup_journal = pruneon.succeed(
                    "journalctl -u garm-reconcile.service --no-pager"
                )
                assert "controller API ready" in startup_journal, startup_journal
                assert "reconcile complete" in startup_journal, startup_journal

            with subtest("(a) APPLY: reconcile created the declared cred/org/scale-set"):
                for node in (pruneoff, pruneon):
                    creds = J.loads(gcli(node, "github credentials list"))
                    names = [c.get("name") for c in creds]
                    assert "mcl-app" in names, f"mcl-app credential missing: {names}"

                    oid = org_id(node, "metacraft-labs")
                    ss = scaleset_by_name(node, oid, "incus")
                    assert ss is not None, "scale set 'incus' was not created"
                    assert ss["max_runners"] == 4, f"maxRunners drift on create: {ss}"
                    assert ss.get("enabled", False) is True, f"declared-enabled scale set came up disabled: {ss}"
                    # Exactly the two declared scale sets in the managed org.
                    allss = J.loads(gcli(node, f"scaleset list --org {oid}"))
                    assert len(allss) == 2, f"expected exactly 2 scale sets, got {allss}"

            with subtest("(a2) ENABLED=FALSE: a declared-disabled scale set ends up disabled"):
                for node in (pruneoff, pruneon):
                    oid = org_id(node, "metacraft-labs")
                    dss = scaleset_by_name(node, oid, "incus-disabled")
                    assert dss is not None, "declared-disabled scale set 'incus-disabled' missing"
                    assert dss.get("enabled", False) is False, \
                        f"declared enabled=false scale set is ENABLED (enabled_flag bug): {dss}"

            with subtest("(b) IDEMPOTENT: a second reconcile run makes zero changes"):
                node = pruneoff
                oid = org_id(node, "metacraft-labs")
                before_id = scaleset_by_name(node, oid, "incus")["id"]
                before_ct = len(J.loads(gcli(node, f"scaleset list --org {oid}")))
                creds_before = gcli(node, "github credentials list")
                # Re-run the oneshot.
                node.systemctl("restart garm-reconcile.service")
                node.wait_for_unit("garm-reconcile.service")
                after = J.loads(gcli(node, f"scaleset list --org {oid}"))
                assert len(after) == before_ct == 2, f"idempotency broke count: {after}"
                incus_after = scaleset_by_name(node, oid, "incus")
                assert incus_after["id"] == before_id, "idempotency changed the scale-set id"
                assert incus_after["max_runners"] == 4, "idempotency changed maxRunners"
                creds_after = gcli(node, "github credentials list")
                assert J.loads(creds_before) == J.loads(creds_after), "idempotency changed credentials"

            with subtest("(c) DRIFT: mutate the DB, re-run, declared state restored"):
                node = pruneoff
                oid = org_id(node, "metacraft-labs")
                sid = scaleset_by_name(node, oid, "incus")["id"]
                # Drive the DB away from declared (maxRunners 4 -> 9).
                node.succeed(
                    "sudo -u garm env HOME=/var/lib/garm garm-cli scaleset update "
                    f"{sid} --name incus --image linux-runner --enabled "
                    "--min-idle-runners 0 --max-runners 9 --os-type linux --os-arch amd64 "
                    "--runner-bootstrap-timeout 20"
                )
                drifted = scaleset_by_name(node, oid, "incus")
                assert drifted["max_runners"] == 9, f"drift setup failed: {drifted}"
                # Reconcile must restore it.
                node.systemctl("restart garm-reconcile.service")
                node.wait_for_unit("garm-reconcile.service")
                fixed = scaleset_by_name(node, oid, "incus")
                assert fixed["max_runners"] == 4, f"drift not corrected: {fixed}"
                assert fixed["id"] == sid, "drift-correct recreated (should update in place)"

            with subtest("(e) PRUNE OFF (default): an unmanaged scale set is LEFT ALONE"):
                node = pruneoff
                oid = org_id(node, "metacraft-labs")
                # Add an EXTRA (undeclared) scale set directly via garm-cli.
                node.succeed(
                    "sudo -u garm env HOME=/var/lib/garm garm-cli scaleset add "
                    f"--org {oid} --provider-name vmharness --image linux-runner "
                    "--name extra-unmanaged --flavor default --enabled "
                    "--min-idle-runners 0 --max-runners 1 --os-type linux --os-arch amd64 "
                    "--runner-bootstrap-timeout 20"
                )
                assert scaleset_by_name(node, oid, "extra-unmanaged") is not None
                node.systemctl("restart garm-reconcile.service")
                node.wait_for_unit("garm-reconcile.service")
                # Prune is OFF here: the extra must SURVIVE.
                assert scaleset_by_name(node, oid, "extra-unmanaged") is not None, \
                    "prune-off deleted an unmanaged scale set"
                assert scaleset_by_name(node, oid, "incus") is not None, \
                    "prune-off deleted the declared scale set"

            with subtest("(d) PRUNE ON: an undeclared scale set in a managed org is removed"):
                node = pruneon
                oid = org_id(node, "metacraft-labs")
                node.succeed(
                    "sudo -u garm env HOME=/var/lib/garm garm-cli scaleset add "
                    f"--org {oid} --provider-name vmharness --image linux-runner "
                    "--name extra-unmanaged --flavor default --enabled "
                    "--min-idle-runners 0 --max-runners 1 --os-type linux --os-arch amd64 "
                    "--runner-bootstrap-timeout 20"
                )
                assert scaleset_by_name(node, oid, "extra-unmanaged") is not None
                node.systemctl("restart garm-reconcile.service")
                node.wait_for_unit("garm-reconcile.service")
                # Prune is ON: the extra must be GONE, the declared one KEPT.
                assert scaleset_by_name(node, oid, "extra-unmanaged") is None, \
                    "prune-on did NOT remove the undeclared scale set"
                assert scaleset_by_name(node, oid, "incus") is not None, \
                    "prune-on removed the declared scale set"

            with subtest("(f) ADOPT-EXISTING: pre-populated DB is a NO-OP for the reconcile"):
                # Mirrors the live high-mem-server case: EXP2/3/4 created the
                # orgs/creds/scale-sets DIRECTLY via garm-cli, OUTSIDE the
                # reconcile. Here the reconcile oneshot does NOT auto-run at boot
                # (wantedBy forced empty on the adopt node); the test first
                # builds the exact declared state by hand, THEN triggers the
                # reconcile and asserts it changes NOTHING (same ids, same count,
                # same enabled flags) — i.e. it adopts rather than recreates.
                node = adopt
                pw = "correct-horse-battery-staple-9!"

                node.wait_for_unit("multi-user.target")
                node.wait_for_unit("mock-github.service")
                node.wait_for_unit("garm.service")
                node.wait_for_open_port(${toString mockPort})
                node.wait_for_open_port(9997)
                # The reconcile must NOT have run at boot on this node.
                assert "inactive" in node.succeed(
                    "systemctl is-active garm-reconcile.service || true"
                ), "adopt node reconcile should not have auto-run"

                # (1) First-run admin + CLI login in one step — `garm-cli init`
                # does the POST /first-run AND saves the logged-in CLI profile
                # (exactly what the reconcile would otherwise do). Do NOT also
                # curl /first-run separately — that makes garm-cli init's own
                # first-run 409.
                node.succeed(
                    "sudo -u garm env HOME=/var/lib/garm garm-cli init "
                    "--name reconcile --url http://127.0.0.1:9997 "
                    f"--username admin --email admin@example.com --password '{pw}'"
                )
                # Controller URLs (urlsRequired gate) — set to the mock.
                base = "http://127.0.0.1:${toString mockPort}"
                node.succeed(
                    "sudo -u garm env HOME=/var/lib/garm garm-cli controller update "
                    f"--metadata-url {base}/api/v1/metadata "
                    f"--callback-url {base}/api/v1/callbacks "
                    f"--agent-url {base}/api/v1/agent"
                )
                # (2) Forge endpoint + credential (the same names the manifest
                # declares) — created OUT-OF-BAND, before any reconcile.
                node.succeed(
                    "sudo -u garm env HOME=/var/lib/garm garm-cli github endpoint create "
                    "--name mock-github "
                    f"--api-base-url {base} --base-url {base} --upload-url {base}"
                )
                # The module stages the mcl-app App PEM at this 0600 path (the
                # same path the reconcile manifest's pemPath points at).
                # The reconcile's ExecStartPre normally stages the App PEM here,
                # but it's gated off on this adopt node — stage it by hand (as the
                # operator/EXP2-3-4 flow would have), so the out-of-band
                # credential add below can reference it.
                pem = "/var/lib/garm/app-key-mcl-app.pem"
                node.succeed(f"install -o garm -g garm -m0600 ${appPem} {pem}")
                node.succeed(
                    "sudo -u garm env HOME=/var/lib/garm garm-cli github credentials add "
                    "--name mcl-app --endpoint mock-github --auth-type app "
                    "--description 'mcl-app' --app-id 111 --app-installation-id 222 "
                    f"--private-key-path {pem}"
                )
                # (3) The org + BOTH scale sets, matching the declared config
                # (incus: enabled max=4; incus-disabled: disabled max=2).
                node.succeed(
                    "sudo -u garm env HOME=/var/lib/garm garm-cli organization add "
                    "--name metacraft-labs --credentials mcl-app --random-webhook-secret"
                )
                oid = org_id(node, "metacraft-labs")
                node.succeed(
                    "sudo -u garm env HOME=/var/lib/garm garm-cli scaleset add "
                    f"--org {oid} --provider-name vmharness --image linux-runner "
                    "--name incus --flavor default --enabled=true "
                    "--min-idle-runners 0 --max-runners 4 --os-type linux --os-arch amd64 "
                    "--runner-bootstrap-timeout 20"
                )
                node.succeed(
                    "sudo -u garm env HOME=/var/lib/garm garm-cli scaleset add "
                    f"--org {oid} --provider-name vmharness --image linux-runner "
                    "--name incus-disabled --flavor default --enabled=false "
                    "--min-idle-runners 0 --max-runners 2 --os-type linux --os-arch amd64 "
                    "--runner-bootstrap-timeout 20"
                )

                # Snapshot the pre-existing state (ids + enabled + count).
                before_creds = J.loads(gcli(node, "github credentials list"))
                before_ss = {s["name"]: s for s in J.loads(gcli(node, f"scaleset list --org {oid}"))}
                assert set(before_ss) == {"incus", "incus-disabled"}, before_ss
                assert before_ss["incus"].get("enabled", False) is True
                assert before_ss["incus-disabled"].get("enabled", False) is False
                before_ids = {n: s["id"] for n, s in before_ss.items()}

                # NOW run the reconcile for the first time — it must ADOPT.
                # Isolate its readiness request from the periodic watchdog so we
                # can prove an initialized controller does not incur 60 retries.
                node.systemctl("stop garm-healthcheck.timer garm-healthcheck.service")
                probe_count_cmd = (
                    "journalctl -u garm.service -o cat --no-pager "
                    "| grep -c 'access_log method=GET uri=/api/v1/controller-info user_agent=curl/' || true"
                )
                probes_before = int(node.succeed(probe_count_cmd).strip())
                node.systemctl("start garm-reconcile.service")
                node.wait_for_unit("garm-reconcile.service")
                probes_after = int(node.succeed(probe_count_cmd).strip())
                assert probes_after - probes_before == 1, \
                    f"adopt readiness issued {probes_after - probes_before} HTTP probes instead of one"
                assert "success" in node.succeed(
                    "systemctl show -p Result --value garm-reconcile.service"
                ), "adopt reconcile did not succeed"

                after_ss = {s["name"]: s for s in J.loads(gcli(node, f"scaleset list --org {oid}"))}
                assert set(after_ss) == {"incus", "incus-disabled"}, \
                    f"adopt changed the scale-set set: {list(after_ss)}"
                for n in ("incus", "incus-disabled"):
                    assert after_ss[n]["id"] == before_ids[n], \
                        f"adopt RECREATED scale set {n} (id {before_ids[n]} -> {after_ss[n]['id']})"
                assert after_ss["incus"].get("enabled", False) is True, "adopt disabled the enabled set"
                assert after_ss["incus"]["max_runners"] == 4, "adopt changed maxRunners"
                assert after_ss["incus-disabled"].get("enabled", False) is False, \
                    "adopt enabled the declared-disabled set"
                after_creds = J.loads(gcli(node, "github credentials list"))
                assert before_creds == after_creds, "adopt changed the credentials"
                # The reconcile log should show 'already converged', never 'created'.
                # NB: don't shadow the driver's built-in `log` (AbstractLogger).
                journal = node.succeed("journalctl -u garm-reconcile.service --no-pager")
                assert "controller API ready (HTTP 401)" in journal, \
                    f"adopt reconcile did not accept the initialized controller's 401 readiness response:\n{journal}"
                assert "already converged" in journal, f"adopt did not report convergence:\n{journal}"
                assert "created in org" not in journal, f"adopt CREATED a scale set:\n{journal}"
          '';
        };
      };
    };
}
