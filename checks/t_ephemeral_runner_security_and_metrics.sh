#!/usr/bin/env bash
#
# t_ephemeral_runner_security_and_metrics — M6 gate for the
# Ephemeral-Windows-Runners-GARM campaign. Where M4 proved the single-job e2e
# and M5 the autoscale, BOTH ran GARM as a concrete ROOT config (a transient
# systemd unit + a hand-written config.toml) because the hardened declarative
# `services.garm` module's DynamicUser+PrivateDevices+ProtectSystem=strict
# sandbox BLOCKED the libvirt provider. M6's centerpiece is resolving that: this
# gate runs the FULL ephemeral one-job e2e THROUGH the declarative
# `services.garm` module — the module-built HARDENED systemd unit (dedicated
# `garm` user in libvirtd+kvm, ProtectSystem=full, DeviceAllow=/dev/kvm, targeted
# ReadWritePaths, the module's ExecStartPre config renderer wiring the App +
# provider + metadata URLs) starts GARM, the provider CoW-clones a fresh Windows
# VM, JIT-registers, runs ONE job, and destroys it.
#
# It additionally asserts the M6 security + observability deliverables:
#   * NO STATE BLEED: a marker written by job 1 into C:\ is ABSENT in a fresh
#     job-2 VM (the ephemeral VM is genuinely destroyed + reborn from the golden).
#   * METRICS SERVED: GARM's Prometheus /metrics endpoint returns garm_* series.
#   * SECRETS NOT IN STORE: the App PEM + DB passphrase + JWT secret are not in
#     /nix/store (rendered at runtime; store holds only @SENTINEL@ templates).
#   * RESOURCE-GUARD ASSERTION FIRES: a sibling `nix eval` of an over-committed
#     services.garm config aborts with the eval-time budget assertion.
#   * DOCS/RUNBOOK present: modules/garm/README.md documents the posture.
#
# ============================ PREREQUISITES ============================
# Run as root on the libvirt/KVM host. Same as M4/M5 plus this gate BUILDS the
# module toplevel and installs the module's garm.service unit:
#   * /dev/kvm + qemu:///system libvirtd with the "default" NAT net up
#     (virbr0 = 192.168.122.1, a trusted iface so guests reach the host).
#   * The Windows golden (PREFER a sysprepped golden — fresh SID per clone — if
#     present, else the base golden), UTC RTC. Path(s) via env (VMH_WIN_GOLDEN).
#   * OVMF firmware under /run/libvirt/nix-ovmf.
#   * The GitHub App PEM readable (APP_PEM = the App private-key PEM path), with
#     the App ID / installation / org supplied via env (APP_ID, INSTALLATION_ID,
#     ORG) and the org `Self-hosted runners: Read & write` permission.
#   * `gh` CLI authenticated with repo+admin:org.
#   * nix (to build the module toplevel), and this nixos-modules flake checkout.
#
# ISOLATED + SELF-CLEANING: a UNIQUE scale-set name + a THROWAWAY test repo it
# creates and deletes; ONLY m6-*/garm-* names; NEVER touches production runners
# or other concurrent workstreams.
#
# ============================ CONFIG (env) ============================
set -euo pipefail

APP_ID="${APP_ID:?set APP_ID (the GitHub App ID)}"
INSTALLATION_ID="${INSTALLATION_ID:?set INSTALLATION_ID (the GitHub App installation ID)}"
APP_PEM="${APP_PEM:?set APP_PEM (path to the GitHub App private-key PEM)}"
ORG="${ORG:?set ORG (the GitHub org)}"
SCALESET_NAME="${SCALESET_NAME:-windows-ephemeral-m6}"

# The Windows golden path (prefer a sysprepped golden — fresh SID per clone).
VMH_WIN_GOLDEN="${VMH_WIN_GOLDEN:?set VMH_WIN_GOLDEN (path to the Windows golden qcow2)}"

# A garm-owned pool dir (the module default) — the non-root garm user cannot
# write the shared root-only /var/lib/libvirt/images. Provisioned below.
POOL_DIR="${POOL_DIR:-/var/lib/garm/pool}"
LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"
GARM_PORT="${GARM_PORT:-9997}"
BRIDGE_IP="${BRIDGE_IP:-192.168.122.1}"
MEMORY_MB="${MEMORY_MB:-4096}"
VCPUS="${VCPUS:-4}"

VIRSH="${VIRSH:-$(command -v virsh)}"
FLAKE="${FLAKE:-$(cd "$(dirname "$0")/.." && pwd)}"   # the nixos-modules flake root
STATE_URL="http://${BRIDGE_IP}:${GARM_PORT}"
GARM_STATE_DIR="/var/lib/garm"
JOB_TIMEOUT_SECS="${JOB_TIMEOUT_SECS:-1200}"
EVIDENCE="${EVIDENCE:-/var/lib/garm-m6-gate/evidence}"

fail() { echo "[m6][FAIL] $*" >&2; exit 1; }
info() { echo "[m6] $*"; }

[ "$(id -u)" = 0 ] || fail "must run as root (installs the module garm.service unit + drives libvirt)"
[ -r "$APP_PEM" ] || fail "cannot read App PEM: $APP_PEM"
[ -f "$VMH_WIN_GOLDEN" ] || fail "missing golden: $VMH_WIN_GOLDEN"
command -v nix >/dev/null || fail "nix not on PATH (needed to build the module toplevel)"
command -v gh  >/dev/null || fail "gh not on PATH"

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
gh_garm_runner_count() {
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

cleanup() {
  set +e
  info "cleanup…"
  journalctl -u garm --no-pager > "$EVIDENCE/garm.log" 2>/dev/null
  [ -n "${SCALESET_ID:-}" ] && garm-cli scaleset delete "$SCALESET_ID" >/dev/null 2>&1
  for _ in $(seq 1 12); do
    "$VIRSH" -c "$LIBVIRT_URI" list --all --name 2>/dev/null | grep -q '^garm-' || break; sleep 5
  done
  sweep_github_scaleset
  [ -n "${ORG_ID:-}" ] && garm-cli organization delete "$ORG_ID" >/dev/null 2>&1
  garm-cli github credentials delete mcl-app >/dev/null 2>&1
  garm-cli profile delete m6-gate >/dev/null 2>&1
  # Stop + REMOVE the module unit we installed (do not leave a foreign unit).
  systemctl stop garm >/dev/null 2>&1
  systemctl reset-failed garm >/dev/null 2>&1
  rm -f /run/systemd/system/garm.service
  systemctl daemon-reload >/dev/null 2>&1
  # destroy any stray gate domains + artifacts (ONLY garm-* — never prod/sysprep)
  for d in $("$VIRSH" -c "$LIBVIRT_URI" list --all --name 2>/dev/null | grep '^garm-' || true); do
    "$VIRSH" -c "$LIBVIRT_URI" destroy "$d" >/dev/null 2>&1
    "$VIRSH" -c "$LIBVIRT_URI" undefine "$d" --nvram >/dev/null 2>&1
  done
  rm -f "$POOL_DIR"/garm-*.overlay.qcow2 "$POOL_DIR"/garm-*.nvram.fd "$POOL_DIR"/garm-*.config-drive.iso 2>/dev/null
  [ -n "${TEST_REPO:-}" ] && gh repo delete "${ORG}/${TEST_REPO}" --yes >/dev/null 2>&1
  # Remove the golden-path ACL we granted (leave the host as we found it).
  if [ -n "${ACL_GRANTED:-}" ]; then
    setfacl -x u:garm "$VMH_WIN_GOLDEN" 2>/dev/null || true
    p=$(dirname "$VMH_WIN_GOLDEN")
    while [ "$p" != "/" ] && [ -n "$p" ]; do setfacl -x u:garm "$p" 2>/dev/null || true; p=$(dirname "$p"); done
  fi
  info "evidence retained under $EVIDENCE"
}
trap cleanup EXIT

# =========================================================================
# 0. RESOURCE-GUARD ASSERTION (eval-time) — a bad config must FAIL TO EVAL.
# =========================================================================
info "asserting the M6 eval-time resource guard fires on an over-committed config"
guard_err=$(nix eval --impure --show-trace --expr "
let flake = builtins.getFlake (toString $FLAKE); system = \"x86_64-linux\"; nixpkgs = flake.inputs.nixpkgs;
 sys = nixpkgs.lib.nixosSystem { inherit system; modules = [ flake.modules.nixos.garm
  ({ ... }: { boot.loader.grub.enable = false; fileSystems.\"/\" = { device = \"/dev/vda\"; fsType = \"ext4\"; }; system.stateVersion = \"24.11\";
    services.garm = { enable = true;
      providers.vmharness = { enable = true; memoryMb = 8192; images.golden.sourceImage = \"/g.qcow2\"; };
      hostBudget = { memoryMb = 16384; vcpus = 8; };
      scaleSets.big = { maxRunners = 10; minIdleRunners = 0; }; }; }) ]; };
 in sys.config.system.build.toplevel.drvPath" 2>&1 || true)
echo "$guard_err" | grep -qi "exceeds hostBudget.memoryMb" \
  || fail "resource-guard assertion did NOT fire on an over-committed config; got: $(echo "$guard_err" | tail -3)"
info "PASS: eval-time resource-guard assertion fired (over-committed config rejected)"

# =========================================================================
# 1. Build the module toplevel with the REAL provider/App/scaleset wiring and
#    extract the module-produced garm.service + the config renderer.
# =========================================================================
info "building the services.garm module toplevel (provider ON + App + scale set)"
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
      github.mcl-app = { appId = $APP_ID; installationId = $INSTALLATION_ID; appKeyFile = \"$APP_PEM\"; };
      providers.vmharness = {
        enable = true;
        package = flake.packages.\${system}.garm-provider-vmharness;
        poolDir = \"$POOL_DIR\";
        memoryMb = $MEMORY_MB; vcpus = $VCPUS;
        images.golden = { sourceImage = \"$VMH_WIN_GOLDEN\"; osName = \"windows\"; osVersion = \"11\"; };
      };
      scaleSets.$SCALESET_NAME = { provider = \"vmharness\"; image = \"golden\"; osType = \"windows\"; maxRunners = 1; minIdleRunners = 0; };
      hostBudget = { memoryMb = 65536; vcpus = 32; };
    };
  }) ]; };
 in sys.config.system.build.toplevel")
[ -n "$TOPLEVEL" ] || fail "module toplevel build produced no output"
UNIT_SRC="$TOPLEVEL/etc/systemd/system/garm.service"
[ -f "$UNIT_SRC" ] || fail "module produced no garm.service unit at $UNIT_SRC"
info "module toplevel: $TOPLEVEL"

# The unit references User=garm/Group=garm + supplementary libvirtd/kvm. On a
# rebuilt host the module creates these; this host is deploy-agent-managed and
# not rebuilt for the gate, so create the service account here (idempotent).
if ! getent group garm >/dev/null; then groupadd --system garm; fi
if ! getent passwd garm >/dev/null; then
  useradd --system --gid garm --home-dir "$GARM_STATE_DIR" --shell /usr/sbin/nologin \
    --comment "GARM service user (M6 gate)" garm
fi
usermod -aG libvirtd,kvm garm 2>/dev/null || true

# Provision the garm-owned pool dir (the module does this via systemd-tmpfiles on
# a rebuilt host; we replicate it here since this host is not rebuilt).
mkdir -p "$POOL_DIR"
chown garm:libvirtd "$POOL_DIR" 2>/dev/null || chown garm "$POOL_DIR"
chmod 0771 "$POOL_DIR"

# HOST-INTEGRATION: the non-root garm user must READ the golden + TRAVERSE its
# parents. The golden often lives under a group-gated path (e.g. /storage owned
# root:metacraft 0770). Grant a minimal POSIX ACL for the garm user along the
# path (idempotent; removed in cleanup). This is the documented integration step
# (modules/garm/README §2 / providers.vmharness.images.sourceImage) — the M4/M5
# harnesses masked it by running qemu-img as root.
GOLDEN_DIR=$(dirname "$VMH_WIN_GOLDEN")
if ! sudo -u garm test -r "$VMH_WIN_GOLDEN" 2>/dev/null; then
  info "granting garm read+traverse ACL along the golden path (host integration)"
  # walk up granting --x traverse on each ancestor, r-x on the immediate dir, r on the file
  p="$GOLDEN_DIR"
  ACL_DIRS=()
  while [ "$p" != "/" ] && [ -n "$p" ]; do ACL_DIRS+=("$p"); p=$(dirname "$p"); done
  for d in "${ACL_DIRS[@]}"; do setfacl -m u:garm:--x "$d" 2>/dev/null || true; done
  setfacl -m u:garm:r-x "$GOLDEN_DIR" 2>/dev/null || true
  setfacl -m u:garm:r-- "$VMH_WIN_GOLDEN" 2>/dev/null || true
  ACL_GRANTED=1
fi
sudo -u garm test -r "$VMH_WIN_GOLDEN" || fail "garm user still cannot read the golden $VMH_WIN_GOLDEN after ACL grant"
info "garm user can read the golden + write $POOL_DIR"

# Start from a CLEAN GARM DB (a persisted DB already has an admin → first-run 409).
systemctl stop garm >/dev/null 2>&1 || true
systemctl reset-failed garm >/dev/null 2>&1 || true
rm -f "$GARM_STATE_DIR"/garm.sqlite* "$GARM_STATE_DIR"/blob-garm.sqlite* \
      "$GARM_STATE_DIR"/config.toml "$GARM_STATE_DIR"/app-key.pem 2>/dev/null || true
garm-cli profile delete m6-gate >/dev/null 2>&1 || true

# Install the MODULE-PRODUCED unit verbatim as a runtime unit and start it. This
# is the whole point: GARM runs under the hardened declarative unit (User=garm in
# libvirtd+kvm, ProtectSystem=full, DeviceAllow=/dev/kvm, the module's
# ExecStartPre renderer wiring App+provider+metadata) — NOT a concrete root config.
info "installing + starting the module garm.service (hardened declarative unit)"
install -m 0644 "$UNIT_SRC" /run/systemd/system/garm.service
systemctl daemon-reload
sweep_github_scaleset   # clear any orphan before the pool manager attaches
systemctl start garm
until curl -s -o /dev/null "$STATE_URL/api/v1/controller-info"; do
  systemctl is-failed garm >/dev/null 2>&1 && { journalctl -u garm --no-pager | tail -40; fail "garm.service failed to start under the hardened module unit"; }
  sleep 1
done
info "GARM is serving under the module-built hardened unit"

# Prove the daemon really runs under the hardened posture (not a relaxed shim).
run_user=$(systemctl show -p User --value garm); [ "$run_user" = "garm" ] || fail "garm not running as the dedicated user (User=$run_user)"
systemctl show -p ProtectSystem --value garm | grep -qi full || fail "ProtectSystem is not 'full'"
systemctl show -p DeviceAllow garm | grep -q '/dev/kvm' || fail "DeviceAllow does not include /dev/kvm"
info "PASS: GARM under hardened unit — User=garm, ProtectSystem=full, DeviceAllow=/dev/kvm"

# =========================================================================
# 2. SECRETS NOT IN STORE.
# =========================================================================
info "asserting secrets are NOT in the Nix store"
CFG_TMPL=$(grep -o '/nix/store/[a-z0-9]*-garm-config.toml.tmpl' \
  "$(grep -oE 'ExecStartPre=[^ ]*garm-render-config' "$UNIT_SRC" | cut -d= -f2)" | head -1)
[ -n "$CFG_TMPL" ] && grep -q '@JWT_SECRET@' "$CFG_TMPL" && grep -q '@DB_PASSPHRASE@' "$CFG_TMPL" \
  || fail "store config template does not carry secret SENTINELS (secrets may be baked in!)"
grep -q 'BEGIN' "$CFG_TMPL" 2>/dev/null && fail "PEM material leaked into the store config template"
# The rendered runtime config DOES have real secrets, but lives under stateDir 0700.
test "$(stat -c '%a' "$GARM_STATE_DIR")" = "700" || info "WARN: $GARM_STATE_DIR not 0700"
info "PASS: store holds only @SENTINEL@ templates; real secrets rendered under $GARM_STATE_DIR"

# =========================================================================
# 3. METRICS SERVED.
# =========================================================================
info "asserting GARM Prometheus /metrics is served (garm_* series)"
metrics_body=$(curl -s "$STATE_URL/metrics" || true)
echo "$metrics_body" | grep -q '^garm_' \
  || fail "GARM /metrics did not return garm_* series (metrics not enabled/served)"
echo "$metrics_body" | head -40 > "$EVIDENCE/metrics-sample.txt"
info "PASS: /metrics served ($(echo "$metrics_body" | grep -c '^garm_') garm_* samples)"

# =========================================================================
# 4. init + wire org + scale set (App creds already imported from config.toml).
# =========================================================================
info "init GARM + wire org + scale set"
garm-cli init --name m6-gate --url "$STATE_URL" \
  --username admin --email m6@example.com --full-name "M6 gate" \
  --password 'M6-e2e-Adm!n-pw-2026-xZ' >/dev/null

# DECLARATIVE App WIRING — with a documented GARM constraint.
#
# GARM's config `[[github]]` block (which the module emits) is imported into the
# DB ONLY by the legacy one-shot `migrateCredentialsToDB`, and ONLY on the very
# first DB open (needsCredentialMigration = the credentials table does not yet
# exist) AND only if an admin user already exists at that instant. GARM's
# first-run flow creates the admin via the API AFTER boot, so on a fresh deploy
# the import is always skipped ("Admin user doesn't exist. This is a new
# deploy."). The `[[github]]` block is therefore effective only for UPGRADING a
# pre-existing single-user GARM, not for fresh deploys. See modules/garm/README.
#
# So the credential REGISTRATION is done at provisioning time via garm-cli — but
# every INPUT is sourced from the MODULE: the App ID / installation ID declared
# in services.garm.github, and the App PEM the MODULE staged out of the store to
# a stable 0600 path ($GARM_STATE_DIR/app-key.pem) via LoadCredential. That
# staged PEM existing + being usable is what proves the declarative secret path.
STAGED_PEM="$GARM_STATE_DIR/app-key.pem"
[ -f "$STAGED_PEM" ] || fail "module did NOT stage the App PEM to $STAGED_PEM (declarative secret path broken)"
test "$(stat -c '%a' "$STAGED_PEM")" = "600" || fail "staged App PEM is not mode 0600: $(stat -c '%a' "$STAGED_PEM")"
grep -q 'BEGIN' "$STAGED_PEM" || fail "staged App PEM does not look like a PEM"
info "PASS: module staged the App PEM out of the store to $STAGED_PEM (0600)"

garm-cli github credentials add --name mcl-app --endpoint github.com \
  --description "M6 gate App creds (module-declared App ID/installation, module-staged PEM)" \
  --auth-type app --app-id "$APP_ID" --app-installation-id "$INSTALLATION_ID" \
  --private-key-path "$STAGED_PEM" >/dev/null \
  || fail "failed to register App creds from the module-staged PEM"
info "PASS: App creds registered from the module-declared App ID/installation + module-staged PEM"

ORG_ID=$(garm-cli organization add --name "$ORG" --credentials mcl-app \
  --webhook-secret "$(openssl rand -hex 16)" --format json | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
for _ in $(seq 1 24); do
  r=$(garm-cli organization show "$ORG_ID" --format json | python3 -c 'import sys,json;print(json.load(sys.stdin).get("pool_manager_status",{}).get("running"))')
  [ "$r" = "True" ] && break; sleep 5
done
[ "$r" = "True" ] || fail "GARM org pool manager did not start (App auth via declarative creds failed)"
garm-cli controller update --minimum-job-age-backoff 0 >/dev/null 2>&1 || true
SCALESET_ID=$(garm-cli scaleset add --org "$ORG_ID" --provider-name vmharness \
  --image golden --name "$SCALESET_NAME" --flavor default --enabled \
  --min-idle-runners 0 --max-runners 1 --os-type windows --os-arch amd64 \
  --runner-bootstrap-timeout 30 --format json | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
info "scale set $SCALESET_ID ($SCALESET_NAME) created"

# =========================================================================
# 5. THROUGH-THE-MODULE e2e + NO-STATE-BLEED across two jobs.
# =========================================================================
TEST_REPO="ephemeral-runner-m6-$(date +%Y%m%d-%H%M%S)"
info "creating throwaway repo ${ORG}/${TEST_REPO}"
gh repo create "${ORG}/${TEST_REPO}" --private --description "throwaway M6 e2e (auto-deleted)" >/dev/null
GIT_TOKEN="${GH_TOKEN:-$(gh auth token 2>/dev/null)}"
[ -n "$GIT_TOKEN" ] || fail "no GitHub token for git push"
AUTH_REMOTE="https://x-access-token:${GIT_TOKEN}@github.com/${ORG}/${TEST_REPO}.git"
TMP=$(mktemp -d); git clone -q "$AUTH_REMOTE" "$TMP"
mkdir -p "$TMP/.github/workflows"

# Job 1 writes a marker to C:\ and asserts it was NOT already present (fresh VM).
cat > "$TMP/.github/workflows/bleed1.yml" <<'YML'
name: m6-bleed1
on: { workflow_dispatch: {} }
jobs:
  first:
    runs-on: SCALESET_PLACEHOLDER
    steps:
      - run: |
          if (Test-Path C:\m6-state-bleed-marker.txt) { Write-Error "STATE BLEED: marker already present on a supposedly fresh VM"; exit 1 }
          Set-Content -Path C:\m6-state-bleed-marker.txt -Value "job1 was here"
          hostname
        shell: powershell
YML
# Job 2 (separate run → separate fresh VM) asserts the marker is ABSENT.
cat > "$TMP/.github/workflows/bleed2.yml" <<'YML'
name: m6-bleed2
on: { workflow_dispatch: {} }
jobs:
  second:
    runs-on: SCALESET_PLACEHOLDER
    steps:
      - run: |
          if (Test-Path C:\m6-state-bleed-marker.txt) { Write-Error "STATE BLEED: job1 marker leaked into job2 VM"; exit 1 }
          Write-Output "no state bleed: fresh VM, marker absent"
          hostname
        shell: powershell
YML
sed -i "s/SCALESET_PLACEHOLDER/${SCALESET_NAME}/" "$TMP/.github/workflows/"*.yml
git -C "$TMP" add -A
git -C "$TMP" -c user.email=m6@example.com -c user.name=m6 commit -q -m "m6 e2e + state-bleed"
git -C "$TMP" push -q origin HEAD

# $1 = workflow file (bleed1.yml), $2 = workflow display name (m6-bleed1).
# Robust against transient gh hiccups (empty/non-JSON output) — a poll error
# never aborts; we just retry until the deadline. Uses the run's databaseId so
# we track the exact dispatch, not "the latest run named X".
wait_run() {
  local wf="$1" wfname="$2" deadline concl saw=0 run_id="" disp_ok=0
  # A freshly pushed workflow is not immediately dispatchable — GitHub needs a
  # moment to register it. Retry the DISPATCH itself until it is accepted, then
  # retry resolving the run id (dispatch->run creation also lags).
  for _ in $(seq 1 30); do
    if gh workflow run "$wf" -R "${ORG}/${TEST_REPO}" >/dev/null 2>&1; then disp_ok=1; break; fi
    sleep 6
  done
  [ "$disp_ok" = 1 ] || fail "$wf: could not dispatch the workflow (still not registered on GitHub?)"
  for _ in $(seq 1 30); do
    run_id=$(gh run list -R "${ORG}/${TEST_REPO}" -w "$wfname" --limit 1 --json databaseId 2>/dev/null \
      | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin)
  print(d[0]["databaseId"] if d else "")
except Exception:
  print("")' 2>/dev/null || echo "")
    [ -n "$run_id" ] && break; sleep 6
  done
  [ -n "$run_id" ] || fail "$wf: could not resolve the dispatched run id"
  deadline=$(( $(date +%s) + JOB_TIMEOUT_SECS ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    "$VIRSH" -c "$LIBVIRT_URI" list --name 2>/dev/null | grep -q '^garm-' && saw=1
    concl=$(gh run view "$run_id" -R "${ORG}/${TEST_REPO}" --json status,conclusion 2>/dev/null \
      | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); print(d.get("status","")+"/"+str(d.get("conclusion")))
except Exception:
  print("pending/None")' 2>/dev/null || echo "pending/None")
    case "$concl" in completed/*) break;; esac
    sleep 15
  done
  [ "$saw" = 1 ] || fail "$wf: no ephemeral garm-* VM ever appeared"
  [ "$concl" = "completed/success" ] || fail "$wf did not succeed: $concl"
}

info "JOB 1: fresh VM, write marker (asserts marker absent at start)"
wait_run bleed1.yml m6-bleed1
info "PASS: job 1 ran on a fresh ephemeral VM (via the module unit)"

# The job-1 VM must be destroyed before job 2 (ephemeral teardown).
for _ in $(seq 1 24); do
  "$VIRSH" -c "$LIBVIRT_URI" list --all --name 2>/dev/null | grep -q '^garm-' || break; sleep 5
done
"$VIRSH" -c "$LIBVIRT_URI" list --all --name 2>/dev/null | grep -q '^garm-' && fail "job-1 VM residue before job 2"
ls "$POOL_DIR"/garm-*.overlay.qcow2 2>/dev/null && fail "job-1 overlay residue before job 2"

info "JOB 2: separate fresh VM, assert the job-1 marker is ABSENT (no state bleed)"
wait_run bleed2.yml m6-bleed2
info "PASS: NO STATE BLEED — job-1 marker absent in the fresh job-2 VM"

# Final teardown assertions.
for _ in $(seq 1 24); do
  "$VIRSH" -c "$LIBVIRT_URI" list --all --name 2>/dev/null | grep -q '^garm-' || break; sleep 5
done
"$VIRSH" -c "$LIBVIRT_URI" list --all --name 2>/dev/null | grep -q '^garm-' && fail "VM residue after teardown"
ls "$POOL_DIR"/garm-*.overlay.qcow2 "$POOL_DIR"/garm-*.nvram.fd "$POOL_DIR"/garm-*.config-drive.iso 2>/dev/null \
  && fail "disk residue after teardown"
for _ in $(seq 1 12); do [ "$(gh_garm_runner_count)" = 0 ] && break; sleep 5; done
[ "$(gh_garm_runner_count)" = 0 ] || fail "garm-* runner still registered on GitHub"
info "PASS: VMs destroyed, no residue, runners deregistered"

# =========================================================================
# 6. DOCS/RUNBOOK present.
# =========================================================================
[ -f "$FLAKE/modules/garm/README.md" ] || fail "missing runbook modules/garm/README.md"
for kw in "Relaxations" "Fork-PR" "Network isolation" "Secret management" "Prometheus" "resource guard" "%!s(<nil>)"; do
  grep -qi "$kw" "$FLAKE/modules/garm/README.md" || fail "runbook missing section: $kw"
done
info "PASS: runbook modules/garm/README.md documents posture + security + metrics + guard + log-noise"

echo
echo "[m6][PASS] t_ephemeral_runner_security_and_metrics"
echo "[m6][PASS]   hardened declarative services.garm module ran the libvirt provider e2e"
echo "[m6][PASS]   + no state bleed + metrics served + secrets out of store + guard fires + runbook"
