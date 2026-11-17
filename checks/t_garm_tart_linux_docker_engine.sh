#!/usr/bin/env bash
# Runs the Tart Linux runner bootstrap's Docker Engine fragment
# (packages/garm-provider-vmharness/src/internal/provider/linux_docker_engine.sh)
# in a fresh Ubuntu 24.04 system container and proves its contract: the runner
# user, without sudo, can `docker run --rm ubuntu:24.04 true`.
#
# Why a container and not the real guest: eph-linux-arm64 guests are Tart VMs
# on Apple silicon, which a Linux host cannot boot. An Incus system container
# runs the same Ubuntu userland under systemd, which is what the fragment
# drives. It runs the fragment on the HOST's architecture, so on x86_64 it
# downloads the pinned x86_64 bundle; the aarch64 bundle is covered only by its
# checksum here. The container needs security.nesting for dockerd; the Tart VM
# does not. The fragment's `status`/`fail` helpers are stubbed with plain
# echo/exit, since the GARM callback they normally post to is irrelevant to
# what is under test.
#
# Usage: checks/t_garm_tart_linux_docker_engine.sh   (needs incus and network)
# It creates one ephemeral container and deletes only that container.
# On a bridge that hands out no DHCP lease, give the container a static
# address: T_DOCKER_ENGINE_STATIC_IP=10.0.0.247/24 T_DOCKER_ENGINE_GATEWAY=10.0.0.1
# (DNS then goes to T_DOCKER_ENGINE_DNS, default 1.1.1.1).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fragment="${repo_root}/packages/garm-provider-vmharness/src/internal/provider/linux_docker_engine.sh"
image="${T_DOCKER_ENGINE_IMAGE:-images:ubuntu/24.04}"
name="t-tart-docker-$$-${RANDOM}"

fail() {
  echo "t_garm_tart_linux_docker_engine: FAIL: $*" >&2
  exit 1
}
info() { echo "t_garm_tart_linux_docker_engine: $*"; }

command -v incus >/dev/null 2>&1 || fail "incus not found"
[ -f "$fragment" ] || fail "fragment not found: $fragment"

cleanup() { incus delete --force "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT

info "launching ${name} from ${image}"
incus launch "$image" "$name" --ephemeral \
  -c security.nesting=true -c limits.cpu=4 -c limits.memory=8GiB >/dev/null

# Wait for the container's systemd: the fragment drives it with systemctl.
booted=""
for _ in $(seq 1 120); do
  case "$(incus exec "$name" -- systemctl is-system-running 2>/dev/null || true)" in
    running | degraded)
      booted=1
      break
      ;;
  esac
  sleep 1
done
[ -n "$booted" ] || fail "container systemd did not finish booting"
if [ -n "${T_DOCKER_ENGINE_STATIC_IP:-}" ]; then
  info "static egress ${T_DOCKER_ENGINE_STATIC_IP} via ${T_DOCKER_ENGINE_GATEWAY:?set T_DOCKER_ENGINE_GATEWAY too}"
  incus exec "$name" -- sh -c "
    set -e
    ip addr add '${T_DOCKER_ENGINE_STATIC_IP}' dev eth0
    ip route add default via '${T_DOCKER_ENGINE_GATEWAY}'
    mkdir -p /etc/systemd/resolved.conf.d
    printf '[Resolve]\\nDNS=${T_DOCKER_ENGINE_DNS:-1.1.1.1}\\n' >/etc/systemd/resolved.conf.d/90-test.conf
    systemctl restart systemd-resolved
  " || fail "could not configure static egress"
fi
for _ in $(seq 1 60); do
  if incus exec "$name" -- sh -c 'getent hosts download.docker.com' >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
incus exec "$name" -- sh -c 'getent hosts download.docker.com' >/dev/null \
  || fail "container has no DNS/network"

# The runner user as the bootstrap creates it, plus the curl it already needs.
incus exec "$name" -- sh -c '
  set -e
  command -v curl >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates >/dev/null; }
  getent group runner >/dev/null || groupadd runner
  id -u runner >/dev/null 2>&1 || useradd -m -s /bin/bash -g runner runner
'
if incus exec "$name" -- sh -c 'command -v docker' >/dev/null 2>&1; then
  fail "image already has docker; the install path would not be exercised"
fi

harness="$(mktemp)"
trap 'rm -f "$harness"; cleanup' EXIT
{
  cat <<'PRE'
#!/bin/bash
set -e
set -o pipefail
RUNNER_USER=runner
status() { echo "status: $1"; }
fail() { echo "fail: $1" >&2; exit 1; }
start_ns=$(date +%s%N)
PRE
  cat "$fragment"
  cat <<'POST'
echo "DOCKER_ENGINE_SETUP_MS=$(( ($(date +%s%N) - start_ns) / 1000000 ))"
POST
} >"$harness"
incus file push "$harness" "${name}/root/docker-engine.sh" >/dev/null

# A Tart guest runs the bootstrap long after boot, with network-online.target
# reached; docker.service is ordered after it. Reach it here first, so the
# timing below is the fragment's own (with a static address and no DHCP lease,
# systemd-networkd-wait-online would otherwise spend its 120 s timeout inside
# the fragment's `systemctl enable --now`).
t0=$(date +%s)
incus exec "$name" -- systemctl start network-online.target >/dev/null 2>&1 || true
info "network-online.target settled in $(($(date +%s) - t0)) s"

info "running the fragment"
incus exec "$name" -- bash /root/docker-engine.sh || fail "fragment failed"

info "checking the runner user's Docker access"
incus exec "$name" -- id -nG runner | tr ' ' '\n' | grep -qx docker \
  || fail "runner is not in the docker group"
incus exec "$name" -- sudo -u runner -H docker run --rm ubuntu:24.04 true \
  || fail "runner cannot docker run ubuntu:24.04"
incus exec "$name" -- sudo -u runner -H docker info --format '{{.ServerVersion}} {{.Driver}}'

info "re-running the fragment (already-installed path)"
incus exec "$name" -- bash /root/docker-engine.sh || fail "fragment failed on an installed guest"

info "PASS"
