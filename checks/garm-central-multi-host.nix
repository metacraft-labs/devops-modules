top@{ ... }:
{
  # Runner-Fleet-Capability-Pools-And-Remote-Driving campaign, milestone RB2.
  #
  # gate: t_garm_central_multi_host
  #
  # Proves the Phase-B END STATE at the module level: ONE central `services.garm`
  # control plane whose provider set is entirely RB1 REMOTE-TARGET providers, each
  # an RPC client to a DIFFERENT `vm-harness serve` daemon — the single controller
  # creating + destroying a runner on EACH remote host. It extends RB1's
  # single-provider proof (t_garm_provider_remote) to the multi-provider central
  # topology, WITHOUT the live fleet: the six per-host serve daemons are stood up
  # as `vm-harness serve --backend noop` daemons on distinct loopback ports with
  # DISTINCT bearer tokens (the sanctioned hermetic stand-in, design doc §9.1) —
  # no hypervisor, but the whole wire path (TCP, bearer auth, the NDJSON exec
  # stream, the exit-code round-trip) is exercised for real, per provider.
  #
  # ONE VM, and everything runs inside it:
  #   * ONE real `garm.service` (this flake's module) with SIX remote providers,
  #     forge-less (no [[github]], no scale sets — the M0 forge-less boot), each
  #     provider pointing at 127.0.0.1:<distinct port> with its own staged token.
  #     This is the "one central GARM" — a single systemd unit, a single config,
  #     six [[provider]] blocks.
  #   * SIX `vm-harness serve --backend noop` daemons, one per stand-in host
  #     (hms-incus, hms-libvirt, gpu001, gpu002, wincibare, m3), each on its own
  #     loopback port with its own bearer token.
  #
  # ASSERTIONS:
  #   (1) The central garm.service comes up ACTIVE with all six remote providers
  #       (one controller, six remote targets).
  #   (2) The rendered central config.toml carries SIX remote [[provider]] blocks,
  #       each backend="remote" with the right endpoint + target_backend +
  #       (the RB2 module enhancement) a STAGED auth_token_file under stateDir,
  #       and all six staged token files exist (garm's ExecStartPre ran).
  #   (3) DRIVE: for EACH provider, a CreateInstance -> DeleteInstance cycle over
  #       GARM's REAL external-provider protocol succeeds against THAT provider's
  #       own daemon (proving the single controller drives create+destroy on each
  #       remote host), leaving no residue; DeleteInstance is idempotent.
  #   (4) AUTH ISOLATION: provider A's create fails (401) when pointed at its
  #       endpoint with the WRONG token — the per-host token is load-bearing, so
  #       one central controller cannot cross-drive a host with another's token.
  #   (5) RENDER of the PRODUCTION SHAPE: a second (eval-only) central unit with
  #       the REALISTIC per-host target backends (incus/libvirt/hyperv/tart-macos)
  #       + two providers sharing hms's endpoint (incus + libvirt on the ONE hms
  #       serve daemon) + per-provider staged tokens renders correctly and wires
  #       one serve-token LoadCredential per provider. This ties the gate to the
  #       exact infra central-GARM config without needing the live hosts.
  perSystem =
    {
      pkgs,
      lib,
      self',
      ...
    }:
    let
      flake = top.config.flake;

      vmHarness = self'.packages.vm-harness;
      provider = self'.packages.garm-provider-vmharness;

      # The six stand-in hosts: attr name -> loopback port + bearer token.
      # DISTINCT ports AND distinct tokens, so a create landing on the wrong
      # daemon or with the wrong token cannot silently pass.
      standins = {
        hms-incus = {
          port = 18871;
          token = "serve-bearer-hms-incus-3f9a";
        };
        hms-libvirt = {
          port = 18872;
          token = "serve-bearer-hms-libvirt-7b2c";
        };
        gpu001-incus = {
          port = 18873;
          token = "serve-bearer-gpu001-a14d";
        };
        gpu002-incus = {
          port = 18874;
          token = "serve-bearer-gpu002-c5e6";
        };
        wincibare-hyperv = {
          port = 18875;
          token = "serve-bearer-wincibare-9d0f";
        };
        m3-tart = {
          port = 18876;
          token = "serve-bearer-m3-2a8b";
        };
      };

      tokenSrc = name: "/etc/garm-central-test/token-${name}";

      # A token source file per stand-in, delivered the way agenix delivers the
      # per-host serve token on the real hosts: a 0400 file that appears at boot,
      # handed to garm via LoadCredential and read by the serve daemon directly.
      # Not a store path (well, its content is; in a test that is fine) — mirrors
      # the production LoadCredential-source shape.
      tokenDropModule =
        { ... }:
        {
          systemd.tmpfiles.rules = [ "d /etc/garm-central-test 0755 root root -" ];
          environment.etc = lib.mapAttrs' (
            name: s: lib.nameValuePair "garm-central-test/token-${name}" { text = s.token; mode = "0400"; }
          ) standins;
        };

      # One `vm-harness serve --backend noop` daemon per stand-in host, on its own
      # loopback port with its own token. Plain root services (the noop backend
      # needs nothing) — the point is the wire endpoint, not the hardening (which
      # the RA2 module gate already proves).
      serveDaemons = {
        systemd.services = lib.mapAttrs' (
          name: s:
          lib.nameValuePair "vmh-serve-${name}" {
            description = "vm-harness serve (noop stand-in for ${name})";
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              ExecStart = "${vmHarness}/bin/vm-harness serve --listen 127.0.0.1:${toString s.port} --auth-token-file ${tokenSrc name} --backend noop --quiet";
              Restart = "on-failure";
            };
          }
        ) standins;
      };

      # The ONE central GARM: six remote providers, forge-less. target_backend is
      # "noop" here (the hermetic stand-in); the REALISTIC target backends are
      # asserted at render level in assertion (5) below.
      centralGarm = {
        services.garm = {
          enable = true;
          apiServer.port = 9997;
          providers = lib.mapAttrs (name: s: {
            backend = "remote";
            remote = {
              endpoint = "127.0.0.1:${toString s.port}";
              targetBackend = "noop";
              authTokenFile = tokenSrc name;
            };
          }) standins;
        };
      };

      # (5) The PRODUCTION-SHAPE central unit, built for RENDER assertions only
      # (no boot). Mirrors infra's central-garm.nix: realistic per-host target
      # backends, TWO providers sharing hms's single serve endpoint (incus +
      # libvirt), per-provider staged tokens.
      prodShapeUnit =
        (pkgs.nixos (
          { ... }:
          {
            imports = [ flake.modules.nixos.garm ];
            boot.loader.grub.enable = false;
            fileSystems."/" = {
              device = "/dev/vda";
              fsType = "ext4";
            };
            system.stateVersion = "24.11";
            services.garm = {
              enable = true;
              providers = {
                hms-incus = {
                  backend = "remote";
                  remote = {
                    endpoint = "100.83.180.254:8873";
                    targetBackend = "incus";
                    authTokenFile = "/run/agenix/vm-harness-serve/hms-token";
                  };
                };
                hms-libvirt = {
                  backend = "remote";
                  remote = {
                    endpoint = "100.83.180.254:8873";
                    targetBackend = "libvirt";
                    authTokenFile = "/run/agenix/vm-harness-serve/hms-token";
                  };
                };
                gpu001-incus = {
                  backend = "remote";
                  remote = {
                    endpoint = "100.83.80.37:8873";
                    targetBackend = "incus";
                    authTokenFile = "/run/agenix/vm-harness-serve/gpu001-token";
                  };
                };
                gpu002-incus = {
                  backend = "remote";
                  remote = {
                    endpoint = "100.83.55.181:8873";
                    targetBackend = "incus";
                    authTokenFile = "/run/agenix/vm-harness-serve/gpu002-token";
                  };
                };
                wincibare-hyperv = {
                  backend = "remote";
                  remote = {
                    endpoint = "100.83.99.99:8873";
                    targetBackend = "hyperv";
                    authTokenFile = "/run/agenix/vm-harness-serve/wincibare-token";
                  };
                };
                m3-tart = {
                  backend = "remote";
                  remote = {
                    endpoint = "100.83.174.120:8873";
                    targetBackend = "tart-macos";
                    authTokenFile = "/run/agenix/vm-harness-serve/m3-token";
                  };
                };
                # m3 serves a SECOND guest class off the same daemon: Windows
                # ARM64 under QEMU. Same endpoint and token as m3-tart, a
                # different target_backend -- the hms-incus/hms-libvirt shape
                # again, on the one host that is also double-served by its own
                # per-host GARM.
                #
                # This entry is what keeps `qemu-windows-arm` in the
                # `remote.targetBackend` enum. That enum is a strict subset of
                # the local `backend` enum, so dropping the value is an EVAL
                # ERROR here rather than a silent behaviour change -- which is
                # the point: infra's central-garm.nix declares this exact
                # provider, and without it m3's Windows-ARM pool cannot exist.
                m3-qemu-winarm = {
                  backend = "remote";
                  remote = {
                    endpoint = "100.83.174.120:8873";
                    targetBackend = "qemu-windows-arm";
                    authTokenFile = "/run/agenix/vm-harness-serve/m3-token";
                  };
                };
              };
            };
          }
        )).config.systemd.units."garm.service".unit;
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_garm_central_multi_host = pkgs.testers.nixosTest {
          name = "t_garm_central_multi_host";

          nodes.controller =
            { ... }:
            {
              imports = [
                flake.modules.nixos.garm
                tokenDropModule
                serveDaemons
                centralGarm
              ];
              virtualisation.memorySize = 2048;
              environment.systemPackages = [
                provider
                vmHarness
                pkgs.jq
              ];
            };

          testScript = ''
            import json

            standins = ${builtins.toJSON (
              lib.mapAttrs (name: s: {
                inherit (s) port token;
                svc = "vmh-serve-${name}";
              }) standins
            )}

            start_all()

            # --- (1) one central GARM + six serve daemons come up ------------
            for name, s in standins.items():
                controller.wait_for_unit(str(s["svc"]))
                controller.wait_until_succeeds(
                    f"ss -ltn 'sport = :{s['port']}' | grep -q LISTEN"
                )
            controller.wait_for_unit("garm.service")

            # --- (2) rendered central config: six remote providers, staged ---
            # The provider config files are referenced from the rendered config
            # template; walk them and assert the remote surface + staged tokens.
            cfg = controller.succeed(
                "ls /var/lib/garm/config.toml && cat /var/lib/garm/config.toml"
            )
            nprov = int(controller.succeed(
                "grep -c '^\\[\\[provider\\]\\]' /var/lib/garm/config.toml"
            ).strip())
            assert nprov == 6, f"expected 6 [[provider]] blocks, got {nprov}"

            for name, s in standins.items():
                # the per-provider config.toml (a store path) referenced by name
                pcfg = controller.succeed(
                    f"awk '/^name = \"{name}\"/{{f=1}} f&&/config_file/{{print; exit}}' "
                    f"/var/lib/garm/config.toml | grep -oE '/nix/store/[^\"]+\\.toml'"
                ).strip()
                body = controller.succeed(f"cat {pcfg}")
                assert 'backend = "remote"' in body, f"{name}: not a remote provider: {body}"
                assert f'endpoint = "127.0.0.1:{s["port"]}"' in body, f"{name}: wrong endpoint: {body}"
                assert 'target_backend = "noop"' in body, f"{name}: wrong target_backend: {body}"
                # RB2 module enhancement: auth_token_file is the STAGED path, and
                # garm's ExecStartPre must have created it.
                staged = controller.succeed(
                    f"grep -oE 'auth_token_file = \"[^\"]+\"' {pcfg} | cut -d'\"' -f2"
                ).strip()
                assert staged.startswith("/var/lib/garm/serve-token-"), \
                    f"{name}: auth_token_file not staged under stateDir: {staged}"
                controller.succeed(f"test -s {staged}")
                # and it must equal this stand-in's token (staged verbatim)
                got = controller.succeed(f"cat {staged}").strip()
                assert got == s["token"], f"{name}: staged token mismatch"

            # --- (3) DRIVE create+destroy per provider -----------------------
            controller_id = "ctrl-central-0000"
            pool_id = "9dcf590a-1192-4a9c-b3e4-e0902974c2c0"

            def bootstrap(instname):
                doc = {
                    "name": instname,
                    "tools": [{
                        "os": "linux", "architecture": "x64",
                        "download_url": "https://example.invalid/actions-runner-linux-x64.tar.gz",
                        "filename": "actions-runner-linux-x64.tar.gz",
                        "sha256_checksum": "0" * 64,
                    }],
                    "repo_url": "https://github.com/example-org/scratch",
                    "callback-url": "https://garm.example.com/api/v1/callbacks",
                    "metadata-url": "https://garm.example.com/api/v1/metadata",
                    "instance-token": "jwt-token",
                    "os_type": "linux", "arch": "amd64", "flavor": "linux-large",
                    "image": "runner-linux", "labels": ["linux", "vmharness"],
                    "pool_id": pool_id, "jit_config_enabled": True,
                }
                return json.dumps(doc)

            def provider_env(cmd, pcfg, extra=""):
                return (
                    f"env -i PATH=$PATH HOME=/root TMPDIR=/tmp "
                    f"GARM_INTERFACE_VERSION=v0.1.1 "
                    f"GARM_PROVIDER_CONFIG_FILE={pcfg} "
                    f"GARM_CONTROLLER_ID={controller_id} "
                    f"GARM_COMMAND={cmd} {extra} "
                    f"${provider}/bin/garm-provider-vmharness"
                )

            for name, s in standins.items():
                pcfg = controller.succeed(
                    f"awk '/^name = \"{name}\"/{{f=1}} f&&/config_file/{{print; exit}}' "
                    f"/var/lib/garm/config.toml | grep -oE '/nix/store/[^\"]+\\.toml'"
                ).strip()
                instname = f"garm-central-{name}"
                bs = bootstrap(instname)
                controller.succeed(f"cat > /tmp/bs-{name}.json <<'EOF'\n{bs}\nEOF")

                # CreateInstance over the REMOTE daemon
                out = controller.succeed(
                    provider_env("CreateInstance", pcfg, f"GARM_POOL_ID={pool_id}")
                    + f" < /tmp/bs-{name}.json"
                )
                resp = json.loads(out)
                assert resp.get("provider_id"), f"{name}: no provider_id: {out}"
                assert resp.get("name") == instname, f"{name}: name mismatch: {out}"
                assert resp.get("status") == "running", f"{name}: not running: {out}"

                # DeleteInstance (and idempotent second delete)
                controller.succeed(
                    provider_env("DeleteInstance", pcfg,
                                 f"GARM_INSTANCE_ID={instname} GARM_POOL_ID={pool_id}")
                    + " </dev/null"
                )
                controller.succeed(
                    provider_env("DeleteInstance", pcfg,
                                 f"GARM_INSTANCE_ID={instname} GARM_POOL_ID={pool_id}")
                    + " </dev/null"
                )
                print(f"[drive] {name}: create+destroy OK")

            # --- (4) AUTH ISOLATION: wrong token is rejected (401) -----------
            one = list(standins.items())[0]
            name0, s0 = one
            bad = controller.succeed("mktemp").strip()
            controller.succeed(
                f"cat > {bad} <<'EOF'\n"
                f'backend = "remote"\n\n'
                f"[remote]\n"
                f'endpoint = "127.0.0.1:{s0["port"]}"\n'
                f'target_backend = "noop"\n'
                f'auth_token = "WRONG-TOKEN-DEADBEEF"\n'
                f'guest_os = "linux"\n'
                f"EOF"
            )
            controller.succeed(f"cat > /tmp/bs-bad.json <<'EOF'\n{bootstrap('garm-central-bad')}\nEOF")
            rc, err = controller.execute(
                provider_env("CreateInstance", bad, f"GARM_POOL_ID={pool_id}")
                + " < /tmp/bs-bad.json 2>&1"
            )
            assert rc != 0, "create with WRONG token unexpectedly succeeded"
            assert "401" in err or "unauthor" in err.lower(), \
                f"wrong-token failure did not mention 401/unauthorized: {err}"
            print("[auth] wrong token rejected (401)")

            # --- (5) PRODUCTION-SHAPE render (eval-only, never booted) --------
            prod = "${prodShapeUnit}/garm.service"
            pre = controller.succeed(
                f"grep '^ExecStartPre=' {prod} | head -1 | cut -d= -f2-"
            ).strip()
            tmpl = controller.succeed(
                f"grep -ohE '/nix/store/[a-z0-9]+-garm-config.toml.tmpl' {pre} | head -1"
            ).strip()
            nprov_p = int(controller.succeed(
                f"grep -c '^\\[\\[provider\\]\\]' {tmpl}"
            ).strip())
            assert nprov_p == 7, f"prod-shape: expected 7 providers, got {nprov_p}"
            # LoadCredential: one serve-token per provider (seven)
            ncred = int(controller.succeed(
                f"grep -c 'serve-token-' {prod} || true"
            ).strip())
            assert ncred >= 7, f"prod-shape: expected >=7 serve-token creds, got {ncred}"
            # the realistic target backends are all present
            allbodies = controller.succeed(
                f"for c in $(grep -oE '/nix/store/[a-z0-9]+-garm-provider-[a-z0-9_]+\\.toml' {tmpl} | sort -u); do cat $c; done"
            )
            for tb in ["incus", "libvirt", "hyperv", "tart-macos", "qemu-windows-arm"]:
                assert f'target_backend = "{tb}"' in allbodies, \
                    f"prod-shape: missing target_backend {tb}"
            # hms's two providers share ONE endpoint (incus + libvirt on one daemon)
            hms_hits = allbodies.count('endpoint = "100.83.180.254:8873"')
            assert hms_hits == 2, f"prod-shape: hms endpoint should back 2 providers, got {hms_hits}"
            # m3 does the same thing for a DIFFERENT reason: one macOS guest
            # class and one Windows guest class off a single serve daemon.
            m3_hits = allbodies.count('endpoint = "100.83.174.120:8873"')
            assert m3_hits == 2, f"prod-shape: m3 endpoint should back 2 providers, got {m3_hits}"

            print("[t_garm_central_multi_host] PASS")
          '';
        };
      };
    };
}
