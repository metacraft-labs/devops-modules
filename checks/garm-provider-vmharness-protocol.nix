{ ... }:
{
  # Ephemeral-Windows-Runners-GARM M1 gate: t_garm_provider_vmharness_protocol.
  #
  # Drives the BUILT `garm-provider-vmharness` binary through GARM's real
  # external-provider protocol — the exact env + stdin/stdout contract GARM's
  # own v0.1.1 external provider (runner/providers/v0.1.1/external.go) uses:
  #
  #   * env: GARM_COMMAND / GARM_POOL_ID / GARM_INSTANCE_ID /
  #     GARM_PROVIDER_CONFIG_FILE / GARM_CONTROLLER_ID / GARM_INTERFACE_VERSION
  #   * a real BootstrapInstance JSON piped on stdin for CreateInstance
  #   * the ProviderInstance JSON expected on stdout + the documented exit codes
  #     (0 success; 30 == NotFound).
  #
  # It is HERMETIC: the provider is pointed at a MOCK virsh (a small POSIX-sh
  # emulation that persists domain XML on disk), so the STATELESS provider — it
  # keeps no lifecycle state of its own — has a real backend to recompute
  # GetInstance/ListInstances from via the domain <metadata> tags. No KVM / real
  # libvirt is required. This exercises the REAL binary over the REAL protocol,
  # not internal function calls.
  #
  # Asserted:
  #   - GetVersion -> a vX.Y.Z string;
  #   - GetSupportedInterfaceVersions -> includes v0.1.1;
  #   - GetConfigJSONSchema / GetExtraSpecsJSONSchema -> valid JSON objects;
  #   - CreateInstance -> ProviderInstance with a non-empty provider_id,
  #     name == bootstrap name, status == running, os_type == windows,
  #     os_name/os_version resolved from the config golden-image map;
  #   - GetInstance (by name AND by provider_id) -> reflects the created domain;
  #   - ListInstances -> reflects it for the pool, empty for another pool;
  #   - Stop/Start -> the domain power state flips;
  #   - DeleteInstance -> succeeds; a subsequent GetInstance exits 30 (NotFound);
  #     a second DeleteInstance of the now-absent instance exits 0 (idempotent).
  perSystem =
    { pkgs, self', ... }:
    {
      checks = pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_garm_provider_vmharness_protocol =
          pkgs.runCommand "t_garm_provider_vmharness_protocol"
            {
              nativeBuildInputs = [
                pkgs.jq
                pkgs.coreutils
                pkgs.gnused
                pkgs.bash
              ];
              provider = "${self'.packages.garm-provider-vmharness}/bin/garm-provider-vmharness";
            }
            ''
              set -euo pipefail

              work="$(mktemp -d)"
              export MOCK_VIRSH_STATE="$work/virsh-state"
              mkdir -p "$MOCK_VIRSH_STATE"

              # ---- mock virsh: persists domain XML so the stateless provider
              # has a real backend to recompute from (no KVM needed). The
              # shebang is written to the real bash so it runs when the provider
              # execs it (the build sandbox has no /bin/sh). ------------------
              echo "#!${pkgs.bash}/bin/bash" > "$work/virsh"
              cat >> "$work/virsh" <<'MOCK'
              set -eu
              STATE="''${MOCK_VIRSH_STATE:?MOCK_VIRSH_STATE unset}"
              mkdir -p "$STATE/domains" "$STATE/state"
              if [ "''${1:-}" = "-c" ]; then shift 2; fi
              cmd="''${1:-}"; shift || true
              resolve() {
                want="$1"
                if [ -f "$STATE/domains/$want.xml" ]; then echo "$want"; return 0; fi
                for f in "$STATE"/domains/*.xml; do
                  [ -e "$f" ] || continue
                  n=$(basename "$f" .xml)
                  u=$(sed -n 's/.*<uuid>\(.*\)<\/uuid>.*/\1/p' "$f" | head -n1)
                  if [ "$u" = "$want" ]; then echo "$n"; return 0; fi
                done
                return 1
              }
              case "$cmd" in
                define)
                  xml=$(cat)
                  name=$(printf '%s' "$xml" | sed -n 's/.*<name>\(.*\)<\/name>.*/\1/p' | head -n1)
                  if [ -z "$name" ]; then echo "error: no name in domain xml" >&2; exit 1; fi
                  count=$(ls "$STATE/domains" | wc -l)
                  uuid="00000000-0000-4000-8000-$(printf '%012d' "$(( count + 1 ))")"
                  printf '%s' "$xml" | sed "s|<name>$name</name>|<name>$name</name>\n  <uuid>$uuid</uuid>|" > "$STATE/domains/$name.xml"
                  echo "shutoff" > "$STATE/state/$name"
                  echo "Domain '$name' defined" ;;
                start)
                  n=$(resolve "$1") || { echo "error: failed to get domain '$1'" >&2; exit 1; }
                  echo "running" > "$STATE/state/$n"; echo "Domain '$n' started" ;;
                shutdown)
                  n=$(resolve "$1") || { echo "error: failed to get domain '$1'" >&2; exit 1; }
                  echo "shutoff" > "$STATE/state/$n" ;;
                destroy)
                  n=$(resolve "$1") || { echo "error: failed to get domain '$1'" >&2; exit 1; }
                  echo "shutoff" > "$STATE/state/$n"; echo "Domain '$n' destroyed" ;;
                undefine)
                  dom=""
                  for a in "$@"; do case "$a" in --*) ;; *) dom="$a"; break;; esac; done
                  n=$(resolve "$dom") || { echo "error: failed to get domain '$dom'" >&2; exit 1; }
                  rm -f "$STATE/domains/$n.xml" "$STATE/state/$n"
                  echo "Domain '$n' has been undefined" ;;
                dominfo)
                  n=$(resolve "$1") || { echo "error: failed to get domain '$1'" >&2; exit 1; }
                  uuid=$(sed -n 's/.*<uuid>\(.*\)<\/uuid>.*/\1/p' "$STATE/domains/$n.xml" | head -n1)
                  st=$(cat "$STATE/state/$n" 2>/dev/null || echo shutoff)
                  case "$st" in running) st="running";; *) st="shut off";; esac
                  printf 'Name:           %s\n' "$n"
                  printf 'UUID:           %s\n' "$uuid"
                  printf 'State:          %s\n' "$st" ;;
                dumpxml)
                  n=$(resolve "$1") || { echo "error: failed to get domain '$1'" >&2; exit 1; }
                  cat "$STATE/domains/$n.xml" ;;
                list)
                  for f in "$STATE"/domains/*.xml; do [ -e "$f" ] || continue; basename "$f" .xml; done ;;
                *)
                  echo "mock-virsh: unhandled command '$cmd'" >&2; exit 1 ;;
              esac
              MOCK
              chmod +x "$work/virsh"

              # ---- provider config.toml pointing at the mock virsh -----------
              cat > "$work/config.toml" <<EOF
              backend = "libvirt"
              virsh_path = "$work/virsh"
              libvirt_uri = "test:///default"
              network = "default"

              [images."windows-2022"]
              source_image = "/golden/windows-2022.qcow2"
              os_name = "windows"
              os_version = "2022"
              EOF

              CONTROLLER_ID="ctrl-0000"
              POOL_ID="9dcf590a-1192-4a9c-b3e4-e0902974c2c0"
              NAME="garm-vmh-0001"

              # run <command> [extra KEY=VAL ...] : stdin is inherited (so the
              # caller can pipe a BootstrapInstance), the provider's stdout is
              # captured to $work/out, and the exit code is left in $LAST_CODE.
              # A clean env (env -i) is used so only the GARM_* protocol
              # variables reach the provider. NOTE: run is invoked directly (not
              # in a $(...) subshell) so $LAST_CODE survives into the caller.
              RESP="$work/resp.json"
              run() {
                local cmd="$1"; shift
                set +e
                # PATH is passed so the mock virsh (a child of the provider)
                # can find coreutils/sed; the GARM_* vars are the real protocol
                # surface. Everything else is stripped by env -i.
                env -i \
                  "PATH=$PATH" \
                  "GARM_INTERFACE_VERSION=v0.1.1" \
                  "GARM_PROVIDER_CONFIG_FILE=$work/config.toml" \
                  "GARM_CONTROLLER_ID=$CONTROLLER_ID" \
                  "MOCK_VIRSH_STATE=$MOCK_VIRSH_STATE" \
                  "GARM_COMMAND=$cmd" \
                  "$@" \
                  "$provider" > "$RESP"
                LAST_CODE=$?
                set -e
              }

              bootstrap_json() {
                jq -nc --arg name "$1" --arg pool "$POOL_ID" '{
                  name: $name,
                  tools: [ {os:"win",architecture:"x64",
                           download_url:"https://github.com/actions/runner/releases/download/v2.317.0/actions-runner-win-x64-2.317.0.zip",
                           filename:"actions-runner-win-x64-2.317.0.zip",
                           sha256_checksum:"0000000000000000000000000000000000000000000000000000000000000000"} ],
                  repo_url:"https://github.com/example-org/scratch",
                  "callback-url":"https://garm.example.com/api/v1/callbacks",
                  "metadata-url":"https://garm.example.com/api/v1/metadata",
                  "instance-token":"jwt-token",
                  os_type:"windows", arch:"amd64", flavor:"windows-large",
                  image:"windows-2022", labels:["windows","vmharness"],
                  pool_id:$pool, jit_config_enabled:true
                }'
              }

              echo "== GetVersion =="
              run GetVersion </dev/null; test "$LAST_CODE" -eq 0
              grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+' "$RESP" || { echo "bad version: $(cat "$RESP")" >&2; exit 1; }

              echo "== GetSupportedInterfaceVersions =="
              run GetSupportedInterfaceVersions </dev/null; test "$LAST_CODE" -eq 0
              jq -e 'index("v0.1.1") != null' "$RESP" >/dev/null

              echo "== GetConfigJSONSchema =="
              run GetConfigJSONSchema </dev/null; test "$LAST_CODE" -eq 0
              jq -e '.properties != null' "$RESP" >/dev/null

              echo "== GetExtraSpecsJSONSchema =="
              run GetExtraSpecsJSONSchema </dev/null; test "$LAST_CODE" -eq 0
              jq -e 'type == "object"' "$RESP" >/dev/null

              echo "== CreateInstance =="
              bootstrap_json "$NAME" > "$work/bootstrap.json"
              run CreateInstance "GARM_POOL_ID=$POOL_ID" < "$work/bootstrap.json"
              test "$LAST_CODE" -eq 0 || { echo "create exit=$LAST_CODE: $(cat "$RESP")" >&2; exit 1; }
              jq -e '.provider_id != "" and .provider_id != null' "$RESP" >/dev/null
              jq -e --arg n "$NAME" '.name == $n' "$RESP" >/dev/null
              jq -e '.status == "running"' "$RESP" >/dev/null
              jq -e '.os_type == "windows"' "$RESP" >/dev/null
              jq -e '.os_name == "windows" and .os_version == "2022"' "$RESP" >/dev/null
              PROVIDER_ID=$(jq -r '.provider_id' "$RESP")
              echo "  provider_id=$PROVIDER_ID"

              echo "== GetInstance (by name) =="
              run GetInstance "GARM_INSTANCE_ID=$NAME" "GARM_POOL_ID=$POOL_ID" </dev/null
              test "$LAST_CODE" -eq 0
              jq -e --arg n "$NAME" '.name == $n and .status == "running"' "$RESP" >/dev/null
              jq -e --arg id "$PROVIDER_ID" '.provider_id == $id' "$RESP" >/dev/null

              echo "== GetInstance (by provider_id) =="
              run GetInstance "GARM_INSTANCE_ID=$PROVIDER_ID" "GARM_POOL_ID=$POOL_ID" </dev/null
              test "$LAST_CODE" -eq 0
              jq -e --arg n "$NAME" '.name == $n' "$RESP" >/dev/null

              echo "== ListInstances (pool) =="
              run ListInstances "GARM_POOL_ID=$POOL_ID" </dev/null; test "$LAST_CODE" -eq 0
              jq -e --arg n "$NAME" 'length == 1 and .[0].name == $n' "$RESP" >/dev/null

              echo "== ListInstances (other pool -> empty) =="
              run ListInstances "GARM_POOL_ID=other-pool" </dev/null; test "$LAST_CODE" -eq 0
              jq -e 'length == 0' "$RESP" >/dev/null

              echo "== StopInstance =="
              run StopInstance "GARM_INSTANCE_ID=$NAME" "GARM_POOL_ID=$POOL_ID" </dev/null
              test "$LAST_CODE" -eq 0
              run GetInstance "GARM_INSTANCE_ID=$NAME" "GARM_POOL_ID=$POOL_ID" </dev/null
              jq -e '.status == "stopped"' "$RESP" >/dev/null

              echo "== StartInstance =="
              run StartInstance "GARM_INSTANCE_ID=$NAME" "GARM_POOL_ID=$POOL_ID" </dev/null
              test "$LAST_CODE" -eq 0
              run GetInstance "GARM_INSTANCE_ID=$NAME" "GARM_POOL_ID=$POOL_ID" </dev/null
              jq -e '.status == "running"' "$RESP" >/dev/null

              echo "== DeleteInstance =="
              run DeleteInstance "GARM_INSTANCE_ID=$NAME" "GARM_POOL_ID=$POOL_ID" </dev/null
              test "$LAST_CODE" -eq 0

              echo "== GetInstance after delete -> exit 30 (NotFound) =="
              run GetInstance "GARM_INSTANCE_ID=$NAME" "GARM_POOL_ID=$POOL_ID" </dev/null || true
              test "$LAST_CODE" -eq 30 || { echo "expected exit 30, got $LAST_CODE" >&2; exit 1; }

              echo "== DeleteInstance idempotent (absent -> exit 0) =="
              run DeleteInstance "GARM_INSTANCE_ID=$NAME" "GARM_POOL_ID=$POOL_ID" </dev/null
              test "$LAST_CODE" -eq 0 || { echo "idempotent delete exit=$LAST_CODE" >&2; exit 1; }

              echo "== RemoveAllInstances (by controller tag) =="
              for n in garm-vmh-a garm-vmh-b; do
                bootstrap_json "$n" > "$work/bootstrap.json"
                run CreateInstance "GARM_POOL_ID=$POOL_ID" < "$work/bootstrap.json"
                test "$LAST_CODE" -eq 0 || { echo "create $n exit=$LAST_CODE" >&2; exit 1; }
              done
              run RemoveAllInstances "GARM_POOL_ID=$POOL_ID" </dev/null
              test "$LAST_CODE" -eq 0
              run ListInstances "GARM_POOL_ID=$POOL_ID" </dev/null; test "$LAST_CODE" -eq 0
              jq -e 'length == 0' "$RESP" >/dev/null

              echo "ALL PROTOCOL ASSERTIONS PASSED"
              touch "$out"
            '';
      };
    };
}
