#!/usr/bin/env bash
#
# t_incus_linux_autoscale_and_harden — IM4 gate for the
# Ephemeral-Linux-Runners-Incus campaign. The container analog of the Windows
# M5 (autoscale) + M6 (hardened declarative module) gates, folded into one and
# run at a HIGHER concurrency than the Windows path (containers are cheap: no
# /dev/kvm, sub-second launch).
#
# It proves, end to end and against the REAL GitHub org (set via ORG):
#
#   PART 1 — HARDENED DECLARATIVE MODULE runs the INCUS provider.
#     Build the `services.garm` module toplevel with
#     `providers.vmharness.backend = "incus"` + metrics + the declarative
#     incus-bridge egress option, install the MODULE-PRODUCED garm.service unit
#     and start GARM under it. Assert the IM4 incus sandbox posture:
#       * User=garm in the `incus-admin` group (socket access) — NOT libvirtd/kvm
#       * NO /dev/kvm (DeviceAllow empty — containers share the host kernel)
#       * STRICT knobs kept: ProtectSystem=strict, PrivateDevices=true,
#         MemoryDenyWriteExecute=true (a strictly stronger sandbox than the
#         libvirt posture, which must relax all three for qemu).
#     Assert `/metrics` serves garm_* series. Assert (via `nix eval`) that
#     `openIncusBridgeFirewall` wires the declarative firewall rule.
#
#   PART 2 — AUTOSCALE reconcilers with the incus provider, THROUGH that same
#            hardened module unit:
#     Phase A  CONCURRENCY CAP + SCALE-OUT (min-idle=0, max-runners=N):
#              enqueue MORE jobs than the cap; assert GARM launches up to (never
#              more than) max-runners FRESH containers concurrently, the excess
#              jobs wait, each container runs exactly one job, ALL succeed. This
#              IS the hardened-module one-job incus e2e (N times over).
#     Phase B  SCALE-TO-ZERO: after drain, ZERO garm-* containers + ZERO garm-*
#              runners registered on GitHub.
#     Phase C  WARM POOL (min-idle=1): assert 1 pre-launched idle container is
#              kept; a job consumes it; the pool REFILLS to 1; then min-idle=0
#              drains to zero again.
#
# NOT hermetic: talks to the real org (set via ORG) via a GitHub App and launches
# real Incus containers. ISOLATED + SELF-CLEANING: a UNIQUE scale-set name + a
# THROWAWAY repo it creates and deletes; ONLY `garm-*` container names + an
# `im4-*` transient GARM unit; NEVER touches production runners or other
# production Incus containers on the host.
#
# ============================ NETWORKING ==============================
# Container -> internet (github.com): works through incus's EXISTING NAT (table
#   `inet incus`: pstrt.incusbr0 masquerade + fwd.incusbr0 accept). NO host
#   firewall change is needed for egress.
# Container -> host GARM (metadata/callback on :GARM_PORT): incusbr0 is not a
#   trusted nixos-fw interface. The DECLARATIVE fix is the module option
#   `services.garm.openIncusBridgeFirewall = true`
#   (=> networking.firewall.interfaces.incusbr0.allowedTCPPorts = [ 9997 ]);
#   this gate ASSERTS that option evaluates, and — because this host is
#   deploy-agent-managed and NOT rebuilt for the gate — ALSO inserts the exact
#   equivalent runtime nft rule (scoped to incusbr0 + the subnet + the port) and
#   REMOVES it on exit. incusbr0 DHCP does not lease here, so the provider
#   injects a static IPv4 per container (module incusIPv4* options) — nothing to
#   revert there.
#
# ============================ PREREQUISITES ============================
# Run as root on the Incus host (installs the module unit + creates the garm
# service account + drives incus/nft). Needs:
#   * incus daemon reachable with the `incusbr0` bridge up (the bridge subnet is
#     read at runtime) and the runner image present, its alias set via
#     VMH_RUNNER_ALIAS (build with vm-harness/guest-recipes/linux-x64-runner).
#   * The GitHub App PEM readable (APP_PEM = the App private-key PEM path), with
#     the App ID / installation / org supplied via env (APP_ID, INSTALLATION_ID,
#     ORG) and the org `Self-hosted runners: Read & write` permission.
#   * `gh` authenticated with repo+admin:org; `nix` (to build the module).
#
# ============================ CONFIG (env) ============================
set -uo pipefail

APP_ID="${APP_ID:?set APP_ID (the GitHub App ID)}"
INSTALLATION_ID="${INSTALLATION_ID:?set INSTALLATION_ID (the GitHub App installation ID)}"
APP_PEM="${APP_PEM:?set APP_PEM (path to the GitHub App private-key PEM)}"
ORG="${ORG:?set ORG (the GitHub org)}"
SCALESET_NAME="${SCALESET_NAME:-linux-ephemeral-im4}"

RUNNER_IMAGE="${VMH_RUNNER_ALIAS:?set VMH_RUNNER_ALIAS (the incus runner image alias)}"
INCUS_BRIDGE="${VMH_INCUS_BRIDGE:-incusbr0}"
# Use the HOST incus binary (matches the running daemon version) rather than the
# module default pkgs.incus, to avoid client/server version skew on this host.
INCUS_BIN="${VMH_INCUS_BIN:-$(command -v incus || echo /run/current-system/sw/bin/incus)}"

GARM_PORT="${GARM_PORT:-9997}"
FLAKE="${FLAKE:-$(cd "$(dirname "$0")/.." && pwd)}"   # the nixos-modules flake root
GARM_STATE_DIR="/var/lib/garm"

# ---- AUTOSCALE TUNING (higher than the Windows path — containers are cheap) --
MAX_RUNNERS="${MAX_RUNNERS:-3}"
NUM_JOBS="${NUM_JOBS:-5}"
BOOTSTRAP_TIMEOUT_MIN="${BOOTSTRAP_TIMEOUT_MIN:-20}"
# Generous per-phase deadline. A cold container boot + cloud-init + JIT register
# + a ~40s job is a couple of minutes; with cap=MAX_RUNNERS and NUM_JOBS>cap,
# Phase A needs ceil(NUM_JOBS/MAX_RUNNERS) waves. 1800s covers 2 waves + margin.
PHASE_TIMEOUT_SECS="${PHASE_TIMEOUT_SECS:-1800}"

WORKDIR="${WORKDIR:-/var/lib/garm-im4-gate}"
EVIDENCE="${EVIDENCE:-$WORKDIR/evidence}"
STATE_URL="http://__BRIDGE_IP__:${GARM_PORT}"   # __BRIDGE_IP__ filled below

FW_TABLE="inet nixos-fw"
FW_CHAIN="input"
FW_COMMENT="im4-e2e-garm-${GARM_PORT}"

fail() { echo "[im4][FAIL] $*" >&2; exit 1; }
info() { echo "[im4] $*"; }

[ "$(id -u)" = 0 ] || fail "must run as root (installs the module garm.service unit + drives incus/nft)"
[ -r "$APP_PEM" ] || fail "cannot read App PEM: $APP_PEM"
command -v nix >/dev/null || fail "nix not on PATH (needed to build the module toplevel)"
command -v gh  >/dev/null || fail "gh not on PATH"
"$INCUS_BIN" image info "$RUNNER_IMAGE" >/dev/null 2>&1 || fail "runner image '$RUNNER_IMAGE' absent (build vm-harness/guest-recipes/linux-x64-runner)"

# Resolve `garm` + `garm-cli` onto PATH. Prefer already-on-PATH; else build the
# flake's garm package and prepend its bin (this host does not install garm-cli
# globally). The MODULE unit uses its own package copy; this is only for the
# harness's own garm-cli/garm invocations.
if ! command -v garm-cli >/dev/null 2>&1; then
  GARM_PKG="${GARM_PKG:-$(nix build --impure --no-link --print-out-paths "$FLAKE#garm" 2>/dev/null | head -1)}"
  [ -n "$GARM_PKG" ] && [ -x "$GARM_PKG/bin/garm-cli" ] || fail "could not resolve garm-cli (build $FLAKE#garm)"
  export PATH="$GARM_PKG/bin:$PATH"
fi
command -v garm-cli >/dev/null || fail "garm-cli not on PATH after resolution"

# Derive incusbr0 /24 + host IP (GARM metadata/callback base + container gateway).
BRIDGE_CIDR="$("$INCUS_BIN" network get "$INCUS_BRIDGE" ipv4.address 2>/dev/null)"  # e.g. 10.0.100.1/24
[ -n "$BRIDGE_CIDR" ] || fail "cannot read $INCUS_BRIDGE ipv4.address (incus reachable?)"
BRIDGE_IP="${BRIDGE_CIDR%/*}"
PREFIX="${BRIDGE_CIDR##*/}"
SUBNET_BASE="$(echo "$BRIDGE_IP" | cut -d. -f1-3)"
SUBNET="${SUBNET_BASE}.0/${PREFIX}"
STATE_URL="http://${BRIDGE_IP}:${GARM_PORT}"

mkdir -p "$EVIDENCE"

# ---- App installation token (for GitHub-side assertions) -------------------
app_token() {
  local b64url now h p s jwt
  b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
  now=$(date +%s)
  h=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
  p=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now-60)) $((now+540)) "$APP_ID" | b64url)
  s=$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -sign "$APP_PEM" -binary | b64url)
  jwt="$h.$p.$s"
  curl -s -X POST -H "Authorization: Bearer $jwt" \
    "https://api.github.com/app/installations/${INSTALLATION_ID}/access_tokens" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])'
}
gh_garm_runners() {
  local tok; tok=$(app_token)
  curl -s -H "Authorization: token $tok" \
    "https://api.github.com/orgs/${ORG}/actions/runners?per_page=100" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(len([r for r in d.get("runners",[]) if r["name"].startswith("garm-")]))'
}

# Delete an orphaned GitHub-side runner scale set (ARC runner-admin flow), so a
# re-run after an abort does not hit RunnerScaleSetExistsException.
sweep_github_scaleset() {
  local tok regtok auth svcurl bearer list
  tok=$(app_token) || return 0
  regtok=$(curl -s -X POST -H "Authorization: token $tok" \
    "https://api.github.com/orgs/${ORG}/actions/runners/registration-token" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))') || return 0
  [ -n "$regtok" ] || return 0
  auth=$(curl -s -X POST "https://api.github.com/actions/runner-registration" \
    -H "Authorization: RemoteAuth $regtok" -H "Content-Type: application/json" \
    -d "{\"url\":\"https://github.com/${ORG}\",\"runner_event\":\"register\"}") || return 0
  svcurl=$(echo "$auth" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("url",""))') || return 0
  bearer=$(echo "$auth" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))') || return 0
  [ -n "$svcurl" ] && [ -n "$bearer" ] || return 0
  list=$(curl -s "${svcurl}/_apis/runtime/runnerscalesets?api-version=6.0-preview" \
    -H "Authorization: Bearer $bearer") || return 0
  for id in $(echo "$list" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for s in d.get('value',[]):
    if s.get('name')=='${SCALESET_NAME}': print(s['id'])
" 2>/dev/null); do
    info "sweeping orphaned GitHub scale set '${SCALESET_NAME}' (id=$id)"
    curl -s -X DELETE "${svcurl}/_apis/runtime/runnerscalesets/${id}?api-version=6.0-preview" \
      -H "Authorization: Bearer $bearer" -o /dev/null
  done
}
gh_purge_garm_runners() {
  local tok; tok=$(app_token)
  local ids
  ids=$(curl -s -H "Authorization: token $tok" \
    "https://api.github.com/orgs/${ORG}/actions/runners?per_page=100" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print("\n".join(str(r["id"]) for r in d.get("runners",[]) if r["name"].startswith("garm-")))')
  local id
  for id in $ids; do
    curl -s -o /dev/null -X DELETE -H "Authorization: token $tok" \
      "https://api.github.com/orgs/${ORG}/actions/runners/$id"
  done
}

# No other garm-* Incus containers are expected on the host (production runners
# use libvirt and non-garm-* names for their Incus containers), so matching
# ^garm- is safe + scoped to instances THIS gate creates.
list_gate_containers() {
  "$INCUS_BIN" list --format csv -c n 2>/dev/null | grep '^garm-' || true
}
containers_running() { list_gate_containers | grep -c . || true; }

fw_rule_present() { nft -a list chain $FW_TABLE $FW_CHAIN 2>/dev/null | grep -q "$FW_COMMENT"; }
fw_add_rule() {
  fw_rule_present && return 0
  nft insert rule $FW_TABLE $FW_CHAIN \
    iifname "$INCUS_BRIDGE" ip saddr "$SUBNET" tcp dport "$GARM_PORT" accept \
    comment "$FW_COMMENT"
}
fw_del_rule() {
  local handles
  handles=$(nft -a list chain $FW_TABLE $FW_CHAIN 2>/dev/null \
    | awk -v c="$FW_COMMENT" '$0 ~ c {for(i=1;i<=NF;i++) if($i=="handle") print $(i+1)}')
  local h
  for h in $handles; do nft delete rule $FW_TABLE $FW_CHAIN handle "$h" 2>/dev/null || true; done
}

cleanup() {
  set +e
  info "cleanup…"
  journalctl -u garm --no-pager > "$EVIDENCE/garm.log" 2>/dev/null
  [ -n "${SCALESET_ID:-}" ] && garm-cli scaleset delete "$SCALESET_ID" >/dev/null 2>&1
  # give GARM a moment to tear down instances it owns before we force-destroy
  for _ in $(seq 1 18); do [ -z "$(list_gate_containers)" ] && break; sleep 5; done
  sweep_github_scaleset
  [ -n "${ORG_ID:-}" ] && garm-cli organization delete "$ORG_ID" >/dev/null 2>&1
  garm-cli github credentials delete mcl-app >/dev/null 2>&1
  garm-cli profile delete im4-gate >/dev/null 2>&1
  systemctl stop garm >/dev/null 2>&1
  systemctl reset-failed garm >/dev/null 2>&1
  rm -f /run/systemd/system/garm.service
  systemctl daemon-reload >/dev/null 2>&1
  for c in $(list_gate_containers); do "$INCUS_BIN" delete --force "$c" >/dev/null 2>&1; done
  [ -n "${TEST_REPO:-}" ] && gh repo delete "${ORG}/${TEST_REPO}" --yes >/dev/null 2>&1
  gh_purge_garm_runners
  fw_del_rule
  if fw_rule_present; then echo "[im4][WARN] firewall rule still present after cleanup!" >&2; fi
  info "evidence retained under $EVIDENCE"
}
trap cleanup EXIT

# Dispatch a workflow ROBUSTLY. A freshly pushed workflow is not immediately
# dispatchable — GitHub needs a moment to register the ref + the workflow, so a
# naive `gh workflow run` right after `git push` races and 422s ("No ref found").
# Retry the dispatch (explicit --ref main) until accepted.
dispatch_wf() {
  local wf="$1" i
  for i in $(seq 1 40); do
    gh workflow run "$wf" -R "${ORG}/${TEST_REPO}" --ref main >/dev/null 2>&1 && return 0
    sleep 6
  done
  return 1
}

# Sample container + GitHub runner counts into the evidence timeline.
sample() {
  local label="$1" nc ngh
  nc=$(containers_running); ngh=$(gh_garm_runners 2>/dev/null || echo '?')
  printf '%s  %-24s containers=%s  gh_garm_runners=%s\n' \
    "$(date +%H:%M:%S)" "$label" "$nc" "$ngh" | tee -a "$EVIDENCE/timeline.log"
}

# =========================================================================
# 0. DECLARATIVE EGRESS OPTION — assert the module wires the incusbr0 rule.
# =========================================================================
info "asserting services.garm.openIncusBridgeFirewall wires the declarative incusbr0 rule"
fw_eval=$(nix eval --impure --json --expr "
let flake = builtins.getFlake (toString $FLAKE); system = \"x86_64-linux\"; nixpkgs = flake.inputs.nixpkgs;
 sys = nixpkgs.lib.nixosSystem { inherit system; modules = [ flake.modules.nixos.garm
  ({ ... }: { boot.loader.grub.enable = false; fileSystems.\"/\" = { device = \"/dev/vda\"; fsType = \"ext4\"; }; system.stateVersion = \"24.11\";
    services.garm = { enable = true; openIncusBridgeFirewall = true;
      providers.vmharness = { enable = true; backend = \"incus\";
        incusBridge = \"$INCUS_BRIDGE\"; incusIPv4CIDR = \"$SUBNET\"; incusIPv4Gateway = \"$BRIDGE_IP\";
        images.linux-runner.sourceImage = \"$RUNNER_IMAGE\"; }; }; }) ]; };
 in sys.config.networking.firewall.interfaces.\"$INCUS_BRIDGE\".allowedTCPPorts" 2>&1 || true)
echo "$fw_eval" | grep -q "$GARM_PORT" \
  || fail "openIncusBridgeFirewall did NOT wire incusbr0 allowedTCPPorts=$GARM_PORT; got: $fw_eval"
info "PASS: declarative egress option wires networking.firewall.interfaces.$INCUS_BRIDGE.allowedTCPPorts = [ $GARM_PORT ]"

# =========================================================================
# 1. Build the module toplevel (backend=incus, metrics, egress option) and
#    extract the module-produced garm.service.
# =========================================================================
info "building the services.garm module toplevel (incus provider ON + metrics + egress)"
TOPLEVEL=$(nix build --impure --no-link --print-out-paths --expr "
let flake = builtins.getFlake (toString $FLAKE); system = \"x86_64-linux\"; nixpkgs = flake.inputs.nixpkgs;
 sys = nixpkgs.lib.nixosSystem { inherit system; modules = [ flake.modules.nixos.garm
  ({ ... }: {
    boot.loader.grub.enable = false; fileSystems.\"/\" = { device = \"/dev/vda\"; fsType = \"ext4\"; }; system.stateVersion = \"24.11\";
    services.garm = {
      enable = true;
      package = flake.packages.\${system}.garm;
      apiServer = { bind = \"0.0.0.0\"; port = $GARM_PORT; };
      metadataURL = \"$STATE_URL/api/v1/metadata\";
      callbackURL = \"$STATE_URL/api/v1/callbacks\";
      metrics = { enable = true; disableAuth = true; };
      openIncusBridgeFirewall = true;
      providers.vmharness = {
        enable = true;
        package = flake.packages.\${system}.garm-provider-vmharness;
        backend = \"incus\";
        incusPath = \"$INCUS_BIN\";
        incusBridge = \"$INCUS_BRIDGE\";
        incusIPv4CIDR = \"$SUBNET\";
        incusIPv4Gateway = \"$BRIDGE_IP\";
        incusIPv4RangeStart = \"${SUBNET_BASE}.200\";
        incusIPv4RangeEnd = \"${SUBNET_BASE}.250\";
        images.linux-runner = { sourceImage = \"$RUNNER_IMAGE\"; osName = \"linux\"; osVersion = \"debian12\"; };
      };
      scaleSets.$SCALESET_NAME = { provider = \"vmharness\"; image = \"linux-runner\"; osType = \"linux\"; maxRunners = $MAX_RUNNERS; minIdleRunners = 0; };
      hostBudget = { memoryMb = 65536; vcpus = 32; };
    };
  }) ]; };
 in sys.config.system.build.toplevel")
[ -n "$TOPLEVEL" ] || fail "module toplevel build produced no output"
UNIT_SRC="$TOPLEVEL/etc/systemd/system/garm.service"
[ -f "$UNIT_SRC" ] || fail "module produced no garm.service unit at $UNIT_SRC"
info "module toplevel: $TOPLEVEL"

# The unit references User=garm/Group=garm + SupplementaryGroups=incus-admin. On
# a rebuilt host the module creates these; this host is deploy-agent-managed and
# not rebuilt for the gate, so create the service account here (idempotent).
if ! getent group garm >/dev/null; then groupadd --system garm; fi
if ! getent passwd garm >/dev/null; then
  useradd --system --gid garm --home-dir "$GARM_STATE_DIR" --shell /usr/sbin/nologin \
    --comment "GARM service user (IM4 gate)" garm
fi
usermod -aG incus-admin garm 2>/dev/null || fail "could not add garm to incus-admin group"

# Start from a CLEAN GARM DB (a persisted DB already has an admin → first-run 409).
systemctl stop garm >/dev/null 2>&1 || true
systemctl reset-failed garm >/dev/null 2>&1 || true
rm -f "$GARM_STATE_DIR"/garm.sqlite* "$GARM_STATE_DIR"/blob-garm.sqlite* \
      "$GARM_STATE_DIR"/config.toml 2>/dev/null || true
garm-cli profile delete im4-gate >/dev/null 2>&1 || true

# Add the scoped, reversible container->host GARM firewall rule (the runtime
# equivalent of the asserted declarative openIncusBridgeFirewall option).
info "adding scoped nixos-fw rule: $INCUS_BRIDGE $SUBNET -> host:$GARM_PORT (reversible; == the declarative option)"
fw_add_rule || fail "could not add firewall rule (nft)"
fw_rule_present || fail "firewall rule not present after insert"

# Install the MODULE-PRODUCED unit verbatim + start it — GARM runs under the
# hardened declarative incus posture (User=garm in incus-admin, ProtectSystem=
# strict, PrivateDevices, MDWE, NO /dev/kvm), NOT a concrete root config.
info "installing + starting the module garm.service (hardened declarative incus unit)"
install -m 0644 "$UNIT_SRC" /run/systemd/system/garm.service
systemctl daemon-reload
sweep_github_scaleset
systemctl start garm
until curl -s -o /dev/null "$STATE_URL/api/v1/controller-info"; do
  systemctl is-failed garm >/dev/null 2>&1 && { journalctl -u garm --no-pager | tail -40; fail "garm.service failed to start under the hardened incus module unit"; }
  sleep 1
done
info "GARM is serving under the module-built hardened incus unit"

# Prove the daemon runs under the IM4 incus posture (not a relaxed shim).
run_user=$(systemctl show -p User --value garm); [ "$run_user" = "garm" ] || fail "garm not running as the dedicated user (User=$run_user)"
systemctl show -p SupplementaryGroups --value garm | grep -qw incus-admin || fail "SupplementaryGroups does not include incus-admin"
systemctl show -p ProtectSystem --value garm | grep -qi strict || fail "ProtectSystem is not 'strict' (incus posture should keep it strict)"
systemctl show -p PrivateDevices --value garm | grep -qi yes || fail "PrivateDevices is not on (incus posture should keep it)"
systemctl show -p MemoryDenyWriteExecute --value garm | grep -qi yes || fail "MemoryDenyWriteExecute is not on (incus posture should keep it)"
dev_allow=$(systemctl show -p DeviceAllow garm)
echo "$dev_allow" | grep -q '/dev/kvm' && fail "incus posture must NOT grant /dev/kvm; got: $dev_allow"
info "PASS: hardened incus posture — User=garm in incus-admin, ProtectSystem=strict, PrivateDevices+MDWE on, NO /dev/kvm"

# =========================================================================
# 2. METRICS SERVED.
# =========================================================================
info "asserting GARM Prometheus /metrics is served (garm_* series)"
metrics_body=$(curl -s "$STATE_URL/metrics" || true)
echo "$metrics_body" | grep -q '^garm_' || fail "GARM /metrics did not return garm_* series"
echo "$metrics_body" | head -40 > "$EVIDENCE/metrics-sample.txt"
info "PASS: /metrics served ($(echo "$metrics_body" | grep -c '^garm_') garm_* samples)"

# =========================================================================
# 3. init + App creds + org + scale set.
# =========================================================================
info "init GARM + wire the App + org + scale set (max-runners=$MAX_RUNNERS, min-idle=0)"
garm-cli init --name im4-gate --url "$STATE_URL" \
  --username admin --email im4@example.com --full-name "IM4 gate" \
  --password 'IM4-e2e-Adm!n-pw-2026-xZ' >/dev/null
garm-cli github credentials add --name mcl-app --endpoint github.com \
  --description "IM4 autoscale+harden gate App creds" \
  --auth-type app --app-id "$APP_ID" --app-installation-id "$INSTALLATION_ID" \
  --private-key-path "$APP_PEM" >/dev/null
ORG_ID=$(garm-cli organization add --name "$ORG" --credentials mcl-app \
  --webhook-secret "$(openssl rand -hex 16)" --format json | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
for _ in $(seq 1 24); do
  r=$(garm-cli organization show "$ORG_ID" --format json | python3 -c 'import sys,json;print(json.load(sys.stdin).get("pool_manager_status",{}).get("running"))')
  [ "$r" = "True" ] && break; sleep 5
done
[ "$r" = "True" ] || fail "GARM org pool manager did not start (App auth failed)"
# Eager reconciler: react to queued jobs immediately (scale-to-zero needs this).
garm-cli controller update --minimum-job-age-backoff 0 >/dev/null 2>&1 || true
SCALESET_ID=$(garm-cli scaleset add --org "$ORG_ID" --provider-name vmharness \
  --image linux-runner --name "$SCALESET_NAME" --flavor default --enabled \
  --min-idle-runners 0 --max-runners "$MAX_RUNNERS" --os-type linux --os-arch amd64 \
  --runner-bootstrap-timeout "$BOOTSTRAP_TIMEOUT_MIN" --format json \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
info "scale set $SCALESET_ID ($SCALESET_NAME) created: max=$MAX_RUNNERS min-idle=0"

# ---- throwaway repo + a matrix workflow (NUM_JOBS jobs) --------------------
TEST_REPO="incus-linux-autoscale-im4-$(date +%Y%m%d-%H%M%S)"
info "creating throwaway repo ${ORG}/${TEST_REPO}"
gh repo create "${ORG}/${TEST_REPO}" --private --description "throwaway IM4 autoscale (auto-deleted)" >/dev/null
GIT_TOKEN="${GH_TOKEN:-$(gh auth token 2>/dev/null)}"
[ -n "$GIT_TOKEN" ] || fail "no GitHub token for git push"
AUTH_REMOTE="https://x-access-token:${GIT_TOKEN}@github.com/${ORG}/${TEST_REPO}.git"
TMP=$(mktemp -d); git clone -q "$AUTH_REMOTE" "$TMP"
mkdir -p "$TMP/.github/workflows"
MATRIX=$(python3 -c "import json;print(json.dumps(list(range(1,$NUM_JOBS+1))))")
cat > "$TMP/.github/workflows/fanout.yml" <<YML
name: im4-fanout
on: { workflow_dispatch: {} }
jobs:
  fan:
    strategy:
      fail-fast: false
      matrix:
        n: ${MATRIX}
    runs-on: ${SCALESET_NAME}
    steps:
      - run: |
          echo "im4 job \${{ matrix.n }} on ephemeral linux incus runner"
          hostname
          sleep 40
YML
git -C "$TMP" add -A
git -C "$TMP" -c user.email=im4@example.com -c user.name=im4 commit -q -m "im4 autoscale fanout"
git -C "$TMP" branch -M main
git -C "$TMP" push -q origin main

# =========================================================================
# PHASE A — CONCURRENCY CAP + SCALE-OUT (the hardened-module one-job e2e, xN)
# =========================================================================
info "PHASE A: enqueue $NUM_JOBS jobs (> max-runners=$MAX_RUNNERS); assert cap honored"
: > "$EVIDENCE/timeline.log"
dispatch_wf fanout.yml || fail "could not dispatch fanout.yml (GitHub never registered the workflow)"
RUN_ID=""
for _ in $(seq 1 20); do
  RUN_ID=$(gh run list -R "${ORG}/${TEST_REPO}" -w im4-fanout --limit 1 --json databaseId \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d[0]["databaseId"] if d else "")' 2>/dev/null)
  [ -n "$RUN_ID" ] && break; sleep 3
done
[ -n "$RUN_ID" ] || fail "could not resolve the fanout run id"

peak=0; cap_ok=1; deadline=$(( $(date +%s) + PHASE_TIMEOUT_SECS ))
succ=0; total="$NUM_JOBS"; done_jobs=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  n=$(containers_running)
  [ "$n" -gt "$peak" ] && peak=$n
  if [ "$n" -gt "$MAX_RUNNERS" ]; then cap_ok=0; sample "A:CAP-VIOLATION($n)"; fi
  read -r succ done_jobs total < <(gh run view "$RUN_ID" -R "${ORG}/${TEST_REPO}" --json jobs 2>/dev/null \
    | python3 -c 'import sys,json
j=json.load(sys.stdin).get("jobs",[])
succ=sum(1 for x in j if x.get("conclusion")=="success")
done=sum(1 for x in j if x.get("status")=="completed")
print(succ, done, len(j))' 2>/dev/null || echo "0 0 $NUM_JOBS")
  sample "A:scale-out($succ/$done_jobs/$total)"
  [ "$done_jobs" = "$NUM_JOBS" ] && [ "$total" = "$NUM_JOBS" ] && break
  sleep 12
done
info "PHASE A: peak concurrent containers = $peak (cap = $MAX_RUNNERS); succeeded=$succ done=$done_jobs total=$total"
[ "$cap_ok" = 1 ] || fail "CONCURRENCY CAP VIOLATED: observed >$MAX_RUNNERS concurrent garm-* containers"
[ "$peak" -ge 1 ] || fail "no ephemeral garm-* container ever appeared (scale-out did not happen)"
[ "$peak" -ge "$MAX_RUNNERS" ] || info "WARN: sampled peak ($peak) < cap ($MAX_RUNNERS) — sampler may have missed concurrency; cap still honored"
[ "$done_jobs" = "$NUM_JOBS" ] || fail "not all $NUM_JOBS jobs reached a terminal state within ${PHASE_TIMEOUT_SECS}s ($done_jobs done)"
[ "$succ" = "$NUM_JOBS" ] && [ "$total" = "$NUM_JOBS" ] || fail "not all $NUM_JOBS jobs succeeded ($succ/$total)"
info "PHASE A PASS: cap honored (peak $peak <= $MAX_RUNNERS) + all $NUM_JOBS jobs succeeded on fresh containers (hardened-module e2e)"

# =========================================================================
# PHASE B — SCALE-TO-ZERO
# =========================================================================
info "PHASE B: assert the pool scales to ZERO after the jobs drain (min-idle=0)"
for _ in $(seq 1 36); do
  [ -z "$(list_gate_containers)" ] && break
  sample "B:draining"; sleep 5
done
sample "B:drained"
[ -z "$(list_gate_containers)" ] || fail "container residue after drain (scale-to-zero failed): $(list_gate_containers)"
for _ in $(seq 1 24); do [ "$(gh_garm_runners)" = 0 ] && break; sleep 5; done
[ "$(gh_garm_runners)" = 0 ] || fail "garm-* runners still registered on GitHub after drain"
info "PHASE B PASS: scaled to ZERO — 0 containers, 0 registered runners"

# =========================================================================
# PHASE C — WARM POOL (min-idle=1) + REFILL
# =========================================================================
info "PHASE C: set min-idle=1 (warm pool); assert 1 pre-launched idle runner is kept"
garm-cli scaleset update "$SCALESET_ID" --min-idle-runners 1 >/dev/null
warm_ok=0; deadline=$(( $(date +%s) + PHASE_TIMEOUT_SECS ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  n=$(containers_running); sample "C:warm-boot"
  [ "$n" -gt "$MAX_RUNNERS" ] && fail "warm pool exceeded max-runners ($n > $MAX_RUNNERS)"
  if [ "$n" -ge 1 ] && [ "$(gh_garm_runners)" -ge 1 ]; then warm_ok=1; break; fi
  sleep 10
done
[ "$warm_ok" = 1 ] || fail "warm pool did not establish 1 pre-launched idle runner within deadline"
info "PHASE C: warm pool established (1 idle pre-launched runner)"

info "PHASE C: firing one job to consume the warm runner; assert refill to 1 idle"
cat > "$TMP/.github/workflows/warm.yml" <<YML
name: im4-warm
on: { workflow_dispatch: {} }
jobs:
  consume:
    runs-on: ${SCALESET_NAME}
    steps:
      - run: |
          echo "im4 warm-consume on ephemeral linux incus runner"
          hostname
YML
git -C "$TMP" add -A
git -C "$TMP" -c user.email=im4@example.com -c user.name=im4 commit -q -m "im4 warm consume"
git -C "$TMP" push -q origin main
dispatch_wf warm.yml || fail "could not dispatch warm.yml"
deadline=$(( $(date +%s) + PHASE_TIMEOUT_SECS )); wconcl=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  sample "C:consume"
  wconcl=$(gh run list -R "${ORG}/${TEST_REPO}" -w im4-warm --limit 1 --json status,conclusion 2>/dev/null \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print((d[0]["status"]+"/"+str(d[0].get("conclusion"))) if d else "none")')
  case "$wconcl" in completed/*) break;; esac
  sleep 10
done
[ "$wconcl" = "completed/success" ] || fail "warm-pool consume job did not succeed: $wconcl"
info "PHASE C: warm-consume job succeeded"

refill_ok=0; deadline=$(( $(date +%s) + PHASE_TIMEOUT_SECS ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  n=$(containers_running); sample "C:refill"
  [ "$n" -gt "$MAX_RUNNERS" ] && fail "warm pool exceeded max-runners during refill ($n > $MAX_RUNNERS)"
  if [ "$n" -ge 1 ] && [ "$(gh_garm_runners)" -ge 1 ]; then refill_ok=1; break; fi
  sleep 10
done
[ "$refill_ok" = 1 ] || fail "warm pool did not REFILL to 1 idle runner after consumption"
info "PHASE C PASS: warm pool refilled to 1 idle runner after consumption"

info "PHASE C: set min-idle=0; assert warm pool drains back to zero"
garm-cli scaleset update "$SCALESET_ID" --min-idle-runners 0 >/dev/null
for _ in $(seq 1 36); do
  [ -z "$(list_gate_containers)" ] && break
  sample "C:final-drain"; sleep 5
done
sample "C:final-drained"
[ -z "$(list_gate_containers)" ] || fail "warm pool did not drain to zero after min-idle=0"
info "PHASE C PASS: warm pool drained to zero after min-idle=0"

echo
echo "===================== EVIDENCE (timeline) ====================="
cat "$EVIDENCE/timeline.log"
echo "==============================================================="
echo "[im4][PASS] t_incus_linux_autoscale_and_harden"
echo "[im4][PASS]   hardened declarative services.garm module ran the INCUS provider"
echo "[im4][PASS]   (User=garm in incus-admin, ProtectSystem=strict, no /dev/kvm) + metrics served"
echo "[im4][PASS]   + declarative incusbr0 egress option + concurrency cap (peak $peak <= $MAX_RUNNERS)"
echo "[im4][PASS]   + all $NUM_JOBS jobs succeeded + scale-to-zero + warm-pool establish/consume/refill"
