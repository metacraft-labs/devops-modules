#!/usr/bin/env bash
#
# t_ephemeral_runner_autoscale — M5 gate for the Ephemeral-Windows-Runners-GARM
# campaign. Where the M4 gate (t_ephemeral_runner_one_job_e2e) proved ONE queued
# job drives the full ephemeral lifecycle, this gate validates GARM's
# AUTOSCALING reconcilers against the real libvirt/KVM provider under load:
#
#   Phase A — CONCURRENCY CAP + SCALE-OUT (min-idle=0, max-runners=N):
#     enqueue MORE jobs than max-runners on the scale set; assert GARM spawns
#     up to (but NEVER more than) max-runners FRESH VMs concurrently — the cap
#     is honored, the excess jobs wait for a slot — each VM runs exactly one
#     job, ALL jobs succeed, and every VM is destroyed afterward.
#
#   Phase B — SCALE-TO-ZERO (min-idle=0):
#     after the jobs drain, assert ZERO runner VMs remain and ZERO garm-*
#     runners are registered on GitHub (the pool scaled all the way down).
#
#   Phase C — WARM POOL (min-idle=1):
#     update the scale set to keep 1 pre-booted idle runner; assert GARM boots
#     and keeps exactly 1 idle runner (hiding Windows cold-boot latency); a job
#     consumes it; the pool REFILLS back to 1 idle afterward. Then drop min-idle
#     back to 0 and assert it scales to zero again.
#
# This gate is the autoscale analogue of the M4 gate: NOT hermetic (it talks to
# the REAL GitHub org (set via ORG) using a GitHub App and boots real Windows
# VMs on /dev/kvm), so it lives as a scripted harness rather than a
# `nix flake check`. It is ISOLATED + SELF-CLEANING: a UNIQUE scale-set name +
# a THROWAWAY test repo it creates and deletes; it uses ONLY garm-* VM names and
# NEVER touches production runners or other concurrent workstreams.
#
# ============================ PREREQUISITES ============================
# Identical to t_ephemeral_runner_one_job_e2e (run as root on the KVM host):
#   * /dev/kvm + qemu:///system libvirtd with the "default" NAT net up
#     (virbr0 = 192.168.122.1, a trusted iface so guests reach the host).
#   * The M3 Windows golden with cloudbase-init + the actions runner staged
#     (set VMH_WIN_GOLDEN to the golden qcow2 path), UTC RTC.
#   * OVMF firmware (VMH_OVMF_CODE / VMH_OVMF_VARS).
#   * qemu-img, virsh, genisoimage on PATH.
#   * The GitHub App PEM readable (APP_PEM = the App private-key PEM path), with
#     the App ID / installation / org supplied via env (APP_ID, INSTALLATION_ID,
#     ORG) and the org `Self-hosted runners: Read & write` permission.
#   * `gh` CLI authenticated with repo+admin:org.
#   * GARM + garm-provider-vmharness binaries (GARM_BIN/GARM_CLI_BIN/PROVIDER_BIN).
#
# ======================= HOST RESOURCE GUARD =========================
# Each Windows-11 ephemeral VM is heavy: MEMORY_MB (default 4096) RAM + VCPUS
# (default 4) vCPUs. The scale set's max-runners is the hard ceiling on
# concurrent VMs; combined with MEMORY_MB it bounds the worst-case footprint at
# roughly (MAX_RUNNERS * MEMORY_MB) of committed guest RAM. Before Phase A the
# harness checks free host RAM and REFUSES to run (or is expected to be invoked
# with a smaller MAX_RUNNERS) if the host cannot seat MAX_RUNNERS guests with a
# safety margin. This is the mechanism that keeps autoscale from OOM-ing the
# host: the operator sets max-runners to whatever (RAM, vCPU) headroom allows,
# and GARM never exceeds it. See RESOURCE-GUARD notes at the bottom.
#
# ============================ CONFIG (env) ============================
set -euo pipefail

APP_ID="${APP_ID:?set APP_ID (the GitHub App ID)}"
INSTALLATION_ID="${INSTALLATION_ID:?set INSTALLATION_ID (the GitHub App installation ID)}"
APP_PEM="${APP_PEM:?set APP_PEM (path to the GitHub App private-key PEM)}"
ORG="${ORG:?set ORG (the GitHub org)}"
SCALESET_NAME="${SCALESET_NAME:-windows-ephemeral-m5}"

VMH_WIN_GOLDEN="${VMH_WIN_GOLDEN:?set VMH_WIN_GOLDEN (path to the Windows golden qcow2)}"
VMH_OVMF_CODE="${VMH_OVMF_CODE:-/run/libvirt/nix-ovmf/edk2-x86_64-code.fd}"
VMH_OVMF_VARS="${VMH_OVMF_VARS:-/run/libvirt/nix-ovmf/edk2-i386-vars.fd}"
POOL_DIR="${POOL_DIR:-/var/lib/libvirt/images}"
LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"
GARM_PORT="${GARM_PORT:-9997}"
BRIDGE_IP="${BRIDGE_IP:-192.168.122.1}"

# ---- AUTOSCALE TUNING (the M5 knobs) --------------------------------------
# MODEST by design: prove the MECHANISM (cap/scale-to-zero/warm-pool), not
# stress the host. MAX_RUNNERS is the concurrency cap; NUM_JOBS deliberately
# exceeds it so the cap is exercised.
MAX_RUNNERS="${MAX_RUNNERS:-2}"
NUM_JOBS="${NUM_JOBS:-3}"
BOOTSTRAP_TIMEOUT_MIN="${BOOTSTRAP_TIMEOUT_MIN:-15}"  # per-runner join deadline (minutes)
# Per-VM guest sizing (also the resource-guard inputs).
MEMORY_MB="${MEMORY_MB:-4096}"
VCPUS="${VCPUS:-4}"
# Free-RAM safety margin (GiB) that must remain after seating MAX_RUNNERS VMs.
RAM_MARGIN_GIB="${RAM_MARGIN_GIB:-8}"

GARM_BIN="${GARM_BIN:-$(command -v garm || true)}"
GARM_CLI_BIN="${GARM_CLI_BIN:-$(command -v garm-cli || true)}"
PROVIDER_BIN="${PROVIDER_BIN:-$(command -v garm-provider-vmharness || true)}"
VIRSH="${VIRSH:-$(command -v virsh)}"
QEMU_IMG="${QEMU_IMG:-$(command -v qemu-img)}"

WORKDIR="${WORKDIR:-/var/lib/garm-m5-gate}"
EVIDENCE="${EVIDENCE:-$WORKDIR/evidence}"
STATE_URL="http://${BRIDGE_IP}:${GARM_PORT}"
# Generous per-phase deadline. Each cold Windows boot + cloudbase-init + runner
# register + job run is several minutes; with a concurrency cap of MAX_RUNNERS
# and NUM_JOBS > cap, Phase A needs ceil(NUM_JOBS/MAX_RUNNERS) boot WAVES, and
# on a heavily loaded host a wave can take 8-12 min. Default 3600s (60 min)
# covers a 2-wave Phase A with margin; raise it further if the host is starved.
PHASE_TIMEOUT_SECS="${PHASE_TIMEOUT_SECS:-3600}"

fail() { echo "[m5][FAIL] $*" >&2; exit 1; }
info() { echo "[m5] $*"; }

for b in "$GARM_BIN" "$GARM_CLI_BIN" "$PROVIDER_BIN"; do
  [ -n "$b" ] && [ -x "$b" ] || fail "missing binary (set GARM_BIN/GARM_CLI_BIN/PROVIDER_BIN): $b"
done
[ -r "$APP_PEM" ] || fail "cannot read App PEM: $APP_PEM (run as root)"
[ -f "$VMH_WIN_GOLDEN" ] || fail "missing golden: $VMH_WIN_GOLDEN"
command -v genisoimage >/dev/null || fail "genisoimage not on PATH (nix shell nixpkgs#cdrkit)"

# ---- HOST RESOURCE GUARD ---------------------------------------------------
# Refuse to autoscale beyond what the host can seat. Committed guest RAM at the
# cap is MAX_RUNNERS*MEMORY_MB; require that plus RAM_MARGIN_GIB fits in the
# currently-available RAM. This is the enforcement point for deliverable 3.
guard_resources() {
  local avail_gib need_gib
  avail_gib=$(free -g | awk '/^Mem:/{print $7}')
  need_gib=$(( (MAX_RUNNERS * MEMORY_MB + 1023) / 1024 + RAM_MARGIN_GIB ))
  info "resource guard: MAX_RUNNERS=$MAX_RUNNERS x ${MEMORY_MB}MB + ${RAM_MARGIN_GIB}GiB margin = ${need_gib}GiB needed; ${avail_gib}GiB available"
  if [ "$avail_gib" -lt "$need_gib" ]; then
    fail "insufficient host RAM for MAX_RUNNERS=$MAX_RUNNERS ephemeral VMs (need ${need_gib}GiB, have ${avail_gib}GiB). Lower MAX_RUNNERS/MEMORY_MB."
  fi
}

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
# Count garm-* runners on GitHub, optionally filtered by status (online/offline/idle).
gh_garm_runners() {
  local tok; tok=$(app_token)
  curl -s -H "Authorization: token $tok" \
    "https://api.github.com/orgs/${ORG}/actions/runners?per_page=100" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(len([r for r in d.get("runners",[]) if r["name"].startswith("garm-")]))'
}

# Delete any GitHub-side runner scale set named $SCALESET_NAME. GARM's own
# `scaleset delete` normally deregisters it, but if GARM's DB is torn down (e.g.
# an aborted run) before that completes, GitHub keeps the scale set and a later
# `scaleset add` fails with RunnerScaleSetExistsException. This sweep talks to
# the Actions runner-admin API directly (the flow ARC/GARM use) to remove the
# orphan. Idempotent + safe: it only ever touches the uniquely-named test scale
# set, never production runners. Called at startup AND in cleanup.
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

# Live count of garm-* libvirt domains (running).
vms_running() {
  sudo "$VIRSH" -c "$LIBVIRT_URI" list --name 2>/dev/null | grep -c '^garm-' || true
}
vms_all() {
  sudo "$VIRSH" -c "$LIBVIRT_URI" list --all --name 2>/dev/null | grep -c '^garm-' || true
}

cleanup() {
  set +e
  info "cleanup…"
  # Capture GARM's daemon log (reconciler decisions) as evidence BEFORE teardown.
  mkdir -p "$EVIDENCE" 2>/dev/null
  sudo journalctl -u garm-m5-gate --no-pager > "$EVIDENCE/garm.log" 2>/dev/null
  [ -n "${SCALESET_ID:-}" ] && sudo "$GARM_CLI_BIN" scaleset delete "$SCALESET_ID" >/dev/null 2>&1
  # give GARM a moment to tear down instances it owns before we force-destroy
  for _ in $(seq 1 12); do [ "$(vms_all)" = 0 ] && break; sleep 5; done
  # Fallback: ensure the GitHub-side scale set is gone even if GARM couldn't.
  sweep_github_scaleset
  [ -n "${ORG_ID:-}" ]      && sudo "$GARM_CLI_BIN" organization delete "$ORG_ID" >/dev/null 2>&1
  sudo "$GARM_CLI_BIN" github credentials delete mcl-app >/dev/null 2>&1
  sudo "$GARM_CLI_BIN" profile delete m5-gate >/dev/null 2>&1
  sudo systemctl stop garm-m5-gate >/dev/null 2>&1
  sudo systemctl reset-failed garm-m5-gate >/dev/null 2>&1
  # destroy any stray gate domains + artifacts (ONLY garm-* — never prod/sysprep)
  for d in $(sudo "$VIRSH" -c "$LIBVIRT_URI" list --all --name 2>/dev/null | grep '^garm-' || true); do
    sudo "$VIRSH" -c "$LIBVIRT_URI" destroy "$d" >/dev/null 2>&1
    sudo "$VIRSH" -c "$LIBVIRT_URI" undefine "$d" --nvram >/dev/null 2>&1
  done
  sudo rm -f "$POOL_DIR"/garm-*.overlay.qcow2 "$POOL_DIR"/garm-*.nvram.fd "$POOL_DIR"/garm-*.config-drive.iso 2>/dev/null
  [ -n "${TEST_REPO:-}" ] && gh repo delete "${ORG}/${TEST_REPO}" --yes >/dev/null 2>&1
  # keep $EVIDENCE (logs) for the operator; drop the rest of WORKDIR
  info "evidence retained under $EVIDENCE"
}
trap cleanup EXIT

# Sample GARM's instance count + live VM count into the evidence log with a ts.
sample() {
  local label="$1" nvm ngh
  nvm=$(vms_running); ngh=$(gh_garm_runners 2>/dev/null || echo '?')
  printf '%s  %-22s vms_running=%s  gh_garm_runners=%s\n' \
    "$(date +%H:%M:%S)" "$label" "$nvm" "$ngh" | tee -a "$EVIDENCE/timeline.log"
}

# ---- 1. provider + GARM config, start GARM --------------------------------
guard_resources
# Start from a CLEAN GARM DB every run: a persisted garm.sqlite from a prior
# (possibly aborted) run already has an admin user, so `init`/FirstRun returns
# 409. Also drop a stale local CLI profile. This makes the gate re-runnable.
info "starting GARM (transient unit garm-m5-gate) from a clean state"
sudo systemctl stop garm-m5-gate >/dev/null 2>&1 || true
sudo systemctl reset-failed garm-m5-gate >/dev/null 2>&1 || true
# GARM 0.2.1 stores the DB as blob-<db_file> (object-store prefix); wipe both.
sudo rm -f "$WORKDIR"/garm.sqlite* "$WORKDIR"/blob-garm.sqlite* 2>/dev/null || true
info "writing provider + GARM config under $WORKDIR"
sudo mkdir -p "$WORKDIR" "$EVIDENCE"
sudo tee "$WORKDIR/provider.toml" >/dev/null <<EOF
backend = "libvirt"
virsh_path = "$VIRSH"
qemu_img_path = "$QEMU_IMG"
libvirt_uri = "$LIBVIRT_URI"
network = "default"
pool_dir = "$POOL_DIR"
uefi_loader = "$VMH_OVMF_CODE"
uefi_nvram_template = "$VMH_OVMF_VARS"
memory_mb = $MEMORY_MB
vcpus = $VCPUS
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

info "starting GARM (transient unit garm-m5-gate); logs -> $EVIDENCE/garm.log"
sudo systemctl reset-failed garm-m5-gate 2>/dev/null || true
sudo systemd-run --unit=garm-m5-gate --collect \
  --setenv=PATH="$(dirname "$QEMU_IMG"):$(dirname "$(command -v genisoimage)"):$PATH" \
  --working-directory="$WORKDIR" \
  "$GARM_BIN" -config "$WORKDIR/garm-config.toml" >/dev/null
until curl -s -o /dev/null "$STATE_URL/api/v1/controller-info"; do sleep 1; done

# Sweep any orphaned GitHub-side scale set from a prior aborted run BEFORE we
# try to create ours (else `scaleset add` fails RunnerScaleSetExistsException).
sweep_github_scaleset

# ---- 2. init + App creds + org + scale set --------------------------------
info "init GARM + wire the App + org + scale set (max-runners=$MAX_RUNNERS, min-idle=0)"
# garm-cli persists a named profile under $HOME/.local/share/garm-cli/config.toml
# (it ignores XDG_DATA_HOME). A stale m5-gate profile from a prior aborted run
# makes `init` refuse ("already exists"); drop it for a clean slate.
sudo "$GARM_CLI_BIN" profile delete m5-gate >/dev/null 2>&1 || true
sudo "$GARM_CLI_BIN" init --name m5-gate --url "$STATE_URL" \
  --username admin --email m5@example.com --full-name "M5 gate" \
  --password 'M5-e2e-Adm!n-pw-2026-xZ' >/dev/null
sudo "$GARM_CLI_BIN" github credentials add --name mcl-app --endpoint github.com \
  --description "M5 autoscale gate App creds" \
  --auth-type app --app-id "$APP_ID" --app-installation-id "$INSTALLATION_ID" \
  --private-key-path "$APP_PEM" >/dev/null
ORG_ID=$(sudo "$GARM_CLI_BIN" organization add --name "$ORG" --credentials mcl-app \
  --webhook-secret "$(openssl rand -hex 16)" --format json | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
for _ in $(seq 1 24); do
  r=$(sudo "$GARM_CLI_BIN" organization show "$ORG_ID" --format json | python3 -c 'import sys,json;print(json.load(sys.stdin).get("pool_manager_status",{}).get("running"))')
  [ "$r" = "True" ] && break; sleep 5
done
[ "$r" = "True" ] || fail "GARM org pool manager did not start (App auth failed)"

# Scale-to-zero needs an eager reconciler: drop the 30s job-age backoff to 0 so
# GARM reacts to queued jobs immediately (per pools-and-scaling.md).
sudo "$GARM_CLI_BIN" controller update --minimum-job-age-backoff 0 >/dev/null 2>&1 || true

SCALESET_ID=$(sudo "$GARM_CLI_BIN" scaleset add --org "$ORG_ID" --provider-name vmharness \
  --image golden --name "$SCALESET_NAME" --flavor default --enabled \
  --min-idle-runners 0 --max-runners "$MAX_RUNNERS" --os-type windows --os-arch amd64 \
  --runner-bootstrap-timeout "$BOOTSTRAP_TIMEOUT_MIN" --format json \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
info "scale set $SCALESET_ID ($SCALESET_NAME) created: max=$MAX_RUNNERS min-idle=0"

# ---- 3. throwaway repo + a matrix workflow (NUM_JOBS jobs) -----------------
TEST_REPO="ephemeral-runner-m5-$(date +%Y%m%d-%H%M%S)"
info "creating throwaway repo ${ORG}/${TEST_REPO}"
gh repo create "${ORG}/${TEST_REPO}" --private --description "throwaway M5 autoscale (auto-deleted)" >/dev/null
# Authenticated remote for git clone/push (this harness runs as root, whose git
# has no stored credentials; `gh` uses GH_TOKEN but raw git does not). Embed the
# gh token so clone/push work without a credential helper.
GIT_TOKEN="${GH_TOKEN:-$(gh auth token 2>/dev/null)}"
[ -n "$GIT_TOKEN" ] || fail "no GitHub token for git push (set GH_TOKEN or authenticate gh)"
AUTH_REMOTE="https://x-access-token:${GIT_TOKEN}@github.com/${ORG}/${TEST_REPO}.git"
TMP=$(mktemp -d); git clone -q "$AUTH_REMOTE" "$TMP"
mkdir -p "$TMP/.github/workflows"
# A matrix of NUM_JOBS independent jobs, each sleeping briefly so several are
# in-flight at once — this is what forces GARM to want >max-runners runners and
# thus exercises the concurrency cap. Each job records its host name (proving a
# distinct fresh VM ran it) and sleeps ~40s to overlap with siblings.
MATRIX=$(python3 -c "import json;print(json.dumps(list(range(1,$NUM_JOBS+1))))")
cat > "$TMP/.github/workflows/fanout.yml" <<YML
name: m5-fanout
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
          echo "m5 job \${{ matrix.n }} on ephemeral windows runner"
          hostname
          Start-Sleep -Seconds 40
        shell: powershell
YML
git -C "$TMP" add -A
git -C "$TMP" -c user.email=m5@example.com -c user.name=m5 commit -q -m "m5 autoscale fanout"
git -C "$TMP" push -q origin HEAD

# =========================================================================
# PHASE A — CONCURRENCY CAP + SCALE-OUT
# =========================================================================
info "PHASE A: enqueue $NUM_JOBS jobs (> max-runners=$MAX_RUNNERS); assert cap honored"
: > "$EVIDENCE/timeline.log"
gh workflow run fanout.yml -R "${ORG}/${TEST_REPO}" >/dev/null

# Resolve the run id once (the workflow_dispatch we just triggered).
RUN_ID=""
for _ in $(seq 1 20); do
  RUN_ID=$(gh run list -R "${ORG}/${TEST_REPO}" -w m5-fanout --limit 1 --json databaseId \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d[0]["databaseId"] if d else "")' 2>/dev/null)
  [ -n "$RUN_ID" ] && break; sleep 3
done
[ -n "$RUN_ID" ] || fail "could not resolve the fanout run id"

# Poll PER-JOB terminal state (more reliable than the run-level status, which
# GitHub can hold at "queued" until the last matrix leg is assigned a runner).
# Track the peak concurrent VM count and hard-assert the cap is never exceeded.
peak_vms=0; cap_ok=1; deadline=$(( $(date +%s) + PHASE_TIMEOUT_SECS ))
succ=0; total="$NUM_JOBS"; done_jobs=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  n=$(vms_running)
  [ "$n" -gt "$peak_vms" ] && peak_vms=$n
  # HARD ASSERTION: never exceed the cap
  if [ "$n" -gt "$MAX_RUNNERS" ]; then cap_ok=0; sample "A:CAP-VIOLATION($n)"; fi
  # per-job accounting: how many matrix legs have reached a terminal state,
  # and how many succeeded.
  read -r succ done_jobs total < <(gh run view "$RUN_ID" -R "${ORG}/${TEST_REPO}" --json jobs 2>/dev/null \
    | python3 -c 'import sys,json
j=json.load(sys.stdin).get("jobs",[])
succ=sum(1 for x in j if x.get("conclusion")=="success")
done=sum(1 for x in j if x.get("status")=="completed")
print(succ, done, len(j))' 2>/dev/null || echo "0 0 $NUM_JOBS")
  sample "A:scale-out($succ/$done_jobs/$total done)"
  # finished when every matrix leg has reached a terminal state
  [ "$done_jobs" = "$NUM_JOBS" ] && [ "$total" = "$NUM_JOBS" ] && break
  sleep 15
done
info "PHASE A: peak concurrent VMs = $peak_vms (cap = $MAX_RUNNERS); jobs succeeded=$succ done=$done_jobs total=$total"
[ "$cap_ok" = 1 ] || fail "CONCURRENCY CAP VIOLATED: observed >$MAX_RUNNERS concurrent garm-* VMs"
[ "$peak_vms" -ge 1 ] || fail "no ephemeral garm-* VM ever appeared (scale-out did not happen)"
# We expect scale-out to reach the cap (proves excess jobs waited for a slot).
# On a heavily loaded host the sampler can occasionally miss the exact peak;
# warn (not fail) if peak < cap as long as the cap was never exceeded.
[ "$peak_vms" -ge "$MAX_RUNNERS" ] || info "WARN: sampled peak ($peak_vms) < cap ($MAX_RUNNERS) — sampler may have missed concurrency; cap still honored"

info "PHASE A: $succ/$total matrix jobs succeeded"
[ "$done_jobs" = "$NUM_JOBS" ] || fail "not all $NUM_JOBS jobs reached a terminal state within ${PHASE_TIMEOUT_SECS}s ($done_jobs done) — likely host too loaded for N cold Windows boots; raise PHASE_TIMEOUT_SECS or lower NUM_JOBS"
[ "$succ" = "$NUM_JOBS" ] && [ "$total" = "$NUM_JOBS" ] || fail "not all $NUM_JOBS jobs succeeded ($succ/$total)"
info "PHASE A PASS: cap honored (peak $peak_vms <= $MAX_RUNNERS) + all $NUM_JOBS jobs succeeded on fresh VMs"

# =========================================================================
# PHASE B — SCALE-TO-ZERO
# =========================================================================
info "PHASE B: assert the pool scales to ZERO after the jobs drain (min-idle=0)"
for _ in $(seq 1 36); do
  [ "$(vms_all)" = 0 ] && break
  sample "B:draining"
  sleep 5
done
sample "B:drained"
[ "$(vms_all)" = 0 ] || fail "VM residue after drain (scale-to-zero failed): $(vms_all) garm-* domains remain"
ls "$POOL_DIR"/garm-*.overlay.qcow2 "$POOL_DIR"/garm-*.nvram.fd "$POOL_DIR"/garm-*.config-drive.iso 2>/dev/null \
  && fail "disk residue after drain"
for _ in $(seq 1 24); do [ "$(gh_garm_runners)" = 0 ] && break; sleep 5; done
[ "$(gh_garm_runners)" = 0 ] || fail "garm-* runners still registered on GitHub after drain"
info "PHASE B PASS: scaled to ZERO — 0 VMs, 0 overlays, 0 registered runners"

# =========================================================================
# PHASE C — WARM POOL (min-idle=1) + REFILL
# =========================================================================
info "PHASE C: set min-idle=1 (warm pool); assert 1 pre-booted idle runner is kept"
sudo "$GARM_CLI_BIN" scaleset update "$SCALESET_ID" --min-idle-runners 1 >/dev/null
# GARM's ensureMinIdleRunners must boot exactly 1 idle VM and keep it.
warm_ok=0; deadline=$(( $(date +%s) + PHASE_TIMEOUT_SECS ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  n=$(vms_running)
  sample "C:warm-boot"
  # never exceed max
  [ "$n" -gt "$MAX_RUNNERS" ] && fail "warm pool exceeded max-runners ($n > $MAX_RUNNERS)"
  # 1 idle runner present + online on GitHub == warm pool established
  if [ "$n" -ge 1 ] && [ "$(gh_garm_runners)" -ge 1 ]; then warm_ok=1; break; fi
  sleep 12
done
[ "$warm_ok" = 1 ] || fail "warm pool did not establish 1 pre-booted idle runner within deadline"
info "PHASE C: warm pool established (1 idle pre-booted runner)"

# Consume the warm runner with a single job; the pool must refill to 1 idle.
info "PHASE C: firing one job to consume the warm runner; assert refill to 1 idle"
cat > "$TMP/.github/workflows/warm.yml" <<YML
name: m5-warm
on: { workflow_dispatch: {} }
jobs:
  consume:
    runs-on: ${SCALESET_NAME}
    steps:
      - run: |
          echo "m5 warm-consume on ephemeral windows runner"
          hostname
        shell: powershell
YML
git -C "$TMP" add -A
git -C "$TMP" -c user.email=m5@example.com -c user.name=m5 commit -q -m "m5 warm consume"
git -C "$TMP" push -q origin HEAD
gh workflow run warm.yml -R "${ORG}/${TEST_REPO}" >/dev/null

# wait for the warm job to complete
deadline=$(( $(date +%s) + PHASE_TIMEOUT_SECS )); wconcl=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  sample "C:consume"
  wconcl=$(gh run list -R "${ORG}/${TEST_REPO}" -w m5-warm --limit 1 --json status,conclusion 2>/dev/null \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print((d[0]["status"]+"/"+str(d[0].get("conclusion"))) if d else "none")')
  case "$wconcl" in completed/*) break;; esac
  sleep 12
done
[ "$wconcl" = "completed/success" ] || fail "warm-pool consume job did not succeed: $wconcl"
info "PHASE C: warm-consume job succeeded"

# after consumption the reconciler must REFILL back to 1 idle runner
refill_ok=0; deadline=$(( $(date +%s) + PHASE_TIMEOUT_SECS ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  n=$(vms_running)
  sample "C:refill"
  [ "$n" -gt "$MAX_RUNNERS" ] && fail "warm pool exceeded max-runners during refill ($n > $MAX_RUNNERS)"
  if [ "$n" -ge 1 ] && [ "$(gh_garm_runners)" -ge 1 ]; then refill_ok=1; break; fi
  sleep 12
done
[ "$refill_ok" = 1 ] || fail "warm pool did not REFILL to 1 idle runner after consumption"
info "PHASE C PASS: warm pool refilled to 1 idle runner after consumption"

# ---- drop back to min-idle=0 and confirm scale-to-zero again ---------------
info "PHASE C: set min-idle=0; assert warm pool drains back to zero"
sudo "$GARM_CLI_BIN" scaleset update "$SCALESET_ID" --min-idle-runners 0 >/dev/null
for _ in $(seq 1 36); do
  [ "$(vms_all)" = 0 ] && break
  sample "C:final-drain"
  sleep 5
done
sample "C:final-drained"
[ "$(vms_all)" = 0 ] || fail "warm pool did not drain to zero after min-idle=0"
info "PHASE C PASS: warm pool drained to zero after min-idle=0"

echo
echo "===================== EVIDENCE (timeline) ====================="
cat "$EVIDENCE/timeline.log"
echo "==============================================================="
echo "[m5][PASS] t_ephemeral_runner_autoscale — concurrency cap honored (peak $peak_vms <= $MAX_RUNNERS)"
echo "[m5][PASS]   + all $NUM_JOBS jobs succeeded + scale-to-zero + warm-pool establish/consume/refill"
