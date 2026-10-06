{ ... }:
{
  perSystem =
    {
      pkgs,
      self',
      ...
    }:
    let
      inventory = ./consumer-flake-cachix-inventory.json;
      allowlist = ./cachix-removal-allowlist.json;
      action = ../modules/attic-push-flake-outputs/action.yml;
    in
    {
      checks = {
        attic-migrate-flake-idempotent =
          pkgs.runCommand "attic-migrate-flake-idempotent"
            {
              nativeBuildInputs = [
                self'.packages.attic-migrate-flake
                pkgs.diffutils
                pkgs.gnugrep
                pkgs.python3
              ];
            }
            ''
              mkdir -p fixture
              cat > fixture/flake.nix <<'EOF'
              {
                description = "fixture";
                passthru = {
                  knownCachixOutsideNixConfig = "https://mcl-public-cache.cachix.org";
                  unknownCachixOutsideNixConfig = "https://surprise.cachix.org";
                };
                nixConfig = {
                  extra-substituters = [
                    "https://mcl-public-cache.cachix.org"
                    "https://metacraft-labs-codetracer.cachix.org"
                  ];
                  extra-trusted-public-keys = [
                    "mcl-public-cache.cachix.org-1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
                    "metacraft-labs-codetracer.cachix.org-1:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="
                  ];
                };
                outputs = { self }: {};
              }
              EOF

              attic-migrate-flake --dry-run fixture | grep -q 'cache.metacraft-labs.com'
              grep -q 'mcl-public-cache.cachix.org' fixture/flake.nix

              if attic-migrate-flake --check fixture; then
                echo "check mode should fail before migration" >&2
                exit 1
              fi

              attic-migrate-flake fixture
              cp fixture/flake.nix migrated.once
              attic-migrate-flake fixture
              diff -u migrated.once fixture/flake.nix
              attic-migrate-flake --check fixture

              # Both Cachix caches now collapse into the single private Attic cache.
              grep -q 'https://cache.metacraft-labs.com/metacraft-private-infrastructure' fixture/flake.nix
              grep -q 'metacraft-private-infrastructure:TWjFAlGXK9Mky5VG3PBln2MqYz4XPw3MTHHVPYZiAhE=' fixture/flake.nix
              # None of the four former --public Attic buckets may be injected.
              ! grep -q 'cache.metacraft-labs.com/metacraft-public' fixture/flake.nix
              ! grep -q 'cache.metacraft-labs.com/metacraft-codetracer' fixture/flake.nix
              ! grep -q 'metacraft-public:UtS6PK' fixture/flake.nix
              ! grep -q 'metacraft-codetracer:9OV9wCDX' fixture/flake.nix
              grep -q 'knownCachixOutsideNixConfig = "https://mcl-public-cache.cachix.org"' fixture/flake.nix
              grep -q 'unknownCachixOutsideNixConfig = "https://surprise.cachix.org"' fixture/flake.nix
              ! grep -q 'mcl-public-cache.cachix.org-1:' fixture/flake.nix

              mkdir -p unknown
              cat > unknown/flake.nix <<'EOF'
              {
                nixConfig = {
                  extra-substituters = [ "https://surprise.cachix.org" ];
                };
                outputs = { self }: {};
              }
              EOF
              if attic-migrate-flake unknown 2>unknown.err; then
                echo "unknown cachix cache should fail" >&2
                exit 1
              fi
              grep -q 'surprise.cachix.org' unknown/flake.nix
              grep -q 'refusing to edit unknown Cachix' unknown.err

              python3 - <<'PY'
              import json
              import subprocess
              import tempfile
              import textwrap
              from pathlib import Path

              # Public-Attic-Cache-Decommission: every former public Cachix cache
              # migrates into the SINGLE private Attic cache. No public buckets remain.
              PRIVATE_CACHE = "metacraft-private-infrastructure"
              PRIVATE_KEY = "metacraft-private-infrastructure:TWjFAlGXK9Mky5VG3PBln2MqYz4XPw3MTHHVPYZiAhE="
              STALE = [
                  "metacraft-public:",
                  "metacraft-codetracer:",
                  "blocksense-public:",
                  "agent-harbor:",
                  "/metacraft-public",
                  "/metacraft-codetracer",
                  "/blocksense-public",
                  "/agent-harbor",
              ]

              inventory = json.loads(Path("${inventory}").read_text())
              migration = inventory["atticMigration"]
              base_url = migration["baseUrl"].rstrip("/")
              caches = migration["cachixCaches"]
              assert caches, "no Attic migration Cachix caches declared"

              required_hosts = {
                  "nix-blockchain-development.cachix.org",
                  "blocksense-infra.cachix.org",
              }
              caches_by_host = {cache["host"]: cache for cache in caches}
              for host in required_hosts:
                  assert host in caches_by_host, f"{host} missing from Attic migration inventory"
                  cache = caches_by_host[host]
                  assert cache["bucket"] == PRIVATE_CACHE, cache
                  assert cache["publicKey"] == PRIVATE_KEY, cache

              repo_buckets = {
                  repo["bucket"]
                  for root in inventory["roots"]
                  for repo in root["repositories"]
              }
              assert repo_buckets == {PRIVATE_CACHE}, repo_buckets
              mapped_buckets = {cache["bucket"] for cache in caches}
              assert mapped_buckets == {PRIVATE_CACHE}, mapped_buckets

              for cache in caches:
                  for field in ("host", "bucket", "publicKey"):
                      assert cache.get(field), f"migration cache lacks {field}: {cache}"
                  assert cache["bucket"] == PRIVATE_CACHE, cache
                  assert cache["publicKey"] == PRIVATE_KEY, cache

              with tempfile.TemporaryDirectory() as temp:
                  temp_path = Path(temp)
                  for cache in caches:
                      case = temp_path / cache["host"]
                      case.mkdir()
                      fake_key = f"{cache['host']}-1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
                      (case / "flake.nix").write_text(textwrap.dedent(f"""
                      {{
                        nixConfig = {{
                          extra-substituters = [ "https://{cache['host']}" ];
                          extra-trusted-public-keys = [ "{fake_key}" ];
                        }};
                        outputs = {{ self }}: {{}};
                      }}
                      """))

                      subprocess.run(["attic-migrate-flake", str(case)], check=True)
                      migrated = (case / "flake.nix").read_text()
                      expected_url = f"{base_url}/{PRIVATE_CACHE}"
                      assert expected_url in migrated, (cache, migrated)
                      assert PRIVATE_KEY in migrated, (cache, migrated)
                      assert f"https://{cache['host']}" not in migrated, (cache, migrated)
                      assert f"{cache['host']}-1:" not in migrated, (cache, migrated)
                      for stale in STALE:
                          assert stale not in migrated, (cache, stale, migrated)
              PY

              touch "$out"
            '';

        attic-push-flake-outputs-action =
          pkgs.runCommand "attic-push-flake-outputs-action"
            {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.python3
              ];
            }
            ''
              python3 - <<'PY'
              import os
              import subprocess
              import tempfile
              from pathlib import Path

              action = Path("${action}").read_text()
              required = [
                  "endpoint:",
                  "cache:",
                  "token:",
                  "attributes:",
                  "ATTIC_TOKEN",
                  "attic login --set-default",
                  "nix build",
                  "--print-out-paths",
                  "attic push",
                  "push_with_retry",
                  "push-attempts",
                  "push-retry-delay-seconds",
                  "missing required input",
              ]
              for needle in required:
                  assert needle in action, needle

              lines = action.splitlines()
              blocks = []
              for index, line in enumerate(lines):
                  if line.strip() != "run: |":
                      continue
                  indent = len(line) - len(line.lstrip()) + 2
                  block = []
                  for child in lines[index + 1:]:
                      if child.strip() and len(child) - len(child.lstrip()) < indent:
                          break
                      block.append(child[indent:] if len(child) >= indent else "")
                  blocks.append("\n".join(block) + "\n")
              assert blocks, "no composite action run blocks found"

              with tempfile.TemporaryDirectory() as temp:
                  temp_path = Path(temp)
                  for index, block in enumerate(blocks):
                      path = temp_path / f"block-{index}.bash"
                      path.write_text(block)
                      subprocess.run(["${pkgs.bash}/bin/bash", "-n", str(path)], check=True)

                  fake_bin = temp_path / "bin"
                  fake_bin.mkdir()
                  fake_attic_log = temp_path / "attic.log"
                  fake_attic_counter = temp_path / "attic-counter"
                  fake_nix_log = temp_path / "nix.log"

                  (fake_bin / "attic").write_text("""#!${pkgs.bash}/bin/bash
              set -euo pipefail
              printf '%s\\n' "$*" >> "$FAKE_ATTIC_LOG"
              if [ "''${FAKE_ATTIC_FAIL_PATH:-}" != "" ] && [ "$1" = "push" ]; then
                last="''${!#}"
                if [ "$last" = "$FAKE_ATTIC_FAIL_PATH" ]; then
                  count=0
                  if [ -s "$FAKE_ATTIC_COUNTER" ]; then
                    count=$(cat "$FAKE_ATTIC_COUNTER")
                  fi
                  if [ "$count" -lt "''${FAKE_ATTIC_FAIL_COUNT:-999}" ]; then
                    count=$((count + 1))
                    printf '%s\\n' "$count" > "$FAKE_ATTIC_COUNTER"
                    echo "fake attic push failed for $last" >&2
                    exit 23
                  fi
                fi
              fi
              """)
                  (fake_bin / "nix").write_text("""#!${pkgs.bash}/bin/bash
              set -euo pipefail
              printf '%s\\n' "$*" >> "$FAKE_NIX_LOG"
              attr="''${!#}"
              case "$attr" in
                ".#checks.x86_64-linux.bar")
                  printf '%s\\n' /nix/store/bar
                  ;;
                ".#packages.x86_64-linux.foo")
                  printf '%s\\n' /nix/store/foo-one /nix/store/foo-two
                  ;;
                "github:metacraft/example#prebuilt")
                  printf '%s\\n' /nix/store/prebuilt
                  ;;
                *)
                  echo "unexpected attr $attr" >&2
                  exit 44
                  ;;
              esac
              """)
                  for tool in fake_bin.iterdir():
                      tool.chmod(0o755)

                  script_paths = []
                  for index, block in enumerate(blocks):
                      path = temp_path / f"run-{index}.bash"
                      path.write_text(block)
                      script_paths.append(path)

                  base_env = os.environ.copy()
                  base_env.update({
                      "PATH": f"{fake_bin}:{base_env['PATH']}",
                      "FAKE_ATTIC_LOG": str(fake_attic_log),
                      "FAKE_ATTIC_COUNTER": str(fake_attic_counter),
                      "FAKE_NIX_LOG": str(fake_nix_log),
                      "INPUT_ENDPOINT": "https://cache.metacraft-labs.test",
                      "INPUT_CACHE": "metacraft-private-infrastructure",
                      "INPUT_TOKEN": "",
                      "INPUT_FLAKE": ".",
                      "INPUT_ATTRIBUTES": "packages.x86_64-linux.foo, checks.x86_64-linux.bar\ngithub:metacraft/example#prebuilt packages.x86_64-linux.foo",
                      "INPUT_EXTRA_NIX_ARGS": "",
                      "INPUT_EXTRA_ATTIC_PUSH_ARGS": "--jobs 2",
                      "INPUT_PUSH_ATTEMPTS": "3",
                      "INPUT_PUSH_RETRY_DELAY_SECONDS": "0",
                      "ATTIC_TOKEN": "test-token",
                  })

                  missing_env = base_env.copy()
                  missing_env["INPUT_TOKEN"] = ""
                  missing_env.pop("ATTIC_TOKEN", None)
                  result = subprocess.run(
                      ["${pkgs.bash}/bin/bash", str(script_paths[0])],
                      env=missing_env,
                      text=True,
                      capture_output=True,
                  )
                  assert result.returncode == 64, result
                  assert "missing required input(s): token or ATTIC_TOKEN" in result.stderr, result.stderr

                  invalid_attempts_env = base_env.copy()
                  invalid_attempts_env["INPUT_PUSH_ATTEMPTS"] = "0"
                  result = subprocess.run(
                      ["${pkgs.bash}/bin/bash", str(script_paths[0])],
                      env=invalid_attempts_env,
                      text=True,
                      capture_output=True,
                  )
                  assert result.returncode == 64, result
                  assert "push-attempts must be a positive integer" in result.stderr, result.stderr

                  subprocess.run(["${pkgs.bash}/bin/bash", str(script_paths[0])], env=base_env, check=True)
                  subprocess.run(["${pkgs.bash}/bin/bash", str(script_paths[1])], env=base_env, check=True)

                  attic_log = fake_attic_log.read_text().splitlines()
                  assert attic_log[0] == "login --set-default attic-push-flake-outputs https://cache.metacraft-labs.test test-token", attic_log
                  assert attic_log[1:] == [
                      "push --jobs 2 metacraft-private-infrastructure /nix/store/bar",
                      "push --jobs 2 metacraft-private-infrastructure /nix/store/prebuilt",
                      "push --jobs 2 metacraft-private-infrastructure /nix/store/foo-one",
                      "push --jobs 2 metacraft-private-infrastructure /nix/store/foo-two",
                  ], attic_log

                  nix_log = fake_nix_log.read_text()
                  for attr in [
                      ".#checks.x86_64-linux.bar",
                      "github:metacraft/example#prebuilt",
                      ".#packages.x86_64-linux.foo",
                  ]:
                      assert f"--print-out-paths {attr}" in nix_log.replace("\n", " "), nix_log

                  fake_attic_log.write_text("")
                  fake_attic_counter.write_text("")
                  fake_nix_log.write_text("")
                  transient_env = base_env.copy()
                  transient_env["INPUT_ATTRIBUTES"] = "packages.x86_64-linux.foo"
                  transient_env["FAKE_ATTIC_FAIL_PATH"] = "/nix/store/foo-two"
                  transient_env["FAKE_ATTIC_FAIL_COUNT"] = "2"
                  subprocess.run(
                      ["${pkgs.bash}/bin/bash", str(script_paths[1])],
                      env=transient_env,
                      check=True,
                  )
                  transient_log = fake_attic_log.read_text().splitlines()
                  assert transient_log.count(
                      "push --jobs 2 metacraft-private-infrastructure /nix/store/foo-two"
                  ) == 3, transient_log

                  fake_attic_log.write_text("")
                  fake_attic_counter.write_text("")
                  fake_nix_log.write_text("")
                  fail_env = base_env.copy()
                  fail_env["INPUT_ATTRIBUTES"] = "packages.x86_64-linux.foo"
                  fail_env["FAKE_ATTIC_FAIL_PATH"] = "/nix/store/foo-two"
                  result = subprocess.run(
                      ["${pkgs.bash}/bin/bash", str(script_paths[1])],
                      env=fail_env,
                      text=True,
                      capture_output=True,
                  )
                  assert result.returncode == 23, result
                  assert "fake attic push failed for /nix/store/foo-two" in result.stderr, result.stderr
                  fail_log = fake_attic_log.read_text().splitlines()
                  assert fail_log.count(
                      "push --jobs 2 metacraft-private-infrastructure /nix/store/foo-two"
                  ) == 3, fail_log
                  assert "after 3 attempts" in result.stdout, result.stdout
              PY

              touch "$out"
            '';

        consumer-flake-cachix-inventory =
          pkgs.runCommand "consumer-flake-cachix-inventory"
            {
              nativeBuildInputs = [
                self'.packages.consumer-flake-cachix-inventory-tool
                pkgs.jq
              ];
            }
            ''
              roots="$PWD/roots"
              metacraft="$roots/metacraft"
              blocksense="$roots/blocksense"
              agent_harbor="$blocksense/agent-harbor"
              mkdir -p "$metacraft" "$blocksense" "$agent_harbor"

              jq -r '.roots[] as $root | $root.repositories[] | [$root.name, .name, .bucket] | @tsv' ${inventory} |
                while IFS="$(printf '\t')" read -r root_name repo_name bucket; do
                  case "$root_name" in
                    metacraft) root="$metacraft" ;;
                    blocksense) root="$blocksense" ;;
                    agent-harbor) root="$agent_harbor" ;;
                    *) echo "unknown root $root_name" >&2; exit 1 ;;
                  esac
                  cache_host="$(jq -r --arg bucket "$bucket" '.atticMigration.cachixCaches[] | select(.bucket == $bucket) | .host' ${inventory} | head -n1)"
                  if [ -z "$cache_host" ]; then
                    echo "missing Cachix migration host for bucket $bucket" >&2
                    exit 1
                  fi
                  mkdir -p "$root/$repo_name"
                  cat > "$root/$repo_name/flake.nix" <<EOF
              {
                nixConfig.extra-substituters = [ "https://$cache_host" ];
                outputs = { self }: {};
              }
              EOF
                done

              consumer-flake-cachix-inventory \
                --inventory ${inventory} \
                --root metacraft="$metacraft" \
                --root blocksense="$blocksense" \
                --root agent-harbor="$agent_harbor"

              mkdir -p "$metacraft/new-cache-user"
              cat > "$metacraft/new-cache-user/flake.nix" <<'EOF'
              { nixConfig.extra-substituters = [ "https://mcl-public-cache.cachix.org" ]; outputs = { self }: {}; }
              EOF
              if consumer-flake-cachix-inventory \
                --inventory ${inventory} \
                --root metacraft="$metacraft" \
                --root blocksense="$blocksense" \
                --root agent-harbor="$agent_harbor" 2>err; then
                echo "inventory should fail on unexpected cachix user" >&2
                exit 1
              fi
              grep -q 'new-cache-user' err

              touch "$out"
            '';

        consumer-flake-no-cachix-residual =
          pkgs.runCommand "consumer-flake-no-cachix-residual"
            {
              nativeBuildInputs = [
                self'.packages.consumer-flake-no-cachix-residual-tool
                pkgs.jq
              ];
            }
            ''
              roots="$PWD/roots"
              metacraft="$roots/metacraft"
              blocksense="$roots/blocksense"
              agent_harbor="$blocksense/agent-harbor"
              mkdir -p "$metacraft/nixos-modules" "$blocksense/blocksense" "$agent_harbor/main"
              echo 'https://mcl-public-cache.cachix.org' > "$metacraft/nixos-modules/flake.nix"
              echo 'https://blocksense.cachix.org' > "$blocksense/blocksense/flake.nix"
              echo 'https://agent-harbor.cachix.org' > "$agent_harbor/main/flake.nix"

              consumer-flake-no-cachix-residual \
                --allowlist ${allowlist} \
                --root metacraft="$metacraft" \
                --root blocksense="$blocksense" \
                --root agent-harbor="$agent_harbor"

              consumer-flake-no-cachix-residual \
                --allowlist ${allowlist} \
                --root metacraft="$metacraft" \
                --root blocksense="$blocksense" \
                --root agent-harbor="$agent_harbor" \
                --enforce

              empty_allowlist="$PWD/empty-allowlist.json"
              jq '.allowedRepositories = [] | .enforce = true' ${allowlist} > "$empty_allowlist"
              if consumer-flake-no-cachix-residual \
                --allowlist "$empty_allowlist" \
                --root metacraft="$metacraft" \
                --root blocksense="$blocksense" \
                --root agent-harbor="$agent_harbor" 2>err; then
                echo "no-residual check should fail when enforced without allowlist" >&2
                exit 1
              fi
              grep -q 'residual cachix.org references found' err

              touch "$out"
            '';
      };
    };
}
