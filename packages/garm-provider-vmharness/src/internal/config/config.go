// Copyright 2026 Metacraft Labs
//
//    Licensed under the Apache License, Version 2.0 (the "License"); you may
//    not use this file except in compliance with the License. You may obtain
//    a copy of the License at
//
//         http://www.apache.org/licenses/LICENSE-2.0
//
//    Unless required by applicable law or agreed to in writing, software
//    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
//    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
//    License for the specific language governing permissions and limitations
//    under the License.

// Package config parses the garm-provider-vmharness provider configuration
// file (the path GARM passes via GARM_PROVIDER_CONFIG_FILE). The file is TOML.
//
// The provider is STATELESS: it persists NO lifecycle state. This config only
// tells the provider HOW to reach the backend (which vm-harness/virsh binaries
// to shell to, the libvirt connection URI, the network, and the golden-image
// map that resolves a pool's image/flavor to a concrete libvirt source).
package config

import (
	"fmt"
	"os"
	"strings"

	"github.com/BurntSushi/toml"
)

// BackendKind selects the mechanism the provider uses to drive libvirt.
type BackendKind string

const (
	// BackendLibvirt shells to `virsh` (and, in M2+, `vm-harness`) to manage
	// per-job Windows domains cloned from a golden image.
	BackendLibvirt BackendKind = "libvirt"
	// BackendIncus shells to `incus` to manage per-job Linux SYSTEM
	// CONTAINERS launched from a runner image (the container-based analog of
	// the libvirt path — IM3). Container launch is sub-second and needs no
	// /dev/kvm, so the ephemeral loop (fresh container per job → one job →
	// destroy) is far cheaper than the VM path.
	BackendIncus BackendKind = "incus"
	// BackendTartLinuxArm shells to vm-harness's Tart Linux ARM backend on
	// Apple-silicon macOS hosts.
	BackendTartLinuxArm BackendKind = "tart-linux-arm"
	// BackendTartMacos shells to vm-harness's Tart macOS backend on
	// Apple-silicon macOS hosts.
	BackendTartMacos BackendKind = "tart-macos"
	// BackendUtmWindowsArm shells to vm-harness's UTM Windows ARM backend on
	// Apple-silicon macOS hosts.
	BackendUtmWindowsArm BackendKind = "utm-windows-arm"
	// BackendQemuWindowsArm shells to vm-harness's qemu Windows ARM backend on
	// Apple-silicon macOS hosts.
	BackendQemuWindowsArm BackendKind = "qemu-windows-arm"
	// BackendRemote is the RB1 remote-target mode: instead of exec-ing a LOCAL
	// vm-harness/virsh/incus, the provider is an RPC CLIENT to a remote
	// `vm-harness serve` daemon (RA1 protocol v1) over an authenticated
	// HTTP/JSON endpoint (bearer token, typically bound to a NetBird overlay).
	// The remote daemon runs the SAME vm-harness CLI, so a remote exec of
	// `run --ephemeral --backend <target> …` / `ephemeral-destroy …` is
	// byte-equivalent to the local path. The provider stays STATELESS: it
	// keeps no local lifecycle state and recovers instance/host liveness from
	// the remote serve (its `/v1/info`), never from a local store. See
	// config.RemoteConfig and backend.RemoteBackend.
	BackendRemote BackendKind = "remote"
)

// DefaultAuthTokenEnv is the environment variable the remote-target mode reads
// the bearer token from when neither an inline token nor a token file is set.
// It matches the variable `vm-harness serve` itself documents ($VMH_SERVE_TOKEN),
// so a single per-host secret can be handed to both ends via systemd
// LoadCredential / an EnvironmentFile.
const DefaultAuthTokenEnv = "VMH_SERVE_TOKEN"

// RemoteConfig configures the RB1 remote-target mode ([remote] TOML table). It
// is COMPANY-AGNOSTIC: it names an endpoint + how to obtain the bearer token +
// which vm-harness backend the remote host drives — no Metacraft host or
// credential is baked in. Present (and Backend == "remote") ⇒ the provider is
// an RPC client to `Endpoint` instead of a local-exec backend.
type RemoteConfig struct {
	// Endpoint is the remote `vm-harness serve` address as host:port (the
	// NetBird overlay IP + port the daemon binds). Required in remote mode.
	Endpoint string `toml:"endpoint"`

	// TargetBackend is the vm-harness backend id the REMOTE host drives
	// (eg "incus", "libvirt", "hyperv", "tart-macos", or "noop" for the
	// hermetic gate). It is forwarded verbatim as the remote `--backend` and
	// selects the per-target lifecycle recipe. Required in remote mode.
	TargetBackend string `toml:"target_backend"`

	// AuthToken is the bearer token inline. DISCOURAGED (it lands in the Nix
	// store when set from the module); prefer AuthTokenFile or AuthTokenEnv so
	// the secret is provisioned at runtime via LoadCredential/agenix.
	AuthToken string `toml:"auth_token"`

	// AuthTokenFile is a path the bearer token is read from (first line,
	// whitespace-trimmed). systemd `LoadCredential` / agenix friendly.
	AuthTokenFile string `toml:"auth_token_file"`

	// AuthTokenEnv is the environment variable name the token is read from when
	// AuthToken and AuthTokenFile are both empty. Empty ⇒ DefaultAuthTokenEnv
	// ($VMH_SERVE_TOKEN).
	AuthTokenEnv string `toml:"auth_token_env"`

	// GuestOS is the reported guest OS for instances created through this
	// remote (surfaced in ProviderInstance.os_name when the golden-image map
	// carries none). Defaults to "linux".
	GuestOS string `toml:"guest_os"`

	// RequestTimeoutSec bounds a single non-streaming RPC (eg /v1/info). 0 ⇒ a
	// conservative built-in default. The create/delete streams are NOT bounded
	// here — the remote worker owns the job lifetime (its own --timeout-sec).
	RequestTimeoutSec int `toml:"request_timeout_sec"`

	// IncusSecurityNesting grants the fixed vm-harness nested-container
	// capability to remote Incus guests. It maps only to
	// --incus-security-nesting; callers cannot choose arbitrary Incus config
	// keys. This is trusted provider configuration, never pool tools, workflow
	// input, CreateArgs, bootstrap, or guest-controlled data. Default false
	// preserves the pre-capability remote create argv byte-for-byte.
	IncusSecurityNesting bool `toml:"incus_security_nesting"`

	// IncusNestedKvm grants the fixed vm-harness nested-KVM capability to remote
	// Incus guests. It maps only to --incus-nested-kvm, whose vm-harness
	// implementation attaches the fixed host /dev/kvm -> guest /dev/kvm
	// mapping, verifies exact mode 0666, and opens it read-write. Device paths
	// and modes are deliberately not configurable.
	// Default false preserves the pre-capability remote create argv byte-for-byte.
	IncusNestedKvm bool `toml:"incus_nested_kvm"`

	// IncusLimitsCPU, when > 0, caps every remote Incus per-job container at
	// that many CPUs. It maps only to vm-harness's generic `--cpus <n>` flag,
	// which the Incus ephemeral path turns into `limits.cpu = <n>` before the
	// container's first start. 0 (default) emits nothing, preserving the
	// create argv byte-for-byte. Older vm-harness daemons parse and ignore
	// `--cpus` on this path, so enabling it never breaks a create.
	IncusLimitsCPU int `toml:"incus_limits_cpu"`

	// IncusLimitsMemoryMB, when > 0, caps every remote Incus per-job
	// container's memory, via vm-harness `--memory-mb <n>` ⇒
	// `limits.memory = <n>MiB`. Same rules as IncusLimitsCPU.
	IncusLimitsMemoryMB int `toml:"incus_limits_memory_mb"`
}

// HasIncusLimits reports whether any per-job Incus resource cap is set.
func (r *RemoteConfig) HasIncusLimits() bool {
	return r.IncusLimitsCPU != 0 || r.IncusLimitsMemoryMB != 0
}

// GoldenImage maps a pool label/flavor to a concrete libvirt source.
//
// In M1 the per-job clone is still a vm-harness stub (that lands in M2) and the
// real config-drive injection lands in M3, so these fields are recorded and
// passed to the backend but the backend is free to treat clone/injection as a
// no-op when running against a mock virsh (the hermetic gate path).
type GoldenImage struct {
	// SourceImage is the golden qcow2 (or volume) the per-job domain is cloned
	// from. Consumed by the vm-harness/libvirt clone path (M2).
	SourceImage string `toml:"source_image"`
	// OSName is the reported OS name (eg: "windows"), surfaced in
	// ProviderInstance.os_name.
	OSName string `toml:"os_name"`
	// OSVersion is the reported OS version (eg: "2022").
	OSVersion string `toml:"os_version"`
}

// Config is the parsed provider configuration.
type Config struct {
	// Backend selects the VM management mechanism. Defaults to "libvirt".
	Backend BackendKind `toml:"backend"`

	// VirshPath is the path to the `virsh` binary the provider shells to. The
	// hermetic gate points this at a mock virsh that emulates domain lifecycle
	// without KVM. Defaults to "virsh" (resolved via PATH).
	VirshPath string `toml:"virsh_path"`

	// VMHarnessPath is the path to the `vm-harness` binary used for the per-job
	// clone + config-drive injection. In M1 this is only recorded (the real
	// clone lands in M2, injection in M3); the seam is kept explicit so those
	// milestones can wire it without changing the protocol surface.
	VMHarnessPath string `toml:"vm_harness_path"`

	// QemuImgPath is the path to the `qemu-img` binary used to create the
	// per-job CoW overlay over the golden (M4 clone path). Defaults to
	// "qemu-img" (resolved via PATH).
	QemuImgPath string `toml:"qemu_img_path"`

	// UEFILoader / UEFINVRAMTemplate configure OVMF firmware for the per-job
	// domain (Windows 11 requires UEFI). UEFILoader is the read-only OVMF code
	// firmware (eg /run/libvirt/nix-ovmf/edk2-x86_64-code.fd) and
	// UEFINVRAMTemplate the OVMF vars template that is copied into a per-job
	// writable nvram file. When UEFILoader is empty the domain boots via
	// SeaBIOS (kept so the hermetic M1 mock gate, which never boots a real
	// guest, is unchanged).
	UEFILoader        string `toml:"uefi_loader"`
	UEFINVRAMTemplate string `toml:"uefi_nvram_template"`

	// MemoryMB / VCPUs size the per-job domain. Zero => conservative defaults
	// (4096 MiB / 2 vCPU) applied in the domain-XML builder.
	MemoryMB int `toml:"memory_mb"`
	VCPUs    int `toml:"vcpus"`

	// CurrentMemoryMB is the virtio-balloon boot target (<currentMemory>) for
	// the per-job domain: MemoryMB becomes a ceiling and this the floor the
	// guest starts at, the rest parked in the balloon. Zero (the default, and
	// anything not strictly between 0 and MemoryMB) omits <currentMemory>
	// entirely, leaving the domain XML exactly as it was before. Note this is a
	// request the guest must honour via the virtio-balloon driver, not an
	// enforced cap.
	CurrentMemoryMB int `toml:"current_memory_mb"`

	// LibvirtURI is the libvirt connection URI (eg: "qemu:///system"). Passed
	// to virsh as `-c`.
	LibvirtURI string `toml:"libvirt_uri"`

	// Network is the libvirt network the per-job domains attach to. Recorded
	// for the M2 clone; not required by the M1 protocol gate.
	Network string `toml:"network"`

	// PoolDir is the libvirt image pool directory where per-job artifacts (the
	// CoW overlay + the M3 config-drive ISO) are written. When empty the
	// provider skips config-drive injection (the hermetic M1 gate). On a real
	// host this is typically "/var/lib/libvirt/images".
	PoolDir string `toml:"pool_dir"`

	// Images maps a pool image identifier (BootstrapInstance.Image, typically a
	// label/flavor key) to a concrete golden source. If a pool's image is not
	// present here, the raw image string is used as the source directly.
	Images map[string]GoldenImage `toml:"images"`

	// ---- Incus backend (IM3) -------------------------------------------
	// These fields are consumed only when Backend == "incus". For the incus
	// path a GoldenImage's SourceImage is an incus IMAGE ALIAS (eg
	// "runner-linux") rather than a qcow2 path.

	// IncusPath is the incus binary the provider shells to. Defaults to
	// "incus" (resolved via PATH). GARM runs as root, which can reach the
	// incus-admin socket directly.
	IncusPath string `toml:"incus_path"`

	// IncusBridge is the managed incus bridge the per-job containers attach
	// to (their eth0). Defaults to "incusbr0". Informational — the container
	// inherits it from the default profile — but recorded for clarity.
	IncusBridge string `toml:"incus_bridge"`

	// The incus DHCP server on incusbr0 does not lease on this host (nixos-fw
	// drops the DHCP path), so the provider injects a STATIC IPv4 via
	// cloud-init.network-config. It allocates the lowest free host address in
	// [IncusIPv4RangeStart, IncusIPv4RangeEnd] (full dotted IPs) on the
	// IncusIPv4CIDR subnet, routing default via IncusIPv4Gateway and resolving
	// through IncusNameservers. Egress itself works through incus's existing
	// NAT (no host firewall change); only the lease is worked around here.
	IncusIPv4CIDR       string   `toml:"incus_ipv4_cidr"`
	IncusIPv4Gateway    string   `toml:"incus_ipv4_gateway"`
	IncusIPv4RangeStart string   `toml:"incus_ipv4_range_start"`
	IncusIPv4RangeEnd   string   `toml:"incus_ipv4_range_end"`
	IncusNameservers    []string `toml:"incus_nameservers"`

	// IncusGpuPassthrough, when true, makes the incus backend attach an NVIDIA
	// GPU to every per-job container before start (`incus config device add
	// <name> gpu gpu` + `incus config set <name> nvidia.runtime=true`). Requires
	// the host's nvidia-container-toolkit (CDI runtime) so the GPU + userspace
	// driver are exposed into the container. Backs the `incus-gpu` runner class.
	IncusGpuPassthrough bool `toml:"incus_gpu_passthrough"`

	// IncusShareHostNixStore, when true, wires every per-job container into the
	// HOST's shared /nix/store as a build-farm participant (multi-user-Nix
	// model — build once, cache-hit for every later guest/host):
	//   incus config device add <name> nixstore  disk \
	//     source=/nix/store path=/nix/store readonly=true
	//   incus config device add <name> nixdaemon disk \
	//     source=/nix/var/nix/daemon-socket path=/nix/var/nix/daemon-socket
	// /nix/store is mounted READ-ONLY (the guest reads prebuilt paths directly —
	// instant cache hits — but cannot mutate store bytes). All guest WRITES and
	// BUILDS go through the HOST nix-daemon over the shared socket
	// (NIX_REMOTE=daemon), so a guest-built NOVEL path lands in the shared host
	// store (validated + content-addressed by the daemon) and is a cache hit for
	// later guests. The share is WRITABLE-BY-DESIGN yet SAFE: incus's default
	// idmap shifts guest root to an unprivileged, UNTRUSTED host uid (NOT in nix
	// trusted-users), so the daemon reports Trusted: 0 — the guest can build +
	// add content-addressed paths but CANNOT set substituters/trusted-keys or
	// import unsigned NARs as trusted, and content-addressing means a malicious
	// path hashes differently than anything production resolves (no cache
	// poisoning). Residual risk: disk-DoS, contained by ephemeral guests +
	// store quotas. Backs PM2. Default false ⇒ the container is byte-unchanged.
	// Ignored by non-incus backends.
	IncusShareHostNixStore bool `toml:"incus_share_host_nix_store"`

	// IncusReprobuildStore, when non-empty, is the HOST path of the reprobuild
	// content-addressed store (`repro_local_store`) mounted READ-WRITE into
	// every per-job container before start:
	//   incus config device add <name> reprostore disk \
	//     source=<IncusReprobuildStore> path=<IncusReprobuildStoreGuestPath>
	// The CAS is BLAKE3-content-addressed (hash-on-read), so writes are
	// self-verifying: a guest ADDS content-addressed entries that PERSIST to
	// the shared store for later guests, and CANNOT corrupt an existing entry
	// (a tampered blob hashes to a different digest). A job resolves prebuilt
	// artifacts locally (no HTTP round-trip) by pointing reprobuild at the mount
	// (REPRO_STORE_ROOT=<guest path>). Backs PM3. Empty ⇒ no reprobuild share.
	// Ignored by non-incus backends.
	IncusReprobuildStore string `toml:"incus_reprobuild_store"`

	// IncusReprobuildStoreGuestPath is the in-guest mount point for the
	// reprobuild store share. Empty ⇒ mirrors the host path. Only consulted
	// when IncusReprobuildStore is set.
	IncusReprobuildStoreGuestPath string `toml:"incus_reprobuild_store_guest_path"`

	// IncusSecurityNesting, when true, makes the incus backend enable NESTED
	// containerisation on every per-job container before start so an in-guest
	// Docker/Podman daemon can run (the `runs-on: incus` nested-Docker path —
	// HR1):
	//   incus config set <name> security.nesting true
	//   incus config set <name> security.syscalls.intercept.mknod true
	//   incus config set <name> security.syscalls.intercept.setxattr true
	// security.nesting lets the guest create its own namespaces/cgroups + mount
	// an overlay; the two syscall intercepts let fuse-overlayfs build images
	// UNPRIVILEGED (mknod for device-node image layers, setxattr for
	// overlayfs's trusted.overlay.* xattrs). Default false ⇒ the container is
	// byte-unchanged (the live runners are untouched). Ignored by non-incus
	// backends. Backs HR1.
	IncusSecurityNesting bool `toml:"incus_security_nesting"`

	// IncusNestedKvm, when true, makes the incus backend expose the host
	// `/dev/kvm` into every per-job container and ensure security.nesting=true
	// so an in-guest `qemu-system-* -enable-kvm` gets hardware-accelerated
	// virtualisation (the `runs-on: incus` nested-VM path — HR2):
	//   incus config set <name> security.nesting true
	//   incus config device add <name> kvm unix-char source=/dev/kvm path=/dev/kvm mode=0666
	// The device is world-open only inside this dedicated, ephemeral nested-KVM
	// guest. Without the explicit mode, Incus creates it root-only and the
	// unprivileged GitHub runner cannot use the capability it requested.
	// The host must expose /dev/kvm with nested virtualisation enabled
	// (kvm_intel.nested=Y / kvm_amd.nested=Y). Default false ⇒ the container is
	// byte-unchanged (the live runners are untouched). Ignored by non-incus
	// backends. Backs HR2.
	IncusNestedKvm bool `toml:"incus_nested_kvm"`

	// IncusLimitsCPU, when non-empty, is written verbatim to each per-job
	// container's `limits.cpu` before start:
	//   incus config set <name> limits.cpu <IncusLimitsCPU>
	//
	// Incus accepts either a COUNT ("8") or an explicit CPU SET ("0-7",
	// "0,2,4"). A count is dynamic: incusd picks that many host CPUs (the
	// least loaded ones) and pins the container's cpuset to them, re-balancing
	// as containers come and go. The container's `cpuset.cpus` therefore has N
	// entries, which is what `nproc` (and every build tool that shells to it)
	// reports inside the guest.
	//
	// THAT LAST PROPERTY IS THE POINT, and it is why this is a `limits.cpu`
	// key rather than a `limits.cpu.allowance` one. An uncapped container on a
	// 32-thread host reports 32 to `nproc`, so `make -j$(nproc)` /
	// `cargo build` / `nix build --cores 0` each spawn ~32 runnable compilers.
	// The cap bounds the DEMAND the guest generates, not merely the share it is
	// scheduled at, and it does so without a CFS quota that would idle host
	// CPUs whenever fewer containers than the worst case are running.
	//
	// Empty (the default) sets nothing at all, so a provider that does not want
	// a cap produces a byte-identical container to before this key existed.
	// Ignored by non-incus backends.
	IncusLimitsCPU string `toml:"incus_limits_cpu"`

	// StateDir stores pid/metadata files for vm-harness run based backends
	// (Tart/UTM on m3). It contains no secrets.
	StateDir string `toml:"state_dir"`

	// GuestMetadataURL / GuestCallbackURL optionally override the GARM-provided
	// guest-facing metadata/callback URLs before rendering the bootstrap script.
	// This is useful when one backend needs a different host alias than the
	// service-wide default (for example QEMU user networking's 10.0.2.2 host).
	GuestMetadataURL string `toml:"guest_metadata_url"`
	GuestCallbackURL string `toml:"guest_callback_url"`

	// ---- Remote-target mode (RB1) --------------------------------------
	// Consulted only when Backend == "remote": the endpoint + auth material +
	// remote backend id for the RPC client to a `vm-harness serve` daemon.
	Remote *RemoteConfig `toml:"remote"`
}

// ResolveToken returns the bearer token for the remote endpoint, resolved (in
// priority order) from the inline value, the token file, or the environment
// variable. It is resolved at call time so a runtime-provisioned secret
// (LoadCredential / agenix) is picked up without a config rebuild.
func (r *RemoteConfig) ResolveToken() (string, error) {
	if r.AuthToken != "" {
		return r.AuthToken, nil
	}
	if r.AuthTokenFile != "" {
		data, err := os.ReadFile(r.AuthTokenFile)
		if err != nil {
			return "", fmt.Errorf("reading remote auth_token_file %q: %w", r.AuthTokenFile, err)
		}
		tok := strings.TrimSpace(string(data))
		if tok == "" {
			return "", fmt.Errorf("remote auth_token_file %q is empty", r.AuthTokenFile)
		}
		return tok, nil
	}
	envName := r.AuthTokenEnv
	if envName == "" {
		envName = DefaultAuthTokenEnv
	}
	if tok := strings.TrimSpace(os.Getenv(envName)); tok != "" {
		return tok, nil
	}
	return "", fmt.Errorf("remote-target mode: no bearer token (set auth_token, auth_token_file, or $%s)", envName)
}

// Defaults returns a Config populated with sensible defaults for fields the
// operator did not set.
func (c *Config) applyDefaults() {
	if c.Backend == "" {
		c.Backend = BackendLibvirt
	}
	if c.VirshPath == "" {
		c.VirshPath = "virsh"
	}
	if c.VMHarnessPath == "" {
		c.VMHarnessPath = "vm-harness"
	}
	if c.QemuImgPath == "" {
		c.QemuImgPath = "qemu-img"
	}
	if c.LibvirtURI == "" {
		c.LibvirtURI = "qemu:///system"
	}
	if c.Images == nil {
		c.Images = map[string]GoldenImage{}
	}
	if c.IncusPath == "" {
		c.IncusPath = "incus"
	}
	if c.IncusBridge == "" {
		c.IncusBridge = "incusbr0"
	}
	if len(c.IncusNameservers) == 0 {
		c.IncusNameservers = []string{"1.1.1.1", "8.8.8.8"}
	}
	if c.StateDir == "" {
		c.StateDir = "/var/lib/garm-provider-vmharness"
	}
	if c.Backend == BackendRemote && c.Remote != nil {
		if c.Remote.TargetBackend == "" {
			c.Remote.TargetBackend = string(BackendIncus)
		}
		if c.Remote.AuthTokenEnv == "" {
			c.Remote.AuthTokenEnv = DefaultAuthTokenEnv
		}
		if c.Remote.GuestOS == "" {
			c.Remote.GuestOS = "linux"
		}
	}
}

// Validate returns an error if the config is internally inconsistent.
func (c *Config) Validate() error {
	if c.Remote != nil && (c.Remote.IncusSecurityNesting || c.Remote.IncusNestedKvm) &&
		(c.Backend != BackendRemote || c.Remote.TargetBackend != string(BackendIncus)) {
		return fmt.Errorf("remote Incus capabilities incus_security_nesting/incus_nested_kvm require backend %q with remote.target_backend %q", BackendRemote, BackendIncus)
	}
	if c.Remote != nil && (c.Remote.IncusLimitsCPU < 0 || c.Remote.IncusLimitsMemoryMB < 0) {
		return fmt.Errorf("remote incus_limits_cpu/incus_limits_memory_mb must be >= 0")
	}
	if c.Remote != nil && c.Remote.HasIncusLimits() &&
		(c.Backend != BackendRemote || c.Remote.TargetBackend != string(BackendIncus)) {
		return fmt.Errorf("remote incus_limits_cpu/incus_limits_memory_mb require backend %q with remote.target_backend %q", BackendRemote, BackendIncus)
	}
	switch c.Backend {
	case BackendLibvirt:
	case BackendIncus:
		// Static-IP injection needs a subnet + gateway (DHCP is broken on
		// incusbr0). The range is optional: it defaults to the whole subnet
		// minus the gateway when unset, but a subnet + gateway are required.
		if c.IncusIPv4CIDR == "" || c.IncusIPv4Gateway == "" {
			return fmt.Errorf("backend %q requires incus_ipv4_cidr and incus_ipv4_gateway (incusbr0 DHCP does not lease on this host)", c.Backend)
		}
	case BackendTartLinuxArm, BackendTartMacos, BackendUtmWindowsArm, BackendQemuWindowsArm:
		if c.VMHarnessPath == "" {
			return fmt.Errorf("backend %q requires vm_harness_path", c.Backend)
		}
	case BackendRemote:
		if c.Remote == nil {
			return fmt.Errorf("backend %q requires a [remote] section (endpoint + auth material)", c.Backend)
		}
		if c.Remote.Endpoint == "" {
			return fmt.Errorf("backend %q requires remote.endpoint (host:port of the vm-harness serve daemon)", c.Backend)
		}
		if !strings.Contains(c.Remote.Endpoint, ":") {
			return fmt.Errorf("remote.endpoint %q must be host:port", c.Remote.Endpoint)
		}
		if c.Remote.TargetBackend == "" {
			return fmt.Errorf("backend %q requires remote.target_backend (the vm-harness backend id the remote host drives)", c.Backend)
		}
		// The token is resolved lazily (LoadCredential/agenix at runtime), but
		// at least ONE source must be declared so a misconfiguration fails at
		// parse time rather than on the first CreateInstance.
		if c.Remote.AuthToken == "" && c.Remote.AuthTokenFile == "" {
			envName := c.Remote.AuthTokenEnv
			if envName == "" {
				envName = DefaultAuthTokenEnv
			}
			if strings.TrimSpace(os.Getenv(envName)) == "" {
				return fmt.Errorf("backend %q requires a bearer token (remote.auth_token, remote.auth_token_file, or $%s)", c.Backend, envName)
			}
		}
	default:
		return fmt.Errorf("unsupported backend %q (supported: %q, %q, %q, %q, %q, %q, %q)", c.Backend, BackendLibvirt, BackendIncus, BackendTartLinuxArm, BackendTartMacos, BackendUtmWindowsArm, BackendQemuWindowsArm, BackendRemote)
	}
	return nil
}

// Parse reads and parses the provider config file at path.
func Parse(path string) (*Config, error) {
	var cfg Config
	if _, err := toml.DecodeFile(path, &cfg); err != nil {
		return nil, fmt.Errorf("decoding provider config %q: %w", path, err)
	}
	cfg.applyDefaults()
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	return &cfg, nil
}

// ParseBytes parses provider config from an in-memory TOML blob. Useful for
// tests and for the ValidatePoolInfo command which receives the config path.
func ParseBytes(data []byte) (*Config, error) {
	var cfg Config
	if err := toml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("decoding provider config: %w", err)
	}
	cfg.applyDefaults()
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	return &cfg, nil
}

// ResolveImage returns the golden source + OS metadata for a pool image key.
// If the key is not present in the Images map, the raw key is used as the
// source image directly (with empty OS metadata), which keeps simple single
// image pools configuration-free.
func (c *Config) ResolveImage(image string) GoldenImage {
	if gi, ok := c.Images[image]; ok {
		if gi.SourceImage == "" {
			gi.SourceImage = image
		}
		return gi
	}
	return GoldenImage{SourceImage: image}
}

// mustExist is a small helper used by callers that need to fail fast when the
// config file is missing. GARM's harness already Lstat's the file, but the
// provider double-checks for clearer error messages.
func mustExist(path string) error {
	if _, err := os.Stat(path); err != nil {
		return fmt.Errorf("provider config file %q: %w", path, err)
	}
	return nil
}

var _ = mustExist
