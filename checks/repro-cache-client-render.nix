top@{ ... }:
{
  # Reprobuild-Binary-Cache-Fleet R2 (REPRO-FLEET-PROVISION) gate:
  # t_repro_cache_client_render.
  #
  # Proves the reusable `mcl-reprobuild` module (a) puts the reprobuild `repro`
  # CLI — which BUNDLES the binary-cache client — on PATH and (b) RENDERS the R1
  # caches.conf with the managed fleet cache — the EXACT url + 130-hex ECDSA-P256
  # trusted key + priority — for the NixOS module class (system-wide
  # /etc/repro/caches.conf), asserted live in a booted VM.
  #
  # (mcl-reprobuild superseded the former mcl-repro-cache-client module — the
  # client toolset is the `repro cache` subcommand group bundled in the one
  # `reprobuild` package, so the client config knobs live on the one reprobuild
  # module. The historical standalone `repro-binary-cache-client` package was
  # retired; see Binary-Caches.md §"Client CLI Surface".)
  #
  # The home-manager module class shares the SAME renderer + option schema (one
  # definition, in reprobuild's own nix/modules/reprobuild.nix, which this repo
  # re-exports as mcl-reprobuild), so this render proof covers it too;
  # ~/dotfiles additionally evaluates the home config as its own build.
  #
  # It also gates the PER-USER DAEMON: Distribution-And-Packaging M4 made
  # `enableUserDaemon` render a NixOS `systemd.user` unit (not only a
  # home-manager one), and a unit file that exists is not a daemon that runs.
  # The subtest below boots a lingering user, waits for the unit to reach
  # `active`, and then makes `repro` complete an IPC round-trip with it —
  # cross-checking the pid the daemon reports over the socket against the pid
  # systemd supervises.
  #
  # NON-VACUITY: the assertions check the EXACT 130-hex key string, the exact
  # url, and the exact priority line. A missing key, a wrong key, or a wrong
  # url/priority makes the rendered file differ and the gate FAILS — the trust
  # key is load-bearing, not decorative.
  perSystem =
    {
      pkgs,
      lib,
      inputs',
      ...
    }:
    let
      flake = top.config.flake;
      # Pass the reprobuild package explicitly (like the sibling cross-host gate
      # passes the daemon), keeping the check self-contained. This is the full
      # toolset — `repro`, whose `cache` subcommand bundles the client.
      reproPkg = inputs'.reprobuild.packages.reprobuild;

      # The concrete fleet cache (from R3's managed signing key). The pubkey is
      # the exact 130-hex string committed at
      # infra/services/repro-binary-cache/signing-pubkey.txt (R3). It is spelled
      # out here (not read cross-repo) so the gate is self-contained and a
      # transcription error would fail against the module-rendered value.
      cacheName = "repro-cache";
      cacheUrl = "https://repro-cache.metacraft-labs.com";
      fleetKey = "04d09ced68a33f83359f6e0b25e975137aec67a5305c3a76e6de33916a0d43a83e056509945d1793ebf923e6e07a0cbeb4175dfdf6b885bafd6d8077903bfd700f";
      cachePriority = 20;

      caches.${cacheName} = {
        url = cacheUrl;
        trustedPublicKeys = [ fleetKey ];
        priority = cachePriority;
      };
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_repro_cache_client_render = pkgs.testers.nixosTest {
          name = "t_repro_cache_client_render";

          nodes.host =
            { ... }:
            {
              imports = [ flake.modules.nixos.mcl-reprobuild ];
              # Spelled with the LEGACY `programs.reprobuild` path on purpose:
              # the canonical path is `services.reprobuild` now, and this is
              # what proves the compatibility aliases this repo layers on the
              # re-exported module actually forward definitions. If the aliases
              # regress, nothing below renders and every subtest fails.
              programs.reprobuild = {
                enable = true;
                package = reproPkg;
                inherit caches;
                # Also gate the direnv-like shell-hook injection: with this on,
                # the module must wire `repro shell hook <shell>` into the
                # interactive shell init (asserted in /etc/bashrc below).
                enableShellHook = true;
                enableUserDaemon = true;
              };

              users.users.alice = {
                isNormalUser = true;
                uid = 1000;
                # Without linger there is no systemd user manager at boot, the
                # unit would merely exist on disk, and the daemon subtest would
                # be asserting nothing.
                linger = true;
              };
            };

          testScript = ''
            start_all()
            host.wait_for_unit("multi-user.target")

            with subtest("repro + its bundled binary-cache client subcommand are on PATH"):
                # `enable` puts the reprobuild package in environment.systemPackages;
                # it ships `repro`, whose `cache` subcommand group folds in the
                # retired standalone `repro-binary-cache-client` toolset
                # (Binary-Caches.md §"Client CLI Surface").
                host.succeed("command -v repro")
                # `repro cache` prints its usage banner and exits 0 — proves the
                # client toolset is bundled into the shipped `repro` binary.
                host.succeed("repro cache 2>&1 | grep -q 'repro cache'")

            with subtest("/etc/repro/caches.conf is rendered with the fleet cache"):
                host.succeed("test -f /etc/repro/caches.conf")
                conf = host.succeed("cat /etc/repro/caches.conf")
                print(conf)

                # The section header is the cache name.
                assert "[${cacheName}]" in conf, f"missing [${cacheName}] section: {conf!r}"

                # The exact url must be present (quoted, R1 parser syntax).
                assert 'url = "${cacheUrl}"' in conf, f"missing/wrong url: {conf!r}"

                # The EXACT 130-hex trusted key must be present — the
                # load-bearing trust anchor. A missing/wrong key must fail here.
                assert (
                    'trusted-public-keys = "${fleetKey}"' in conf
                ), f"missing/wrong trusted key: {conf!r}"

                # The priority line must be the configured value.
                assert (
                    "priority = ${toString cachePriority}" in conf
                ), f"missing/wrong priority: {conf!r}"

            with subtest("the per-user daemon unit is ACTIVE and `repro` answers on its socket"):
                import re

                host.wait_for_unit("user@1000.service")
                su = "su alice -c 'XDG_RUNTIME_DIR=/run/user/1000 PATH=/run/current-system/sw/bin:$PATH {}'"

                host.wait_until_succeeds(
                    su.format("systemctl --user is-active repro-daemon.service"), timeout=90
                )
                state = host.succeed(
                    su.format("systemctl --user show -p ActiveState --value repro-daemon.service")
                ).strip()
                assert state == "active", f"repro-daemon.service ActiveState={state!r}"

                # NON-VACUITY: `repro daemon status` EXITS 0 and prints
                # "repro daemon: not-running" when nothing answers, so the
                # assertion is on the text, not on the exit code.
                status = host.succeed(su.format("repro daemon status"))
                print(status)
                assert "repro daemon: running" in status, f"daemon did not answer: {status!r}"

                main_pid = host.succeed(
                    su.format("systemctl --user show -p MainPID --value repro-daemon.service")
                ).strip()
                assert main_pid not in ("", "0"), f"no MainPID: {main_pid!r}"
                m = re.search(r"^pid: (\d+)$", status, re.M)
                assert m, f"no pid line in status: {status!r}"
                assert m.group(1) == main_pid, (
                    f"daemon answered with pid {m.group(1)}, systemd supervises {main_pid}"
                )

            with subtest("enableShellHook wires `repro shell hook` into interactive bash init"):
                # NixOS writes programs.bash.interactiveShellInit into /etc/bashrc.
                # NON-VACUITY: with enableShellHook = false this string is absent,
                # so a regressed/removed injection fails here rather than passing.
                bashrc = host.succeed("cat /etc/bashrc")
                assert (
                    "repro shell hook bash" in bashrc
                ), f"shell hook not injected into /etc/bashrc: {bashrc!r}"
          '';
        };
      };
    };
}
