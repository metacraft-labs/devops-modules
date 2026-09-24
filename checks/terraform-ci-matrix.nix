{ ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      checks.terraform-ci-matrix =
        pkgs.runCommand "terraform-ci-matrix-test"
          {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.coreutils
              pkgs.findutils
              pkgs.jq
              pkgs.python3
            ];
          }
          ''
            export TERRAFORM_CI_MATRIX_SCRIPT=${../terraform/ci/terraform-ci-matrix}
            export TERRAFORM_CI_MATRIX_SCHEMA=${../terraform/ci/metadata.schema.json}
            export TERRAFORM_CI_MATRIX_BASH=${pkgs.bash}/bin/bash

            ${pkgs.bash}/bin/bash ${../terraform/ci/tests/test-matrix.sh}
            ${pkgs.bash}/bin/bash ${../terraform/ci/tests/test-matrix-mutations.sh}

            export PLAN_DESTROY_GUARD_SCRIPT=${../terraform/ci/plan-destroy-guard}
            export PLAN_DESTROY_GUARD_PYTHON=${pkgs.python3}/bin/python3
            ${pkgs.bash}/bin/bash ${../terraform/ci/tests/test-plan-destroy-guard.sh}

            export GITHUB_PROVIDER_CREDENTIAL_GATE_SCRIPT=${../terraform/ci/github-provider-credential-gate}
            export GITHUB_PROVIDER_CREDENTIAL_GATE_PYTHON=${pkgs.python3}/bin/python3
            ${pkgs.bash}/bin/bash ${../terraform/ci/tests/test-github-provider-credential-gate.sh}
            touch "$out"
          '';
    };
}
