{ ... }:
{
  # Runner-Fleet-Capability-Pools-And-Remote-Driving RB1 gate: t_garm_provider_remote.
  #
  # Proves the `garm-provider-vmharness` REMOTE-TARGET mode (backend = "remote"):
  # instead of exec-ing a LOCAL vm-harness/virsh/incus, the provider is an RPC
  # CLIENT to a remote `vm-harness serve` daemon (the RA1 protocol v1 — bearer
  # auth, GET /v1/info, chunked NDJSON POST /v1/exec). A CreateInstance ->
  # DeleteInstance cycle is driven through GARM's REAL external-provider protocol
  # (the same env + stdin/stdout contract runner/providers/v0.1.1/external.go
  # uses) against a REAL daemon, and a wrong bearer token is rejected.
  #
  # HERMETIC + REAL WIRE. The daemon is a genuine `vm-harness serve` bound to
  # loopback with the SANCTIONED noop backend (design doc §9.1): no hypervisor,
  # no network, but the whole wire path — TCP, HTTP framing, bearer auth, the
  # NDJSON exec stream, the exit-code round-trip — is exercised for real end to
  # end. `provision`/`ephemeral-destroy --backend noop` are the create/delete
  # verbs the remote worker runs (both exit 0 without a hypervisor), so the
  # provider's remote Create/Delete complete a real cross-process round-trip.
  #
  # This is preferred over a hand-rolled mock endpoint precisely so the Go serve
  # client is validated against the ACTUAL Nim daemon, catching any drift in the
  # shared /v1 contract. The fast, dependency-free unit coverage of the client +
  # backend logic lives in internal/backend/remote_test.go (run by the
  # t_garm_provider_vmharness_backend gate); this gate adds the real-daemon,
  # real-protocol end-to-end proof.
  #
  # Statelessness: the provider keeps NO local state in remote mode — the
  # provider_id is GARM's instance name and host liveness is recovered from the
  # remote daemon's /v1/info. The M1 local-exec protocol gate
  # (t_garm_provider_vmharness_protocol) stays green unchanged, proving
  # back-compat: local-exec mode is untouched and config-selected.
  perSystem =
    { pkgs, self', ... }:
    {
      checks = pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_garm_provider_remote =
          pkgs.runCommand "t_garm_provider_remote"
            {
              nativeBuildInputs = [
                pkgs.jq
                pkgs.coreutils
                pkgs.bash
              ];
              provider = "${self'.packages.garm-provider-vmharness}/bin/garm-provider-vmharness";
              vmHarness = "${self'.packages.vm-harness}/bin/vm-harness";
            }
            ''
              set -euo pipefail

              work="$(mktemp -d)"
              export HOME="$work/home"; mkdir -p "$HOME"
              export TMPDIR="$work/tmp"; mkdir -p "$TMPDIR"

              CONTROLLER_ID="ctrl-0000"
              POOL_ID="9dcf590a-1192-4a9c-b3e4-e0902974c2c0"
              NAME="garm-remote-0001"
              TOKEN="serve-bearer-$(date +%s)-3f9a2c"

              # ---- 1. Stand up a REAL `vm-harness serve` (noop backend) --------
              printf '%s' "$TOKEN" > "$work/token"
              # Ownership records written by `ephemeral-label` (the provider
              # labels every instance it creates). The sandbox HOME is not
              # writable, so point it at the scratch dir as the serve units do.
              export VMH_EPHEMERAL_LABEL_DIR="$work/ephemeral-labels"
              "$vmHarness" serve \
                --listen 127.0.0.1:0 \
                --auth-token-file "$work/token" \
                --port-file "$work/port" \
                --quiet &
              SERVE_PID=$!
              cleanup() { kill "$SERVE_PID" 2>/dev/null || true; }
              trap cleanup EXIT

              # Wait for the daemon to report its bound port.
              PORT=""
              for _ in $(seq 1 100); do
                if [ -s "$work/port" ]; then PORT="$(cat "$work/port")"; break; fi
                sleep 0.1
              done
              if [ -z "$PORT" ]; then
                echo "vm-harness serve did not report a port" >&2
                exit 1
              fi
              echo "serve listening on 127.0.0.1:$PORT (pid $SERVE_PID)"

              # ---- 2. Remote-target provider config (backend = remote) --------
              cat > "$work/config.toml" <<EOF
              backend = "remote"

              [remote]
              endpoint = "127.0.0.1:$PORT"
              target_backend = "noop"
              auth_token_file = "$work/token"
              guest_os = "linux"
              EOF

              RESP="$work/resp.json"
              run() {
                local cmd="$1"; shift
                local cfg="$1"; shift
                set +e
                env -i \
                  "PATH=$PATH" \
                  "HOME=$HOME" \
                  "TMPDIR=$TMPDIR" \
                  "GARM_INTERFACE_VERSION=v0.1.1" \
                  "GARM_PROVIDER_CONFIG_FILE=$cfg" \
                  "GARM_CONTROLLER_ID=$CONTROLLER_ID" \
                  "GARM_COMMAND=$cmd" \
                  "$@" \
                  "$provider" > "$RESP" 2> "$work/err"
                LAST_CODE=$?
                set -e
              }

              bootstrap_json() {
                jq -nc --arg name "$1" --arg pool "$POOL_ID" '{
                  name: $name,
                  tools: [ {os:"linux",architecture:"x64",
                           download_url:"https://example.invalid/actions-runner-linux-x64.tar.gz",
                           filename:"actions-runner-linux-x64.tar.gz",
                           sha256_checksum:"0000000000000000000000000000000000000000000000000000000000000000"} ],
                  repo_url:"https://github.com/example-org/scratch",
                  "callback-url":"https://garm.example.com/api/v1/callbacks",
                  "metadata-url":"https://garm.example.com/api/v1/metadata",
                  "instance-token":"jwt-token",
                  os_type:"linux", arch:"amd64", flavor:"linux-large",
                  image:"runner-linux", labels:["linux","vmharness"],
                  pool_id:$pool, jit_config_enabled:true
                }'
              }

              # ---- 3. GetConfigJSONSchema advertises the remote surface --------
              echo "== GetConfigJSONSchema (remote surface) =="
              run GetConfigJSONSchema "$work/config.toml" </dev/null
              test "$LAST_CODE" -eq 0 || { echo "schema exit=$LAST_CODE: $(cat "$work/err")" >&2; exit 1; }
              jq -e '.properties.remote != null' "$RESP" >/dev/null
              jq -e '.properties.backend.enum | index("remote") != null' "$RESP" >/dev/null

              # ---- 4. CreateInstance over the REMOTE daemon -------------------
              echo "== CreateInstance (remote) =="
              bootstrap_json "$NAME" > "$work/bootstrap.json"
              run CreateInstance "$work/config.toml" "GARM_POOL_ID=$POOL_ID" < "$work/bootstrap.json"
              test "$LAST_CODE" -eq 0 || { echo "create exit=$LAST_CODE: $(cat "$RESP") / $(cat "$work/err")" >&2; exit 1; }
              jq -e '.provider_id != "" and .provider_id != null' "$RESP" >/dev/null
              jq -e --arg n "$NAME" '.name == $n' "$RESP" >/dev/null
              jq -e '.status == "running"' "$RESP" >/dev/null
              jq -e '.os_type == "linux"' "$RESP" >/dev/null
              # Evidence the create actually ran on the REMOTE worker (noop
              # provision log relayed through the exec stream to the provider).
              grep -q 'provision' "$work/err" || { echo "no remote provision evidence in provider stderr" >&2; cat "$work/err" >&2; exit 1; }
              echo "  provider_id=$(jq -r '.provider_id' "$RESP")"

              # ---- 5. DeleteInstance over the REMOTE daemon -------------------
              echo "== DeleteInstance (remote) =="
              run DeleteInstance "$work/config.toml" "GARM_INSTANCE_ID=$NAME" "GARM_POOL_ID=$POOL_ID" </dev/null
              test "$LAST_CODE" -eq 0 || { echo "delete exit=$LAST_CODE: $(cat "$work/err")" >&2; exit 1; }

              # ---- 6. DeleteInstance is idempotent ---------------------------
              echo "== DeleteInstance idempotent =="
              run DeleteInstance "$work/config.toml" "GARM_INSTANCE_ID=$NAME" "GARM_POOL_ID=$POOL_ID" </dev/null
              test "$LAST_CODE" -eq 0 || { echo "idempotent delete exit=$LAST_CODE: $(cat "$work/err")" >&2; exit 1; }

              # ---- 7. Wrong bearer token is REJECTED (401) -------------------
              echo "== Wrong token rejected =="
              cat > "$work/bad.toml" <<EOF
              backend = "remote"

              [remote]
              endpoint = "127.0.0.1:$PORT"
              target_backend = "noop"
              auth_token = "WRONG-TOKEN"
              guest_os = "linux"
              EOF
              bootstrap_json "$NAME" > "$work/bootstrap.json"
              run CreateInstance "$work/bad.toml" "GARM_POOL_ID=$POOL_ID" < "$work/bootstrap.json"
              test "$LAST_CODE" -ne 0 || { echo "create with WRONG token unexpectedly succeeded" >&2; exit 1; }
              grep -qi '401\|unauthor' "$work/err" || { echo "wrong-token failure did not mention 401/unauthorized" >&2; cat "$work/err" >&2; exit 1; }

              # ---- 8. ListInstances answers from the daemon's enumeration ----
              # A live daemon enumerates (noop keeps nothing, so the pool's list
              # is a positive, EMPTY answer, exit 0) ...
              echo "== ListInstances (remote, live daemon) =="
              run ListInstances "$work/config.toml" "GARM_POOL_ID=$POOL_ID" </dev/null
              test "$LAST_CODE" -eq 0 || { echo "list exit=$LAST_CODE: $(cat "$work/err")" >&2; exit 1; }

              # ... and an UNREACHABLE daemon is an ERROR, never `[]`. GARM reads
              # an instance's absence from ListInstances as "already gone" and
              # forgets it without calling DeleteInstance; answering `[]` for a
              # host it could not see is how ~210 Windows VMs leaked.
              echo "== ListInstances fails closed when the daemon is down =="
              kill "$SERVE_PID" 2>/dev/null || true
              wait "$SERVE_PID" 2>/dev/null || true
              run ListInstances "$work/config.toml" "GARM_POOL_ID=$POOL_ID" </dev/null
              test "$LAST_CODE" -ne 0 || { echo "ListInstances against a DOWN daemon succeeded with: $(cat "$RESP")" >&2; exit 1; }
              grep -q 'enumeration unavailable' "$work/err" || { echo "down-daemon list failed without the fail-closed error" >&2; cat "$work/err" >&2; exit 1; }

              echo "ALL REMOTE-TARGET ASSERTIONS PASSED"
              touch "$out"
            '';
      };
    };
}
