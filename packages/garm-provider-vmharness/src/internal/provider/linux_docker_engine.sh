# Docker Engine for the Tart Linux runner class (eph-linux-arm64).
#
# Spliced into linuxForegroundRunnerInstallTemplate (provider.go) after the
# runner user exists and before the runner starts. Runs as root and relies on
# the template's `status`/`fail` helpers and $RUNNER_USER.
#
# Why here: the Tart Linux guests boot the plain Cirrus Labs Ubuntu image
# (ghcr.io/cirruslabs/ubuntu:latest), which has no container runtime, and this
# bootstrap is the only per-guest setup the class has. The fleet's rule is that
# container support is universal: every Linux runner can run Docker, so no job
# asks for it with a label. eph-linux-x64 meets it by baking Docker into its
# golden.
#
# What it installs matches the eph-linux-x64 golden (gosti
# guest-recipes/linux-x64-runner/build-runner-image.sh, VMH_RUNNER_DOCKER=1):
# the static Docker 27.5.1 bundle from download.docker.com in /usr/local/bin,
# rootful dockerd + containerd as systemd units, and a docker.socket owned by
# the `docker` group that the runner user joins, so jobs use `docker` without
# sudo. Bump DOCKER_ENGINE_VERSION together with that recipe's default.
#
# One deliberate difference: no daemon.json. The x64 golden forces
# fuse-overlayfs because its dockerd runs in an unprivileged Incus container.
# A Tart guest is a full VM with its own kernel, so dockerd's default driver
# (overlay2) works and is faster.
#
# Docker publishes no checksums for the static bundles, so the sha256 values
# below were taken when the version was pinned (2026-11-17) and make any later
# change to the downloaded bytes fail the bootstrap.
#
# If the image already ships dockerd and docker (a future golden), nothing is
# downloaded: the group membership and the daemon check below still run, so
# this becomes an assertion.
DOCKER_ENGINE_VERSION="27.5.1"
DOCKER_ENGINE_SHA256_AARCH64="e6b53725a73763ab3f988c73f8772eaed429754c1a579db5ff11f21990fd1817"
DOCKER_ENGINE_SHA256_X86_64="4f798b3ee1e0140eab5bf30b0edc4e84f4cdb53255a429dc3bbae9524845d640"

install_docker_engine() {
	local arch sum url tgz
	case "$(uname -m)" in
		aarch64 | arm64)
			arch="aarch64"
			sum="$DOCKER_ENGINE_SHA256_AARCH64"
			;;
		x86_64 | amd64)
			arch="x86_64"
			sum="$DOCKER_ENGINE_SHA256_X86_64"
			;;
		*)
			fail "no pinned Docker Engine bundle for architecture $(uname -m)"
			;;
	esac
	url="https://download.docker.com/linux/static/stable/${arch}/docker-${DOCKER_ENGINE_VERSION}.tgz"
	status "installing Docker Engine ${DOCKER_ENGINE_VERSION}"
	tgz="$(mktemp /tmp/docker-engine.XXXXXX)"
	curl --retry 5 --retry-delay 5 --retry-connrefused --fail -sS -L \
		-o "$tgz" "$url" || fail "failed to download Docker Engine from $url"
	printf '%s  %s\n' "$sum" "$tgz" | sha256sum -c - >/dev/null \
		|| fail "Docker Engine bundle checksum mismatch for $url"
	tar xzf "$tgz" -C /usr/local/bin --strip-components=1 \
		|| fail "failed to extract Docker Engine"
	rm -f "$tgz"

	# dockerd programs iptables for the default bridge network. Ubuntu cloud
	# images ship it; install it only if this one does not.
	if ! command -v iptables >/dev/null 2>&1; then
		{ DEBIAN_FRONTEND=noninteractive apt-get update -qq \
			&& DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables; } >/dev/null \
			|| fail "failed to install iptables for Docker"
	fi

	# The same units as the eph-linux-x64 golden.
	cat >/etc/systemd/system/containerd.service <<'UNIT'
[Unit]
Description=containerd container runtime (static)
After=network.target
[Service]
ExecStart=/usr/local/bin/containerd
Restart=always
Delegate=yes
KillMode=process
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
UNIT
	cat >/etc/systemd/system/docker.socket <<'UNIT'
[Unit]
Description=Docker Socket for the API
[Socket]
ListenStream=/run/docker.sock
SocketMode=0660
SocketUser=root
SocketGroup=docker
[Install]
WantedBy=sockets.target
UNIT
	cat >/etc/systemd/system/docker.service <<'UNIT'
[Unit]
Description=Docker Application Container Engine (static)
After=network-online.target docker.socket containerd.service
Wants=network-online.target
Requires=docker.socket containerd.service
[Service]
Type=notify
ExecStart=/usr/local/bin/dockerd --containerd=/run/containerd/containerd.sock
ExecReload=/bin/kill -s HUP $MAINPID
LimitNOFILE=1048576
Delegate=yes
KillMode=process
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT
}

ensure_docker_engine() {
	local fresh=""
	# The socket unit names the group, so it must exist before the socket starts.
	if ! getent group docker >/dev/null 2>&1; then
		groupadd docker
	fi
	if ! command -v dockerd >/dev/null 2>&1 || ! command -v docker >/dev/null 2>&1; then
		install_docker_engine
		fresh=1
	fi
	# `sudo -u` below initialises the runner's groups from /etc/group when the
	# runner starts, so the membership is in effect for every job step.
	usermod -aG docker "$RUNNER_USER" || fail "failed to add $RUNNER_USER to the docker group"
	if [ -n "$fresh" ]; then
		systemctl daemon-reload || fail "systemctl daemon-reload failed"
		systemctl enable --now containerd.service docker.socket docker.service >/dev/null 2>&1 \
			|| fail "failed to start Docker Engine"
	fi
	local _
	for _ in $(seq 1 60); do
		if sudo -u "$RUNNER_USER" -H docker info >/dev/null 2>&1; then
			return 0
		fi
		sleep 1
	done
	fail "Docker Engine is not reachable by $RUNNER_USER after 60 s"
}

ensure_docker_engine
