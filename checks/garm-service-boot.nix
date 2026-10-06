top@{ ... }:
{
  # Ephemeral-Windows-Runners-GARM M0 gate: t_garm_nixos_service_boots.
  #
  # Boots a NixOS VM with `services.garm.enable = true` in the M0 forge-less /
  # provider-less configuration and proves the GARM DAEMON is actually up (not
  # merely that the unit is "active"):
  #
  #   (a) garm.service is active/running (a long-running Type=exec unit —
  #       `exec`, not `simple`: Type=simple + ExecStartPost= + credentials is a
  #       race systemd warns about by name, and it cost this fleet eight
  #       243/CREDENTIALS starts. See t_garm_credentials_no_race);
  #   (b) the guest `garm --version` equals the packaged post-v0.2.1 pin;
  #   (c) the daemon SERVES its API:
  #        - the apiserver port (9997) is listening;
  #        - GET /api/v1/controller-info BEFORE first-run responds 409 with the
  #          `init_required` body — GARM's `initRequired` middleware queries the
  #          DB (HasAdminUser) and short-circuits protected routes until an
  #          admin exists, proving the router + DB are live pre-init;
  #        - POST /api/v1/first-run initialises the controller and returns
  #          200 + a User JSON (this exercises the full path: HTTP router ->
  #          handler -> SQLite DB write -> JSON response, proving the DB opened
  #          with the runtime-generated passphrase and the daemon is genuinely
  #          operational, no GitHub credentials required);
  #        - a SECOND POST /api/v1/first-run returns 409 Conflict
  #          ("already initialized"), confirming the first-run write persisted;
  #        - GET /api/v1/controller-info AFTER first-run responds 409 with the
  #          DISTINCT `urls_required` body — the request advanced past the init
  #          gate (admin now exists) to the `urlsRequired` middleware, which
  #          fires because M0 configures no callback/metadata/agent URLs. The
  #          body changing from `init_required` to `urls_required` proves the
  #          first-run write took effect and the middleware chain is live.
  #
  # What "daemon up" means for GARM's first-run behaviour: a freshly booted,
  # forge-less GARM starts its API server immediately and is UN-INITIALISED
  # until someone calls POST /api/v1/first-run to create the initial admin
  # user (see apiserver/controllers/controllers.go: FirstRunHandler and
  # auth/init_required.go). GARM's protected `/api/v1` routes pass through a
  # middleware chain: initRequired (409 `init_required` until an admin exists)
  # -> urlsRequired (409 `urls_required` until callback/metadata/agent URLs are
  # set — never set in M0) -> JWT auth (401 when unauthenticated). In the
  # forge-less M0 config the chain therefore stops at urlsRequired post-init.
  # We assert the pre-init 409 `init_required`, a successful first-run, AND the
  # post-init 409 `urls_required` — together these prove the router, handlers,
  # DB, and middleware chain are all live, i.e. the daemon genuinely serves,
  # with no forge/provider configured. (Reaching the JWT 401 would require
  # setting the controller URLs, which is out of M0 scope.)
  perSystem =
    {
      pkgs,
      lib,
      self',
      ...
    }:
    let
      flake = top.config.flake;
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_garm_nixos_service_boots = pkgs.testers.nixosTest {
          name = "t_garm_nixos_service_boots";

          nodes.server =
            { ... }:
            {
              imports = [ flake.modules.nixos.garm ];
              environment.systemPackages = [
                pkgs.curl
                self'.packages.garm
              ];
              services.garm = {
                enable = true;
                package = self'.packages.garm;
                # Bind all interfaces (default) so in-VM curl reaches it.
                apiServer = {
                  bind = "0.0.0.0";
                  port = 9997;
                };
              };
            };

          testScript = ''
            start_all()
            server.wait_for_unit("multi-user.target")

            with subtest("garm.service is a long-running Type=exec unit"):
                service_type = server.succeed(
                    "systemctl show -p Type --value garm.service"
                ).strip()
                assert service_type == "exec", f"unexpected Type={service_type!r}"

            with subtest("garm.service passes the config through the supported long flag"):
                exec_start = server.succeed(
                    "systemctl show -p ExecStart --value garm.service"
                ).strip()
                expected = " --config /var/lib/garm/config.toml"
                assert expected in exec_start, f"garm.service ExecStart={exec_start!r}"

            with subtest("garm.service is active/running"):
                server.wait_for_unit("garm.service")
                active = server.succeed(
                    "systemctl show -p ActiveState --value garm.service"
                ).strip()
                assert active == "active", f"garm.service ActiveState={active!r}"

            with subtest("the packaged garm --version matches the post-v0.2.1 race-fix pin"):
                version = server.succeed("garm --version").strip()
                assert version == "v0.2.1-unstable-2026-07-08", f"garm --version={version!r}"

            with subtest("the daemon binds the apiserver port"):
                server.wait_for_open_port(9997)

            with subtest("a protected route returns 409 init_required before first-run (router + DB live)"):
                status = server.succeed(
                    "curl -s -o /tmp/preinit.body -w '%{http_code}' "
                    "http://localhost:9997/api/v1/controller-info"
                ).strip()
                body = server.succeed("cat /tmp/preinit.body")
                assert status == "409", f"controller-info pre-init status={status!r} body={body!r}"
                # GARM's initRequired middleware returned the init_required body
                # after querying the DB for an admin user — proves router + DB.
                assert "init_required" in body, f"pre-init body missing init_required: {body!r}"

            with subtest("POST /api/v1/first-run initialises the controller (200 + User JSON)"):
                status = server.succeed(
                    "curl -s -o /tmp/firstrun.body -w '%{http_code}' "
                    "-X POST http://localhost:9997/api/v1/first-run "
                    "-H 'Content-Type: application/json' "
                    "-d '{\"username\":\"admin\",\"email\":\"admin@example.com\","
                    "\"password\":\"Sup3rStr0ng-Garm-M0-Passphrase!\"}'"
                ).strip()
                body = server.succeed("cat /tmp/firstrun.body")
                assert status == "200", f"first-run status={status!r} body={body!r}"
                # The response is the created User; it must echo the username and
                # carry a generated id, proving the DB write + JSON round-trip.
                assert '"admin"' in body, f"first-run body missing username: {body!r}"
                assert '"id"' in body, f"first-run body missing id: {body!r}"

            with subtest("a second first-run returns 409 Conflict (init persisted to the DB)"):
                status = server.succeed(
                    "curl -s -o /dev/null -w '%{http_code}' "
                    "-X POST http://localhost:9997/api/v1/first-run "
                    "-H 'Content-Type: application/json' "
                    "-d '{\"username\":\"admin2\",\"email\":\"admin2@example.com\","
                    "\"password\":\"An0ther-Str0ng-Garm-Passphrase!\"}'"
                ).strip()
                assert status == "409", f"second first-run status={status!r}"

            with subtest("a protected route advances to 409 urls_required after first-run (chain live)"):
                status = server.succeed(
                    "curl -s -o /tmp/postinit.body -w '%{http_code}' "
                    "http://localhost:9997/api/v1/controller-info"
                ).strip()
                body = server.succeed("cat /tmp/postinit.body")
                assert status == "409", f"controller-info post-init status={status!r} body={body!r}"
                # The gate moved past initRequired to urlsRequired — the body
                # changed from init_required to urls_required, proving the
                # first-run admin write took effect (M0 sets no controller URLs).
                assert "urls_required" in body, f"post-init body not urls_required: {body!r}"

            with subtest("the SQLite DB and rendered config persist under the StateDirectory"):
                server.succeed("test -f /var/lib/garm/garm.sqlite")
                server.succeed("test -f /var/lib/garm/config.toml")
                # The auto-generated secrets are persisted (mode 0600) and NOT
                # sourced from the world-readable Nix store.
                server.succeed("test -f /var/lib/garm/db-passphrase.secret")
                server.succeed("test -f /var/lib/garm/jwt-secret.secret")
          '';
        };
      };
    };
}
