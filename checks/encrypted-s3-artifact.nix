{ ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      checks.encrypted-s3-artifact =
        let
          fakeAws = pkgs.writeShellScript "aws" ''
            set -euo pipefail
            if [[ "$1" == "kms" && "$2" == "describe-key" ]]; then
              [[ "$3" == "--key-id" && "$4" == "alias/test" ]] || exit 2
              printf 'arn:aws:kms:us-east-1:123456789012:key/00000000-1111-2222-3333-444444444444\n'
              exit 0
            fi
            [[ "$1" == "s3api" ]] || exit 2
            operation="$2"
            shift 2
            body=""
            output=""
            metadata=""
            key=""
            sse_kms_key_id=""
            while [[ $# -gt 0 ]]; do
              case "$1" in
                --body)
                  body="$2"
                  shift 2
                  ;;
                --metadata)
                  metadata="$2"
                  shift 2
                  ;;
                --key)
                  key="$2"
                  shift 2
                  ;;
                --ssekms-key-id)
                  sse_kms_key_id="$2"
                  shift 2
                  ;;
                --bucket | --expected-bucket-owner | --version-id | --if-none-match | --server-side-encryption)
                  shift 2
                  ;;
                *)
                  output="$1"
                  shift
                  ;;
              esac
            done
            object="$FAKE_S3/object"
            head="$FAKE_S3/head.json"
            case "$operation" in
              put-object)
                [[ "$sse_kms_key_id" == "arn:aws:kms:us-east-1:123456789012:key/00000000-1111-2222-3333-444444444444" ]] || exit 42
                [[ ! -e "$object" ]] || exit 41
                cp "$body" "$object"
                run_id="$(sed -n "s/.*source-run-id=\([^,]*\).*/\1/p" <<<"$metadata")"
                source_sha="$(sed -n "s/.*source-sha=\([^,]*\).*/\1/p" <<<"$metadata")"
                digest="$(sed -n "s/.*ciphertext-sha256=\([^,]*\).*/\1/p" <<<"$metadata")"
                jq -n \
                  --arg r "$run_id" \
                  --arg s "$source_sha" \
                  --arg d "$digest" \
                  '{
                    VersionId: "version-1",
                    Metadata: {
                      format: "age-tar-v1",
                      "source-run-id": $r,
                      "source-sha": $s,
                      "ciphertext-sha256": $d
                    }
                  }' >"$head"
                printf '{"VersionId":"version-1"}\n'
                ;;
              head-object)
                cp "$head" /dev/stdout
                ;;
              get-object)
                cp "$object" "$output"
                printf '{"VersionId":"version-1"}\n'
                ;;
              *) exit 2 ;;
            esac
          '';
        in
        pkgs.runCommand "encrypted-s3-artifact-test"
          {
            nativeBuildInputs = [
              pkgs.age
              pkgs.bash
              pkgs.coreutils
              pkgs.gnutar
              pkgs.jq
              pkgs.openssh
            ];
          }
          ''
            set -euo pipefail
            export PATH="$PWD/fake-bin:$PATH"
            mkdir -p fake-bin fake-s3 source restored
            ln -s ${fakeAws} fake-bin/aws

            age-keygen -o identity >/dev/null 2>&1
            printf 'reviewed-plan\n' >source/secret-values.tfplan
            printf '{"replica":"prod-001"}\n' >source/metadata.json

            export FAKE_S3="$PWD/fake-s3"

            export GITHUB_RUN_ID=123456
            export GITHUB_SHA=0123456789abcdef0123456789abcdef01234567
            export GITHUB_OUTPUT="$PWD/upload.outputs"
            ${pkgs.bash}/bin/bash ${../.github/encrypted-s3-artifact/encrypted-s3-artifact} upload \
              --directory source \
              --bucket test-bucket \
              --object-key plans/123456/prod-001.tar.age \
              --identity-file identity \
              --kms-key-id alias/test \
              --expected-bucket-owner 123456789012

            grep -q '^source-run-id=123456$' upload.outputs
            grep -q '^source-sha=0123456789abcdef0123456789abcdef01234567$' upload.outputs
            grep -Eq '^ciphertext-sha256=[0-9a-f]{64}$' upload.outputs
            grep -q '^version-id=version-1$' upload.outputs
            ! grep -a -q 'reviewed-plan' fake-s3/object

            export GITHUB_OUTPUT="$PWD/download.outputs"
            ${pkgs.bash}/bin/bash ${../.github/encrypted-s3-artifact/encrypted-s3-artifact} download \
              --directory restored \
              --bucket test-bucket \
              --object-key plans/123456/prod-001.tar.age \
              --identity-file identity \
              --expected-run-id 123456 \
              --expected-bucket-owner 123456789012

            cmp source/secret-values.tfplan restored/secret-values.tfplan
            cmp source/metadata.json restored/metadata.json
            grep -q '^source-run-id=123456$' download.outputs

            if ${pkgs.bash}/bin/bash ${../.github/encrypted-s3-artifact/encrypted-s3-artifact} download \
              --directory wrong-run \
              --bucket test-bucket \
              --object-key plans/123456/prod-001.tar.age \
              --identity-file identity \
              --expected-run-id 999999 \
              --expected-bucket-owner 123456789012; then
              echo 'download accepted the wrong reviewed run ID' >&2
              exit 1
            fi

            if ${pkgs.bash}/bin/bash ${../.github/encrypted-s3-artifact/encrypted-s3-artifact} upload \
              --directory source \
              --bucket test-bucket \
              --object-key plans/123456/prod-001.tar.age \
              --identity-file identity \
              --kms-key-id alias/test \
              --expected-bucket-owner 123456789012; then
              echo 'conditional upload allowed an overwrite' >&2
              exit 1
            fi

            mkdir -p fake-s3-ssh restored-ssh
            ssh-keygen -q -t ed25519 -N "" -f ssh-identity
            export FAKE_S3="$PWD/fake-s3-ssh"
            export GITHUB_RUN_ID=123457
            export GITHUB_OUTPUT="$PWD/upload-ssh.outputs"
            ${pkgs.bash}/bin/bash ${../.github/encrypted-s3-artifact/encrypted-s3-artifact} upload \
              --directory source \
              --bucket test-bucket \
              --object-key plans/123457/prod-001.tar.age \
              --identity-file ssh-identity \
              --kms-key-id alias/test \
              --expected-bucket-owner 123456789012

            export GITHUB_OUTPUT="$PWD/download-ssh.outputs"
            ${pkgs.bash}/bin/bash ${../.github/encrypted-s3-artifact/encrypted-s3-artifact} download \
              --directory restored-ssh \
              --bucket test-bucket \
              --object-key plans/123457/prod-001.tar.age \
              --identity-file ssh-identity \
              --expected-run-id 123457 \
              --expected-bucket-owner 123456789012

            cmp source/secret-values.tfplan restored-ssh/secret-values.tfplan
            cmp source/metadata.json restored-ssh/metadata.json
            grep -q '^source-run-id=123457$' download-ssh.outputs

            touch "$out"
          '';
    };
}
