{ ... }:
{
  perSystem =
    {
      pkgs,
      self',
      ...
    }:
    let
      repoRoot = ../.;
      docs = ../docs/deployment;
      skills = ../docs/skills;
      workflow = ../.github/workflows/reusable-flake-checks-ci-matrix.yml;
    in
    {
      checks = {
        deployment-event-schema-examples = pkgs.runCommand "deployment-event-schema-examples" { } ''
          ${pkgs.python3}/bin/python3 <<'PY'
          import json
          import re
          from pathlib import Path

          docs = Path("${docs}")
          schema = json.loads((docs / "event-schema.json").read_text())
          examples = docs / "examples" / "events-success.jsonl"
          desired_state_schema = json.loads((docs / "desired-state-schema.json").read_text())
          desired_state_example_path = docs / "examples" / "desired-state-success.json"

          expected_desired_state_required = [
              "schemaVersion",
              "deploymentId",
              "target",
              "gitRevision",
              "sequence",
              "manifestSignature",
              "desiredSystemPath",
              "cacheRequirements",
              "healthChecks",
              "rollbackPolicy",
              "currentState",
              "supersededState",
              "retryTimestamps",
          ]
          actual_desired_state_required = desired_state_schema["required"]
          if actual_desired_state_required != expected_desired_state_required:
              raise SystemExit(
                  "desired-state required fields drifted: "
                  f"{actual_desired_state_required!r}"
              )

          expected_phases = [
              "evaluate",
              "build",
              "closure-prefill",
              "cache-push",
              "activate-requested",
              "agent-restore",
              "switch",
              "healthcheck",
              "rollback",
              "complete",
          ]
          actual_phases = schema["properties"]["phase"]["enum"]
          if actual_phases != expected_phases:
              raise SystemExit(f"phase enum drifted: {actual_phases!r}")

          def type_name(value):
              if value is None:
                  return "null"
              if isinstance(value, bool):
                  return "boolean"
              if isinstance(value, int) and not isinstance(value, bool):
                  return "integer"
              if isinstance(value, str):
                  return "string"
              if isinstance(value, list):
                  return "array"
              if isinstance(value, dict):
                  return "object"
              return type(value).__name__

          def validate(schema, value, path):
              allowed = schema.get("type")
              if allowed is not None:
                  allowed_types = allowed if isinstance(allowed, list) else [allowed]
                  actual = type_name(value)
                  if actual not in allowed_types:
                      raise AssertionError(f"{path}: expected {allowed_types}, got {actual}")
                  if actual == "null":
                      return

              if "enum" in schema and value not in schema["enum"]:
                  raise AssertionError(f"{path}: {value!r} not in enum {schema['enum']!r}")

              if "minLength" in schema and len(value) < schema["minLength"]:
                  raise AssertionError(f"{path}: shorter than minLength {schema['minLength']}")
              if "minimum" in schema and value < schema["minimum"]:
                  raise AssertionError(f"{path}: less than minimum {schema['minimum']}")
              if "pattern" in schema and not re.search(schema["pattern"], value):
                  raise AssertionError(f"{path}: {value!r} does not match {schema['pattern']!r}")

              if type_name(value) == "object":
                  required = schema.get("required", [])
                  for key in required:
                      if key not in value:
                          raise AssertionError(f"{path}: missing required key {key!r}")
                  props = schema.get("properties", {})
                  if schema.get("additionalProperties") is False:
                      extra = sorted(set(value) - set(props))
                      if extra:
                          raise AssertionError(f"{path}: unexpected keys {extra!r}")
                  for key, nested in props.items():
                      if key in value:
                          validate(nested, value[key], f"{path}.{key}")

              if type_name(value) == "array" and "items" in schema:
                  for index, item in enumerate(value):
                      validate(schema["items"], item, f"{path}[{index}]")

          seen = []
          for line_no, line in enumerate(examples.read_text().splitlines(), 1):
              if not line.strip():
                  continue
              event = json.loads(line)
              validate(schema, event, f"events-success.jsonl:{line_no}")
              seen.append(event["phase"])

          required_success_phases = [
              phase for phase in expected_phases if phase != "rollback"
          ]
          missing = [phase for phase in required_success_phases if phase not in seen]
          if missing:
              raise SystemExit(f"success example missing phases: {missing!r}")
          if "rollback" in seen:
              raise SystemExit("success example must not include rollback phase")

          desired_state_example = json.loads(desired_state_example_path.read_text())
          validate(
              desired_state_schema,
              desired_state_example,
              "examples/desired-state-success.json",
          )
          PY
          touch "$out"
        '';

        deployment-current-flow-inventory = pkgs.runCommand "deployment-current-flow-inventory" { } ''
          ${pkgs.python3}/bin/python3 <<'PY'
          import json
          import re
          from pathlib import Path

          docs = Path("${docs}")
          workflow = Path("${workflow}")
          inventory = json.loads((docs / "current-flow-inventory.json").read_text())
          text = workflow.read_text()

          required_files = [
              docs / "event-schema.json",
              docs / "desired-state-schema.json",
              docs / "examples" / "events-success.jsonl",
              docs / "examples" / "desired-state-success.json",
              docs / "current-cachix-flow.md",
              docs / "cache-and-deploy-risk-register.md",
          ]
          for path in required_files:
              if not path.is_file():
                  raise SystemExit(f"required M0 key source file is missing: {path.relative_to(docs.parent)}")

          workflow_name = re.compile(
              r"^name:\s*['\"]?" + re.escape(inventory["workflowName"]) + r"['\"]?\s*$",
              re.MULTILINE,
          )
          if not workflow_name.search(text):
              raise SystemExit(f"workflow name {inventory['workflowName']!r} not found")

          for job in inventory["jobs"]:
              if not re.search(r"^  " + re.escape(job) + r":\s*$", text, re.MULTILINE):
                  raise SystemExit(f"documented job not found in workflow: {job}")

          for step in inventory["criticalSteps"]:
              quoted = re.escape(step)
              if not re.search(r"^\s+- name:\s*['\"]?" + quoted + r"['\"]?\s*$", text, re.MULTILINE):
                  raise SystemExit(f"documented step not found in workflow: {step}")

          for command in inventory["criticalCommands"]:
              if command not in text:
                  raise SystemExit(f"documented command fragment not found in workflow: {command}")

          publish = inventory["deploymentCachePublishPath"]
          for value in [publish["entryJob"], publish["publishStep"], publish["publishCondition"], publish["mclCommand"]]:
              if value not in text:
                  raise SystemExit(f"deployment cache publish path value not found in workflow: {value}")

          removed = inventory["removedDeployPath"]
          for token in removed["absentTokens"]:
              if token in text:
                  raise SystemExit(f"legacy Cachix Deploy token must be absent from the Attic-only workflow: {token}")

          monitoring = inventory["monitoringPath"]
          required_monitoring_sources = {
              "metacraft-labs/infra/services/monitoring/cachix-deploy-metrics/default.nix",
              "modules/cachix-deploy-metrics/default.nix",
              "packages/cachix-deploy-metrics/default.nix",
              "packages/cachix-deploy-metrics/main.d",
          }
          documented_sources = set(monitoring["sourceFiles"])
          missing_sources = sorted(required_monitoring_sources - documented_sources)
          if missing_sources:
              raise SystemExit(f"monitoring inventory is missing sources: {missing_sources!r}")

          flow_doc = (docs / "current-cachix-flow.md").read_text()
          required_monitoring_terms = [
              "services.cachix-deploy-metrics",
              "auth-token-path",
              "workspace",
              "agent-names",
              "Prometheus exporter",
              "Cachix Deploy API",
              "event stream",
          ]
          for term in required_monitoring_terms:
              if term not in flow_doc:
                  raise SystemExit(f"current Cachix flow doc is missing monitoring term: {term}")
          for source in required_monitoring_sources:
              if source not in flow_doc:
                  raise SystemExit(f"current Cachix flow doc is missing monitoring source: {source}")
          PY
          touch "$out"
        '';

        deployment-cache-backend-policy = pkgs.runCommand "deployment-cache-backend-policy" { } ''
          ${pkgs.python3}/bin/python3 <<'PY'
          import os
          import re
          import subprocess
          import tempfile
          from pathlib import Path

          workflow = Path("${workflow}")
          text = workflow.read_text()

          def require(condition, message):
              if not condition:
                  raise SystemExit(message)

          require(
              re.search(
                  r"deployment-cache-required-backends:\s*\n"
                  r"\s+description:.*\n"
                  r"\s+default:\s*'attic'\s*\n"
                  r"\s+required:\s*false\s*\n"
                  r"\s+type:\s*string",
                  text,
              ),
              "reusable workflow must expose deployment-cache-required-backends defaulting to attic",
          )
          require(
              re.search(
                  r"deployment-cache-optional-timeout-seconds:\s*\n"
                  r"\s+description:.*\n"
                  r"\s+default:\s*'300'\s*\n"
                  r"\s+required:\s*false\s*\n"
                  r"\s+type:\s*string",
                  text,
              ),
              "reusable workflow must expose configurable optional backend timeout defaulting to 300 seconds",
          )
          require(
              "DEPLOYMENT_CACHE_REQUIRED_BACKENDS: ''${{ inputs.deployment-cache-required-backends }}" in text,
              "cache push step must receive the required backend policy input",
          )
          require(
              "DEPLOYMENT_CACHE_OPTIONAL_TIMEOUT_SECONDS: ''${{ inputs.deployment-cache-optional-timeout-seconds }}" in text,
              "cache push step must receive the optional backend timeout input",
          )
          require(
              "backend_is_required()" in text and 'required=true' in text,
              "cache push script must classify attempted backends as required or optional",
          )
          require(
              'echo "::warning title=Optional deployment cache backend::backend=$backend $message"' in text,
              "optional backend failures must emit GitHub warning annotations",
          )
          require(
              'warn_optional_backend "$backend" "$message; continuing without this mirror backend"' in text,
              "optional missing variables must warn and continue",
          )
          require(
              re.search(
                  r'if \[\[ "\$required" == true \]\]; then\s*\n'
                  r'\s+echo "\$message" >&2\s*\n'
                  r'\s+exit 1',
                  text,
              ),
              "required missing variables must exit hard",
          )
          require(
              'require_backend_vars "$backend" "$required" ATTIC_TOKEN ATTIC_CACHE ATTIC_SUBSTITUTER ATTIC_TRUSTED_PUBLIC_KEY' in text,
              "Attic variables must be checked manually through the backend policy",
          )
          require("cachix)" not in text, "Attic-only cache push must not retain a cachix backend case")
          require("CACHIX_CACHE" not in text and "CACHIX_AUTH_TOKEN" not in text, "Attic-only cache push step must not reference Cachix env")
          require("--transport attic-ci" in text, "deployment cache push must use the Attic CI transport")
          for forbidden in [
              ': "''${ATTIC_TOKEN:?',
              ': "''${ATTIC_CACHE:?',
              ': "''${ATTIC_SUBSTITUTER:?',
              ': "''${ATTIC_TRUSTED_PUBLIC_KEY:?',
          ]:
              require(forbidden not in text, f"Attic variable guard bypasses optional policy: {forbidden}")
          require(
              'timeout --kill-after=30s "''${DEPLOYMENT_CACHE_OPTIONAL_TIMEOUT_SECONDS}s" "$@"' in text,
              "optional backend commands must be wrapped in the configurable timeout",
          )
          require(
              'if [[ "$required" == true ]]; then\n              "$@"' in text,
              "required backend commands must run directly without the optional timeout wrapper",
          )
          require(
              'Required deployment cache backend $backend failed during $label' in text,
              "required backend command failures must exit hard",
          )
          require(
              'if ! run_backend_command "$backend" "$required" "attic login"' in text,
              "Attic login must honor required versus optional policy",
          )
          require(
              'if ! run_backend_command "$backend" "$required" "cache push and substitute probe"' in text,
              "cache push and substitute probe must honor required versus optional policy",
          )
          require(
              "if: ''${{ always() && inputs.push-deployment-caches && !matrix.noop && matrix.deploymentTarget }}" in text,
              "cache push event artifact upload must remain available after optional backend failures",
          )

          def extract_cache_push_script():
              lines = text.splitlines()
              step_index = None
              for index, line in enumerate(lines):
                  if re.match(r"\s+- name: Push deployment closure caches", line):
                      step_index = index
                      break
              require(step_index is not None, "cache push step not found")

              run_index = None
              for index in range(step_index + 1, len(lines)):
                  if re.match(r"\s+run:\s*\|\s*$", lines[index]):
                      run_index = index
                      break
                  if re.match(r"\s+- name:", lines[index]):
                      break
              require(run_index is not None, "cache push run block not found")

              run_indent = len(lines[run_index]) - len(lines[run_index].lstrip())
              block_indent = run_indent + 2
              block = []
              for line in lines[run_index + 1:]:
                  if not line.strip():
                      block.append("")
                      continue
                  indent = len(line) - len(line.lstrip())
                  if indent <= run_indent:
                      break
                  require(indent >= block_indent, f"unexpected run block indentation: {line!r}")
                  block.append(line[block_indent:])
              return "\n".join(block) + "\n"

          script = extract_cache_push_script()
          require(
              "''${{ needs.compute-mcl-ref.outputs.mcl_flake_cmd }}" in script,
              "cache push script must still use the computed mcl-devops flake command expression",
          )
          script = script.replace("''${{ needs.compute-mcl-ref.outputs.mcl_flake_cmd }}", "mcl-devops")

          with tempfile.TemporaryDirectory() as temp:
              temp_path = Path(temp)
              script_path = temp_path / "cache-policy.sh"
              script_path.write_text(script)
              subprocess.run(
                  ["${pkgs.bash}/bin/bash", "-n", str(script_path)],
                  check=True,
              )

              fake_bin = temp_path / "bin"
              fake_bin.mkdir()
              log_path = temp_path / "commands.log"
              (fake_bin / "nix").write_text(
                  """#!${pkgs.bash}/bin/bash
          printf 'nix %s\\n' "$*" >> "$FAKE_LOG"
          if [[ "''${NIX_FAIL_LOGIN:-}" == 1 ]]; then
            exit 19
          fi
          exit 0
          """
              )
              (fake_bin / "mcl-devops").write_text(
                  """#!${pkgs.bash}/bin/bash
          backend=""
          previous=""
          for arg in "$@"; do
            if [[ "$previous" == "--backend" ]]; then
              backend="$arg"
            fi
            previous="$arg"
          done
          printf 'mcl-devops backend=%s args=%s\\n' "$backend" "$*" >> "$FAKE_LOG"
          mkdir -p .result
          printf '{"phase":"cache-push","backend":"%s"}\\n' "$backend" >> .result/deployment-cache-push-events.jsonl
          if [[ "''${MCL_SLEEP_BACKEND:-}" == "$backend" ]]; then
            sleep 2
          fi
          if [[ "''${MCL_FAIL_BACKEND:-}" == "$backend" ]]; then
            exit 23
          fi
          exit 0
          """
              )
              os.chmod(fake_bin / "nix", 0o755)
              os.chmod(fake_bin / "mcl-devops", 0o755)

              base_env = {
                  "PATH": str(fake_bin) + ":${pkgs.coreutils}/bin",
                  "FAKE_LOG": str(log_path),
                  "DEPLOY_TARGET": "test-target",
                  "DEPLOY_SYSTEM": "x86_64-linux",
                  "DEPLOY_KIND": "server",
                  "DEPLOY_STORE_PATH": "${pkgs.hello}",
                  "DEPLOYMENT_CACHE_PUSH_BACKENDS": "attic,none",
                  "DEPLOYMENT_CACHE_REQUIRED_BACKENDS": "attic",
                  "DEPLOYMENT_CACHE_OPTIONAL_TIMEOUT_SECONDS": "1",
                  "ATTIC_CACHE": "mirror-cache",
                  "ATTIC_SUBSTITUTER": "https://attic.example/mirror-cache",
                  "ATTIC_ENDPOINT": "",
                  "ATTIC_TRUSTED_PUBLIC_KEY": "attic-public-key",
                  "ATTIC_TOKEN": "attic-token",
                  "DEPLOYMENT_TRUSTED_PUBLIC_KEYS": "",
                  "DEPLOYMENT_TRUSTED_SUBSTITUTERS": "",
              }

              def run_case(
                  name,
                  env_updates,
                  expected_returncode,
                  stdout_contains=(),
                  stderr_contains=(),
                  log_contains=(),
                  log_absent=(),
                  expect_artifact=None,
              ):
                  log_path.write_text("")
                  case_dir = temp_path / name
                  case_dir.mkdir()
                  home = case_dir / "home"
                  home.mkdir()
                  env = os.environ.copy()
                  env.update(base_env)
                  env["HOME"] = str(home)
                  env.update(env_updates)

                  result = subprocess.run(
                      ["${pkgs.bash}/bin/bash", str(script_path)],
                      cwd=case_dir,
                      env=env,
                      text=True,
                      stdout=subprocess.PIPE,
                      stderr=subprocess.PIPE,
                  )
                  require(
                      result.returncode == expected_returncode,
                      f"{name}: expected exit {expected_returncode}, got {result.returncode}\n"
                      f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
                  )
                  for needle in stdout_contains:
                      require(needle in result.stdout, f"{name}: stdout missing {needle!r}: {result.stdout}")
                  for needle in stderr_contains:
                      require(needle in result.stderr, f"{name}: stderr missing {needle!r}: {result.stderr}")
                  log = log_path.read_text()
                  for needle in log_contains:
                      require(needle in log, f"{name}: command log missing {needle!r}: {log}")
                  for needle in log_absent:
                      require(needle not in log, f"{name}: command log unexpectedly contained {needle!r}: {log}")
                  if expect_artifact is not None:
                      artifact = case_dir / ".result" / "deployment-cache-push-events.jsonl"
                      has_artifact = artifact.exists() and artifact.read_text().strip()
                      require(bool(has_artifact) == expect_artifact, f"{name}: artifact expectation failed")

              run_case(
                  "optional_attic_missing_vars",
                  {"DEPLOYMENT_CACHE_REQUIRED_BACKENDS": "none", "ATTIC_TOKEN": ""},
                  0,
                  stdout_contains=("::warning title=Optional deployment cache backend::backend=attic",),
                  log_contains=("mcl-devops backend=none",),
                  log_absent=("nix shell", "mcl-devops backend=attic"),
                  expect_artifact=True,
              )
              run_case(
                  "required_attic_missing_vars",
                  {
                      "DEPLOYMENT_CACHE_PUSH_BACKENDS": "attic",
                      "DEPLOYMENT_CACHE_REQUIRED_BACKENDS": "attic",
                      "ATTIC_TOKEN": "",
                  },
                  1,
                  stderr_contains=("ATTIC_TOKEN required when deployment-cache-push-backends includes attic",),
                  log_absent=("nix shell", "mcl-devops backend="),
                  expect_artifact=False,
              )
              run_case(
                  "optional_attic_login_failure",
                  {
                      "DEPLOYMENT_CACHE_PUSH_BACKENDS": "attic",
                      "DEPLOYMENT_CACHE_REQUIRED_BACKENDS": "none",
                      "NIX_FAIL_LOGIN": "1",
                  },
                  0,
                  stdout_contains=("attic login failed with exit 19; continuing",),
                  log_contains=("nix shell nixpkgs#attic-client -c attic login",),
                  log_absent=("mcl-devops backend=attic",),
                  expect_artifact=False,
              )
              run_case(
                  "required_attic_login_failure",
                  {
                      "DEPLOYMENT_CACHE_PUSH_BACKENDS": "attic",
                      "DEPLOYMENT_CACHE_REQUIRED_BACKENDS": "attic",
                      "NIX_FAIL_LOGIN": "1",
                  },
                  19,
                  stderr_contains=("Required deployment cache backend attic failed during attic login",),
                  log_contains=("nix shell nixpkgs#attic-client -c attic login",),
                  expect_artifact=False,
              )
              run_case(
                  "optional_attic_push_failure_preserves_artifact",
                  {
                      "DEPLOYMENT_CACHE_PUSH_BACKENDS": "attic",
                      "DEPLOYMENT_CACHE_REQUIRED_BACKENDS": "none",
                      "MCL_FAIL_BACKEND": "attic",
                  },
                  0,
                  stdout_contains=("cache push and substitute probe failed with exit 23; continuing",),
                  log_contains=("nix shell nixpkgs#attic-client -c attic login", "mcl-devops backend=attic"),
                  expect_artifact=True,
              )
              run_case(
                  "required_attic_push_failure",
                  {
                      "DEPLOYMENT_CACHE_PUSH_BACKENDS": "attic",
                      "DEPLOYMENT_CACHE_REQUIRED_BACKENDS": "attic",
                      "MCL_FAIL_BACKEND": "attic",
                  },
                  23,
                  stderr_contains=("Required deployment cache backend attic failed during cache push and substitute probe",),
                  log_contains=("nix shell nixpkgs#attic-client -c attic login", "mcl-devops backend=attic"),
                  expect_artifact=True,
              )
              run_case(
                  "attic_probe_uses_only_attic_substituter",
                  {
                      "DEPLOYMENT_CACHE_PUSH_BACKENDS": "attic",
                      "DEPLOYMENT_CACHE_REQUIRED_BACKENDS": "attic",
                      "DEPLOYMENT_TRUSTED_SUBSTITUTERS": "https://aux.example https://mirror.example",
                      "DEPLOYMENT_TRUSTED_PUBLIC_KEYS": "aux-public-key",
                  },
                  0,
                  log_contains=(
                      "mcl-devops backend=attic",
                      "--substituter https://attic.example/mirror-cache --require-substitute",
                      "--trusted-public-key aux-public-key",
                      "--trusted-public-key attic-public-key",
                  ),
                  log_absent=(
                      "--substituter https://aux.example",
                      "--substituter https://mirror.example",
                      "--substituter https://cache.nixos.org",
                      "cache.nixos.org-1:",
                  ),
                  expect_artifact=True,
              )
              run_case(
                  "none_probe_keeps_fallback_substituters",
                  {
                      "DEPLOYMENT_CACHE_PUSH_BACKENDS": "none",
                      "DEPLOYMENT_CACHE_REQUIRED_BACKENDS": "none",
                      "DEPLOYMENT_TRUSTED_SUBSTITUTERS": "https://aux.example",
                      "DEPLOYMENT_TRUSTED_PUBLIC_KEYS": "aux-public-key",
                  },
                  0,
                  log_contains=(
                      "mcl-devops backend=none",
                      "--substituter https://aux.example",
                      "--substituter https://cache.nixos.org",
                      "--trusted-public-key aux-public-key",
                      "cache.nixos.org-1:",
                  ),
                  log_absent=("--require-substitute",),
                  expect_artifact=True,
              )
              run_case(
                  "optional_attic_timeout",
                  {
                      "DEPLOYMENT_CACHE_PUSH_BACKENDS": "attic",
                      "DEPLOYMENT_CACHE_REQUIRED_BACKENDS": "none",
                      "MCL_SLEEP_BACKEND": "attic",
                  },
                  0,
                  stdout_contains=("cache push and substitute probe timed out after 1s; continuing",),
                  log_contains=("mcl-devops backend=attic",),
                  expect_artifact=True,
              )
          PY
          touch "$out"
        '';

        deployment-skill-doc-command-references =
          pkgs.runCommand "deployment-skill-doc-command-references" { }
            ''
              ${pkgs.python3}/bin/python3 <<'PY'
              import json
              import re
              import shlex
              from pathlib import Path

              repo = Path("${repoRoot}")
              docs = Path("${docs}")
              skills = Path("${skills}")
              surface = json.loads((docs / "operator-command-surface.json").read_text())

              skill_names = [
                  "deployment-investigation",
                  "deployment-operation",
                  "cache-operation",
                  "deployment-break-glass",
                  "deployment-reconciler",
                  "deployment-e2e-rehearsal",
              ]
              required_sections = [
                  "## Prerequisites",
                  "## Commands",
                  "## Workflow",
                  "## Evidence",
                  "## Stop And Ask",
                  "## Rollback",
              ]

              def require(condition, message):
                  if not condition:
                      raise SystemExit(message)

              def read(path):
                  require(path.is_file(), f"missing required file: {path}")
                  return path.read_text()

              skill_paths = [skills / name / "SKILL.md" for name in skill_names]
              runbook = docs / "runbook.md"
              all_docs = skill_paths + [runbook]
              for name, path in zip(skill_names, skill_paths):
                  text = read(path)
                  frontmatter = re.match(r"---\n(.*?)\n---\n", text, re.S)
                  require(frontmatter, f"{path}: missing YAML frontmatter")
                  require(f"name: {name}" in frontmatter.group(1), f"{path}: frontmatter name mismatch")
                  require("description:" in frontmatter.group(1), f"{path}: missing description")
                  for section in required_sections:
                      require(section in text, f"{path}: missing required section {section}")
                  require("```sh" in text, f"{path}: missing shell command block")

              require(read(runbook).startswith("# Deployment Operator Runbook"), "runbook title drifted")

              for command, spec in surface["mclCommands"].items():
                  source = repo / spec["source"]
                  source_text = read(source)
                  for token in spec["tokens"]:
                      require(token in source_text, f"{command}: source token missing from {source}: {token}")

              required_by_file = {
                  "docs/skills/deployment-investigation/SKILL.md": [
                      "mcl-devops deploy-status summarize",
                      "gh run view",
                      "gh run download",
                      "nix path-info --store",
                  ],
                  "docs/skills/deployment-operation/SKILL.md": [
                      "just deploy-machine",
                      "just deploy-machine-direct-ssh",
                      "mcl-devops cache push-closure",
                      "mcl-devops deploy-plan",
                      "mcl-devops deploy-ssh",
                      "mcl-devops deploy-status summarize",
                  ],
                  "docs/skills/cache-operation/SKILL.md": [
                      "mcl-devops cache push-closure",
                      "nix path-info --store",
                      "just attic-verify-host-substituters",
                  ],
                  "docs/skills/deployment-break-glass/SKILL.md": [
                      "just deploy-machine-direct-ssh",
                      "mcl-devops deploy-plan",
                      "mcl-devops deploy-ssh",
                      "just rollback-machine-direct-ssh",
                  ],
                  "docs/skills/deployment-reconciler/SKILL.md": [
                      "mcl-devops deploy-reconcile",
                      "mcl-devops deploy-agent",
                      "systemctl status mcl-deployment-reconciler.service",
                      "systemctl status mcl-deploy-agent.service",
                  ],
                  "docs/skills/deployment-e2e-rehearsal/SKILL.md": [
                      "deployment-attic-push-substitute-vm",
                      "deployment-cache-corruption-vm",
                      "deployment-direct-ssh-success-vm",
                      "deployment-direct-ssh-rollback-vm",
                      "deployment-direct-ssh-attic-restore-vm",
                      "deployment-reconciler-timer-retry-vm",
                      "deployment-reconciler-lock-contention-vm",
                      "deployment-pull-agent-latest-vm",
                      "deployment-pull-agent-rejects-invalid-vm",
                      "deployment-pull-agent-lock-contention-vm",
                      "deployment-scheduled-canary-local-vm",
                      "deployment-incus-rehearsal-image",
                      "deployment-incus-rehearsal-script-static",
                      "bash scripts/deployment-incus-rehearsal.sh",
                  ],
                  "docs/deployment/runbook.md": [
                      "mcl-devops deploy-status summarize",
                      "just deploy-machine-direct-ssh",
                      "just deployment-incus-rehearsal",
                      "just test-deployment-incus-rehearsal",
                      "mcl-devops cache push-closure",
                      "mcl-devops deploy-plan",
                      "mcl-devops deploy-ssh",
                      "mcl-devops deploy-reconcile",
                      "mcl-devops deploy-apply",
                      "just attic-verify-host-substituters",
                      "bash scripts/deployment-incus-rehearsal.sh",
                  ],
              }

              for rel, terms in required_by_file.items():
                  path = repo / rel
                  text = read(path)
                  for term in terms:
                      require(term in text, f"{rel}: missing documented command/check {term!r}")

              allowed_mcl_commands = set(surface["mclCommands"])
              allowed_just_targets = set(surface["infraJustTargets"])
              allowed_rehearsal_scenarios = set(surface["rehearsalScenarios"])

              def shell_blocks(text):
                  in_block = False
                  for line in text.splitlines():
                      if line.startswith("```"):
                          fence = line.strip()
                          if not in_block and fence in {"```sh", "```bash"}:
                              in_block = True
                              continue
                          if in_block:
                              in_block = False
                              continue
                      if in_block:
                          stripped = line.strip()
                          if stripped and not stripped.startswith("#"):
                              yield stripped

              def parse_command_line(line):
                  try:
                      return shlex.split(line.rstrip("\\"))
                  except ValueError as error:
                      raise SystemExit(f"invalid shell command line in M6 docs: {line!r}: {error}") from error

              def doc_label(path):
                  if path == runbook:
                      return "docs/deployment/runbook.md"
                  return f"docs/skills/{path.parent.name}/SKILL.md"

              for path in all_docs:
                  rel = doc_label(path)
                  for line in shell_blocks(read(path)):
                      tokens = parse_command_line(line)
                      if not tokens:
                          continue
                      if tokens[0] == "mcl-devops":
                          prefixes = [
                              " ".join(tokens[:width])
                              for width in range(min(len(tokens), 3), 1, -1)
                          ]
                          require(
                              any(prefix in allowed_mcl_commands for prefix in prefixes),
                              f"{rel}: documented stale or uninventoried mcl-devops command: {line!r}",
                          )
                      if tokens[0] == "just":
                          require(
                              len(tokens) >= 2 and tokens[1] in allowed_just_targets,
                              f"{rel}: documented stale or uninventoried just target: {line!r}",
                          )
                      if (
                          tokens[0] == "bash"
                          and len(tokens) >= 3
                          and tokens[1] == "scripts/deployment-incus-rehearsal.sh"
                      ):
                          require(
                              tokens[2] in allowed_rehearsal_scenarios,
                              f"{rel}: documented stale or uninventoried rehearsal scenario: {line!r}",
                          )

              all_text = "\n".join(read(path) for path in all_docs)
              for command in surface["mclCommands"]:
                  if command in all_text:
                      continue
                  require(command == "mcl-devops deploy-apply", f"mcl command not referenced by docs: {command}")
              for target in surface["infraJustTargets"]:
                  if target in all_text:
                      continue
                  require(target in {"deploy-machine-cachix", "deploy-machine-remote-switch"}, f"Just target not referenced by docs: {target}")

              forbidden_test_words = re.compile(r"\b(skip|skipped|ignore|ignored|placeholder)\b", re.I)
              for path in all_docs:
                  text = read(path)
                  matches = [m.group(0) for m in forbidden_test_words.finditer(text)]
                  allowed = {"pending"} if path.name == "runbook.md" else set()
                  require(not matches, f"{path}: weak-test wording is not allowed in M6 docs: {matches}")
              PY
              touch "$out"
            '';

        deployment-break-glass-runbook-sections =
          pkgs.runCommand "deployment-break-glass-runbook-sections" { }
            ''
              ${pkgs.python3}/bin/python3 <<'PY'
              from pathlib import Path

              skill = Path("${skills}") / "deployment-break-glass" / "SKILL.md"
              runbook = Path("${docs}") / "runbook.md"
              skill_text = skill.read_text()
              runbook_text = runbook.read_text()

              def require(term, text, label):
                  if term not in text:
                      raise SystemExit(f"{label}: missing {term!r}")

              for section in [
                  "## Prerequisites",
                  "## Commands",
                  "## Workflow",
                  "## Forced-command SSH Boundary",
                  "## Evidence",
                  "## Stop And Ask",
                  "## Rollback",
              ]:
                  require(section, skill_text, str(skill))

              for section in [
                  "## Safe Direct SSH Deploy",
                  "## Rollback",
                  "## Forced-command SSH Boundary",
                  "## Human Approval Required",
              ]:
                  require(section, runbook_text, str(runbook))

              for term in [
                  "human approval",
                  "verified host key",
                  "MCL_DEPLOY_MANIFEST_SIGNING_KEY",
                  "MCL_DEPLOY_SSH_IDENTITY",
                  "just deploy-machine-direct-ssh",
                  "mcl-devops deploy-plan",
                  "mcl-devops deploy-ssh",
                  "just rollback-machine-direct-ssh",
                  "BatchMode=yes",
                  "StrictHostKeyChecking=yes",
                  "--reject-ssh-original-command",
                  "allowed-signers",
                  "sudo -n",
                  "SSH_ORIGINAL_COMMAND",
                  "restrict,no-agent-forwarding,no-X11-forwarding,no-port-forwarding,no-pty",
                  "manifest signature",
                  "manifest target",
              ]:
                  require(term, skill_text, str(skill))

              for term in [
                  "verified SSH host key",
                  "restricted deploy SSH key",
                  "signed manifest",
                  "cache substitute proof",
                  "interactive shell",
                  "sudo -n",
                  "mcl-devops deploy-apply --manifest - --allowed-signers",
                  "--reject-ssh-original-command",
                  "bypassing SSH host key checks",
                  "bypassing manifest signature checks",
              ]:
                  require(term, runbook_text, str(runbook))
              PY
              touch "$out"
            '';

        deployment-reconciler-skill-doc = pkgs.runCommand "deployment-reconciler-skill-doc" { } ''
          ${pkgs.python3}/bin/python3 <<'PY'
          from pathlib import Path

          repo = Path("${repoRoot}")
          skill = Path("${skills}") / "deployment-reconciler" / "SKILL.md"
          runbook = Path("${docs}") / "runbook.md"
          state_source = repo / "packages/mcl-devops/src/mcl/utils/deploy_state.d"
          agent_source = repo / "packages/mcl-devops/src/mcl/commands/deploy_agent.d"

          combined = skill.read_text() + "\n" + runbook.read_text()
          for term in [
              "latest-only",
              "pending",
              "accepted",
              "superseded",
              "failed",
              "converged",
              "succeeded",
              "retryable",
              "retry budget",
              "non-retryable",
              "maxAttempts",
              "same-sequence",
              "different deployment id",
              "flock -n",
              "targets/<target>.json",
              "desired/",
              "current/",
              "failed/",
              "superseded/",
              "converged/",
              "agent-status/",
              "mcl-devops deploy-reconcile --state-dir",
              "mcl-devops deploy-agent --target",
              "mcl-deployment-reconciler.service",
              "mcl-deploy-agent.service",
          ]:
              if term not in combined:
                  raise SystemExit(f"reconciler docs missing {term!r}")

          source_text = state_source.read_text()
          for token in [
              '"desired"',
              '"current"',
              '"failed"',
              '"superseded"',
              '"converged"',
              '"targets"',
              '"agent-status"',
              "recordDesiredManifest",
              "supersededStateForLatest",
          ]:
              if token not in source_text:
                  raise SystemExit(f"deploy_state source missing expected token {token!r}")

          agent_text = agent_source.read_text()
          for token in [
              '"non-retryable"',
              '"retry_budget_exhausted"',
              "maxAttempts",
              "latestCandidate",
          ]:
              if token not in agent_text:
                  raise SystemExit(f"deploy_agent source missing expected token {token!r}")
          PY
          touch "$out"
        '';

        deployment-e2e-rehearsal-skill-doc = pkgs.runCommand "deployment-e2e-rehearsal-skill-doc" { } ''
          ${pkgs.python3}/bin/python3 <<'PY'
          import json
          from pathlib import Path

          docs = Path("${docs}")
          skill = Path("${skills}") / "deployment-e2e-rehearsal" / "SKILL.md"
          runbook = docs / "runbook.md"
          surface = json.loads((docs / "operator-command-surface.json").read_text())
          text = skill.read_text()
          combined = text + "\n" + runbook.read_text()
          normalized = " ".join(combined.split())

          for check in surface["nixChecks"]:
              if check not in text:
                  raise SystemExit(f"e2e skill missing NixOS VM check {check}")

          for scenario in surface["rehearsalScenarios"]:
              if scenario not in combined:
                  raise SystemExit(f"e2e docs missing rehearsal scenario {scenario}")

          for term in [
              "Incus/LXC",
              "--check-env",
              "--check-runtime",
              "--dry-run",
              "bash scripts/deployment-incus-rehearsal.sh full-topology --check-env",
              "bash scripts/deployment-incus-rehearsal.sh full-topology --check-runtime",
              "bash scripts/deployment-incus-rehearsal.sh full-topology --dry-run",
              "bash scripts/deployment-incus-rehearsal.sh full-topology",
              "full-topology-failures",
              "offline-latest-only",
              "forced-command",
              "pull-agent",
              "pending-runtime",
              "controller or CI runner",
              "Attic cache",
              "monitoring or status collector",
              "network partition",
              "stale desired state",
              "newer desired state while offline",
              "cache object missing or corruption",
              "forced-command SSH misuse",
              "health-check failure",
              "rollback",
              "lock contention",
              "production enablement",
              "event JSONL",
              "target journals",
              "metrics snapshot",
          ]:
              if " ".join(term.split()) not in normalized:
                  raise SystemExit(f"e2e rehearsal docs missing {term!r}")
          PY
          touch "$out"
        '';

        deployment-summary-artifact = pkgs.runCommand "deployment-summary-artifact" { } ''
          mkdir -p "$out"
          cat > events.jsonl <<'EOF'
          {"schemaVersion":1,"deploymentId":"gh-123456789-abcdef0-app-server-01","correlationId":"gh-123456789-abcdef0-app-server-01-0123456789abcdfghijklmnpqrsvwxyz","phase":"evaluate","target":{"name":"app-server-01","system":"x86_64-linux","kind":"server","transport":"cachix-agent"},"backend":{"cache":"example-private-cache","substituters":["https://example-private-cache.cachix.org","https://cache.nixos.org"],"controller":"cachix-deploy"},"storePaths":{"system":"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-nixos-system-app-server-01-25.11"},"timestamps":{"startedAt":"2026-05-13T09:00:00Z","finishedAt":"2026-05-13T09:01:00Z"},"command":{"name":"nix-eval-jobs","argv":["nix-eval-jobs"],"status":"succeeded","exitCode":0}}
          {"schemaVersion":1,"deploymentId":"gh-123456789-abcdef0-app-server-01","correlationId":"gh-123456789-abcdef0-app-server-01-0123456789abcdfghijklmnpqrsvwxyz","phase":"activate-requested","target":{"name":"app-server-01","system":"x86_64-linux","kind":"server","transport":"cachix-agent"},"backend":{"cache":"example-private-cache","substituters":["https://example-private-cache.cachix.org","https://cache.nixos.org"],"controller":"cachix-deploy"},"storePaths":{"system":"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-nixos-system-app-server-01-25.11","closure":{"count":2,"totalBytes":null,"rootHashes":["0123456789abcdfghijklmnpqrsvwxyz"]}},"timestamps":{"startedAt":"2026-05-13T09:01:00Z","finishedAt":"2026-05-13T09:01:05Z"},"command":{"name":"cachix deploy activate","argv":["cachix","deploy","activate"],"status":"failed","exitCode":23},"error":{"code":"activation_request_failed","message":"Activation request failed","retryable":false,"details":{"stderrSummary":"fixture activation failure"}}}
          EOF

          ${self'.packages.mcl-devops}/bin/mcl-devops deploy-status summarize events.jsonl \
            --output "$out/deployment-summary.md" \
            --json-output "$out/deployment-summary.json"

          grep -Fq "app-server-01" "$out/deployment-summary.md"
          grep -Fq "Activation request failed" "$out/deployment-summary.md"
          grep -Fq "fixture activation failure" "$out/deployment-summary.md"
          ${pkgs.python3}/bin/python3 <<PY
          import json
          from pathlib import Path
          summary = json.loads(Path("$out/deployment-summary.json").read_text())
          assert summary["finalState"] == "failed", summary
          assert summary["failureCount"] == 1, summary
          assert summary["targetCount"] == 1, summary
          PY
        '';
      };
    };
}
