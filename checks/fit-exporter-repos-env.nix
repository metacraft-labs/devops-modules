top@{ ... }:
{
  # Runtime regression gate for github-actions-fit-exporter:
  # t_fit_exporter_repos_env_roundtrip.
  #
  # WHY A VM (and why the eval-only t_runner_fit_monitoring did not catch this):
  # the exporter is handed its watched-repos list through the systemd unit. The
  # module used to render it as an inline `Environment=GHA_REPOS_JSON=[{"owner":
  # …}]`. That BUILDS and EVALS fine — the unit file on disk holds the correct
  # JSON — but systemd's `Environment=` directive parses shell-style quoting and
  # STRIPS the unescaped double-quotes before the process starts, so the exporter
  # saw `[{owner:…}]` and died on the first `json.loads`. Only a booted, real
  # systemd reproduces that, so this gate boots one and asserts against the exact
  # `systemctl show -p Environment` view the operator used to diagnose it on the
  # live host.
  #
  # The assertion is deliberately runtime-faithful and non-tautological: it takes
  # the EFFECTIVE environment systemd exposes (post-quote-parsing), feeds it to
  # the REAL exporter's REAL `load_repos()`, and requires it to parse and yield
  # the configured repos — which FAILS on the pre-fix inline-JSON rendering and
  # PASSES on the file-path rendering. It also starts the (oneshot) service and
  # requires it to reach success, reproducing the failed→fixed transition.
  perSystem =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    let
      flake = top.config.flake;
      exporter = config.packages.github-actions-fit-exporter;
      # The two repos carry the double-quotes that systemd's Environment= parser
      # used to eat; they are what must survive to json.loads.
      repos = [
        {
          owner = "metacraft-labs";
          repo = "codetracer";
        }
        {
          owner = "metacraft-labs";
          repo = "web";
        }
      ];
      expectedJson = builtins.toJSON (map (r: { inherit (r) owner repo; }) repos);
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_fit_exporter_repos_env_roundtrip = pkgs.testers.nixosTest {
          name = "t_fit_exporter_repos_env_roundtrip";

          nodes.host =
            { ... }:
            {
              imports = [ flake.modules.nixos.github-actions-fit-exporter ];
              environment.systemPackages = [ pkgs.python3 ];
              # The textfile-collector dir is normally provided by
              # node-exporter; create it so the hardened unit's ReadWritePaths
              # target exists and the DynamicUser can write its .prom snapshot in
              # this minimal VM (world-writable sticky dir, node-exporter-style).
              systemd.tmpfiles.rules = [
                "d /var/lib/prometheus-node-exporter/textfile 1777 root root -"
              ];
              services.github-actions-fit-exporter = {
                enable = true;
                package = exporter;
                inherit repos;
                # No network in the VM; keep the cycle cheap. The repos-loading
                # (json parse) happens BEFORE any API call regardless, so this
                # gate exercises exactly the code path that failed on the host.
                scanLogs = false;
                lookbackRuns = 1;
              };
            };

          testScript = ''
            import json

            expected = json.loads(${builtins.toJSON expectedJson})

            start_all()
            host.wait_for_unit("multi-user.target")

            unit = "github-actions-fit-exporter.service"

            with subtest("systemd exposes the repos config the exporter can actually parse"):
                # Exactly the operator's live-host diagnostic: the EFFECTIVE
                # environment after systemd's Environment= quote-parsing.
                raw = host.succeed(f"systemctl show -p Environment --value {unit}").strip()
                print("effective Environment:", raw)

                # Reconstruct the env dict as the process would receive it. The
                # `Environment` property is a space-separated list of KEY=VALUE
                # assignments (values with spaces are quoted); ours have none.
                import shlex
                env = {}
                for tok in shlex.split(raw):
                    k, _, v = tok.partition("=")
                    env[k] = v

                # Feed that effective env to the REAL exporter loader and require
                # it to parse and yield the configured repos. On the pre-fix
                # inline-JSON rendering, GHA_REPOS_JSON arrives with its quotes
                # stripped and this raises JSONDecodeError -> the gate fails.
                script = "${exporter}/share/gh-actions-fit-exporter.py"
                py = (
                    "import importlib.util, os, json, sys\n"
                    "os.environ.clear()\n"
                    f"os.environ.update({env!r})\n"
                    f"spec = importlib.util.spec_from_file_location('fit', {script!r})\n"
                    "m = importlib.util.module_from_spec(spec)\n"
                    "spec.loader.exec_module(m)\n"
                    "print(json.dumps(m.load_repos()))\n"
                )
                host.succeed("cat > /tmp/roundtrip.py <<'PY'\n" + py + "PY")
                got = json.loads(host.succeed("python3 /tmp/roundtrip.py"))
                assert got == expected, f"exporter loaded {got!r}, expected {expected!r}"

            with subtest("the oneshot service reaches success (not failed, as on the host)"):
                # A clean run: json parse succeeds, per-repo API calls fail-soft
                # (no network), the .prom is still written and ExecStart exits 0.
                host.succeed(f"systemctl start {unit}")
                result = host.succeed(f"systemctl show -p Result --value {unit}").strip()
                assert result == "success", f"unit Result={result!r} (expected success)"
                host.succeed(
                    "test -s /var/lib/prometheus-node-exporter/textfile/github-actions-fit.prom"
                )
          '';
        };
      };
    };
}
