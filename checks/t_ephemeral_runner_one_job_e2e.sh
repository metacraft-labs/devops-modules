#!/usr/bin/env bash
#
# t_ephemeral_runner_one_job_e2e — M4 gate for the Ephemeral-Windows-Runners-GARM
# campaign. Proves ONE queued GitHub job drives the full ephemeral lifecycle:
#
#   GARM (scale-set message queue) sees the queued job
#     -> CreateInstance -> garm-provider-vmharness CoW-clones the Windows golden
#        into a thin overlay + builds a cloudbase-init config-drive carrying
#        GARM's JIT bootstrap + boots a fresh UEFI/OVMF Windows VM
#     -> the guest's cloudbase-init consumes the config-drive, pulls the JIT
#        runner credentials from GARM's metadata endpoint (per-instance JWT),
#        and registers a one-shot --ephemeral runner with REAL GitHub
#     -> the runner executes EXACTLY ONE job (asserted success)
#     -> GARM sees `completed` -> DeleteInstance destroys the VM + overlay +
#        nvram + config-drive (no residue) and the runner is deregistered.
#
# This gate is NOT hermetic: it talks to the REAL GitHub org (set via ORG) using
# a GitHub App and boots a real Windows VM on /dev/kvm. It therefore
# lives as a scripted harness rather than a `nix flake check`. It is
# ISOLATED + SELF-CLEANING: a UNIQUE scale-set name/label + a THROWAWAY test
# repo it creates and deletes; it never touches production runners.
#
# ============================ PREREQUISITES ============================
# Run as root on the libvirt/KVM host, which must have:
#   * /dev/kvm + a reachable qemu:///system libvirtd, with the libvirt
#     "default" NAT network up (virbr0 = 192.168.122.1). The host firewall
#     must let guests reach the host on GARM_PORT (virbr0 trusted iface).
#   * The M3 Windows golden with cloudbase-init + the actions runner staged
#     (set VMH_WIN_GOLDEN to the golden qcow2 path).
#     NOTE: the golden's Windows timezone must be UTC (the provider boots the
#     domain with <clock offset='utc'>; a non-UTC golden needs
#     RealTimeIsUniversal=1 instead, else the runner's JIT/OAuth token is
#     stamped in a skewed clock and GitHub deletes the registration).
#   * OVMF firmware (VMH_OVMF_CODE=/run/libvirt/nix-ovmf/edk2-x86_64-code.fd,
#     VMH_OVMF_VARS=/run/libvirt/nix-ovmf/edk2-i386-vars.fd).
#   * qemu-img, virsh, genisoimage on PATH (genisoimage via nixpkgs#cdrkit).
#   * The GitHub App PEM readable (APP_PEM = the App private-key PEM path), with
#     the App ID / installation / org supplied via env (APP_ID, INSTALLATION_ID,
#     ORG) and the org `Self-hosted runners: Read & write` permission (no webhook
#     needed for scale sets).
#   * `gh` CLI authenticated with repo+admin:org (to create/delete the test repo).
#   * The GARM + garm-provider-vmharness binaries (built from this repo:
#     `nix build .#packages.x86_64-linux.garm .#packages.x86_64-linux.garm-provider-vmharness`)
#     passed via GARM_BIN / GARM_CLI_BIN / PROVIDER_BIN, or on PATH.
#
# ============================ CONFIG (env) ============================
set -euo pipefail

APP_ID="${APP_ID:?set APP_ID (the GitHub App ID)}"
INSTALLATION_ID="${INSTALLATION_ID:?set INSTALLATION_ID (the GitHub App installation ID)}"
APP_PEM="${APP_PEM:?set APP_PEM (path to the GitHub App private-key PEM)}"
ORG="${ORG:?set ORG (the GitHub org)}"
SCALESET_NAME="${SCALESET_NAME:-windows-ephemeral-e2e}"

VMH_WIN_GOLDEN="${VMH_WIN_GOLDEN:?set VMH_WIN_GOLDEN (path to the Windows golden qcow2)}"
VMH_OVMF_CODE="${VMH_OVMF_CODE:-/run/libvirt/nix-ovmf/edk2-x86_64-code.fd}"
VMH_OVMF_VARS="${VMH_OVMF_VARS:-/run/libvirt/nix-ovmf/edk2-i386-vars.fd}"
POOL_DIR="${POOL_DIR:-/var/lib/libvirt/images}"
LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"
GARM_PORT="${GARM_PORT:-9997}"
BRIDGE_IP="${BRIDGE_IP:-192.168.122.1}"

GARM_BIN="${GARM_BIN:-$(command -v garm || true)}"
GARM_CLI_BIN="${GARM_CLI_BIN:-$(command -v garm-cli || true)}"
PROVIDER_BIN="${PROVIDER_BIN:-$(command -v garm-provider-vmharness || true)}"
VIRSH="${VIRSH:-$(command -v virsh)}"
QEMU_IMG="${QEMU_IMG:-$(command -v qemu-img)}"

WORKDIR="${WORKDIR:-/var/lib/garm-m4-gate}"
STATE_URL="http://${BRIDGE_IP}:${GARM_PORT}"
JOB_TIMEOUT_SECS="${JOB_TIMEOUT_SECS:-900}"   # generous: cold Windows boot + register + run

fail() { echo "[e2e][FAIL] $*" >&2; exit 1; }
info() { echo "[e2e] $*"; }

for b in "$GARM_BIN" "$GARM_CLI_BIN" "$PROVIDER_BIN"; do
  [ -n "$b" ] && [ -x "$b" ] || fail "missing binary (set GARM_BIN/GARM_CLI_BIN/PROVIDER_BIN): $b"
done
[ -r "$APP_PEM" ] || fail "cannot read App PEM: $APP_PEM (run as root)"
[ -f "$VMH_WIN_GOLDEN" ] || fail "missing golden: $VMH_WIN_GOLDEN"
command -v genisoimage >/dev/null || fail "genisoimage not on PATH (nix shell nixpkgs#cdrkit)"

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

cleanup() {
  set +e
  info "cleanup…"
  [ -n "${SCALESET_ID:-}" ] && sudo "$GARM_CLI_BIN" scaleset delete "$SCALESET_ID" >/dev/null 2>&1
  [ -n "${ORG_ID:-}" ]      && sudo "$GARM_CLI_BIN" organization delete "$ORG_ID" >/dev/null 2>&1
  sudo "$GARM_CLI_BIN" github credentials delete mcl-app >/dev/null 2>&1
  sudo systemctl stop garm-m4-gate >/dev/null 2>&1
  sudo systemctl reset-failed garm-m4-gate >/dev/null 2>&1
  # destroy any stray gate domains + artifacts
  for d in $(sudo "$VIRSH" -c "$LIBVIRT_URI" list --all --name 2>/dev/null | grep '^garm-' || true); do
    sudo "$VIRSH" -c "$LIBVIRT_URI" destroy "$d" >/dev/null 2>&1
    sudo "$VIRSH" -c "$LIBVIRT_URI" undefine "$d" --nvram >/dev/null 2>&1
  done
  sudo rm -f "$POOL_DIR"/garm-*.overlay.qcow2 "$POOL_DIR"/garm-*.nvram.fd "$POOL_DIR"/garm-*.config-drive.iso 2>/dev/null
  [ -n "${TEST_REPO:-}" ] && gh repo delete "${ORG}/${TEST_REPO}" --yes >/dev/null 2>&1
  sudo rm -rf "$WORKDIR" 2>/dev/null
}
trap cleanup EXIT

# ---- 1. provider + GARM config, start GARM --------------------------------
info "writing provider + GARM config under $WORKDIR"
sudo mkdir -p "$WORKDIR"
sudo tee "$WORKDIR/provider.toml" >/dev/null <<EOF
backend = "libvirt"
virsh_path = "$VIRSH"
qemu_img_path = "$QEMU_IMG"
libvirt_uri = "$LIBVIRT_URI"
network = "default"
pool_dir = "$POOL_DIR"
uefi_loader = "$VMH_OVMF_CODE"
uefi_nvram_template = "$VMH_OVMF_VARS"
memory_mb = 4096
vcpus = 4
[images.golden]
source_image = "$VMH_WIN_GOLDEN"
os_name = "windows"
os_version = "11"
EOF
JWT=$(openssl rand -hex 32); DBP=$(openssl rand -hex 16)
sudo tee "$WORKDIR/garm-config.toml" >/dev/null <<EOF
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
name = "vmharness"
provider_type = "external"
description = "libvirt/KVM Windows ephemeral runners via vm-harness"
  [provider.external]
  provider_executable = "$PROVIDER_BIN"
  config_file = "$WORKDIR/provider.toml"
  interface_version = "v0.1.1"
  environment_variables = ["PATH"]
EOF

info "starting GARM (transient unit garm-m4-gate)"
sudo systemctl reset-failed garm-m4-gate 2>/dev/null || true
sudo systemd-run --unit=garm-m4-gate --collect \
  --setenv=PATH="$(dirname "$QEMU_IMG"):$(dirname "$(command -v genisoimage)"):$PATH" \
  --working-directory="$WORKDIR" \
  "$GARM_BIN" -config "$WORKDIR/garm-config.toml" >/dev/null
until curl -s -o /dev/null "$STATE_URL/api/v1/controller-info"; do sleep 1; done

# ---- 2. init + App creds + org + scale set --------------------------------
info "init GARM + wire the App + org + scale set"
sudo "$GARM_CLI_BIN" init --name m4-gate --url "$STATE_URL" \
  --username admin --email e2e@example.com --full-name "M4 gate" \
  --password 'M4-e2e-Adm!n-pw-2026-xZ' >/dev/null
sudo "$GARM_CLI_BIN" github credentials add --name mcl-app --endpoint github.com \
  --auth-type app --app-id "$APP_ID" --app-installation-id "$INSTALLATION_ID" \
  --private-key-path "$APP_PEM" >/dev/null
ORG_ID=$(sudo "$GARM_CLI_BIN" organization add --name "$ORG" --credentials mcl-app \
  --webhook-secret "$(openssl rand -hex 16)" --format json | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
# pool manager running == GARM authenticated to the org via the App
for _ in $(seq 1 24); do
  r=$(sudo "$GARM_CLI_BIN" organization show "$ORG_ID" --format json | python3 -c 'import sys,json;print(json.load(sys.stdin).get("pool_manager_status",{}).get("running"))')
  [ "$r" = "True" ] && break; sleep 5
done
[ "$r" = "True" ] || fail "GARM org pool manager did not start (App auth failed)"
SCALESET_ID=$(sudo "$GARM_CLI_BIN" scaleset add --org "$ORG_ID" --provider-name vmharness \
  --image golden --name "$SCALESET_NAME" --flavor default --enabled \
  --min-idle-runners 0 --max-runners 1 --os-type windows --os-arch amd64 \
  --runner-bootstrap-timeout 30 --format json | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
info "scale set $SCALESET_ID ($SCALESET_NAME) created"

# ---- 3. throwaway repo + workflow, trigger one job ------------------------
TEST_REPO="ephemeral-runner-e2e-$(date +%Y%m%d-%H%M%S)"
info "creating throwaway repo ${ORG}/${TEST_REPO}"
gh repo create "${ORG}/${TEST_REPO}" --private --description "throwaway M4 e2e (auto-deleted)" >/dev/null
TMP=$(mktemp -d); git clone -q "https://github.com/${ORG}/${TEST_REPO}.git" "$TMP"
mkdir -p "$TMP/.github/workflows"
cat > "$TMP/.github/workflows/e2e.yml" <<YML
name: m4-e2e
on: { workflow_dispatch: {} }
jobs:
  hello:
    runs-on: ${SCALESET_NAME}
    steps:
      - run: |
          echo "hello from ephemeral windows runner"
          hostname
        shell: powershell
YML
git -C "$TMP" add -A
git -C "$TMP" -c user.email=e2e@example.com -c user.name=e2e commit -q -m "m4 e2e"
git -C "$TMP" push -q origin HEAD
gh workflow run e2e.yml -R "${ORG}/${TEST_REPO}" >/dev/null

# ---- 4. assert the create -> run-one -> destroy lifecycle -----------------
info "waiting for the ephemeral job to complete (up to ${JOB_TIMEOUT_SECS}s)…"
saw_instance=0; deadline=$(( $(date +%s) + JOB_TIMEOUT_SECS )); concl=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  # a VM must appear at some point (the fresh clone)
  sudo "$VIRSH" -c "$LIBVIRT_URI" list --name 2>/dev/null | grep -q '^garm-' && saw_instance=1
  concl=$(gh run list -R "${ORG}/${TEST_REPO}" --limit 1 --json status,conclusion \
    | python3 -c 'import sys,json;d=json.load(sys.stdin)[0];print(d["status"]+"/"+str(d.get("conclusion")))')
  case "$concl" in completed/*) break;; esac
  sleep 15
done
[ "$saw_instance" = 1 ] || fail "no ephemeral garm-* VM ever appeared"
[ "$concl" = "completed/success" ] || fail "job did not succeed: $concl"
info "PASS: job completed successfully on a fresh ephemeral VM"

# VM + artifacts must be gone after teardown (GARM DeleteInstance)
for _ in $(seq 1 24); do
  sudo "$VIRSH" -c "$LIBVIRT_URI" list --all --name 2>/dev/null | grep -q '^garm-' || break
  sleep 5
done
sudo "$VIRSH" -c "$LIBVIRT_URI" list --all --name 2>/dev/null | grep -q '^garm-' && fail "VM residue after teardown"
ls "$POOL_DIR"/garm-*.overlay.qcow2 "$POOL_DIR"/garm-*.nvram.fd "$POOL_DIR"/garm-*.config-drive.iso 2>/dev/null \
  && fail "disk residue after teardown"
info "PASS: VM + overlay + nvram + config-drive destroyed (no residue)"

# runner deregistered on GitHub
for _ in $(seq 1 12); do [ "$(gh_garm_runner_count)" = 0 ] && break; sleep 5; done
[ "$(gh_garm_runner_count)" = 0 ] || fail "garm-* runner still registered on GitHub"
info "PASS: runner deregistered on GitHub"

echo "[e2e][PASS] t_ephemeral_runner_one_job_e2e — fresh VM -> JIT -> one job (success) -> destroy, no residue"
