# Test-double policy: helper heredocs are extracted from the production script
# so the tests execute the exact emitted helper bodies, never reimplemented
# behavior. The fake `ip` replaces only the unavailable container network
# namespace while those exact `container-assert.sh` bytes run, and accepts only
# the production `-o link show` probe. The existing fake Incus isolates the
# post-runtime invalid-image-attribute boundary, with every unexpected command
# failing loudly instead of simulating any deployment behavior.
top@{ config, ... }:
{
  perSystem =
    {
      pkgs,
      lib,
      ...
    }:
    let
      rehearsal = top.config.flake.lib.deploymentIncusRehearsal;
      repoRoot = ../.;
      topology = "${repoRoot}/tests/deployment/incus-topology-example.json";
      image = rehearsal.mkDeploymentRehearsalImage {
        inherit pkgs;
        name = "generic-target";
        role = "target";
        targetGroup = "home-lab-gpu";
        networks = [
          "control"
          "cache"
          "home-lab"
        ];
        avahi = true;
        manifestText = builtins.toJSON {
          schemaVersion = 1;
          role = "target";
          targetGroup = "home-lab-gpu";
          avahi = true;
        };
      };
      scriptPath = "${repoRoot}/scripts/deployment-incus-rehearsal.sh";
      scenarios = [
        "full-topology"
        "full-topology-failures"
        "offline-latest-only"
        "forced-command"
        "break-glass"
        "pull-agent"
      ];
      runtimePath = lib.makeBinPath [
        pkgs.bash
        pkgs.coreutils
        pkgs.curl
        pkgs.gnugrep
        pkgs.gnused
        pkgs.jq
        pkgs.nix
        pkgs.python3
        pkgs.time
      ];
    in
    {
      packages = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        deployment-incus-rehearsal-image = image;
      };

      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        deployment-incus-rehearsal-script-static =
          pkgs.runCommand "deployment-incus-rehearsal-script-static" { }
            ''
                export PATH=${runtimePath}:$PATH
                export MCL_DEPLOYMENT_INCUS_TOPOLOGY=${topology}
                export MCL_DEPLOYMENT_INCUS_RUNTIME_PROBE_TIMEOUT=1
                export MCL_DEPLOYMENT_INCUS_SYSTEM=${pkgs.stdenv.hostPlatform.system}

              bash -n ${scriptPath}

              run_topology_body="$(sed -n '/^run_topology()/,/^}/p' ${scriptPath})"
              if echo "$run_topology_body" | grep -q "intentionally gated"; then
                echo "run_topology still contains the old unconditional pending-runtime gate" >&2
                exit 1
              fi
              grep -q "topology_build_import_image" ${scriptPath}
              grep -q "topology_capture_artifacts" ${scriptPath}
              grep -q "topology_exercise_forced_command" ${scriptPath}
              grep -q "topology_exercise_break_glass" ${scriptPath}
              test "$(grep -c 'example-site' ${scriptPath})" -eq 2

              bash ${scriptPath} --help > help.out 2> help.err
              grep -q "MCL_DEPLOYMENT_INCUS_SITE_GROUP" help.err
              grep -q "must be non-empty" help.err
              grep -q "existing, distinct topology group" help.err

              for scenario in ${lib.concatStringsSep " " scenarios}; do
                bash ${scriptPath} "$scenario" --check-env
                bash ${scriptPath} "$scenario" --dry-run > "$scenario.dry-run"
                grep -q "deployment-incus-rehearsal: scenario=$scenario" "$scenario.dry-run"
                grep -q "forcedCommandPrincipal=mcl-deploy-rehearsal" "$scenario.dry-run"
                grep -q "manifestPrincipal=mcl-deployment-rehearsal" "$scenario.dry-run"
                grep -q "home-lab-gpu" "$scenario.dry-run"
                grep -q "site-group=example-site" "$scenario.dry-run"
                grep -q "example-site" "$scenario.dry-run"
                grep -q "hetzner" "$scenario.dry-run"
                grep -q "workstation" "$scenario.dry-run"

                set +e
                bash ${scriptPath} "$scenario" > "$scenario.run.out" 2> "$scenario.run.err"
                status=$?
                set -e
                test "$status" -eq 69
                grep -q "pending-runtime" "$scenario.run.err"
              done

              # The public fixture's neutral site name is only a default. A
              # consumer may select a differently named, still structurally
              # identical site group without weakening any fixed rollout-group
              # or Avahi checks.
              alternate_topology="$(mktemp)"
              jq 'walk(if type == "string" then gsub("example-site"; "satellite-site") else . end)' \
                ${topology} > "$alternate_topology"

              MCL_DEPLOYMENT_INCUS_TOPOLOGY="$alternate_topology" \
                MCL_DEPLOYMENT_INCUS_SITE_GROUP=satellite-site \
                bash ${scriptPath} full-topology --check-env
              MCL_DEPLOYMENT_INCUS_TOPOLOGY="$alternate_topology" \
                MCL_DEPLOYMENT_INCUS_SITE_GROUP=satellite-site \
                bash ${scriptPath} full-topology-failures --dry-run > alternate-site.dry-run
              grep -q "site-group=satellite-site" alternate-site.dry-run
              grep -q "satellite-site-target" alternate-site.dry-run
              if grep -q "example-site" alternate-site.dry-run; then
                echo "alternate-site dry-run retained the default fixture group" >&2
                exit 1
              fi

              MCL_DEPLOYMENT_INCUS_SITE_GROUP=example-site \
                bash ${scriptPath} full-topology --check-env

              targetless_topology="$(mktemp)"
              jq '(.roles[] | select(.targetGroup == "satellite-site").role) = "monitoring"' \
                "$alternate_topology" > "$targetless_topology"
              jq -e '
                any(.targetGroups[]; .name == "satellite-site")
                and (any(.roles[]; .role == "target" and .targetGroup == "satellite-site") | not)
              ' "$targetless_topology" >/dev/null

              set +e
              env -u MCL_DEPLOYMENT_INCUS_SITE_GROUP \
                MCL_DEPLOYMENT_INCUS_TOPOLOGY="$alternate_topology" \
                bash ${scriptPath} full-topology --check-env > alternate-unset.out 2> alternate-unset.err
              alternate_unset_status=$?
              MCL_DEPLOYMENT_INCUS_TOPOLOGY="$alternate_topology" \
                MCL_DEPLOYMENT_INCUS_SITE_GROUP=missing-site \
                bash ${scriptPath} full-topology --check-env > alternate-wrong.out 2> alternate-wrong.err
              alternate_wrong_status=$?
              MCL_DEPLOYMENT_INCUS_TOPOLOGY="$alternate_topology" \
                MCL_DEPLOYMENT_INCUS_SITE_GROUP= \
                bash ${scriptPath} full-topology --check-env > alternate-empty.out 2> alternate-empty.err
              alternate_empty_status=$?
              MCL_DEPLOYMENT_INCUS_TOPOLOGY="$targetless_topology" \
                MCL_DEPLOYMENT_INCUS_SITE_GROUP=satellite-site \
                bash ${scriptPath} full-topology --check-env > targetless-site.out 2> targetless-site.err
              targetless_site_status=$?
              MCL_DEPLOYMENT_INCUS_SITE_GROUP=home-lab-gpu \
                bash ${scriptPath} full-topology --check-env > reserved-site.out 2> reserved-site.err
              reserved_site_status=$?
              set -e
              test "$alternate_unset_status" -ne 0
              test "$alternate_wrong_status" -ne 0
              test "$alternate_empty_status" -ne 0
              test "$targetless_site_status" -ne 0
              test "$reserved_site_status" -ne 0
              grep -q "does not name an existing target group with a target role" alternate-unset.err
              grep -q "does not name an existing target group with a target role" alternate-wrong.err
              grep -q "must be non-empty when set" alternate-empty.err
              grep -Fxq \
                "deployment-incus-rehearsal: MCL_DEPLOYMENT_INCUS_SITE_GROUP does not name an existing target group with a target role" \
                targetless-site.err
              grep -q "must name a distinct site group" reserved-site.err

              # Execute the exact helper bytes generated into rehearsal
              # containers. This keeps the test on the real per-container
              # Avahi assertion and real failure-scenario event generator; it
              # does not replace either with a mock implementation.
              helper_dir="$(mktemp -d)"
              python3 - ${scriptPath} "$helper_dir" <<'PY'
              import pathlib
              import sys

              source = pathlib.Path(sys.argv[1]).read_text().splitlines()
              output_dir = pathlib.Path(sys.argv[2])
              for name in ("container-assert.sh", "scenario-driver.py"):
                  marker = f'cat > "$topology_tmp_dir/{name}" <<'
                  start = next(i for i, line in enumerate(source) if marker in line)
                  delimiter = source[start].split("<<", 1)[1].strip().strip("'")
                  end = next(i for i in range(start + 1, len(source)) if source[i] == delimiter)
                  path = output_dir / name
                  path.write_text("\n".join(source[start + 1:end]) + "\n")
                  path.chmod(0o755)
              PY

              mkdir -p "$helper_dir/bin"
              cat > "$helper_dir/bin/ip" <<'SH'
              #!${pkgs.bash}/bin/bash
              set -euo pipefail
              if [[ "$#" -ne 3 || "$1" != "-o" || "$2" != "link" || "$3" != "show" ]]; then
                printf 'fake ip: unexpected argv:' >&2
                printf ' <%s>' "$@" >&2
                printf '\n' >&2
                exit 97
              fi
              printf '%s\n' \
                '1: lo: <LOOPBACK>' \
                '2: eth0: <BROADCAST>' \
                '3: eth1: <BROADCAST>' \
                '4: eth2: <BROADCAST>'
              SH
              chmod +x "$helper_dir/bin/ip"
              set +e
              "$helper_dir/bin/ip" -o address show > fake-ip-wrong.out 2> fake-ip-wrong.err
              fake_ip_wrong_status=$?
              set -e
              test "$fake_ip_wrong_status" -eq 97
              grep -Fxq "fake ip: unexpected argv: <-o> <address> <show>" fake-ip-wrong.err

              jq --arg siteGroup satellite-site '
                . as $topology
                | ($topology.roles[] | select(.targetGroup == $siteGroup)) as $role
                | {
                    schemaVersion: 1,
                    siteGroup: $siteGroup,
                    role: $role,
                    targetGroups: $topology.targetGroups
                  }
              ' "$alternate_topology" > "$helper_dir/satellite.runtime.json"
              rm -rf /tmp/mcl-rehearsal
              PATH="$helper_dir/bin:$PATH" \
                MCL_DEPLOYMENT_INCUS_RUNTIME_META="$helper_dir/satellite.runtime.json" \
                bash "$helper_dir/container-assert.sh"
              jq -e '
                .targetGroup == "satellite-site"
                and .avahiExpected == true
                and .declaredNetworkCount == 3
                and .actualInterfaceCount == 3
              ' /tmp/mcl-rehearsal/assertions.json >/dev/null

              jq '.role.avahi = false' "$helper_dir/satellite.runtime.json" > "$helper_dir/satellite-bad-avahi.runtime.json"
              set +e
              PATH="$helper_dir/bin:$PATH" \
                MCL_DEPLOYMENT_INCUS_RUNTIME_META="$helper_dir/satellite-bad-avahi.runtime.json" \
                bash "$helper_dir/container-assert.sh" > bad-avahi.out 2> bad-avahi.err
              bad_avahi_status=$?
              set -e
              test "$bad_avahi_status" -ne 0
              grep -q "expected Avahi enabled for target group satellite-site" bad-avahi.err

              scenario_out="$helper_dir/scenario-out"
              mkdir -p "$scenario_out"
              cat > "$scenario_out/failure-evidence.json" <<'JSON'
              {
                "offlineTarget": {"target": "satellite-site-target", "partitionedAndReconnected": true},
                "missingCacheObject": {"requestFailed": true, "exitCode": 22},
                "invalidSignature": {"rejected": true, "exitCode": 1},
                "switchFailure": {"failed": true, "exitCode": 1},
                "healthCheckFailure": {"failed": true, "exitCode": 1},
                "rollback": {"started": true, "completed": true, "restoredDeploymentId": 43},
                "staleDesiredState": {"rejected": true, "rejectedDeploymentId": 41, "currentDeploymentId": 42},
                "lockContention": {"detected": true, "exitCode": 1}
              }
              JSON
              python3 "$helper_dir/scenario-driver.py" \
                full-topology-failures "$alternate_topology" "$scenario_out" satellite-site
              jq -s -e '
                [.[] | select(
                  .event == "healthcheck-failed"
                  or .event == "rollback-started"
                  or .event == "rollback-complete"
                )] as $events
                | ($events | length) == 3
                and all($events[]; .targetGroup == "satellite-site")
              ' "$scenario_out/events.jsonl" >/dev/null
              jq -e '.siteGroup == "satellite-site"' "$scenario_out/final-state.json" >/dev/null
              if grep -q "example-site" "$scenario_out/events.jsonl" "$scenario_out/final-state.json"; then
                echo "alternate-site failure artifacts retained the default fixture group" >&2
                exit 1
              fi

              set +e
              python3 "$helper_dir/scenario-driver.py" \
                full-topology-failures "$alternate_topology" "$helper_dir/wrong-site-out" missing-site \
                > wrong-driver.out 2> wrong-driver.err
              wrong_driver_status=$?
              set -e
              test "$wrong_driver_status" -ne 0
              grep -q "configured site group is missing from topology" wrong-driver.err

              fake_runtime="$(mktemp -d)"
              printf '%s\n' \
                '#!${pkgs.bash}/bin/bash' \
                'set -euo pipefail' \
                'case "''${1:-}" in' \
                '  info)' \
                '    exit 0' \
                '    ;;' \
                '  stop | delete)' \
                '    exit 0' \
                '    ;;' \
                '  image)' \
                '    if [[ "''${2:-}" == "delete" ]]; then' \
                '      exit 0' \
                '    fi' \
                '    echo "fake incus should not be reached for image command before invalid image attr fails" >&2' \
                '    exit 99' \
                '    ;;' \
                '  *)' \
                '    echo "fake incus unexpected command: $*" >&2' \
                '    exit 99' \
                '    ;;' \
                'esac' \
                > "$fake_runtime/incus"
              chmod +x "$fake_runtime/incus"
              set +e
              PATH="$fake_runtime:$PATH" \
                MCL_DEPLOYMENT_INCUS_IMAGE_ATTR=".#deployment-incus-rehearsal-missing-image-attr" \
                bash ${scriptPath} full-topology > fake-runtime.out 2> fake-runtime.err
              fake_status=$?
              set -e
              if [[ "$fake_status" -eq 69 ]] || grep -q "pending-runtime" fake-runtime.err; then
                echo "run_topology returned pending-runtime even though incus info succeeded" >&2
                cat fake-runtime.err >&2
                exit 1
              fi
              grep -q "failed to build deployment rehearsal image" fake-runtime.err

              set +e
              bash ${scriptPath} full-topology --check-runtime > check-runtime.out 2> check-runtime.err
              status=$?
              set -e
              test "$status" -eq 69
              grep -q "pending-runtime" check-runtime.err

              python3 - <<'PY'
              import json
              from pathlib import Path

              topology = json.loads(Path("${topology}").read_text())
              roles = topology["roles"]
              networks = {network["name"] for network in topology["networks"]}
              scenarios = {scenario["name"] for scenario in topology["scenarios"]}

              required_networks = {"control", "cache", "home-lab", "hetzner", "workstation"}
              assert required_networks <= networks, networks
              assert {
                  "full-topology",
                  "full-topology-failures",
                  "offline-latest-only",
                  "forced-command",
                  "break-glass",
                  "pull-agent",
              } <= scenarios, scenarios

              by_group = {}
              for role in roles:
                  by_group.setdefault(role.get("targetGroup"), []).append(role)
                  role_networks = set(role["networks"])
                  assert role_networks <= networks, role
                  if role.get("targetGroup") in {"home-lab-gpu", "example-site"}:
                      assert role["avahi"] is True, role
                      assert "home-lab" in role_networks, role
                  if role.get("targetGroup") in {"hetzner", "workstation"}:
                      assert role["avahi"] is False, role
                  if role.get("targetGroup") == "hetzner":
                      assert "hetzner" in role_networks, role
                  if role.get("targetGroup") == "workstation":
                      assert "workstation" in role_networks, role

              assert by_group["home-lab-gpu"], by_group
              assert by_group["example-site"], by_group
              assert by_group["hetzner"], by_group
              assert by_group["workstation"], by_group
              assert any(role["role"] == "orchestrator" for role in roles), roles
              assert any(role["role"] == "attic-cache" for role in roles), roles
              assert any(role["role"] == "monitoring" for role in roles), roles

              controls = {
                  scenario["name"]: " ".join(scenario["controls"]).lower()
                  for scenario in topology["scenarios"]
              }
              required_controls = {
                  "full-topology": [
                      "runner",
                      "attic",
                      "monitoring",
                      "hetzner",
                      "workstation",
                      "deploy",
                  ],
                  "full-topology-failures": [
                      "partition",
                      "missing cache",
                      "invalid",
                      "signature",
                      "switch failure",
                      "health-check failure",
                      "rollback",
                      "lock contention",
                  ],
                  "offline-latest-only": [
                      "deployment 41",
                      "deployment 42",
                      "offline",
                      "only deployment 42 applies",
                  ],
                  "forced-command": [
                      "arbitrary shell",
                      "rejected",
                      "signed manifest",
                      "signature",
                  ],
                  "break-glass": [
                      "failed deploy",
                      "human runbook",
                      "arbitrary shell",
                      "rejected",
                      "signed manifest",
                      "rollback",
                      "final generation",
                  ],
                  "pull-agent": [
                      "signed manifests",
                      "partition",
                      "newer desired state",
                      "latest",
                  ],
              }
              for scenario, tokens in required_controls.items():
                  text = controls[scenario]
                  missing = [token for token in tokens if token not in text]
                  assert not missing, (scenario, missing, text)
              PY

              touch "$out"
            '';
      };
    };
}
