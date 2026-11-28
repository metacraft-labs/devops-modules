REPOMIX_OUT_DIR := env('REPOMIX_OUT_DIR', 'repomix')

image := `nix eval --raw .#ci-image.imageRefUnsafe`

is-podman-available := `if command -v podman &> /dev/null; then echo true; else echo false; fi`
copy-to-docker := if is-podman-available == "true" { "copyToPodman" } else { "copyToDockerDaemon" }
docker-socket := if is-podman-available == "true" { "unix://${XDG_RUNTIME_DIR}/podman/podman.sock" } else { "unix:///var/run/docker.sock" }
do-offline-nix-build := if env("CI", "false") == "false" { "--offline" } else { "" }

# RunQuota bridge (RQE-M6b): prefix for a heavy, finite `nix build` so it takes a
# lease from the host's shared budget and runs at the granted width. Where
# `runquota` is absent it runs the command unchanged; `RQ=` turns it off. See
# scripts/runquota-bridge.sh and tests/test_runquota_bridge.sh
# (`just test-runquota-bridge`).
rq := '"' + justfile_directory() + '/scripts/runquota-bridge.sh" run --'

show:
  @echo image: {{image}}
  @echo docker-socket: {{docker-socket}}
  @echo copy-to-docker: {{copy-to-docker}}
  @echo container engine: `docker --version 2>&1 | grep -v 'Switching default driver'`

# The RunQuota `nix` adapter bounds `nix build` but not `nix run`, so the heavy
# part (building the image closure) is a bridged `nix build`; the `nix run` that
# follows then finds the closure already built and only runs the copy script.
image:
  {{rq}} nix build --no-link --accept-flake-config {{do-offline-nix-build}} .#ci-image.{{copy-to-docker}}
  nix run --accept-flake-config {{do-offline-nix-build}} .#ci-image.{{copy-to-docker}}

# RunQuota bridge check: runs the real `image` recipe against a private runquotad
# with a stub `nix` and asserts the lease bounds concurrency. `--mutate` deletes
# the bridge from a copy of this Justfile and expects the bound to fail.
test-runquota-bridge *args:
  bash tests/test_runquota_bridge.sh {{args}}

exec: image
  docker run -it {{image}}

act workflow_name="ci": image
  #!/usr/bin/env bash
  set -euo pipefail
  if [ ! -f .gh-vars.env ]; then
    echo "ERROR: .gh-vars.env not found"
    echo "Create it with: echo 'CACHIX_CACHE=mcl-public-cache' > .gh-vars.env"
    exit 1
  fi
  if [ ! -f .gh-secrets.env ]; then
    echo "ERROR: .gh-secrets.env not found"
    echo "Create it with your CACHIX_AUTH_TOKEN: echo 'CACHIX_AUTH_TOKEN=...' > .gh-secrets.env"
    exit 1
  fi

  # Map workflow names to their files and job names
  case "{{workflow_name}}" in
    lint)
      workflow_file="reusable-lint"
      job_name="lint"
      ;;
    *)
      workflow_file="{{workflow_name}}"
      job_name="{{workflow_name}}"
      ;;
  esac

  set -x
  DOCKER_HOST="{{docker-socket}}" \
  act workflow_dispatch \
    -W ".github/workflows/${workflow_file}.yml" \
    -j "${job_name}" \
    --var-file './.gh-vars.env' \
    --secret-file './.gh-secrets.env' \
    --concurrent-jobs 1 \
    --pull=false \
    --input "runner=[\"self-hosted\"]" \
    -P self-hosted={{image}}

# Create repomix bundle of shared Terraform infrastructure docs and workflows
REPOMIX_TERRAFORM_SHARED_PATTERNS := replace("""
docs/Terraform-Agent-Development-Methodology.md
docs/Terraform-Testing.md
docs/Terraform-Shared-Infrastructure.status.org
.github/workflows/reusable-terraform*.yml
""", "\n", ",")

repomix-terraform-shared *args:
    mkdir -p {{REPOMIX_OUT_DIR}}
    repomix \
        . \
        --output {{REPOMIX_OUT_DIR}}/Terraform-Shared-Infrastructure.md \
        --style markdown \
        --header-text "Shared Terraform Infrastructure - Reusable CI Workflow, Dev Shell, and Policy Scripts" \
        --include "{{REPOMIX_TERRAFORM_SHARED_PATTERNS}}" \
        {{args}}

attic-migrate-flake path *args:
  nix run --accept-flake-config .#attic-migrate-flake -- {{path}} {{args}}
