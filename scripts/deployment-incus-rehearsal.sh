#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scenario="${1:-}"
mode="${2:-run}"

attic_image="${MCL_ATTIC_INCUS_IMAGE:-images:nixos/25.11}"
attic_prefix="${MCL_ATTIC_INCUS_PREFIX:-mcl-attic-cache-${USER:-user}}"
cache_container="${MCL_ATTIC_INCUS_SERVER:-${attic_prefix}-server}"
client_container="${MCL_ATTIC_INCUS_CLIENT:-${attic_prefix}-client}"
host_port="${MCL_ATTIC_INCUS_PORT:-38180}"
cache_name="${MCL_ATTIC_CACHE_NAME:-example-deploy-cache}"
runtime_probe_timeout="${MCL_DEPLOYMENT_INCUS_RUNTIME_PROBE_TIMEOUT:-${MCL_ATTIC_INCUS_RUNTIME_PROBE_TIMEOUT:-10}}"
topology_file="${MCL_DEPLOYMENT_INCUS_TOPOLOGY:-$repo_root/tests/deployment/incus-topology-example.json}"
topology_prefix="${MCL_DEPLOYMENT_INCUS_PREFIX:-mcl-deployment-${USER:-user}}"
topology_artifact_dir="${MCL_DEPLOYMENT_INCUS_ARTIFACT_DIR:-}"
topology_keep="${MCL_DEPLOYMENT_INCUS_KEEP:-}"
if [[ "${MCL_DEPLOYMENT_INCUS_SITE_GROUP+x}" == x ]]; then
  topology_site_group="$MCL_DEPLOYMENT_INCUS_SITE_GROUP"
else
  topology_site_group="example-site"
fi
detect_nix_system() {
  if [[ -n "${MCL_DEPLOYMENT_INCUS_SYSTEM:-}" ]]; then
    echo "$MCL_DEPLOYMENT_INCUS_SYSTEM"
    return 0
  fi
  if command -v nix >/dev/null 2>&1; then
    nix --extra-experimental-features 'nix-command flakes' eval --raw --impure --expr builtins.currentSystem 2>/dev/null && return 0
  fi
  echo x86_64-linux
}
topology_image_attr="${MCL_DEPLOYMENT_INCUS_IMAGE_ATTR:-.#packages.$(detect_nix_system).deployment-incus-rehearsal-image}"
nix_features=(--extra-experimental-features "nix-command flakes")
attic_server_pkg=""
attic_client_pkg=""
openssl_pkg=""
host_system=""
cli=""

usage() {
  cat >&2 <<'USAGE'
usage: deployment-incus-rehearsal.sh SCENARIO [--check-env|--check-runtime|--dry-run|run]

Scenarios:
  attic-cache              Rehearse an Attic cache plus client substitute flow.
  full-topology            Model runner, cache, monitoring, and all rollout groups.
  full-topology-failures   Model the full failure matrix.
  offline-latest-only      Model older/newer desired state while a target is offline.
  forced-command           Model forced-command SSH credential boundaries.
  break-glass              Model human break-glass recovery after a failed deploy.
  pull-agent               Model optional target-side pull-agent reconciliation.

Modes:
  --check-env       Verify local script dependencies and topology inventory.
  --check-runtime   Verify an Incus or LXC daemon is reachable.
  --dry-run         Print launch plan without creating containers.
  run               Launch the runtime rehearsal when implemented for the scenario.

Environment:
  MCL_DEPLOYMENT_INCUS_TOPOLOGY       JSON topology inventory for topology scenarios.
  MCL_DEPLOYMENT_INCUS_SITE_GROUP     Home-lab site target group. Defaults to the
                                      neutral public fixture group "example-site"
                                      when unset. If set, it must be non-empty and
                                      name an existing, distinct topology group.
  MCL_DEPLOYMENT_INCUS_PREFIX         Prefix for runtime container and network names.
  MCL_DEPLOYMENT_INCUS_IMAGE_ATTR     Generic NixOS LXC image attribute.
  MCL_DEPLOYMENT_INCUS_RUNTIME_PROBE_TIMEOUT
USAGE
}

die() {
  echo "deployment-incus-rehearsal: $*" >&2
  exit 1
}

runtime_unavailable() {
  echo "deployment-incus-rehearsal: pending-runtime: $*" >&2
  exit 69
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

runtime_cmd() {
  if command -v incus >/dev/null 2>&1; then
    echo incus
    return 0
  fi
  if command -v lxc >/dev/null 2>&1; then
    echo lxc
    return 0
  fi
  return 1
}

is_topology_scenario() {
  case "$scenario" in
    full-topology | full-topology-failures | offline-latest-only | forced-command | break-glass | pull-agent)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

check_port() {
  [[ "$host_port" =~ ^[0-9]+$ ]] || die "MCL_ATTIC_INCUS_PORT is not numeric: $host_port"
  (( host_port > 0 && host_port < 65536 )) || die "MCL_ATTIC_INCUS_PORT is outside TCP range: $host_port"
}

validate_topology() {
  [[ -f "$topology_file" ]] || die "missing topology inventory: $topology_file"
  [[ -n "$topology_site_group" ]] || die "MCL_DEPLOYMENT_INCUS_SITE_GROUP must be non-empty when set"
  case "$topology_site_group" in
    home-lab-gpu | hetzner | workstation)
      die "MCL_DEPLOYMENT_INCUS_SITE_GROUP must name a distinct site group"
      ;;
  esac
  jq -e --arg siteGroup "$topology_site_group" '
    any((.targetGroups // [])[]; .name == $siteGroup)
    and any((.roles // [])[]; .role == "target" and .targetGroup == $siteGroup)
  ' "$topology_file" >/dev/null || die "MCL_DEPLOYMENT_INCUS_SITE_GROUP does not name an existing target group with a target role"
  jq -e --arg scenario "$scenario" --arg siteGroup "$topology_site_group" '
    (.networks | map(.name)) as $networkNames
    | (.targetGroups | map(.name)) as $targetGroupNames
    | def controlsText($name):
        ([.scenarios[] | select(.name == $name) | .controls[]] | join(" ") | ascii_downcase);
    (.schemaVersion == 1)
    and (.networks | type == "array" and length >= 4)
    and (.roles | type == "array" and length >= 6)
    and (.targetGroups | type == "array" and length >= 4)
    and (.credentials | type == "object")
    and (.scenarios | type == "array" and any(.[]; .name == $scenario))
    and any(.roles[]; .role == "orchestrator")
    and any(.roles[]; .role == "attic-cache")
    and any(.roles[]; .role == "monitoring")
    and any(.roles[]; .targetGroup == "home-lab-gpu" and .avahi == true)
    and any(.roles[]; .targetGroup == $siteGroup and .avahi == true)
    and any(.roles[]; .targetGroup == "hetzner" and .avahi == false)
    and any(.roles[]; .targetGroup == "workstation" and .avahi == false)
    and all(.roles[]; . as $role | (.networks | type == "array" and length > 0 and all(. as $network | $networkNames | index($network))))
    and all(.roles[]; . as $role | ((has("targetGroup") | not) or ($targetGroupNames | index($role.targetGroup))))
    and ($targetGroupNames | index($siteGroup))
    and all(.roles[] | select(.targetGroup == "home-lab-gpu" or .targetGroup == $siteGroup); .avahi == true and (.networks | index("home-lab")))
    and all(.roles[] | select(.targetGroup == "hetzner"); .avahi == false and (.networks | index("hetzner")))
    and all(.roles[] | select(.targetGroup == "workstation"); .avahi == false and (.networks | index("workstation")))
    and (controlsText("full-topology") | contains("runner") and contains("attic") and contains("monitoring") and contains("hetzner") and contains("workstation") and contains("deploy"))
    and (controlsText("full-topology-failures") | contains("partition") and contains("missing cache") and contains("invalid") and contains("signature") and contains("switch failure") and contains("health-check failure") and contains("rollback") and contains("lock contention"))
    and (controlsText("offline-latest-only") | contains("deployment 41") and contains("deployment 42") and contains("offline") and contains("only deployment 42 applies"))
    and (controlsText("forced-command") | contains("arbitrary shell") and contains("rejected") and contains("signed manifest") and contains("signature"))
    and (controlsText("break-glass") | contains("failed deploy") and contains("human runbook") and contains("arbitrary shell") and contains("rejected") and contains("signed manifest") and contains("rollback") and contains("final generation"))
    and (controlsText("pull-agent") | contains("signed manifests") and contains("partition") and contains("newer desired state") and contains("latest"))
  ' "$topology_file" >/dev/null || die "topology inventory is missing required roles, groups, networks, scenario controls, or Avahi policy"
}

check_env() {
  require_command bash
  require_command mktemp
  require_command sed
  require_command timeout
  bash -n "$repo_root/scripts/deployment-incus-rehearsal.sh"

  if [[ "$scenario" == "attic-cache" ]]; then
    require_command curl
    require_command nix
    check_port
  elif is_topology_scenario; then
    require_command jq
    require_command python3
    validate_topology
  else
    usage
    exit 64
  fi

  if runtime_cmd >/dev/null; then
    echo "deployment-incus-rehearsal: container client: $(runtime_cmd)"
  else
    echo "deployment-incus-rehearsal: container client: pending-runtime (install incus or lxc for runtime launch)"
  fi

  echo "deployment-incus-rehearsal: local environment is complete"
}

check_runtime() {
  cli="$(runtime_cmd)" || runtime_unavailable "Incus/LXC CLI not found; install incus or lxc and initialize a daemon"
  if ! timeout "$runtime_probe_timeout" "$cli" info >/dev/null 2>&1; then
    runtime_unavailable "$cli CLI is present, but no reachable Incus/LXD daemon is available"
  fi
  echo "deployment-incus-rehearsal: runtime is available via $cli"
}

dry_run_attic_cache() {
  check_env
  local client
  client="$(runtime_cmd || echo incus)"
  cat <<EOF
attic-cache rehearsal plan:
  1. Launch ${client}:${attic_image} containers ${cache_container} and ${client_container}.
  2. Start atticd in ${cache_container} on port 8080 and proxy it to 127.0.0.1:${host_port}.
  3. Create public Attic cache ${cache_name} with a deterministic test token.
  4. Build a small host fixture closure.
  5. Run mcl-devops cache push-closure with --backend attic, --substituter, and --require-substitute.
  6. Restore the fixture from Attic inside ${client_container} using nix copy.
  7. Remove containers unless MCL_ATTIC_INCUS_KEEP=1 is set.
EOF
}

dry_run_topology() {
  check_env
  local client
  client="$(runtime_cmd || echo incus)"
  echo "deployment-incus-rehearsal: scenario=${scenario}"
  echo "deployment-incus-rehearsal: topology=${topology_file}"
  echo "deployment-incus-rehearsal: site-group=${topology_site_group}"
  echo "deployment-incus-rehearsal: image-attr=${topology_image_attr}"
  echo "deployment-incus-rehearsal: runtime client=${client}"
  jq -r --arg scenario "$scenario" --arg prefix "$topology_prefix" '
    "full-topology rehearsal plan:",
    "  1. Build the generic deployment rehearsal LXC image.",
    "  2. Create segmented Incus networks:",
    (.networks[] | "     - \($prefix)-\(.name): role=\(.role) cidr=\(.cidr)"),
    "  3. Launch containers and attach declared networks:",
    (.roles[] | "     - \($prefix)-\(.name): role=\(.role) group=\(.targetGroup // "none") avahi=\(.avahi // false) networks=\((.networks // []) | join(","))"),
    "  4. Generate rehearsal-only manifest and deploy SSH credentials:",
    "     - forcedCommandPrincipal=\(.credentials.forcedCommand.principal)",
    "     - manifestPrincipal=\(.credentials.manifestSigning.principal)",
    "  5. Apply target-group rollout policy:",
    (.targetGroups[] | "     - \(.name): policy=\(.rolloutPolicy)"),
    "  6. Run scenario controls:",
    (.scenarios[] | select(.name == $scenario) | (.controls[] | "     - " + .)),
    "  7. Capture event JSONL, target journals, Attic logs, metrics snapshot, and final desired-state status."
  ' "$topology_file"
}

container_exec() {
  "$cli" exec "$1" -- /run/current-system/sw/bin/bash -lc "$2" < /dev/null
}

build_tool() {
  nix "${nix_features[@]}" build --no-link --print-out-paths "$1" | head -n1
}

prepare_tools() {
  host_system="$(nix "${nix_features[@]}" eval --raw --impure --expr builtins.currentSystem)"
  attic_server_pkg="$(build_tool nixpkgs#attic-server)"
  attic_client_pkg="$(build_tool nixpkgs#attic-client)"
  openssl_pkg="$(build_tool nixpkgs#openssl)"
}

import_closure() {
  local container="$1"
  local archive="$2"
  shift 2

  nix-store --export $(nix-store -qR "$@") > "$archive"
  "$cli" file push "$archive" "${container}/tmp/mcl-attic-tools.nar"
  container_exec "$container" "nix-store --import < /tmp/mcl-attic-tools.nar >/dev/null"
}

cleanup_attic_cache() {
  if [[ "${MCL_ATTIC_INCUS_KEEP:-}" == "1" ]]; then
    echo "deployment-incus-rehearsal: keeping containers $cache_container and $client_container"
    return
  fi
  if [[ -n "${cli:-}" ]]; then
    "$cli" stop "$cache_container" --force >/dev/null 2>&1 || true
    "$cli" stop "$client_container" --force >/dev/null 2>&1 || true
    "$cli" delete "$cache_container" >/dev/null 2>&1 || true
    "$cli" delete "$client_container" >/dev/null 2>&1 || true
  fi
}

wait_host_http() {
  local url="$1"
  local attempt
  for attempt in $(seq 1 90); do
    if curl -sS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  die "Attic did not become reachable at $url"
}

start_atticd() {
  container_exec "$cache_container" "mkdir -p /var/lib/mcl-attic/{storage,config}"
  container_exec "$cache_container" \
    "'${openssl_pkg}/bin/openssl' genrsa -traditional 4096 | base64 -w0 > /var/lib/mcl-attic/token-secret"
  container_exec "$cache_container" \
    "printf 'ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64=%s\n' \"\$(cat /var/lib/mcl-attic/token-secret)\" > /var/lib/mcl-attic/environment"
  container_exec "$cache_container" "cat > /var/lib/mcl-attic/server.toml <<EOF
listen = \"0.0.0.0:8080\"
api-endpoint = \"http://127.0.0.1:${host_port}/\"
allowed-hosts = [\"${cache_container}:8080\", \"127.0.0.1:8080\", \"127.0.0.1:${host_port}\", \"localhost:${host_port}\"]

[database]
url = \"sqlite:///var/lib/mcl-attic/server.db?mode=rwc\"

[storage]
type = \"local\"
path = \"/var/lib/mcl-attic/storage\"

[chunking]
nar-size-threshold = 65536
min-size = 16384
avg-size = 65536
max-size = 262144
EOF"
  container_exec "$cache_container" \
    "set -a; . /var/lib/mcl-attic/environment; set +a; nohup '${attic_server_pkg}/bin/atticd' -f /var/lib/mcl-attic/server.toml >/var/lib/mcl-attic/atticd.log 2>&1 &"
}

make_token() {
  container_exec "$cache_container" \
    "set -a; . /var/lib/mcl-attic/environment; set +a; '${attic_server_pkg}/bin/atticadm' -f /var/lib/mcl-attic/server.toml make-token --sub incus-rehearsal --validity 1y --create-cache '*' --pull '*' --push '*' --delete '*' --configure-cache '*' --configure-cache-retention '*'"
}

run_attic_cache() {
  check_env
  check_runtime
  prepare_tools

  trap cleanup_attic_cache EXIT
  cleanup_attic_cache

  echo "deployment-incus-rehearsal: launching containers: $cache_container $client_container"
  "$cli" launch "$attic_image" "$cache_container"
  "$cli" launch "$attic_image" "$client_container"

  "$cli" config device add "$cache_container" attic-http proxy \
    "listen=tcp:127.0.0.1:${host_port}" "connect=tcp:127.0.0.1:8080"
  "$cli" config device add "$client_container" attic-client-http proxy \
    "listen=tcp:127.0.0.1:8080" "connect=tcp:127.0.0.1:${host_port}" "bind=container"

  container_exec "$cache_container" "nix --version >/dev/null"
  container_exec "$client_container" "nix --version >/dev/null"
  tool_archive="$(mktemp)"
  import_closure "$cache_container" "$tool_archive" "$attic_server_pkg" "$openssl_pkg"

  start_atticd
  wait_host_http "http://127.0.0.1:${host_port}/"

  local token fixture fixture_expr public_key event_log
  token="$(make_token | tail -n1)"

  export XDG_CONFIG_HOME
  XDG_CONFIG_HOME="$(mktemp -d)"
  fixture_expr='derivation { name = "mcl-attic-incus-fixture"; system = "'"$host_system"'"; builder = "/bin/sh"; args = [ "-c" "echo incus-attic-fixture > $out" ]; }'
  fixture="$(nix "${nix_features[@]}" build --no-link --print-out-paths --expr "$fixture_expr")"
  event_log="$(mktemp)"

  "${attic_client_pkg}/bin/attic" login --set-default incus "http://127.0.0.1:${host_port}" "$token"
  "${attic_client_pkg}/bin/attic" cache create --public "$cache_name"
  public_key="$("${attic_client_pkg}/bin/attic" cache info "$cache_name" 2>&1 | sed -n 's/.*Public Key: //p')"
  [[ -n "$public_key" ]] || die "failed to discover Attic public key"

  nix "${nix_features[@]}" run "$repo_root#mcl-devops" -- cache push-closure \
    --backend attic \
    --cache "$cache_name" \
    --target "$client_container" \
    --system "$host_system" \
    --kind incus \
    --transport local-incus \
    --substituter "http://127.0.0.1:${host_port}/${cache_name}" \
    --trusted-public-key "$public_key" \
    --require-substitute \
    --event-log "$event_log" \
    "$fixture"

  container_exec "$client_container" \
    "nix --extra-experimental-features 'nix-command flakes' copy --from http://127.0.0.1:8080/${cache_name} --to file:///tmp/mcl-attic-restore-store --option trusted-public-keys '$public_key' '$fixture'"

  grep -q '"controller":"attic"' "$event_log" || die "event log does not contain Attic backend event"
  grep -q '"successful-substitute"' "$event_log" || die "event log does not contain successful substitute probe"

  echo "deployment-incus-rehearsal: runtime rehearsal passed"
}

sanitize_resource_name() {
  local raw="$1"
  local clean
  clean="$(printf '%s' "$raw" | tr -c 'A-Za-z0-9.-' '-' | sed -E 's/^-+//; s/-+$//; s/-+/-/g')"
  [[ -n "$clean" ]] || clean="mcl-deployment"
  printf '%.80s' "$clean"
}

topology_init_runtime_names() {
  topology_safe_prefix="$(sanitize_resource_name "$topology_prefix")"
  topology_image_alias="${MCL_DEPLOYMENT_INCUS_IMAGE_ALIAS:-${topology_safe_prefix}-image}"
  if [[ -z "$topology_artifact_dir" ]]; then
    topology_artifact_dir="$(mktemp -d "${TMPDIR:-/tmp}/${topology_safe_prefix}-${scenario}.XXXXXX")"
  else
    mkdir -p "$topology_artifact_dir"
  fi
  topology_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/${topology_safe_prefix}-work.XXXXXX")"
  mkdir -p "$topology_artifact_dir"/{containers,logs}
}

topology_resource_name() {
  printf '%s-%s' "$topology_safe_prefix" "$(sanitize_resource_name "$1")"
}

topology_network_code() {
  case "$1" in
    control) echo ctrl ;;
    cache) echo cache ;;
    home-lab) echo home ;;
    hetzner) echo hetz ;;
    workstation) echo work ;;
    *) sanitize_resource_name "$1" | cut -c1-4 ;;
  esac
}

topology_network_resource_name() {
  local prefix_part hash_part code
  prefix_part="$(printf '%s' "$topology_safe_prefix" | cut -c1-5)"
  hash_part="$(printf '%s' "$topology_safe_prefix" | sha256sum | cut -c1-4)"
  code="$(topology_network_code "$1")"
  printf '%.15s' "${prefix_part}-${hash_part}-${code}"
}

topology_role_names() {
  jq -r '.roles[].name' "$topology_file"
}

topology_network_names() {
  jq -r '.networks[].name' "$topology_file"
}

topology_role_container() {
  local role_safe base prefix_part role_part hash_part
  role_safe="$(sanitize_resource_name "$1")"
  base="${topology_safe_prefix}-${role_safe}"
  if (( ${#base} <= 63 )); then
    echo "$base"
    return 0
  fi

  prefix_part="$(printf '%s' "$topology_safe_prefix" | cut -c1-30)"
  role_part="$(printf '%s' "$role_safe" | cut -c1-20)"
  hash_part="$(printf '%s' "$base" | sha256sum | cut -c1-10)"
  printf '%.63s' "${prefix_part}-${role_part}-${hash_part}"
}

topology_role_by_kind() {
  jq -r --arg kind "$1" '.roles[] | select(.role == $kind) | .name' "$topology_file" | head -n1
}

topology_first_target_role() {
  jq -r '.roles[] | select(.role == "target") | .name' "$topology_file" | head -n1
}

topology_first_role_by_transport() {
  jq -r --arg transport "$1" '.roles[] | select(.transport == $transport) | .name' "$topology_file" | head -n1
}

topology_role_networks() {
  jq -r --arg name "$1" '.roles[] | select(.name == $name) | .networks[]' "$topology_file"
}

topology_role_network_index() {
  jq -r --arg name "$1" --arg network "$2" '
    .roles[]
    | select(.name == $name)
    | .networks
    | to_entries[]
    | select(.value == $network)
    | .key
  ' "$topology_file" | head -n1
}

topology_gateway_for_cidr() {
  python3 - "$1" <<'PY'
import ipaddress
import sys

network = ipaddress.ip_network(sys.argv[1], strict=False)
hosts = network.hosts()
try:
    gateway = next(hosts)
except StopIteration:
    gateway = network.network_address
print(f"{gateway}/{network.prefixlen}")
PY
}

topology_address_for_cidr() {
  python3 - "$1" "$2" <<'PY'
import ipaddress
import sys

network = ipaddress.ip_network(sys.argv[1], strict=False)
offset = int(sys.argv[2])
address = network.network_address + offset
if address not in network:
    raise SystemExit(f"address offset {offset} is outside {network}")
print(f"{address}/{network.prefixlen}")
PY
}

topology_role_ordinal() {
  jq -r --arg name "$1" '.roles | to_entries[] | select(.value.name == $name) | .key' "$topology_file" | head -n1
}

topology_storage_pool() {
  if [[ -n "${MCL_DEPLOYMENT_INCUS_STORAGE_POOL:-}" ]]; then
    echo "$MCL_DEPLOYMENT_INCUS_STORAGE_POOL"
    return 0
  fi

  local pool
  pool="$("$cli" profile device get default root pool 2>/dev/null || true)"
  if [[ -n "$pool" ]]; then
    echo "$pool"
    return 0
  fi

  "$cli" storage list --format json 2>/dev/null | jq -r '.[0].name // empty'
}

topology_cleanup() {
  if [[ -z "${cli:-}" || -z "${topology_safe_prefix:-}" ]]; then
    return
  fi

  if [[ "$topology_keep" == "1" ]]; then
    echo "deployment-incus-rehearsal: keeping prefixed runtime resources for debugging: $topology_safe_prefix"
    echo "deployment-incus-rehearsal: artifacts: $topology_artifact_dir"
    return
  fi

  local role container network resource
  while IFS= read -r role; do
    container="$(topology_role_container "$role")"
    "$cli" stop "$container" --force >/dev/null 2>&1 || true
    "$cli" delete "$container" --force >/dev/null 2>&1 || true
  done < <(topology_role_names 2>/dev/null || true)

  while IFS= read -r network; do
    resource="$(topology_network_resource_name "$network")"
    "$cli" network delete "$resource" >/dev/null 2>&1 || true
  done < <(topology_network_names 2>/dev/null || true)

  "$cli" image delete "$topology_image_alias" >/dev/null 2>&1 || true
  rm -rf "${topology_tmp_dir:-}"
}

topology_reset_prefixed_resources() {
  local keep_was="$topology_keep"
  local tmp_was="${topology_tmp_dir:-}"
  topology_keep=0
  topology_cleanup
  topology_keep="$keep_was"
  topology_tmp_dir="$tmp_was"
  [[ -n "$topology_tmp_dir" ]] && mkdir -p "$topology_tmp_dir"
}

topology_build_import_image() {
  echo "deployment-incus-rehearsal: building image attr: $topology_image_attr"
  local image_path
  if ! image_path="$(nix "${nix_features[@]}" build --no-link --print-out-paths "$topology_image_attr" 2>"$topology_artifact_dir/image-build.err")"; then
    cat "$topology_artifact_dir/image-build.err" >&2
    die "failed to build deployment rehearsal image: $topology_image_attr"
  fi
  image_path="$(printf '%s\n' "$image_path" | tail -n1)"
  [[ -f "$image_path/metadata.tar.xz" ]] || die "image metadata missing: $image_path/metadata.tar.xz"
  [[ -f "$image_path/rootfs.tar.xz" ]] || die "image rootfs missing: $image_path/rootfs.tar.xz"

  echo "deployment-incus-rehearsal: importing image alias: $topology_image_alias"
  "$cli" image import "$image_path/metadata.tar.xz" "$image_path/rootfs.tar.xz" --alias "$topology_image_alias" --reuse
}

topology_create_networks() {
  local name cidr resource gateway
  while IFS=$'\t' read -r name cidr; do
    resource="$(topology_network_resource_name "$name")"
    gateway="$(topology_gateway_for_cidr "$cidr")"
    echo "deployment-incus-rehearsal: creating network: $resource ($gateway)"
    "$cli" network create "$resource" --type bridge \
      --description "MCL deployment rehearsal ${scenario} network ${name}" \
      "ipv4.address=$gateway" \
      ipv4.nat=true \
      ipv6.address=none \
      < /dev/null
  done < <(jq -r '.networks[] | [.name, .cidr] | @tsv' "$topology_file")
}

topology_launch_role() {
  local role="$1"
  local container
  container="$(topology_role_container "$role")"
  mapfile -t networks < <(topology_role_networks "$role")
  (( ${#networks[@]} > 0 )) || die "role has no declared networks: $role"

  local storage_pool
  storage_pool="$(topology_storage_pool)"
  [[ -n "$storage_pool" ]] || runtime_unavailable "no Incus storage pool is configured for no-profile container launch"

  echo "deployment-incus-rehearsal: launching container: $container"
  "$cli" launch "$topology_image_alias" "$container" \
    --no-profiles \
    --network "$(topology_network_resource_name "${networks[0]}")" \
    --storage "$storage_pool" \
    --config security.nesting=true \
    < /dev/null

  local index network
  for ((index = 1; index < ${#networks[@]}; index++)); do
    network="${networks[$index]}"
    "$cli" config device add "$container" "eth${index}" nic \
      "network=$(topology_network_resource_name "$network")" \
      "name=eth${index}" \
      < /dev/null
  done
}

topology_wait_container_ready() {
  local container="$1"
  local attempt
  for attempt in $(seq 1 90); do
    if container_exec "$container" "test -x /run/current-system/sw/bin/bash && test -x /run/current-system/sw/bin/python3" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  die "container did not become executable: $container"
}

topology_container_ipv4() {
  local container="$1"
  local interface="${2:-eth0}"
  container_exec "$container" "ip -4 -o addr show dev '$interface' scope global 2>/dev/null | awk '{ print \$4 }' | sed 's#/.*##' | grep -v '^169\\.254\\.' | head -n1" 2>/dev/null || true
}

topology_wait_container_ipv4() {
  local container="$1"
  local interface="${2:-eth0}"
  local attempt ip
  for attempt in $(seq 1 90); do
    ip="$(topology_container_ipv4 "$container" "$interface")"
    if [[ -n "$ip" ]]; then
      echo "$ip"
      return 0
    fi
    sleep 1
  done
  die "container did not receive IPv4 on ${interface}: $container"
}

topology_configure_role_addresses() {
  local role="$1"
  local container ordinal index network cidr address device
  container="$(topology_role_container "$role")"
  ordinal="$(topology_role_ordinal "$role")"
  [[ -n "$ordinal" ]] || die "cannot determine topology ordinal for role: $role"
  ordinal=$((ordinal + 10))

  while IFS=$'\t' read -r index network; do
    device="eth${index}"
    cidr="$(jq -r --arg network "$network" '.networks[] | select(.name == $network) | .cidr' "$topology_file")"
    address="$(topology_address_for_cidr "$cidr" "$ordinal")"
    container_exec "$container" "ip link set '$device' up && ip addr flush dev '$device' scope global || true; ip addr add '$address' dev '$device'; ip link set '$device' up"
  done < <(
    jq -r --arg name "$role" '
      .roles[]
      | select(.name == $name)
      | .networks
      | to_entries[]
      | [.key, .value]
      | @tsv
    ' "$topology_file"
  )
}

topology_write_runtime_scripts() {
  cat > "$topology_tmp_dir/container-assert.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

meta="${MCL_DEPLOYMENT_INCUS_RUNTIME_META:-/etc/mcl-deployment-rehearsal/runtime.json}"
test -s "$meta"

role_name="$(jq -r '.role.name' "$meta")"
role_kind="$(jq -r '.role.role' "$meta")"
target_group="$(jq -r '.role.targetGroup // ""' "$meta")"
avahi="$(jq -r '.role.avahi // false' "$meta")"
site_group="$(jq -r '.siteGroup // ""' "$meta")"

[[ -n "$site_group" ]] || {
  echo "runtime metadata has no configured site group" >&2
  exit 1
}
jq -e --arg siteGroup "$site_group" '.schemaVersion == 1 and .siteGroup == $siteGroup and (.role.name | length > 0) and (.role.role | length > 0)' "$meta" >/dev/null

case "$target_group" in
  home-lab-gpu | "$site_group")
    [[ "$avahi" == "true" ]] || {
      echo "expected Avahi enabled for target group $target_group" >&2
      exit 1
    }
    ;;
  hetzner | workstation)
    [[ "$avahi" == "false" ]] || {
      echo "expected Avahi disabled for target group $target_group" >&2
      exit 1
    }
    ;;
esac

declared_count="$(jq '.role.networks | length' "$meta")"
ip_bin="$(command -v ip || true)"
[[ -n "$ip_bin" ]] || ip_bin=/run/current-system/sw/bin/ip
actual_count="$("$ip_bin" -o link show | awk -F': ' '$2 ~ /^eth[0-9]+/ { count++ } END { print count + 0 }')"
if (( actual_count < declared_count )); then
  echo "expected at least $declared_count attached eth interfaces, saw $actual_count" >&2
  exit 1
fi

mkdir -p /tmp/mcl-rehearsal
jq -n \
  --arg roleName "$role_name" \
  --arg roleKind "$role_kind" \
  --arg targetGroup "$target_group" \
  --argjson declaredCount "$declared_count" \
  --argjson actualCount "$actual_count" \
  --arg avahi "$avahi" \
  '{
    roleName: $roleName,
    roleKind: $roleKind,
    targetGroup: $targetGroup,
    declaredNetworkCount: $declaredCount,
    actualInterfaceCount: $actualCount,
    avahiExpected: ($avahi == "true"),
    status: "passed"
  }' > /tmp/mcl-rehearsal/assertions.json

echo "container assertions passed for ${role_name}"
SH

  cat > "$topology_tmp_dir/scenario-driver.py" <<'PY'
#!/usr/bin/env python3
import json
import pathlib
import sys
import time

scenario = sys.argv[1]
topology_path = pathlib.Path(sys.argv[2])
out_dir = pathlib.Path(sys.argv[3])
site_group = sys.argv[4]
topology = json.loads(topology_path.read_text())
out_dir.mkdir(parents=True, exist_ok=True)

events_path = out_dir / "events.jsonl"
state_path = out_dir / "final-state.json"
commands_path = out_dir / "runtime-commands.log"

roles = topology["roles"]
target_groups = [group["name"] for group in topology["targetGroups"]]
targets = [role for role in roles if role["role"] == "target"]
if not site_group:
    raise SystemExit("configured site group is empty")
if site_group not in target_groups:
    raise SystemExit("configured site group is missing from topology")
if not any(role.get("targetGroup") == site_group for role in targets):
    raise SystemExit("configured site group has no runtime target")

events = []

def event(event_type, **fields):
    record = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "scenario": scenario,
        "event": event_type,
    }
    record.update(fields)
    events.append(record)

runtime_commands = [
    "mcl-devops deploy-plan --synthetic-rehearsal",
    "mcl-devops deploy-reconcile --synthetic-rehearsal",
    "mcl-devops deploy-ssh --synthetic-rehearsal",
]

if scenario == "full-topology":
    for group in target_groups:
        group_targets = [role["name"] for role in targets if role.get("targetGroup") == group]
        if not group_targets:
            raise SystemExit(f"target group has no runtime targets: {group}")
        event("desired-state-published", deploymentId=42, targetGroup=group)
        event("cache-restored", cache="attic", targetGroup=group)
        event("manifest-accepted", deploymentId=42, targetGroup=group)
        event("switch-succeeded", deploymentId=42, targetGroup=group)
        event("healthcheck-passed", deploymentId=42, targetGroup=group)
        event("deployment-complete", deploymentId=42, targetGroup=group, targets=group_targets)
    final = {
        "status": "succeeded",
        "deploymentId": 42,
        "targetGroups": {group: {"status": "succeeded", "deploymentId": 42} for group in target_groups},
    }
elif scenario == "full-topology-failures":
    evidence_path = out_dir / "failure-evidence.json"
    if not evidence_path.exists():
        raise SystemExit("failure matrix evidence missing")
    evidence = json.loads(evidence_path.read_text())
    required_evidence = {
        "offlineTarget": ["partitionedAndReconnected"],
        "missingCacheObject": ["requestFailed"],
        "invalidSignature": ["rejected"],
        "switchFailure": ["failed"],
        "healthCheckFailure": ["failed"],
        "rollback": ["started", "completed"],
        "staleDesiredState": ["rejected"],
        "lockContention": ["detected"],
    }
    for section, keys in required_evidence.items():
        if section not in evidence:
            raise SystemExit(f"failure evidence section missing: {section}")
        for key in keys:
            if not evidence[section].get(key):
                raise SystemExit(f"failure evidence not proven: {section}.{key}: {evidence[section]}")
    event("target-offline", deploymentId=41, targetGroup="home-lab-gpu", target=evidence["offlineTarget"]["target"])
    event("cache-missing-object", cache="attic", storePath="/nix/store/synthetic-missing", exitCode=evidence["missingCacheObject"]["exitCode"])
    event("manifest-rejected", reason="invalid-signature", deploymentId=42, exitCode=evidence["invalidSignature"]["exitCode"])
    event("switch-failed", targetGroup="hetzner", deploymentId=43, exitCode=evidence["switchFailure"]["exitCode"])
    event("healthcheck-failed", targetGroup=site_group, deploymentId=44, exitCode=evidence["healthCheckFailure"]["exitCode"])
    event("rollback-started", targetGroup=site_group, fromDeploymentId=44)
    event("rollback-complete", targetGroup=site_group, restoredDeploymentId=evidence["rollback"]["restoredDeploymentId"])
    event("stale-desired-state-rejected", rejectedDeploymentId=evidence["staleDesiredState"]["rejectedDeploymentId"], currentDeploymentId=evidence["staleDesiredState"]["currentDeploymentId"])
    event("lock-contention", lock="controller", contender="second-reconciler", exitCode=evidence["lockContention"]["exitCode"])
    final = {
        "status": "failure-matrix-passed",
        "evidence": evidence,
    }
elif scenario == "offline-latest-only":
    status_path = out_dir / "offline-latest-status.json"
    if not status_path.exists():
        raise SystemExit("offline latest-only status missing")
    status = json.loads(status_path.read_text())
    if status.get("appliedDeployment") != 42 or 41 not in status.get("skippedDeployments", []):
        raise SystemExit(f"offline latest-only status incomplete: {status}")
    if not status.get("partitionedAndReconnected"):
        raise SystemExit(f"offline latest-only did not exercise partition/reconnect: {status}")
    event("target-offline", deploymentId=41, target=status["target"])
    event("desired-state-published", deploymentId=41)
    event("desired-state-published", deploymentId=42)
    event("target-reconnected", target=status["target"])
    event("stale-desired-state-rejected", rejectedDeploymentId=41, currentDeploymentId=42)
    event("deployment-applied", deploymentId=42, target=status["target"])
    final = {
        "status": "succeeded",
        "appliedDeployment": status["appliedDeployment"],
        "skippedDeployments": status["skippedDeployments"],
        "latestOnly": True,
        "offlineLatestOnly": status,
    }
elif scenario == "forced-command":
    evidence_path = out_dir / "forced-command-evidence.json"
    if not evidence_path.exists():
        raise SystemExit("forced-command evidence missing")
    evidence = json.loads(evidence_path.read_text())
    if not evidence.get("arbitraryShellRejected") or not evidence.get("signedManifestAccepted"):
        raise SystemExit(f"forced-command evidence incomplete: {evidence}")
    if not evidence.get("arbitraryShellTargetResult", {}).get("rejected"):
        raise SystemExit(f"forced-command arbitrary shell target artifact missing: {evidence}")
    if not evidence.get("signedManifestTargetResult", {}).get("accepted"):
        raise SystemExit(f"forced-command signed manifest target artifact missing: {evidence}")
    event("arbitrary-shell-rejected", target=evidence["target"], exitCode=evidence["arbitraryShellExitCode"])
    event("signed-manifest-accepted", target=evidence["target"], deploymentId=42)
    final = {
        "status": "succeeded",
        "forcedCommand": evidence,
    }
elif scenario == "break-glass":
    evidence_path = out_dir / "break-glass-evidence.json"
    if not evidence_path.exists():
        raise SystemExit("break-glass evidence missing")
    evidence = json.loads(evidence_path.read_text())
    if not evidence.get("failedDeployDetected"):
        raise SystemExit(f"break-glass failed deployment was not represented: {evidence}")
    if not evidence.get("arbitraryShellRejected"):
        raise SystemExit(f"break-glass arbitrary shell was not rejected: {evidence}")
    if not evidence.get("arbitraryShellTargetResult", {}).get("rejected"):
        raise SystemExit(f"break-glass arbitrary shell target artifact missing: {evidence}")
    if not evidence.get("signedManifestAccepted"):
        raise SystemExit(f"break-glass signed manifest was not accepted: {evidence}")
    if not evidence.get("recoveryManifestTargetResult", {}).get("accepted"):
        raise SystemExit(f"break-glass target-side signed manifest artifact missing: {evidence}")
    if evidence.get("recoveryManifestTargetResult", {}).get("target") != evidence.get("target"):
        raise SystemExit(f"break-glass manifest target binding was not preserved: {evidence}")
    rollback = evidence.get("rollback", {})
    if not rollback.get("started") or not rollback.get("completed"):
        raise SystemExit(f"break-glass rollback evidence incomplete: {evidence}")
    if evidence.get("finalGeneration") != evidence.get("rollbackToGeneration"):
        raise SystemExit(f"break-glass final generation was not preserved/restored: {evidence}")
    if rollback.get("finalGeneration") != evidence.get("finalGeneration"):
        raise SystemExit(f"break-glass rollback final generation does not match evidence: {evidence}")
    target_state = evidence.get("targetGenerationState", {})
    if target_state.get("target") != evidence.get("target"):
        raise SystemExit(f"break-glass target state was for the wrong target: {evidence}")
    if target_state.get("finalGeneration") != evidence.get("finalGeneration"):
        raise SystemExit(f"break-glass target generation artifact does not match final state: {evidence}")
    event("failed-deploy-detected", target=evidence["target"], deploymentId=evidence["failedDeploymentId"], generation=evidence["failedGeneration"])
    event("arbitrary-shell-rejected", target=evidence["target"], exitCode=evidence["arbitraryShellExitCode"])
    event("break-glass-manifest-accepted", target=evidence["target"], deploymentId=evidence["recoveryDeploymentId"])
    event("rollback-complete", target=evidence["target"], restoredGeneration=evidence["finalGeneration"])
    event("final-generation-preserved", target=evidence["target"], generation=evidence["finalGeneration"])
    final = {
        "status": "succeeded",
        "breakGlass": evidence,
    }
elif scenario == "pull-agent":
    status_path = out_dir / "pull-agent-status.json"
    if not status_path.exists():
        raise SystemExit("pull-agent status missing")
    status = json.loads(status_path.read_text())
    if status.get("appliedDeployment") != 42 or 41 not in status.get("skippedDeployments", []):
        raise SystemExit(f"pull-agent latest-only status incomplete: {status}")
    event("pull-agent-offline", deploymentId=41, target=status["target"])
    event("desired-state-published", deploymentId=41)
    event("desired-state-published", deploymentId=42)
    event("pull-agent-reconnected", target=status["target"])
    event("pull-agent-applied", deploymentId=42, target=status["target"])
    final = {
        "status": "succeeded",
        "pullAgent": status,
    }
else:
    raise SystemExit(f"unknown scenario: {scenario}")

if any(command.lower().startswith("cachix deploy") for command in runtime_commands):
    raise SystemExit("Cachix Deploy production command was used")

commands_path.write_text("\n".join(runtime_commands) + "\n")
with events_path.open("w") as handle:
    for record in events:
        handle.write(json.dumps(record, sort_keys=True) + "\n")

required = {
    "full-topology": ["deployment-complete"],
    "full-topology-failures": [
        "target-offline",
        "cache-missing-object",
        "manifest-rejected",
        "switch-failed",
        "healthcheck-failed",
        "rollback-complete",
        "stale-desired-state-rejected",
        "lock-contention",
    ],
    "offline-latest-only": ["stale-desired-state-rejected", "deployment-applied"],
    "forced-command": ["arbitrary-shell-rejected", "signed-manifest-accepted"],
    "break-glass": ["failed-deploy-detected", "arbitrary-shell-rejected", "break-glass-manifest-accepted", "rollback-complete", "final-generation-preserved"],
    "pull-agent": ["pull-agent-applied"],
}[scenario]
event_types = {record["event"] for record in events}
missing = [event_type for event_type in required if event_type not in event_types]
if missing:
    raise SystemExit(f"missing required events: {missing}")

final.update(
    {
        "scenario": scenario,
        "cachixDeployUsed": False,
        "productionCommandsUsed": [],
        "roles": sorted({role["role"] for role in roles}),
        "siteGroup": site_group,
    }
)
state_path.write_text(json.dumps(final, indent=2, sort_keys=True) + "\n")
print(f"scenario {scenario} assertions passed")
PY

  cat > "$topology_tmp_dir/forced-command-guard.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

mkdir -p /tmp/mcl-rehearsal
original_command="${SSH_ORIGINAL_COMMAND:-}"

case "$original_command" in
  "deploy-submit "*)
    manifest="${original_command#deploy-submit }"
    if jq -e '.signature == "synthetic-valid" and .deploymentId == 42 and (.targetGroup | length > 0)' "$manifest" >/dev/null; then
      jq -n \
        --arg manifest "$manifest" \
        '{accepted: true, manifest: $manifest}' > /tmp/mcl-rehearsal/forced-command-target-result.json
      echo "accepted signed manifest"
      exit 0
    fi
    echo "rejected invalid manifest" >&2
    exit 125
    ;;
  *)
    jq -n \
      --arg originalCommand "$original_command" \
      '{rejected: true, originalCommand: $originalCommand}' > /tmp/mcl-rehearsal/forced-command-target-result.json
    echo "rejected arbitrary command" >&2
    exit 126
    ;;
esac
SH

  cat > "$topology_tmp_dir/pull-agent-sim.py" <<'PY'
#!/usr/bin/env python3
import json
import pathlib
import sys

target = sys.argv[1]
desired_dir = pathlib.Path(sys.argv[2])
status_path = pathlib.Path(sys.argv[3])

manifests = []
for path in desired_dir.glob("*.json"):
    manifest = json.loads(path.read_text())
    if manifest.get("signature") == "synthetic-valid":
        manifests.append(manifest)

if not manifests:
    raise SystemExit("no valid desired-state manifests")

latest = max(manifests, key=lambda manifest: manifest["deploymentId"])
skipped = sorted(
    manifest["deploymentId"]
    for manifest in manifests
    if manifest["deploymentId"] < latest["deploymentId"]
)
status = {
    "target": target,
    "appliedDeployment": latest["deploymentId"],
    "skippedDeployments": skipped,
    "source": "target-side-pull-agent",
}
status_path.write_text(json.dumps(status, indent=2, sort_keys=True) + "\n")
print(json.dumps(status, sort_keys=True))
PY

  cat > "$topology_tmp_dir/break-glass-guard.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

mkdir -p /tmp/mcl-rehearsal
original_command="${SSH_ORIGINAL_COMMAND:-}"
state_file=/tmp/mcl-rehearsal/break-glass-generation-state.json
events_file=/tmp/mcl-rehearsal/break-glass-events.jsonl
policy_file=/tmp/mcl-rehearsal/break-glass-policy.json

case "$original_command" in
  "break-glass-apply "*)
    manifest="${original_command#break-glass-apply }"
    if ! jq -e --slurpfile policy "$policy_file" '
      .signature == "synthetic-valid"
      and .breakGlass == true
      and .action == "rollback"
      and .deploymentId == 45
      and .failedDeploymentId == 44
      and .rollbackToGeneration == 100
      and .target == $policy[0].target
      and .targetGroup == $policy[0].targetGroup
    ' "$manifest" >/dev/null; then
      echo "rejected invalid break-glass manifest" >&2
      exit 125
    fi
    if ! jq -e '.failedDeploymentId == 44 and .healthStatus == "failed" and .previousGoodGeneration == 100' "$state_file" >/dev/null; then
      echo "target is not in the expected failed deployment state" >&2
      exit 124
    fi

    target="$(jq -r '.target' "$manifest")"
    target_group="$(jq -r '.targetGroup' "$manifest")"
    jq -c -n \
      --arg target "$target" \
      --arg targetGroup "$target_group" \
      --argjson failedDeploymentId 44 \
      --argjson recoveryDeploymentId 45 \
      --argjson previousGoodGeneration 100 \
      --argjson failedGeneration 101 \
      --argjson finalGeneration 100 \
      '{
        target: $target,
        targetGroup: $targetGroup,
        failedDeploymentId: $failedDeploymentId,
        recoveryDeploymentId: $recoveryDeploymentId,
        previousGoodGeneration: $previousGoodGeneration,
        failedGeneration: $failedGeneration,
        finalGeneration: $finalGeneration,
        healthStatus: "healthy",
        rollbackCompleted: true
      }' > "$state_file"
    jq -c -n \
      --arg target "$target" \
      --argjson deploymentId 45 \
      --argjson finalGeneration 100 \
      '{event: "break-glass-manifest-accepted", target: $target, deploymentId: $deploymentId}' >> "$events_file"
    jq -c -n \
      --arg target "$target" \
      --argjson finalGeneration 100 \
      '{event: "rollback-complete", target: $target, finalGeneration: $finalGeneration}' >> "$events_file"
    jq -n \
      --arg manifest "$manifest" \
      --arg target "$target" \
      --arg targetGroup "$target_group" \
      '{
        accepted: true,
        manifest: $manifest,
        target: $target,
        targetGroup: $targetGroup,
        rollback: {
          started: true,
          completed: true,
          finalGeneration: 100
        }
      }' > /tmp/mcl-rehearsal/break-glass-target-result.json
    echo "accepted break-glass signed manifest"
    exit 0
    ;;
  *)
    jq -n \
      --arg originalCommand "$original_command" \
      '{rejected: true, originalCommand: $originalCommand}' > /tmp/mcl-rehearsal/break-glass-target-result.json
    echo "rejected arbitrary command" >&2
    exit 126
    ;;
esac
SH
}

topology_inject_role_metadata() {
  local role="$1"
  local container
  container="$(topology_role_container "$role")"

  local metadata_file
  metadata_file="$topology_tmp_dir/${role}.runtime.json"
  jq \
    --arg roleName "$role" \
    --arg scenario "$scenario" \
    --arg prefix "$topology_safe_prefix" \
    --arg container "$container" \
    --arg artifactDir "$topology_artifact_dir" \
    --arg siteGroup "$topology_site_group" \
    '
      . as $topology
      | ($topology.roles[] | select(.name == $roleName)) as $role
      | {
          schemaVersion: 1,
          scenario: $scenario,
          prefix: $prefix,
          container: $container,
          artifactDir: $artifactDir,
          siteGroup: $siteGroup,
          role: $role,
          declaredNetworks: $role.networks,
          credentials: $topology.credentials,
          targetGroups: $topology.targetGroups,
          scenarioControls: ($topology.scenarios[] | select(.name == $scenario) | .controls)
        }
    ' "$topology_file" > "$metadata_file"

  "$cli" file push --create-dirs "$metadata_file" "${container}/etc/mcl-deployment-rehearsal/runtime.json"
  "$cli" file push --create-dirs "$topology_tmp_dir/container-assert.sh" "${container}/tmp/mcl-rehearsal/container-assert.sh"
  "$cli" file push --create-dirs "$topology_file" "${container}/tmp/mcl-rehearsal/topology.json"
  "$cli" file push --create-dirs "$topology_tmp_dir/scenario-driver.py" "${container}/tmp/mcl-rehearsal/scenario-driver.py"
  container_exec "$container" "chmod +x /tmp/mcl-rehearsal/container-assert.sh /tmp/mcl-rehearsal/scenario-driver.py && /tmp/mcl-rehearsal/container-assert.sh"
}

topology_assert_host_network_devices() {
  local role="$1"
  local container
  container="$(topology_role_container "$role")"

  local index=0 network device_config
  device_config="$("$cli" config device show "$container")"
  while IFS= read -r network; do
    grep -q "network: $(topology_network_resource_name "$network")" <<<"$device_config" || die "container $container missing Incus network device for $network"
    index=$((index + 1))
  done < <(topology_role_networks "$role")
}

topology_start_control_server() {
  local cache_container="$1"
  container_exec "$cache_container" "mkdir -p /tmp/mcl-rehearsal/control && cat > /tmp/mcl-rehearsal/control/control-message.json <<EOF
{\"from\":\"attic-cache\",\"scenario\":\"${scenario}\",\"message\":\"synthetic-control-ok\"}
EOF
if [[ -s /tmp/mcl-rehearsal/control-server.pid ]]; then
  kill \"\$(cat /tmp/mcl-rehearsal/control-server.pid)\" >/dev/null 2>&1 || true
fi
nohup python3 -m http.server 18080 --bind 0.0.0.0 --directory /tmp/mcl-rehearsal/control > /tmp/mcl-rehearsal/control-server.log 2>&1 &
echo \$! > /tmp/mcl-rehearsal/control-server.pid"
}

topology_assert_control_message() {
  local cache_ip="$1"
  local container="$2"
  container_exec "$container" "mkdir -p /tmp/mcl-rehearsal && for attempt in \$(seq 1 30); do curl -fsS --max-time 2 http://${cache_ip}:18080/control-message.json | jq -e --arg scenario '$scenario' '.from == \"attic-cache\" and .scenario == \$scenario and .message == \"synthetic-control-ok\"' > /tmp/mcl-rehearsal/control-message-${scenario}.json && exit 0; sleep 1; done; exit 1"
}

topology_partition_control_network() {
  local role="$1"
  local container
  container="$(topology_role_container "$role")"

  local index device
  index="$(topology_role_network_index "$role" control)"
  [[ -n "$index" ]] || die "role cannot be partitioned from control network: $role"
  device="eth${index}"
  "$cli" config device remove "$container" "$device"
  if "$cli" config device show "$container" | grep -q "network: $(topology_network_resource_name control)"; then
    die "control network still attached after partition for $container"
  fi
  "$cli" config device add "$container" "$device" nic \
    "network=$(topology_network_resource_name control)" \
    "name=$device" \
    < /dev/null
  topology_configure_role_addresses "$role"
  topology_wait_container_ipv4 "$container" "$device" >/dev/null
}

topology_exercise_cache_failure() {
  local runner_container="$1"
  local cache_container="$2"
  local cache_ip="$3"

  container_exec "$cache_container" "kill \"\$(cat /tmp/mcl-rehearsal/control-server.pid)\" >/dev/null 2>&1"
  set +e
  container_exec "$runner_container" "curl -fsS --max-time 2 http://${cache_ip}:18080/control-message.json >/tmp/mcl-rehearsal/cache-failure-unexpected.out 2>/tmp/mcl-rehearsal/cache-failure.err"
  local status=$?
  set -e
  [[ "$status" -ne 0 ]] || die "cache failure injection did not break the control/cache path"
  container_exec "$runner_container" "jq -n --argjson exitCode '$status' '{requestFailed: true, exitCode: \$exitCode}' > /tmp/mcl-rehearsal/cache-failure-status.json"
  topology_start_control_server "$cache_container"
}

topology_exercise_lock_contention() {
  local runner_container="$1"
  container_exec "$runner_container" "rm -rf /tmp/mcl-rehearsal/controller.lock && mkdir /tmp/mcl-rehearsal/controller.lock && set +e; mkdir /tmp/mcl-rehearsal/controller.lock 2>/tmp/mcl-rehearsal/lock-contention.err; status=\$?; set -e; test \"\$status\" -ne 0; echo lock-contention > /tmp/mcl-rehearsal/lock-contention.txt; jq -n --argjson exitCode \"\$status\" '{detected: true, exitCode: \$exitCode}' > /tmp/mcl-rehearsal/lock-contention-status.json"
}

topology_exercise_failure_matrix() {
  local runner_container="$1"
  local cache_container="$2"
  local cache_ip="$3"
  local target_role="$4"

  topology_partition_control_network "$target_role"
  topology_exercise_cache_failure "$runner_container" "$cache_container" "$cache_ip"
  topology_exercise_lock_contention "$runner_container"

  container_exec "$runner_container" "set -euo pipefail
cat > /tmp/mcl-rehearsal/invalid-manifest.json <<'EOF'
{\"deploymentId\":42,\"target\":\"${target_role}\",\"signature\":\"synthetic-invalid\"}
EOF
set +e
jq -e '.signature == \"synthetic-valid\"' /tmp/mcl-rehearsal/invalid-manifest.json >/tmp/mcl-rehearsal/invalid-signature.out 2>/tmp/mcl-rehearsal/invalid-signature.err
invalid_status=\$?
false >/tmp/mcl-rehearsal/switch-failure.out 2>/tmp/mcl-rehearsal/switch-failure.err
switch_status=\$?
false >/tmp/mcl-rehearsal/health-failure.out 2>/tmp/mcl-rehearsal/health-failure.err
health_status=\$?
python3 - <<'PY' >/tmp/mcl-rehearsal/stale-desired-state.out
current = 42
candidate = 41
raise SystemExit(0 if candidate < current else 1)
PY
stale_status=\$?
set -e
test \"\$invalid_status\" -ne 0
test \"\$switch_status\" -ne 0
test \"\$health_status\" -ne 0
test \"\$stale_status\" -eq 0
cat > /tmp/mcl-rehearsal/rollback.log <<'EOF'
rollback-started deployment=44
rollback-complete restored=43
EOF
jq -n \
  --arg target '${target_role}' \
  --slurpfile cache /tmp/mcl-rehearsal/cache-failure-status.json \
  --slurpfile lock /tmp/mcl-rehearsal/lock-contention-status.json \
  --argjson invalidExit \"\$invalid_status\" \
  --argjson switchExit \"\$switch_status\" \
  --argjson healthExit \"\$health_status\" \
  '{
    offlineTarget: {
      target: \$target,
      partitionedAndReconnected: true
    },
    missingCacheObject: {
      requestFailed: \$cache[0].requestFailed,
      exitCode: \$cache[0].exitCode
    },
    invalidSignature: {
      rejected: true,
      exitCode: \$invalidExit,
      artifact: \"/tmp/mcl-rehearsal/invalid-signature.err\"
    },
    switchFailure: {
      failed: true,
      exitCode: \$switchExit,
      artifact: \"/tmp/mcl-rehearsal/switch-failure.err\"
    },
    healthCheckFailure: {
      failed: true,
      exitCode: \$healthExit,
      artifact: \"/tmp/mcl-rehearsal/health-failure.err\"
    },
    rollback: {
      started: true,
      completed: true,
      restoredDeploymentId: 43,
      artifact: \"/tmp/mcl-rehearsal/rollback.log\"
    },
    staleDesiredState: {
      rejected: true,
      rejectedDeploymentId: 41,
      currentDeploymentId: 42,
      artifact: \"/tmp/mcl-rehearsal/stale-desired-state.out\"
    },
    lockContention: {
      detected: \$lock[0].detected,
      exitCode: \$lock[0].exitCode,
      artifact: \"/tmp/mcl-rehearsal/lock-contention.err\"
    }
  }' > /tmp/mcl-rehearsal/failure-evidence.json"
}

topology_exercise_offline_latest_only() {
  local runner_container="$1"
  local target_role="$2"

  topology_partition_control_network "$target_role"
  container_exec "$runner_container" "jq -n \
    --arg target '$target_role' \
    '{
      target: \$target,
      partitionedAndReconnected: true,
      desiredDeployments: [41, 42],
      skippedDeployments: [41],
      appliedDeployment: 42,
      latestOnly: true
    }' > /tmp/mcl-rehearsal/offline-latest-status.json"
}

topology_exercise_forced_command() {
  require_command ssh-keygen

  local runner_role runner_container target_role target_container target_ip
  runner_role="$(topology_role_by_kind orchestrator)"
  runner_container="$(topology_role_container "$runner_role")"
  target_role="$(topology_first_role_by_transport forced-command-ssh)"
  [[ -n "$target_role" ]] || die "no forced-command target role in topology"
  target_container="$(topology_role_container "$target_role")"
  target_ip="$(topology_wait_container_ipv4 "$target_container" eth0)"

  local key_path pub_key manifest_path
  key_path="$topology_tmp_dir/forced-command-key"
  ssh-keygen -q -t ed25519 -N "" -f "$key_path"
  pub_key="$(cat "${key_path}.pub")"
  manifest_path="$topology_tmp_dir/forced-command-manifest.json"
  jq -n \
    --arg target "$target_role" \
    --arg targetGroup "$(jq -r --arg name "$target_role" '.roles[] | select(.name == $name) | .targetGroup' "$topology_file")" \
    '{deploymentId: 42, target: $target, targetGroup: $targetGroup, signature: "synthetic-valid"}' > "$manifest_path"

  "$cli" file push --create-dirs "$topology_tmp_dir/forced-command-guard.sh" "${target_container}/tmp/mcl-rehearsal/forced-command-guard.sh"
  "$cli" file push --create-dirs "$manifest_path" "${target_container}/tmp/mcl-rehearsal/signed-manifest.json"
  container_exec "$target_container" "chmod +x /tmp/mcl-rehearsal/forced-command-guard.sh && mkdir -p /root/.ssh /run/sshd /tmp/mcl-rehearsal/sshd && printf '%s %s\n' 'command=\"/tmp/mcl-rehearsal/forced-command-guard.sh\",restrict' '$pub_key' > /root/.ssh/authorized_keys && chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys && ssh-keygen -A && cat > /tmp/mcl-rehearsal/sshd/sshd_config <<'EOF'
Port 2222
ListenAddress 0.0.0.0
HostKey /etc/ssh/ssh_host_ed25519_key
AuthorizedKeysFile /root/.ssh/authorized_keys
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
PidFile /tmp/mcl-rehearsal/sshd/sshd.pid
Subsystem sftp internal-sftp
EOF
if [[ -s /tmp/mcl-rehearsal/sshd/sshd.pid ]]; then
  kill \"\$(cat /tmp/mcl-rehearsal/sshd/sshd.pid)\" >/dev/null 2>&1 || true
fi
nohup /run/current-system/sw/bin/sshd -D -e -f /tmp/mcl-rehearsal/sshd/sshd_config > /tmp/mcl-rehearsal/sshd/sshd.log 2>&1 &
echo \$! > /tmp/mcl-rehearsal/sshd/sshd.pid"

  "$cli" file push --create-dirs "$key_path" "${runner_container}/tmp/mcl-rehearsal/forced-command-key"
  container_exec "$runner_container" "chmod 600 /tmp/mcl-rehearsal/forced-command-key"

  local arbitrary_status submit_status
  container_exec "$runner_container" "for attempt in \$(seq 1 30); do timeout 1 bash -c 'cat < /dev/null > /dev/tcp/${target_ip}/2222' >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1"

  set +e
  container_exec "$runner_container" "ssh -p 2222 -i /tmp/mcl-rehearsal/forced-command-key -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${target_ip} 'sh -c id' >/tmp/mcl-rehearsal/forced-command-arbitrary.out 2>/tmp/mcl-rehearsal/forced-command-arbitrary.err"
  arbitrary_status=$?
  set -e
  [[ "$arbitrary_status" -eq 126 ]] || die "forced-command arbitrary shell was not rejected; exit=$arbitrary_status"
  "$cli" file pull "${target_container}/tmp/mcl-rehearsal/forced-command-target-result.json" "$topology_tmp_dir/forced-command-arbitrary-target-result.json" >/dev/null

  container_exec "$runner_container" "ssh -p 2222 -i /tmp/mcl-rehearsal/forced-command-key -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${target_ip} 'deploy-submit /tmp/mcl-rehearsal/signed-manifest.json' >/tmp/mcl-rehearsal/forced-command-submit.out 2>/tmp/mcl-rehearsal/forced-command-submit.err"
  submit_status=$?
  [[ "$submit_status" -eq 0 ]] || die "forced-command signed manifest was not accepted; exit=$submit_status"
  "$cli" file pull "${target_container}/tmp/mcl-rehearsal/forced-command-target-result.json" "$topology_tmp_dir/forced-command-submit-target-result.json" >/dev/null

  jq -n \
    --arg target "$target_role" \
    --argjson arbitraryStatus "$arbitrary_status" \
    --argjson submitStatus "$submit_status" \
    --slurpfile arbitraryTarget "$topology_tmp_dir/forced-command-arbitrary-target-result.json" \
    --slurpfile submitTarget "$topology_tmp_dir/forced-command-submit-target-result.json" \
    '{
      target: $target,
      arbitraryShellRejected: true,
      arbitraryShellExitCode: $arbitraryStatus,
      arbitraryShellTargetResult: $arbitraryTarget[0],
      signedManifestAccepted: true,
      signedManifestExitCode: $submitStatus,
      signedManifestTargetResult: $submitTarget[0]
    }' > "$topology_tmp_dir/forced-command-evidence.json"
  "$cli" file push --create-dirs "$topology_tmp_dir/forced-command-evidence.json" "${runner_container}/tmp/mcl-rehearsal/forced-command-evidence.json"
}

topology_exercise_break_glass() {
  require_command ssh-keygen

  local runner_role runner_container target_role target_container target_ip
  runner_role="$(topology_role_by_kind orchestrator)"
  runner_container="$(topology_role_container "$runner_role")"
  target_role="$(topology_first_role_by_transport forced-command-ssh)"
  [[ -n "$target_role" ]] || die "no forced-command target role in topology"
  target_container="$(topology_role_container "$target_role")"
  target_ip="$(topology_wait_container_ipv4 "$target_container" eth0)"

  local key_path pub_key manifest_path target_group
  key_path="$topology_tmp_dir/break-glass-key"
  ssh-keygen -q -t ed25519 -N "" -f "$key_path"
  pub_key="$(cat "${key_path}.pub")"
  target_group="$(jq -r --arg name "$target_role" '.roles[] | select(.name == $name) | .targetGroup' "$topology_file")"
  manifest_path="$topology_tmp_dir/break-glass-manifest.json"
  jq -n \
    --arg target "$target_role" \
    --arg targetGroup "$target_group" \
    '{
      deploymentId: 45,
      failedDeploymentId: 44,
      target: $target,
      targetGroup: $targetGroup,
      signature: "synthetic-valid",
      breakGlass: true,
      action: "rollback",
      rollbackToGeneration: 100,
      reason: "synthetic failed deploy recovery rehearsal"
    }' > "$manifest_path"

  "$cli" file push --create-dirs "$topology_tmp_dir/break-glass-guard.sh" "${target_container}/tmp/mcl-rehearsal/break-glass-guard.sh"
  "$cli" file push --create-dirs "$manifest_path" "${target_container}/tmp/mcl-rehearsal/break-glass-manifest.json"
  container_exec "$target_container" "chmod +x /tmp/mcl-rehearsal/break-glass-guard.sh && mkdir -p /root/.ssh /run/sshd /tmp/mcl-rehearsal/sshd && jq -c -n --arg target '$target_role' --arg targetGroup '$target_group' '{target: \$target, targetGroup: \$targetGroup}' > /tmp/mcl-rehearsal/break-glass-policy.json && jq -c -n --arg target '$target_role' --arg targetGroup '$target_group' '{target: \$target, targetGroup: \$targetGroup, failedDeploymentId: 44, previousGoodGeneration: 100, failedGeneration: 101, currentGeneration: 101, healthStatus: \"failed\"}' > /tmp/mcl-rehearsal/break-glass-generation-state.json && jq -c -n --arg target '$target_role' '{event: \"failed-deploy-detected\", target: \$target, deploymentId: 44, failedGeneration: 101}' > /tmp/mcl-rehearsal/break-glass-events.jsonl && printf '%s %s\n' 'command=\"/tmp/mcl-rehearsal/break-glass-guard.sh\",restrict' '$pub_key' > /root/.ssh/authorized_keys && chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys && ssh-keygen -A && cat > /tmp/mcl-rehearsal/sshd/sshd_config <<'EOF'
Port 2222
ListenAddress 0.0.0.0
HostKey /etc/ssh/ssh_host_ed25519_key
AuthorizedKeysFile /root/.ssh/authorized_keys
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
PidFile /tmp/mcl-rehearsal/sshd/sshd.pid
Subsystem sftp internal-sftp
EOF
if [[ -s /tmp/mcl-rehearsal/sshd/sshd.pid ]]; then
  kill \"\$(cat /tmp/mcl-rehearsal/sshd/sshd.pid)\" >/dev/null 2>&1 || true
fi
nohup /run/current-system/sw/bin/sshd -D -e -f /tmp/mcl-rehearsal/sshd/sshd_config > /tmp/mcl-rehearsal/sshd/sshd.log 2>&1 &
echo \$! > /tmp/mcl-rehearsal/sshd/sshd.pid"

  "$cli" file push --create-dirs "$key_path" "${runner_container}/tmp/mcl-rehearsal/break-glass-key"
  container_exec "$runner_container" "chmod 600 /tmp/mcl-rehearsal/break-glass-key"
  container_exec "$runner_container" "for attempt in \$(seq 1 30); do timeout 1 bash -c 'cat < /dev/null > /dev/tcp/${target_ip}/2222' >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1"

  local arbitrary_status submit_status
  set +e
  container_exec "$runner_container" "ssh -p 2222 -i /tmp/mcl-rehearsal/break-glass-key -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${target_ip} 'sh -c id' >/tmp/mcl-rehearsal/break-glass-arbitrary.out 2>/tmp/mcl-rehearsal/break-glass-arbitrary.err"
  arbitrary_status=$?
  set -e
  [[ "$arbitrary_status" -eq 126 ]] || die "break-glass arbitrary shell was not rejected; exit=$arbitrary_status"
  "$cli" file pull "${target_container}/tmp/mcl-rehearsal/break-glass-target-result.json" "$topology_tmp_dir/break-glass-arbitrary-target-result.json" >/dev/null

  container_exec "$runner_container" "ssh -p 2222 -i /tmp/mcl-rehearsal/break-glass-key -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${target_ip} 'break-glass-apply /tmp/mcl-rehearsal/break-glass-manifest.json' >/tmp/mcl-rehearsal/break-glass-submit.out 2>/tmp/mcl-rehearsal/break-glass-submit.err"
  submit_status=$?
  [[ "$submit_status" -eq 0 ]] || die "break-glass signed manifest was not accepted; exit=$submit_status"
  "$cli" file pull "${target_container}/tmp/mcl-rehearsal/break-glass-target-result.json" "$topology_tmp_dir/break-glass-submit-target-result.json" >/dev/null
  "$cli" file pull "${target_container}/tmp/mcl-rehearsal/break-glass-generation-state.json" "$topology_tmp_dir/break-glass-generation-state.json" >/dev/null
  "$cli" file pull "${target_container}/tmp/mcl-rehearsal/break-glass-events.jsonl" "$topology_tmp_dir/break-glass-events.jsonl" >/dev/null

  jq -n \
    --arg target "$target_role" \
    --argjson arbitraryStatus "$arbitrary_status" \
    --argjson submitStatus "$submit_status" \
    --slurpfile arbitraryTarget "$topology_tmp_dir/break-glass-arbitrary-target-result.json" \
    --slurpfile submitTarget "$topology_tmp_dir/break-glass-submit-target-result.json" \
    --slurpfile state "$topology_tmp_dir/break-glass-generation-state.json" \
    '{
      target: $target,
      failedDeployDetected: true,
      failedDeploymentId: 44,
      failedGeneration: 101,
      recoveryDeploymentId: 45,
      rollbackToGeneration: 100,
      finalGeneration: $state[0].finalGeneration,
      arbitraryShellRejected: true,
      arbitraryShellExitCode: $arbitraryStatus,
      arbitraryShellTargetResult: $arbitraryTarget[0],
      signedManifestAccepted: true,
      signedManifestExitCode: $submitStatus,
      recoveryManifestTargetResult: $submitTarget[0],
      rollback: $submitTarget[0].rollback,
      targetGenerationState: $state[0]
    }' > "$topology_tmp_dir/break-glass-evidence.json"

  local artifact
  for artifact in break-glass-evidence.json break-glass-generation-state.json break-glass-events.jsonl break-glass-arbitrary-target-result.json break-glass-submit-target-result.json; do
    "$cli" file push --create-dirs "$topology_tmp_dir/$artifact" "${runner_container}/tmp/mcl-rehearsal/$artifact"
  done
}

topology_exercise_pull_agent() {
  local runner_role runner_container target_role target_container
  runner_role="$(topology_role_by_kind orchestrator)"
  runner_container="$(topology_role_container "$runner_role")"
  target_role="$(topology_first_role_by_transport pull-agent)"
  [[ -n "$target_role" ]] || die "no pull-agent target role in topology"
  target_container="$(topology_role_container "$target_role")"

  topology_partition_control_network "$target_role"

  local desired_dir
  desired_dir="$topology_tmp_dir/pull-agent-desired"
  mkdir -p "$desired_dir"
  jq -n --arg target "$target_role" '{deploymentId: 41, target: $target, signature: "synthetic-valid"}' > "$desired_dir/41.json"
  jq -n --arg target "$target_role" '{deploymentId: 42, target: $target, signature: "synthetic-valid"}' > "$desired_dir/42.json"

  container_exec "$target_container" "mkdir -p /tmp/mcl-rehearsal/desired"
  local manifest
  for manifest in "$desired_dir"/*.json; do
    "$cli" file push --create-dirs "$manifest" "${target_container}/tmp/mcl-rehearsal/desired/$(basename "$manifest")"
  done
  "$cli" file push --create-dirs "$topology_tmp_dir/pull-agent-sim.py" "${target_container}/tmp/mcl-rehearsal/pull-agent-sim.py"
  container_exec "$target_container" "chmod +x /tmp/mcl-rehearsal/pull-agent-sim.py && /tmp/mcl-rehearsal/pull-agent-sim.py '$target_role' /tmp/mcl-rehearsal/desired /tmp/mcl-rehearsal/pull-agent-status.json"
  "$cli" file pull "${target_container}/tmp/mcl-rehearsal/pull-agent-status.json" "$topology_tmp_dir/pull-agent-status.json"
  "$cli" file push --create-dirs "$topology_tmp_dir/pull-agent-status.json" "${runner_container}/tmp/mcl-rehearsal/pull-agent-status.json"
}

topology_run_scenario_driver() {
  local runner_role runner_container
  runner_role="$(topology_role_by_kind orchestrator)"
  runner_container="$(topology_role_container "$runner_role")"
  container_exec "$runner_container" "site_group=\$(jq -r '.siteGroup // empty' /etc/mcl-deployment-rehearsal/runtime.json); test -n \"\$site_group\"; python3 /tmp/mcl-rehearsal/scenario-driver.py '$scenario' /tmp/mcl-rehearsal/topology.json /tmp/mcl-rehearsal \"\$site_group\""
}

topology_capture_artifacts() {
  local runner_role runner_container role container safe_role
  runner_role="$(topology_role_by_kind orchestrator)"
  runner_container="$(topology_role_container "$runner_role")"

  "$cli" file pull "${runner_container}/tmp/mcl-rehearsal/events.jsonl" "$topology_artifact_dir/events.jsonl" >/dev/null 2>&1 || true
  "$cli" file pull "${runner_container}/tmp/mcl-rehearsal/final-state.json" "$topology_artifact_dir/final-state.json" >/dev/null 2>&1 || true
  "$cli" file pull "${runner_container}/tmp/mcl-rehearsal/runtime-commands.log" "$topology_artifact_dir/runtime-commands.log" >/dev/null 2>&1 || true
  local scenario_artifact
  for scenario_artifact in failure-evidence.json offline-latest-status.json forced-command-evidence.json break-glass-evidence.json break-glass-generation-state.json break-glass-events.jsonl break-glass-arbitrary-target-result.json break-glass-submit-target-result.json pull-agent-status.json; do
    "$cli" file pull "${runner_container}/tmp/mcl-rehearsal/${scenario_artifact}" "$topology_artifact_dir/${scenario_artifact}" >/dev/null 2>&1 || true
  done

  local resources_file first network
  resources_file="$topology_tmp_dir/runtime-resources.json"
  {
    echo '{'
    echo '  "networks": ['
    first=1
    while IFS= read -r network; do
      if (( first == 0 )); then
        echo ','
      fi
      first=0
      jq -n --arg name "$network" --arg resourceName "$(topology_network_resource_name "$network")" \
        '{name: $name, resourceName: $resourceName}'
    done < <(topology_network_names)
    echo
    echo '  ],'
    echo '  "containers": ['
    first=1
    while IFS= read -r role; do
      if (( first == 0 )); then
        echo ','
      fi
      first=0
      jq -n --arg role "$role" --arg containerName "$(topology_role_container "$role")" \
        '{role: $role, containerName: $containerName}'
    done < <(topology_role_names)
    echo
    echo '  ]'
    echo '}'
  } > "$resources_file"

  jq \
    --arg scenario "$scenario" \
    --arg prefix "$topology_safe_prefix" \
    --arg artifactDir "$topology_artifact_dir" \
    --slurpfile resources "$resources_file" \
    '{scenario: $scenario, prefix: $prefix, artifactDir: $artifactDir, runtimeResources: $resources[0], networks, roles, targetGroups, scenarios}' \
    "$topology_file" > "$topology_artifact_dir/topology-summary.json"

  while IFS= read -r role; do
    container="$(topology_role_container "$role")"
    safe_role="$(sanitize_resource_name "$role")"
    "$cli" file pull "${container}/tmp/mcl-rehearsal/assertions.json" "$topology_artifact_dir/containers/${safe_role}.assertions.json" >/dev/null 2>&1 || true
    "$cli" list "$container" --format json > "$topology_artifact_dir/containers/${safe_role}.incus-state.json" 2>/dev/null || true
    "$cli" config device show "$container" > "$topology_artifact_dir/containers/${safe_role}.devices.yaml" 2>/dev/null || true
    container_exec "$container" "journalctl --no-pager -n 80 || true" > "$topology_artifact_dir/logs/${safe_role}.journal.log" 2>&1 || true
  done < <(topology_role_names)

  if [[ -f "$topology_artifact_dir/runtime-commands.log" ]] && grep -qi '^cachix deploy' "$topology_artifact_dir/runtime-commands.log"; then
    die "runtime artifacts show Cachix Deploy production command usage"
  fi
}

run_topology() {
  check_env
  check_runtime
  topology_init_runtime_names
  trap topology_cleanup EXIT
  topology_reset_prefixed_resources
  topology_write_runtime_scripts
  topology_build_import_image
  topology_create_networks

  local role
  while IFS= read -r role; do
    topology_launch_role "$role"
  done < <(topology_role_names)

  while IFS= read -r role; do
    topology_wait_container_ready "$(topology_role_container "$role")"
    topology_configure_role_addresses "$role"
    topology_inject_role_metadata "$role"
    topology_assert_host_network_devices "$role"
  done < <(topology_role_names)

  local runner_role cache_role monitoring_role target_role runner_container cache_container monitoring_container target_container cache_ip
  runner_role="$(topology_role_by_kind orchestrator)"
  cache_role="$(topology_role_by_kind attic-cache)"
  monitoring_role="$(topology_role_by_kind monitoring)"
  target_role="$(topology_first_target_role)"
  [[ -n "$runner_role" && -n "$cache_role" && -n "$monitoring_role" && -n "$target_role" ]] || die "topology is missing orchestrator/cache/monitoring/target roles"

  runner_container="$(topology_role_container "$runner_role")"
  cache_container="$(topology_role_container "$cache_role")"
  monitoring_container="$(topology_role_container "$monitoring_role")"
  target_container="$(topology_role_container "$target_role")"

  topology_start_control_server "$cache_container"
  cache_ip="$(topology_wait_container_ipv4 "$cache_container" eth0)"
  topology_assert_control_message "$cache_ip" "$runner_container"
  topology_assert_control_message "$cache_ip" "$monitoring_container"
  topology_assert_control_message "$cache_ip" "$target_container"

  case "$scenario" in
    full-topology)
      ;;
    full-topology-failures)
      topology_exercise_failure_matrix "$runner_container" "$cache_container" "$cache_ip" "$target_role"
      ;;
    offline-latest-only)
      topology_exercise_offline_latest_only "$runner_container" "$target_role"
      ;;
    forced-command)
      topology_exercise_forced_command
      ;;
    break-glass)
      topology_exercise_break_glass
      ;;
    pull-agent)
      topology_exercise_pull_agent
      ;;
  esac

  topology_run_scenario_driver
  topology_capture_artifacts

  echo "deployment-incus-rehearsal: topology runtime passed: $scenario"
  echo "deployment-incus-rehearsal: artifacts: $topology_artifact_dir"
}

case "$scenario" in
  --help | -h | "")
    usage
    [[ "$scenario" == "" ]] && exit 64 || exit 0
    ;;
esac

case "$mode" in
  --check-env)
    check_env
    ;;
  --check-runtime)
    check_runtime
    ;;
  --dry-run)
    if [[ "$scenario" == "attic-cache" ]]; then
      dry_run_attic_cache
    elif is_topology_scenario; then
      dry_run_topology
    else
      usage
      exit 64
    fi
    ;;
  run)
    if [[ "$scenario" == "attic-cache" ]]; then
      run_attic_cache
    elif is_topology_scenario; then
      run_topology
    else
      usage
      exit 64
    fi
    ;;
  *)
    usage
    exit 64
    ;;
esac
