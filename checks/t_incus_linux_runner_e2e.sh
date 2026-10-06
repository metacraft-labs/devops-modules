#!/usr/bin/env bash
#
# t_incus_linux_runner_e2e — IM3 gate for the Ephemeral-Linux-Runners-Incus
# campaign. Proves ONE queued GitHub job drives the full ephemeral LINUX
# CONTAINER lifecycle (the container analog of the Windows M4 gate):
#
#   GARM (scale-set message queue) sees the queued job
#     -> CreateInstance -> garm-provider-vmharness (backend = "incus")
#        `incus init` a FRESH runner container, injects GARM's Linux
#        JIT bootstrap as cloud-init.user-data + a static IPv4 as
#        cloud-init.network-config, then `incus start`
#     -> the container's cloud-init consumes the user-data, pulls the JIT
#        runner credentials from GARM's metadata endpoint (per-instance JWT)
#        and registers a one-shot --ephemeral runner with REAL GitHub
#     -> the runner executes EXACTLY ONE job (asserted success)
#     -> GARM sees `completed` -> DeleteInstance `incus delete --force`
#        destroys the container (+ its storage volume) — no residue — and the
#        runner is deregistered.
#
# NOT hermetic: talks to the REAL GitHub org (set via ORG) via a GitHub App and
# launches a real Incus container. ISOLATED + SELF-CLEANING: a UNIQUE scale-set
# name/label + a THROWAWAY repo it creates and deletes; only `garm-lin-*`
# container names; never touches production runners or other production Incus
# containers on the host.
#
# ============================ NETWORKING ==============================
# Container -> internet (github.com): works through incus's EXISTING NAT
#   (table inet incus: pstrt.incusbr0 masquerade + fwd.incusbr0 accept). NO
#   host firewall change is needed for egress. incusbr0 DHCP does not lease on
#   this host (nixos-fw drops the DHCP path), so a STATIC IPv4 is injected via
#   cloud-init.network-config (the provider does this per container).
# Container -> host GARM (metadata/callback on :GARM_PORT): incusbr0 is NOT a
#   trusted nixos-fw interface, so this gate ADDITIVELY inserts ONE scoped,
#   REVERSIBLE nixos-fw input accept rule (incusbr0 saddr <subnet> tcp dport
#   GARM_PORT) and REMOVES it on exit. The production-declarative equivalent
#   is to trust incusbr0 for the GARM port in the host firewall config.
#
# ============================ PREREQUISITES ============================
# Run as a user with: sudo nft (firewall rule), incus (via VMH_INCUS_CMD or
# incus-admin group), the App PEM readable (sudo), and gh authenticated with
# repo+admin:org. The runner incus image (alias via VMH_RUNNER_ALIAS) must be
# present. Pass the GARM + provider binaries via GARM_BIN / GARM_CLI_BIN /
# PROVIDER_BIN. Supply the App ID / installation / org / PEM path via env
# (APP_ID, INSTALLATION_ID, ORG, APP_PEM).
#
# ============================ CONFIG (env) ============================
set -uo pipefail

APP_ID="${APP_ID:?set APP_ID (the GitHub App ID)}"
INSTALLATION_ID="${INSTALLATION_ID:?set INSTALLATION_ID (the GitHub App installation ID)}"
APP_PEM="${APP_PEM:?set APP_PEM (path to the GitHub App private-key PEM)}"
ORG="${ORG:?set ORG (the GitHub org)}"
SCALESET_NAME="${SCALESET_NAME:-linux-ephemeral-e2e}"

INCUS_CMD="${VMH_INCUS_CMD:-sudo -n incus}"
# The provider runs as ROOT under GARM and reaches the incus socket directly
# (no sudo-to-user needed); it uses the absolute incus binary.
INCUS_BIN="${VMH_INCUS_BIN:-$(command -v incus || echo /run/current-system/sw/bin/incus)}"
RUNNER_IMAGE="${VMH_RUNNER_ALIAS:?set VMH_RUNNER_ALIAS (the incus runner image alias)}"
INCUS_BRIDGE="${VMH_INCUS_BRIDGE:-incusbr0}"

GARM_BIN="${GARM_BIN:-$(command -v garm || true)}"
GARM_CLI_BIN="${GARM_CLI_BIN:-$(command -v garm-cli || true)}"
PROVIDER_BIN="${PROVIDER_BIN:-$(command -v garm-provider-vmharness || true)}"

GARM_PORT="${GARM_PORT:-9997}"
WORKDIR="${WORKDIR:-/tmp/garm-im3-gate}"
JOB_TIMEOUT_SECS="${JOB_TIMEOUT_SECS:-900}"
FW_TABLE="inet nixos-fw"
FW_CHAIN="input"
FW_COMMENT="im3-e2e-garm-${GARM_PORT}"

fail() { echo "[e2e][FAIL] $*" >&2; exit 1; }
info() { echo "[e2e] $*"; }

# Derive the incusbr0 /24 + host IP (GARM metadata/callback base).
BRIDGE_CIDR="$($INCUS_CMD network get "$INCUS_BRIDGE" ipv4.address 2>/dev/null)"  # e.g. 10.0.100.1/24
[ -n "$BRIDGE_CIDR" ] || fail "cannot read $INCUS_BRIDGE ipv4.address (incus reachable?)"
BRIDGE_IP="${BRIDGE_CIDR%/*}"                 # e.g. 10.0.100.1
PREFIX="${BRIDGE_CIDR##*/}"                   # 24
SUBNET_BASE="$(echo "$BRIDGE_IP" | cut -d. -f1-3)"   # e.g. 10.0.100
SUBNET="${SUBNET_BASE}.0/${PREFIX}"          # e.g. 10.0.100.0/24
STATE_URL="http://${BRIDGE_IP}:${GARM_PORT}"

for b in "$GARM_BIN" "$GARM_CLI_BIN" "$PROVIDER_BIN"; do
  [ -n "$b" ] && [ -x "$b" ] || fail "missing binary (set GARM_BIN/GARM_CLI_BIN/PROVIDER_BIN): $b"
done
sudo -n test -r "$APP_PEM" || fail "cannot read App PEM: $APP_PEM"
$INCUS_CMD image info "$RUNNER_IMAGE" >/dev/null 2>&1 || fail "runner image '$RUNNER_IMAGE' absent"
command -v gh >/dev/null || fail "gh not on PATH"

# ---- App installation token (for GitHub-side assertions) -------------------
app_token() {
  local b64url now h p s jwt
  b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
  now=$(date +%s)
  h=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
  p=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now-60)) $((now+540)) "$APP_ID" | b64url)
  s=$(printf '%s.%s' "$h" "$p" | sudo -n openssl dgst -sha256 -sign "$APP_PEM" -binary | b64url)
  jwt="$h.$p.$s"
  curl -s -X POST -H "Authorization: Bearer $jwt" \
    "https://api.github.com/app/installations/${INSTALLATION_ID}/access_tokens" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])'
}
gh_garm_runner_count() {
  local tok; tok=$(app_token)
  curl -s -H "Authorization: token $tok" \
    "https://api.github.com/orgs/${ORG}/actions/runners?per_page=100" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(len([r for r in d.get("runners",[]) if r["name"].startswith("garm-")]))'
}

# Delete any leftover org runners named garm-* (a container destroyed without a
# clean --ephemeral deregistration leaves a registration behind). Best-effort.
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

# Delete any GitHub Actions runner SCALE SET whose name starts with our name,
# via the actions broker API (the same internal endpoint GARM uses). GARM's own
# `scaleset delete` removes it from GitHub, but if a run is interrupted before
# that runs, an orphan can linger and block re-creation ("already exists"). This
# makes the gate self-healing: called in preflight AND cleanup. Best-effort.
gh_purge_scalesets() {
  local tok; tok=$(app_token)
  SCALESET_NAME="$SCALESET_NAME" ORG="$ORG" GH_APP_TOKEN="$tok" python3 - <<'PY' 2>/dev/null || true
import json,os,urllib.request,urllib.error
tok=os.environ["GH_APP_TOKEN"]; org=os.environ["ORG"]; name=os.environ["SCALESET_NAME"]
def req(url,method="GET",data=None,auth=None):
    h={"Accept":"application/json"}
    if auth: h["Authorization"]=auth
    b=json.dumps(data).encode() if data is not None else None
    if b: h["Content-Type"]="application/json"
    try:
        with urllib.request.urlopen(urllib.request.Request(url,data=b,headers=h,method=method)) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
st,body=req(f"https://api.github.com/orgs/{org}/actions/runners/registration-token","POST",data={},auth=f"token {tok}")
if st//100!=2: raise SystemExit(0)
regtok=json.loads(body)["token"]
st,body=req("https://api.github.com/actions/runner-registration","POST",
            data={"url":f"https://github.com/{org}","runner_event":"register"},auth=f"RemoteAuth {regtok}")
if st//100!=2: raise SystemExit(0)
j=json.loads(body); svc=j["url"].rstrip("/"); bearer=j["token"]
st,body=req(f"{svc}/_apis/runtime/runnerscalesets?api-version=6.0-preview","GET",auth=f"Bearer {bearer}")
if st//100!=2: raise SystemExit(0)
for x in json.loads(body).get("value",[]):
    if x["name"].startswith(name):
        s,_=req(f"{svc}/_apis/runtime/runnerscalesets/{x['id']}?api-version=6.0-preview","DELETE",auth=f"Bearer {bearer}")
        print(f"[e2e] purged orphan scale set {x['id']} {x['name']}: HTTP {s}")
PY
}

# GARM names its ephemeral instances garm-<id>; the container name mirrors it.
# No other garm-* Incus containers are expected on the host (production runners
# use libvirt and non-garm-* names for their Incus containers), so matching
# ^garm- is safe + scoped to instances THIS gate creates.
list_gate_containers() {
  $INCUS_CMD list --format csv -c n 2>/dev/null | grep '^garm-' || true
}

fw_rule_present() {
  sudo -n nft -a list chain $FW_TABLE $FW_CHAIN 2>/dev/null | grep -q "$FW_COMMENT"
}
fw_add_rule() {
  fw_rule_present && return 0
  sudo -n nft insert rule $FW_TABLE $FW_CHAIN \
    iifname "$INCUS_BRIDGE" ip saddr "$SUBNET" tcp dport "$GARM_PORT" accept \
    comment "$FW_COMMENT"
}
fw_del_rule() {
  # Remove every rule carrying our comment (by handle), idempotently.
  local handles
  handles=$(sudo -n nft -a list chain $FW_TABLE $FW_CHAIN 2>/dev/null \
    | awk -v c="$FW_COMMENT" '$0 ~ c {for(i=1;i<=NF;i++) if($i=="handle") print $(i+1)}')
  local h
  for h in $handles; do
    sudo -n nft delete rule $FW_TABLE $FW_CHAIN handle "$h" 2>/dev/null || true
  done
}

cleanup() {
  set +e
  info "cleanup…"
  [ -n "${SCALESET_ID:-}" ] && sudo -n env "HOME=$WORKDIR" "$GARM_CLI_BIN" scaleset delete "$SCALESET_ID" >/dev/null 2>&1
  [ -n "${ORG_ID:-}" ]      && sudo -n env "HOME=$WORKDIR" "$GARM_CLI_BIN" organization delete "$ORG_ID" >/dev/null 2>&1
  sudo -n env "HOME=$WORKDIR" "$GARM_CLI_BIN" github credentials delete mcl-app >/dev/null 2>&1
  sudo -n systemctl stop garm-im3-gate >/dev/null 2>&1
  sudo -n systemctl reset-failed garm-im3-gate >/dev/null 2>&1
  # destroy any stray gate containers
  for c in $(list_gate_containers); do
    $INCUS_CMD delete --force "$c" >/dev/null 2>&1
  done
  [ -n "${TEST_REPO:-}" ] && gh repo delete "${ORG}/${TEST_REPO}" --yes >/dev/null 2>&1
  # belt-and-suspenders: drop any orphan GitHub scale set + leftover runners
  gh_purge_scalesets
  gh_purge_garm_runners
  fw_del_rule
  sudo -n rm -rf "$WORKDIR" 2>/dev/null
  sudo -n rm -f /root/.local/share/garm-cli/config.toml 2>/dev/null
  if fw_rule_present; then echo "[e2e][WARN] firewall rule still present after cleanup!" >&2; fi
}
trap cleanup EXIT

# ---- 0. add the scoped, reversible firewall rule --------------------------
info "adding scoped nixos-fw input rule: $INCUS_BRIDGE $SUBNET -> host:$GARM_PORT (reversible)"
fw_add_rule || fail "could not add firewall rule (sudo nft)"
fw_rule_present || fail "firewall rule not present after insert"

# ---- 1. provider + GARM config, start GARM --------------------------------
info "writing provider + GARM config under $WORKDIR (GARM base $STATE_URL)"
sudo -n mkdir -p "$WORKDIR"
sudo -n tee "$WORKDIR/provider.toml" >/dev/null <<EOF
backend = "incus"
incus_path = "$INCUS_BIN"
incus_bridge = "$INCUS_BRIDGE"
incus_ipv4_cidr = "$SUBNET"
incus_ipv4_gateway = "$BRIDGE_IP"
incus_ipv4_range_start = "${SUBNET_BASE}.200"
incus_ipv4_range_end = "${SUBNET_BASE}.250"
incus_nameservers = ["1.1.1.1", "8.8.8.8"]
[images.linux-runner]
source_image = "$RUNNER_IMAGE"
os_name = "linux"
os_version = "debian12"
EOF
JWT=$(openssl rand -hex 32); DBP=$(openssl rand -hex 16)
sudo -n tee "$WORKDIR/garm-config.toml" >/dev/null <<EOF
[default]
enable_webhook_management = false
[logging]
log_level = "info"
log_format = "text"
[metrics]
enable = false
[jwt_auth]
secret = "$JWT"
time_to_live = "24h"
[apiserver]
bind = "0.0.0.0"
port = $GARM_PORT
use_tls = false
[database]
backend = "sqlite3"
passphrase = "$DBP"
  [database.sqlite3]
  db_file = "$WORKDIR/garm.sqlite"
[[provider]]
name = "vmharness-incus"
provider_type = "external"
description = "incus Linux ephemeral runners via vm-harness"
  [provider.external]
  provider_executable = "$PROVIDER_BIN"
  config_file = "$WORKDIR/provider.toml"
  interface_version = "v0.1.1"
  environment_variables = ["PATH", "HOME"]
EOF

info "starting GARM (transient unit garm-im3-gate)"
sudo -n systemctl reset-failed garm-im3-gate 2>/dev/null || true
sudo -n systemd-run --unit=garm-im3-gate --collect \
  --setenv=PATH="$PATH" \
  --working-directory="$WORKDIR" \
  "$GARM_BIN" -config "$WORKDIR/garm-config.toml" >/dev/null
until curl -s -o /dev/null "$STATE_URL/api/v1/controller-info"; do sleep 1; done

# ---- 2. init + App creds + org + scale set --------------------------------
info "init GARM + wire the App + org + scale set (base URL guest-reachable)"
sudo -n env "HOME=$WORKDIR" "$GARM_CLI_BIN" init --name im3-gate --url "$STATE_URL" \
  --username admin --email e2e@example.com --full-name "IM3 gate" \
  --password 'IM3-e2e-Adm!n-pw-2026-xZ' >/dev/null
sudo -n env "HOME=$WORKDIR" "$GARM_CLI_BIN" github credentials add --name mcl-app --endpoint github.com \
  --description "MCL App (IM3 incus e2e)" \
  --auth-type app --app-id "$APP_ID" --app-installation-id "$INSTALLATION_ID" \
  --private-key-path "$APP_PEM" >/dev/null
ORG_ID=$(sudo -n env "HOME=$WORKDIR" "$GARM_CLI_BIN" organization add --name "$ORG" --credentials mcl-app \
  --webhook-secret "$(openssl rand -hex 16)" --format json | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
for _ in $(seq 1 24); do
  r=$(sudo -n env "HOME=$WORKDIR" "$GARM_CLI_BIN" organization show "$ORG_ID" --format json | python3 -c 'import sys,json;print(json.load(sys.stdin).get("pool_manager_status",{}).get("running"))')
  [ "$r" = "True" ] && break; sleep 5
done
[ "$r" = "True" ] || fail "GARM org pool manager did not start (App auth failed)"
# Self-heal: drop any orphan scale set of this name left by an interrupted run.
gh_purge_scalesets
SCALESET_ID=$(sudo -n env "HOME=$WORKDIR" "$GARM_CLI_BIN" scaleset add --org "$ORG_ID" --provider-name vmharness-incus \
  --image linux-runner --name "$SCALESET_NAME" --flavor default --enabled \
  --min-idle-runners 0 --max-runners 1 --os-type linux --os-arch amd64 \
  --runner-bootstrap-timeout 20 --format json | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
info "scale set $SCALESET_ID ($SCALESET_NAME) created"

# ---- 3. throwaway repo + workflow, trigger one job ------------------------
TEST_REPO="incus-linux-runner-e2e-$(date +%Y%m%d-%H%M%S)"
info "creating throwaway repo ${ORG}/${TEST_REPO}"
gh repo create "${ORG}/${TEST_REPO}" --private --description "throwaway IM3 e2e (auto-deleted)" >/dev/null
TMP=$(mktemp -d); git clone -q "https://github.com/${ORG}/${TEST_REPO}.git" "$TMP"
mkdir -p "$TMP/.github/workflows"
cat > "$TMP/.github/workflows/e2e.yml" <<YML
name: im3-e2e
on: { workflow_dispatch: {} }
jobs:
  hello:
    runs-on: ${SCALESET_NAME}
    steps:
      - run: |
          echo "hello from ephemeral linux incus runner"
          hostname
YML
git -C "$TMP" add -A
git -C "$TMP" -c user.email=e2e@example.com -c user.name=e2e commit -q -m "im3 e2e"
git -C "$TMP" push -q origin HEAD
gh workflow run e2e.yml -R "${ORG}/${TEST_REPO}" >/dev/null

# ---- 4. assert the create -> run-one -> destroy lifecycle -----------------
info "waiting for the ephemeral job to complete (up to ${JOB_TIMEOUT_SECS}s)…"
saw_instance=0; deadline=$(( $(date +%s) + JOB_TIMEOUT_SECS )); concl=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  [ -n "$(list_gate_containers)" ] && saw_instance=1
  concl=$(gh run list -R "${ORG}/${TEST_REPO}" --limit 1 --json status,conclusion 2>/dev/null \
    | python3 -c 'import sys,json
d=json.load(sys.stdin)
print((d[0]["status"]+"/"+str(d[0].get("conclusion"))) if d else "none")' 2>/dev/null)
  case "$concl" in completed/*) break;; esac
  sleep 10
done
[ "$saw_instance" = 1 ] || fail "no ephemeral garm-lin-* container ever appeared"
[ "$concl" = "completed/success" ] || fail "job did not succeed: $concl"
info "PASS: job completed successfully on a fresh ephemeral Incus container"

# container must be gone after teardown (GARM DeleteInstance)
for _ in $(seq 1 24); do
  [ -z "$(list_gate_containers)" ] && break
  sleep 5
done
[ -z "$(list_gate_containers)" ] || fail "container residue after teardown: $(list_gate_containers)"
info "PASS: ephemeral container destroyed (no residue)"

# runner deregistered on GitHub
for _ in $(seq 1 12); do [ "$(gh_garm_runner_count)" = 0 ] && break; sleep 5; done
[ "$(gh_garm_runner_count)" = 0 ] || fail "garm-* runner still registered on GitHub"
info "PASS: runner deregistered on GitHub"

echo "[e2e][PASS] t_incus_linux_runner_e2e — fresh container -> JIT -> one job (success) -> destroy, no residue"
