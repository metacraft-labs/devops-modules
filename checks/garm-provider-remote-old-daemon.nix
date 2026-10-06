# Gate `t_garm_provider_remote_old_daemon`: the remote vmharness provider must
# keep a MIXED-VERSION fleet working, driving the REAL old `vm-harness serve`.
#
# WHY. On 2026-09-24 the central GARM on high-mem-server got the fail-closed
# provider (#686) while gpu-server-001/002 still ran a `vm-harness serve` that
# predates `ephemeral-list`/`ephemeral-label` (gosti #47). The provider's
# old-daemon tolerance matched "unknown subcommand 'ephemeral-label'", but the
# old binary parses the whole argv before dispatching and dies on the flag:
# "vm-harness: Unknown flag: '--label'". Every create ended in `error`. The unit
# tests passed because their fake daemon printed what the author EXPECTED the
# old binary to print. This gate runs the binary itself.
#
# WHAT IT ASSERTS, against gosti e337cb6 (infra's `gosti` pin at the incident):
#   0. drift detector: the old daemon really answers `--label` with
#      "Unknown flag: '--label'" (if a re-pin changes that, this gate says so
#      before the provider silently stops recognising it);
#   1. CreateInstance SUCCEEDS, and the provider says, with its greppable tag,
#      that it created the instance unlabelled;
#   2. ListInstances FAILS CLOSED with the distinguishable old-daemon error
#      (never an empty list: the patched GARM would recycle live runners on it);
# and, as the control, against the CURRENT pinned daemon (self'.packages.vm-harness):
#   4. the same create prints NO old-daemon line and List succeeds.
#
# Hermetic: target backend `noop` (the sanctioned test backend), loopback only.
{ ... }:
{
  perSystem =
    { pkgs, self', ... }:
    let
      # The serve the fleet ran on 2026-09-24 (infra flake.lock `gosti`), built
      # with this repo's own vm-harness derivation. The hash is that input's
      # narHash.
      vmHarnessOld = self'.packages.vm-harness.overrideAttrs (_: {
        version = "0.1.0-e337cb6";
        src = pkgs.fetchFromGitHub {
          owner = "metacraft-labs";
          repo = "gosti";
          rev = "e337cb6fa456aa7fd0d934e2e5a36eb3a9c7c551";
          hash = "sha256-We9CZcUOEvkE62FBuKdvi7cVYBUHpMkoIpVzcsOmfaA=";
        };
      });
    in
    {
      checks = pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_garm_provider_remote_old_daemon =
          pkgs.runCommand "t_garm_provider_remote_old_daemon"
            {
              nativeBuildInputs = [
                pkgs.jq
                pkgs.coreutils
                pkgs.gnugrep
                pkgs.bash
              ];
              provider = "${self'.packages.garm-provider-vmharness}/bin/garm-provider-vmharness";
              vmHarnessOld = "${vmHarnessOld}/bin/vm-harness";
              vmHarnessNew = "${self'.packages.vm-harness}/bin/vm-harness";
            }
            ''
              set -euo pipefail
              work="$(mktemp -d)"
              export HOME="$work/home"; mkdir -p "$HOME"
              export TMPDIR="$work/tmp"; mkdir -p "$TMPDIR"
              CONTROLLER_ID="ctrl-0000"
              POOL_ID="9dcf590a-1192-4a9c-b3e4-e0902974c2c0"
              TOKEN="serve-bearer-old-daemon-7c1e"
              printf '%s' "$TOKEN" > "$work/token"
              SERVE_PID=""
              cleanup() { [ -n "$SERVE_PID" ] && kill "$SERVE_PID" 2>/dev/null || true; }
              trap cleanup EXIT

              start_serve() { # <binary> <tag>
                rm -f "$work/port"
                mkdir -p "$work/$2-labels"
                VMH_EPHEMERAL_LABEL_DIR="$work/$2-labels" "$1" serve \
                  --listen 127.0.0.1:0 --auth-token-file "$work/token" \
                  --port-file "$work/port" --quiet &
                SERVE_PID=$!
                PORT=""
                for _ in $(seq 1 100); do
                  if [ -s "$work/port" ]; then PORT="$(cat "$work/port")"; break; fi
                  sleep 0.1
                done
                [ -n "$PORT" ] || { echo "$2 serve did not report a port" >&2; exit 1; }
                cat > "$work/config.toml" <<EOF
              backend = "remote"

              [remote]
              endpoint = "127.0.0.1:$PORT"
              target_backend = "noop"
              auth_token_file = "$work/token"
              guest_os = "linux"
              EOF
              }
              stop_serve() { kill "$SERVE_PID" 2>/dev/null || true; wait "$SERVE_PID" 2>/dev/null || true; SERVE_PID=""; }

              RESP="$work/resp.json"
              run() {
                local cmd="$1"; shift
                set +e
                env -i "PATH=$PATH" "HOME=$HOME" "TMPDIR=$TMPDIR" \
                  "GARM_INTERFACE_VERSION=v0.1.1" \
                  "GARM_PROVIDER_CONFIG_FILE=$work/config.toml" \
                  "GARM_CONTROLLER_ID=$CONTROLLER_ID" \
                  "GARM_COMMAND=$cmd" "$@" \
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
                  "instance-token":"jwt-token", os_type:"linux", arch:"amd64",
                  flavor:"linux-large", image:"runner-linux", labels:["linux"],
                  pool_id:$pool, jit_config_enabled:true }'
              }
              fail() { echo "FAIL: $1" >&2; echo "--- stdout"; cat "$RESP" >&2 || true; echo "--- stderr"; head -c 4000 "$work/err" >&2 || true; exit 1; }

              echo "=== OLD daemon (gosti e337cb6) ==="
              start_serve "$vmHarnessOld" old

              echo "== 0. the old daemon's real answer to --label =="
              set +e
              VMH_SERVE_TOKEN="$TOKEN" "$vmHarnessOld" --remote "127.0.0.1:$PORT" \
                ephemeral-list --backend noop --label "garm-pool=$POOL_ID" --log-format json > "$work/raw" 2>&1
              RAW_CODE=$?
              set -e
              head -1 "$work/raw"
              [ "$RAW_CODE" -eq 2 ] || { cat "$work/raw" >&2; echo "FAIL: old daemon exit $RAW_CODE, want 2" >&2; exit 1; }
              grep -qF "vm-harness: Unknown flag: '--label'" "$work/raw" \
                || { echo "FAIL: the old daemon no longer prints the marker the provider matches" >&2; exit 1; }

              echo "== 1. CreateInstance succeeds, unlabelled =="
              bootstrap_json garm-old-0001 > "$work/bootstrap.json"
              run CreateInstance "GARM_POOL_ID=$POOL_ID" < "$work/bootstrap.json"
              [ "$LAST_CODE" -eq 0 ] || fail "create against the old daemon exited $LAST_CODE (the 2026-09-24 outage)"
              jq -e '.status == "running"' "$RESP" >/dev/null || fail "create status"
              grep -q 'vmharness-provider old-daemon .*verb=ephemeral-label action=create-unlabelled' "$work/err" \
                || fail "no old-daemon create line"

              echo "== 2. ListInstances fails closed, distinguishably =="
              run ListInstances "GARM_POOL_ID=$POOL_ID" </dev/null
              [ "$LAST_CODE" -ne 0 ] || fail "List against the old daemon returned $(cat "$RESP") instead of failing closed"
              grep -q 'enumeration unavailable' "$work/err" || fail "List error is not ErrEnumerationUnavailable"
              grep -q 'predates ephemeral-list' "$work/err" || fail "List error does not identify the old daemon"
              grep -q 'vmharness-provider old-daemon .*verb=ephemeral-list action=fail-closed' "$work/err" \
                || fail "no old-daemon list line"

              # No Delete assertion against the old daemon: e337cb6's
              # `ephemeral-destroy --backend noop` falls through to its libvirt
              # branch and needs `virsh` (the same fall-through gosti #47 fixed for
              # hyperv), so it cannot run hermetically. Delete never touches the
              # verbs this gate is about.
              stop_serve

              echo "=== CURRENT daemon (control) ==="
              start_serve "$vmHarnessNew" new
              echo "== 4. no old-daemon classification; List succeeds =="
              bootstrap_json garm-new-0001 > "$work/bootstrap.json"
              run CreateInstance "GARM_POOL_ID=$POOL_ID" < "$work/bootstrap.json"
              [ "$LAST_CODE" -eq 0 ] || fail "create against the current daemon exited $LAST_CODE"
              if grep -q 'old-daemon' "$work/err"; then fail "current daemon classified as old"; fi
              run ListInstances "GARM_POOL_ID=$POOL_ID" </dev/null
              [ "$LAST_CODE" -eq 0 ] || fail "List against the current daemon exited $LAST_CODE"
              if grep -q 'old-daemon' "$work/err"; then fail "current daemon List classified as old"; fi
              stop_serve

              echo "ALL OLD-DAEMON COMPATIBILITY ASSERTIONS PASSED"
              touch "$out"
            '';
      };
    };
}
