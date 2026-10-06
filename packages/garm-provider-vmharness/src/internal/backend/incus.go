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

package backend

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"

	garmErrors "github.com/cloudbase/garm-provider-common/errors"
)

// IncusBackend shells to the `incus` CLI to drive per-job Linux SYSTEM
// CONTAINERS — the container-based analog of VirshBackend (IM3). It is the
// same STATELESS shape: the provider holds no lifecycle state; every query
// (GetInstance/ListInstances) is recomputed from the daemon, and the
// GARM identity (controller/pool/name/os) is carried entirely in the
// container's `user.garm.*` config keys (the incus analog of libvirt's
// <metadata> tags), never in a provider-owned store.
//
// Create lifecycle (mirrors the IM2 gate's proven init → inject → start
// order so cloud-init consumes the injected user-data on FIRST boot):
//
//	incus init <image> <name>                     # create, stopped
//	incus config set <name> user.garm.* ...       # stateless identity tags
//	incus config set <name> cloud-init.user-data  # GARM's Linux JIT bootstrap
//	incus config set <name> cloud-init.network-config  # static IPv4 (no DHCP)
//	incus start <name>                            # cloud-init runs the bootstrap
//
// Delete is ORDERED (see the Delete doc comment for the measurement that
// motivates it): stop and wait for `Stopped`, detach the devices Create
// attached, then `incus delete`, with a short bounded local retry and a
// `--force` last resort. Idempotent: a missing container is success.
type IncusBackend struct {
	// IncusCmd is the incus invocation vector, eg ["incus"] or
	// ["sudo","-n","incus"]. Built from config.IncusPath (whitespace-split)
	// so a session that pre-dates the incus-admin group grant can still run
	// via sudo; production (GARM as root) uses a plain ["incus"].
	IncusCmd []string
	// Bridge is the managed incus bridge the containers attach to (recorded;
	// the default profile provides eth0).
	Bridge string
	// Static-IPv4 injection parameters (incusbr0 DHCP does not lease on this
	// host). CIDR is the subnet in a.b.c.d/nn form; Gateway the default route;
	// RangeStart/RangeEnd bound the allocatable host addresses (inclusive,
	// dotted); Nameservers the resolvers written into the netplan.
	IPv4CIDR    string
	IPv4Gateway string
	RangeStart  string
	RangeEnd    string
	Nameservers []string
	// IPAllocationLockPath overrides the host-wide lease lock path. Production
	// leaves this empty so every provider subprocess on the host shares the
	// default lock. Tests may point it at an isolated temporary directory.
	IPAllocationLockPath string
	// GpuPassthrough, when true, gives each per-job container a working SHARED
	// NVIDIA GPU userspace before start — the container's `nvidia-smi`/CUDA see
	// the host's GPU(s) WHILE the host keeps using them (cooperative), with no
	// driver-version coupling. Backs the `incus-gpu` class.
	//
	// The recipe is NOT `nvidia.runtime=true` + the nvidia-container-toolkit
	// CDI: incus-lts (6.0.6) has NO CDI (CDI is LXD-only) and its `nvidia.runtime`
	// lxc hook does NOT inject the userspace on a NixOS host (NVIDIA_VISIBLE_DEVICES
	// stays `none`). What works (proven live on gpu-server-001 — guest lists both
	// RTX 3090s while the host uses them) is:
	//
	//   * `incus config device add <name> gpu gpu` — shares the host /dev/nvidia*
	//     char devices cooperatively (the host never loses the GPU).
	//   * mount the host `/nix/store` READ-ONLY (unless ShareHostNixStore already
	//     did) so the Nix-ELF loader resolves and the driver `.so`s (referenced by
	//     absolute /nix/store paths behind the /run/opengl-driver symlinks) load.
	//   * set `environment.LD_LIBRARY_PATH` to the host `/run/opengl-driver/lib`
	//     RESOLVED to its /nix/store target (so `libcuda.so.1` etc. resolve via the
	//     mounted store), and prepend the host `nvidia-smi`'s store bin dir to
	//     `environment.PATH`. Both are resolved on the HOST at Create time, so the
	//     recipe follows whatever driver the current system provides.
	//
	// NB: we do NOT bind-mount /run/opengl-driver itself — it is a symlink into
	// the /nix ZFS dataset and incus mounts the dataset root, not the subpath, so
	// the mount is unusable. The full /nix/store mount + the resolved LD_LIBRARY_PATH
	// is what makes the driver libs resolve.
	GpuPassthrough bool
	// ShareHostNixStore, when true, wires each per-job container into the
	// HOST's shared `/nix/store` as a build-farm participant (the multi-user
	// Nix model — build once, cache-hit for every later guest/host). The share
	// is WRITABLE-BY-DESIGN but SAFE:
	//
	//   * /nix/store is mounted READ-ONLY (the guest sees every prebuilt path
	//     directly — instant cache hits — but its raw filesystem bytes are
	//     immutable from the guest).
	//   * the host nix-daemon socket dir (/nix/var/nix/daemon-socket) is
	//     mounted so the guest can reach the host daemon; all guest WRITES and
	//     BUILDS go THROUGH that daemon (NIX_REMOTE=daemon), which runs on the
	//     host with write access, content-addresses/validates every added path,
	//     and builds derivations in its own sandbox. A guest-built novel path
	//     lands in the shared host store and is a cache hit for later guests.
	//   * the guest's daemon user is UNTRUSTED: incus's default idmap shifts
	//     container root to an unprivileged host uid (base 1_000_000) that is
	//     NOT in nix `trusted-users`, so the daemon reports Trusted: 0. The
	//     guest can build + add content-addressed paths but CANNOT set
	//     substituters/trusted-keys or import unsigned NARs as trusted, and a
	//     malicious path content-addresses to a different hash than anything
	//     production resolves — no cache poisoning.
	//
	// The nix DB itself is served by the daemon (over the socket) — the guest
	// never touches /nix/var/nix/db directly. Residual risk is disk-DoS (a
	// guest filling the store), contained by ephemeral one-job guests + store
	// quotas. Backs PM2 (shared nix store). Default false ⇒ byte-unchanged.
	ShareHostNixStore bool
	// ReprobuildStore, when non-empty, is the HOST reprobuild content-addressed
	// store path mounted READ-WRITE into each per-job container. The CAS is
	// BLAKE3-content-addressed, so writes are self-verifying: a guest ADDS
	// content-addressed entries (which persist to the shared store for later
	// guests) but CANNOT corrupt an existing entry (a tampered blob hashes to a
	// different digest). Backs PM3 (shared reprobuild store).
	ReprobuildStore string
	// ReprobuildStoreGuestPath is the in-guest mount point for ReprobuildStore.
	// Empty ⇒ mirrors the host path.
	ReprobuildStoreGuestPath string
	// SecurityNesting, when true, enables NESTED containerisation inside each
	// per-job container so an in-guest Docker/Podman daemon can run (the
	// `runs-on: incus` docker path — HR1). Before start it sets
	// `security.nesting=true` (lets the guest create its own
	// namespaces/cgroups + mount an overlay) plus the two syscall intercepts
	// fuse-overlayfs needs to build images UNPRIVILEGED —
	// `security.syscalls.intercept.mknod=true` (the daemon can mknod device
	// nodes the image layers carry) and `security.syscalls.intercept.setxattr=true`
	// (overlayfs writes trusted.overlay.* xattrs). Default false ⇒ the
	// container is byte-unchanged (the live runners are untouched).
	SecurityNesting bool
	// NestedKvm, when true, enables NESTED HARDWARE VIRTUALISATION (KVM)
	// inside each per-job container so an in-guest `qemu-system-* -enable-kvm`
	// can boot an accelerated VM (the `runs-on: incus` nested-KVM path — HR2).
	// Before start it adds the host `/dev/kvm` character device to the
	// container (`incus config device add <name> kvm unix-char
	// source=/dev/kvm path=/dev/kvm`, so the guest sees `/dev/kvm` and can
	// open it) AND ensures `security.nesting=true` (an unprivileged nested
	// container needs the nesting seam to let the in-guest hypervisor create
	// its own namespaces/mounts around the accelerated guest). The host must
	// itself expose `/dev/kvm` with nested virtualisation enabled
	// (`kvm_intel.nested=Y` / `kvm_amd.nested=Y`). Default false ⇒ the
	// container is byte-unchanged (the live runners are untouched).
	NestedKvm bool
	// LimitsCPU, when non-empty, is written verbatim to each per-job
	// container's `limits.cpu` BEFORE start (a count like "8", or an explicit
	// set like "0-7"). Incus turns a count into a dynamic cpuset pin, so the
	// guest's `cpuset.cpus` — and therefore its `nproc` — reports that many
	// CPUs and build tools that self-size from `nproc` stop spawning one job
	// per HOST thread. Default "" ⇒ nothing is set and the container is
	// byte-unchanged (the live runners are untouched).
	LimitsCPU string
	// StopSettleTimeout / DeleteRetryBackoff override the ORDERED teardown's
	// timings (see Delete). Zero means the package defaults
	// (incusStopSettleTimeout / incusDeleteBackoffBase). Production leaves
	// both zero; tests shrink them so the retry ladder is exercised without
	// sleeping through it — the same seam IPAllocationLockPath provides for
	// the IP lease lock.
	StopSettleTimeout  time.Duration
	DeleteRetryBackoff time.Duration
}

func (b *IncusBackend) stopSettleTimeout() time.Duration {
	if b.StopSettleTimeout > 0 {
		return b.StopSettleTimeout
	}
	return incusStopSettleTimeout
}

func (b *IncusBackend) deleteRetryBackoff() time.Duration {
	if b.DeleteRetryBackoff > 0 {
		return b.DeleteRetryBackoff
	}
	return incusDeleteBackoffBase
}

// Host paths shared into the per-job container when ShareHostNixStore is set:
// the content-addressed store (READ-ONLY — the guest reads prebuilt paths
// directly) and the nix-daemon socket directory (so the guest routes all
// WRITES/builds through the host daemon, which validates + content-addresses
// every add). The guest never touches the nix DB directly — the daemon owns it.
const (
	hostNixStorePath        = "/nix/store"
	hostNixDaemonSocketPath = "/nix/var/nix/daemon-socket"
	hostNixClientPath       = "/run/current-system/sw/bin/nix"
	incusIPAllocationLock   = "/tmp/garm-provider-vmharness-incus-ip-allocation.lock"
)

// resolveHostNixBinDir resolves the host's system Nix client into its immutable
// store directory. Containers with ShareHostNixStore can execute that binary
// through the read-only /nix/store mount; /run/current-system itself is not
// shared into the guest. Refuse to create a nominally shared-store runner if
// the host client cannot be resolved into the store it actually shares.
func resolveHostNixBinDir() (string, error) {
	resolved, err := filepath.EvalSymlinks(hostNixClientPath)
	if err != nil {
		return "", fmt.Errorf("resolve host Nix client %s: %w", hostNixClientPath, err)
	}
	if !strings.HasPrefix(resolved, hostNixStorePath+"/") {
		return "", fmt.Errorf("host Nix client %s resolved outside %s: %s", hostNixClientPath, hostNixStorePath, resolved)
	}
	return filepath.Dir(resolved), nil
}

// Host GPU userspace anchors for the `incus-gpu` shared-GPU recipe. Both are
// stable NixOS host conventions resolved on the HOST at Create time (no
// driver-version coupling): hostOpenGLDriver/lib holds the driver .so symlinks
// (libcuda.so.1, …) and hostNvidiaSmi is the host nvidia-smi launcher. The
// container reaches the resolved /nix/store targets through the read-only
// /nix/store mount, so no per-driver paths are hardcoded.
const (
	hostOpenGLDriver = "/run/opengl-driver"
	hostNvidiaSmi    = "/run/current-system/sw/bin/nvidia-smi"
)

// gpuGuestPath is the fallback container PATH the GPU env prepends the host
// nvidia-smi bin dir onto (a standard Debian PATH; the image's own PATH is
// replaced by incus's environment.PATH so it must include the usual dirs).
const gpuGuestPath = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

// resolveHostGpuUserspace resolves, on the HOST, the driver library dir and the
// nvidia-smi bin dir the guest needs for a working shared GPU. Each falls back
// to the literal (unresolved) path when the symlink cannot be resolved (e.g. a
// non-GPU host, or the hermetic sandbox where /run is absent) so Create never
// hard-fails and the emitted config stays deterministic for the unit test.
func resolveHostGpuUserspace() (ldLibraryPath, nvidiaSmiBinDir string) {
	ldLibraryPath = filepath.Join(hostOpenGLDriver, "lib")
	if resolved, err := filepath.EvalSymlinks(hostOpenGLDriver); err == nil {
		ldLibraryPath = filepath.Join(resolved, "lib")
	}
	nvidiaSmiBinDir = filepath.Dir(hostNvidiaSmi)
	if resolved, err := filepath.EvalSymlinks(hostNvidiaSmi); err == nil {
		nvidiaSmiBinDir = filepath.Dir(resolved)
	}
	return ldLibraryPath, nvidiaSmiBinDir
}

// incusMetaPrefix namespaces the provider's stateless identity config keys.
const incusMetaPrefix = "user.garm."

// incusContainer is the slice of `incus list --format json` the backend reads.
type incusContainer struct {
	Name   string            `json:"name"`
	Status string            `json:"status"`
	Config map[string]string `json:"config"`
	// Devices is the container's device map as incusd reports it. Only the
	// device NAMES are used (to detach exactly the devices this provider
	// attached, and only if they are still present), so the inner map is left
	// untyped.
	Devices map[string]map[string]string `json:"devices"`
	State   *struct {
		Network map[string]struct {
			Addresses []struct {
				Family  string `json:"family"`
				Address string `json:"address"`
			} `json:"addresses"`
		} `json:"network"`
	} `json:"state"`
}

// run executes incus with the given args, returning combined stdout+stderr.
func (b *IncusBackend) run(ctx context.Context, stdin string, args ...string) (string, error) {
	full := append(append([]string{}, b.IncusCmd[1:]...), args...)
	cmd := exec.CommandContext(ctx, b.IncusCmd[0], full...)
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	err := cmd.Run()
	if err != nil {
		return out.String(), fmt.Errorf("incus %s: %w: %s",
			strings.Join(args, " "), err, strings.TrimSpace(out.String()))
	}
	return out.String(), nil
}

// listContainers returns the parsed `incus list --format json` view. When
// filter is non-empty it is passed as an incus name filter.
func (b *IncusBackend) listContainers(ctx context.Context, filter string) ([]incusContainer, error) {
	args := []string{"list"}
	if filter != "" {
		args = append(args, filter)
	}
	args = append(args, "--format", "json")
	out, err := b.run(ctx, "", args...)
	if err != nil {
		return nil, err
	}
	var cs []incusContainer
	if uerr := json.Unmarshal([]byte(strings.TrimSpace(out)), &cs); uerr != nil {
		return nil, fmt.Errorf("parsing incus list json: %w", uerr)
	}
	return cs, nil
}

// findExact returns the container with exactly this name, or ErrNotFound.
func (b *IncusBackend) findExact(ctx context.Context, name string) (incusContainer, error) {
	cs, err := b.listContainers(ctx, name)
	if err != nil {
		return incusContainer{}, err
	}
	for _, c := range cs {
		if c.Name == name {
			return c, nil
		}
	}
	return incusContainer{}, garmErrors.ErrNotFound
}

// toInstance maps an incusContainer to the provider's stateless Instance,
// recovering identity from the user.garm.* config keys.
func toInstance(c incusContainer) Instance {
	inst := Instance{
		ProviderID:   c.Name,
		Name:         c.Name,
		ControllerID: c.Config[incusMetaPrefix+"controller_id"],
		PoolID:       c.Config[incusMetaPrefix+"pool_id"],
		OSName:       c.Config[incusMetaPrefix+"os_name"],
		OSVersion:    c.Config[incusMetaPrefix+"os_version"],
		Status:       mapIncusStatus(c.Status),
	}
	if n := c.Config[incusMetaPrefix+"name"]; n != "" {
		inst.Name = n
	}
	if c.State != nil {
		for _, nw := range c.State.Network {
			for _, a := range nw.Addresses {
				if a.Family == "inet" && a.Address != "" {
					inst.Addresses = append(inst.Addresses, a.Address)
				}
			}
		}
	}
	return inst
}

func mapIncusStatus(s string) string {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "running":
		return "running"
	default:
		return "stopped"
	}
}

// allocateIPv4 picks the lowest free host address in [RangeStart, RangeEnd]
// that is not already assigned to a garm-tagged container (user.garm.ipv4).
// This keeps concurrent per-job containers on distinct static IPs even though
// incusbr0 DHCP does not lease.
func (b *IncusBackend) allocateIPv4(ctx context.Context) (string, error) {
	start := net.ParseIP(b.RangeStart).To4()
	end := net.ParseIP(b.RangeEnd).To4()
	if start == nil || end == nil {
		return "", fmt.Errorf("invalid incus ipv4 range: %q-%q", b.RangeStart, b.RangeEnd)
	}
	cs, err := b.listContainers(ctx, "")
	if err != nil {
		return "", err
	}
	used := map[string]bool{}
	for _, c := range cs {
		if ip := c.Config[incusMetaPrefix+"ipv4"]; ip != "" {
			used[ip] = true
		}
	}
	for ip := ipv4ToUint(start); ip <= ipv4ToUint(end); ip++ {
		cand := uintToIPv4(ip).String()
		if !used[cand] {
			return cand, nil
		}
	}
	return "", fmt.Errorf("no free static IPv4 in range %s-%s", b.RangeStart, b.RangeEnd)
}

// acquireIPAllocationLock serialises only the non-atomic Incus lease window:
// list existing user.garm.ipv4 tags, select an address, create the container,
// and publish its tag. GARM invokes external-provider requests in separate
// processes, so an in-process mutex cannot prevent two concurrent Creates
// from observing the same free address. A host filesystem lock can.
func (b *IncusBackend) acquireIPAllocationLock() (*os.File, error) {
	path := b.IPAllocationLockPath
	if path == "" {
		path = incusIPAllocationLock
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open incus IPv4 allocation lock %s: %w", path, err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		_ = f.Close()
		return nil, fmt.Errorf("lock incus IPv4 allocation lock %s: %w", path, err)
	}
	return f, nil
}

func releaseIPAllocationLock(f *os.File) {
	if f == nil {
		return
	}
	_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	_ = f.Close()
}

func ipv4ToUint(ip net.IP) uint32 {
	ip = ip.To4()
	return uint32(ip[0])<<24 | uint32(ip[1])<<16 | uint32(ip[2])<<8 | uint32(ip[3])
}

func uintToIPv4(v uint32) net.IP {
	return net.IPv4(byte(v>>24), byte(v>>16), byte(v>>8), byte(v))
}

// prefixLen extracts the /nn prefix length from the configured CIDR.
func (b *IncusBackend) prefixLen() int {
	if i := strings.LastIndex(b.IPv4CIDR, "/"); i >= 0 {
		var n int
		fmt.Sscanf(b.IPv4CIDR[i+1:], "%d", &n)
		return n
	}
	return 24
}

// networkConfig renders a cloud-init v2 network-config assigning the static
// IPv4 (cloud-init applies this before user-data runs). Egress works through
// incus's existing NAT; this only replaces the broken DHCP lease.
func (b *IncusBackend) networkConfig(ip string) string {
	var ns strings.Builder
	for i, s := range b.Nameservers {
		if i > 0 {
			ns.WriteString(", ")
		}
		ns.WriteString(s)
	}
	// NOTE: use `to: 0.0.0.0/0` (not `to: default`) — the Debian-12 cloud
	// image's cloud-init/netplan rejects the `default` keyword, which silently
	// fails the WHOLE network-config (the container comes up with no IP).
	return fmt.Sprintf(`version: 2
ethernets:
  eth0:
    dhcp4: false
    addresses: [%s/%d]
    routes:
      - to: 0.0.0.0/0
        via: %s
    nameservers:
      addresses: [%s]
`, ip, b.prefixLen(), b.IPv4Gateway, ns.String())
}

// Create materialises ONE fresh per-job container from the runner image,
// tags it with the stateless identity, injects the GARM JIT bootstrap +
// a static IPv4 via cloud-init, and starts it. Rolls back on any failure.
func (b *IncusBackend) Create(ctx context.Context, args CreateArgs) (Instance, error) {
	if args.SourceImage == "" {
		return Instance{}, fmt.Errorf("incus Create: SourceImage (image alias) is required")
	}
	leaseLock, err := b.acquireIPAllocationLock()
	if err != nil {
		return Instance{}, err
	}
	leaseLockHeld := true
	defer func() {
		if leaseLockHeld {
			releaseIPAllocationLock(leaseLock)
		}
	}()

	ip, err := b.allocateIPv4(ctx)
	if err != nil {
		return Instance{}, err
	}

	// 1. create the container (stopped) so config can be injected pre-boot.
	if out, err := b.run(ctx, "", "init", args.SourceImage, args.Name); err != nil {
		return Instance{}, fmt.Errorf("incus init %s %s: %w: %s",
			args.SourceImage, args.Name, err, strings.TrimSpace(out))
	}

	// 2. stateless identity tags (recovered by Get/List).
	meta := map[string]string{
		incusMetaPrefix + "controller_id": args.ControllerID,
		incusMetaPrefix + "pool_id":       args.PoolID,
		incusMetaPrefix + "name":          args.Name,
		incusMetaPrefix + "os_name":       args.OSName,
		incusMetaPrefix + "os_version":    args.OSVersion,
		incusMetaPrefix + "ipv4":          ip,
	}
	// sort keys for deterministic ordering (tests / logs).
	keys := make([]string, 0, len(meta))
	for k := range meta {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		if meta[k] == "" {
			continue
		}
		if out, err := b.run(ctx, "", "config", "set", args.Name, k, meta[k]); err != nil {
			_ = b.forceDelete(ctx, args.Name)
			return Instance{}, fmt.Errorf("incus config set %s: %w: %s", k, err, strings.TrimSpace(out))
		}
	}
	// The selected address is visible to every other provider process now.
	// Release before cloud-init/device setup and start so the expensive parts
	// of independent runner launches still happen concurrently.
	releaseIPAllocationLock(leaseLock)
	leaseLockHeld = false

	// 3. static IPv4 (DHCP does not lease on incusbr0).
	if out, err := b.run(ctx, b.networkConfig(ip), "config", "set", args.Name, "cloud-init.network-config", "-"); err != nil {
		_ = b.forceDelete(ctx, args.Name)
		return Instance{}, fmt.Errorf("incus config set cloud-init.network-config: %w: %s", err, strings.TrimSpace(out))
	}

	// 4. the GARM Linux JIT bootstrap as cloud-init user-data (the injection
	//    seam). When absent (hermetic paths) the container still boots clean.
	if len(args.Bootstrap) > 0 {
		if out, err := b.run(ctx, string(args.Bootstrap), "config", "set", args.Name, "cloud-init.user-data", "-"); err != nil {
			_ = b.forceDelete(ctx, args.Name)
			return Instance{}, fmt.Errorf("incus config set cloud-init.user-data: %w: %s", err, strings.TrimSpace(out))
		}
	}

	// 4b. Shared GPU userspace (the `incus-gpu` class). Give the container a
	//     working NVIDIA userspace that COMPOSES with the host's own use of the
	//     GPU (cooperative — the host never loses it) and has no driver-version
	//     coupling. This is NOT `nvidia.runtime=true` (incus-lts has no CDI and
	//     its lxc hook does not inject the userspace on NixOS — see the struct
	//     doc); it is the /dev/nvidia* share + the /nix/store mount + the driver
	//     LD_LIBRARY_PATH + nvidia-smi on PATH, all resolved on the host. Done
	//     pre-start so the devices+env are present on first boot.
	if b.GpuPassthrough {
		// Share the host /dev/nvidia* char devices cooperatively. `gputype:
		// physical` is incus's default for a `gpu` device and covers the
		// whole-GPU cooperative share this class needs.
		if out, err := b.run(ctx, "", "config", "device", "add", args.Name, "gpu", "gpu"); err != nil {
			_ = b.forceDelete(ctx, args.Name)
			return Instance{}, fmt.Errorf("incus config device add gpu: %w: %s", err, strings.TrimSpace(out))
		}
		// The host /nix/store READ-ONLY so the Nix-ELF loader + the driver .so
		// files (referenced by absolute /nix/store paths) resolve. Guard by
		// device name: when ShareHostNixStore is also on it already attaches an
		// identical `nixstore` disk below, so skip here to avoid a double-add.
		if !b.ShareHostNixStore {
			if err := b.addDisk(ctx, args.Name, "nixstore", hostNixStorePath, hostNixStorePath, true); err != nil {
				_ = b.forceDelete(ctx, args.Name)
				return Instance{}, err
			}
		}
		// The driver-lib LD_LIBRARY_PATH (so libcuda.so.1 etc. resolve via the
		// mounted store) and the host nvidia-smi on PATH — both resolved on the
		// host, so the recipe follows whatever driver the current system runs.
		ldLibraryPath, nvidiaSmiBinDir := resolveHostGpuUserspace()
		gpuEnv := [][2]string{
			{"environment.LD_LIBRARY_PATH", ldLibraryPath},
			{"environment.PATH", nvidiaSmiBinDir + ":" + gpuGuestPath},
		}
		for _, kv := range gpuEnv {
			if out, err := b.run(ctx, "", "config", "set", args.Name, kv[0], kv[1]); err != nil {
				_ = b.forceDelete(ctx, args.Name)
				return Instance{}, fmt.Errorf("incus config set %s=%s: %w: %s", kv[0], kv[1], err, strings.TrimSpace(out))
			}
		}
	}

	// 4c. Shared host build stores (PM2/PM3). Wire the per-job container into
	//     the host's shared content-addressed stores so it resolves prebuilt
	//     artifacts INSTANTLY (cache hit) AND persists its own novel builds
	//     back for later guests — the build-farm / multi-user-Nix model. Done
	//     pre-start so the mounts are present on first boot.
	if b.ShareHostNixStore {
		// /nix/store READ-ONLY: the guest sees every prebuilt path directly
		// (instant cache hits) but cannot mutate the store bytes.
		if err := b.addDisk(ctx, args.Name, "nixstore", hostNixStorePath, hostNixStorePath, true); err != nil {
			_ = b.forceDelete(ctx, args.Name)
			return Instance{}, err
		}
		// The nix-daemon socket dir READ-WRITE: the guest routes all WRITES +
		// BUILDS through the HOST daemon (NIX_REMOTE=daemon), which validates +
		// content-addresses every add and owns the nix DB. incus's default
		// idmap shifts guest root to an unprivileged, UNTRUSTED host uid, so
		// the daemon reports Trusted: 0 (build/add-CA allowed; set-trust
		// refused). The socket dir must be writable so the guest can connect().
		if err := b.addDisk(ctx, args.Name, "nixdaemon", hostNixDaemonSocketPath, hostNixDaemonSocketPath, false); err != nil {
			_ = b.forceDelete(ctx, args.Name)
			return Instance{}, err
		}
	}
	if b.ReprobuildStore != "" {
		guestPath := b.ReprobuildStoreGuestPath
		if guestPath == "" {
			guestPath = b.ReprobuildStore
		}
		// READ-WRITE: the CAS is BLAKE3-content-addressed, so guest-added
		// entries persist to the shared store for later guests and cannot
		// corrupt existing entries (a tampered blob hashes to a new digest).
		if err := b.addDisk(ctx, args.Name, "reprostore", b.ReprobuildStore, guestPath, false); err != nil {
			_ = b.forceDelete(ctx, args.Name)
			return Instance{}, err
		}
	}

	// 4c-bis. CPU cap. Set BEFORE start so the container's cgroup carries the
	//     limit from PID 1 onward: a cap applied after boot would still let
	//     cloud-init and the runner's own start-up see every host thread, and
	//     the tools that matter read `nproc` once, early.
	//
	//     Measured motivation (high-mem-server, 16 days): the per-job
	//     containers run uncapped at `cpu.max=max`, `cpuset.cpus=0-31` on a
	//     32-thread host, so each one reports 32 to `nproc` and self-sizes its
	//     build parallelism to the WHOLE machine. With several containers live
	//     the runnable queue reaches load1 87-191, and the co-resident Windows
	//     libvirt guests miss a ~300 s GitHub job-assignment window they
	//     otherwise clear in ~200 s. Capping bounds the demand each container
	//     generates.
	//
	//     Default "" ⇒ this block is skipped and the container is
	//     byte-unchanged (the live runners are untouched).
	if b.LimitsCPU != "" {
		if out, err := b.run(ctx, "", "config", "set", args.Name, "limits.cpu", b.LimitsCPU); err != nil {
			_ = b.forceDelete(ctx, args.Name)
			return Instance{}, fmt.Errorf("incus config set limits.cpu=%s: %w: %s", b.LimitsCPU, err, strings.TrimSpace(out))
		}
	}

	// 4d. Security nesting (the `runs-on: incus` nested-Docker path — HR1). Turn
	//     on nested containerisation so an in-guest Docker/Podman daemon can
	//     create its own namespaces/cgroups + overlay mount, and add the two
	//     syscall intercepts fuse-overlayfs needs to build images UNPRIVILEGED
	//     (mknod for device-node image layers, setxattr for overlayfs's
	//     trusted.overlay.* xattrs). Done pre-start so the flags apply on first
	//     boot. Default OFF ⇒ this block is skipped and the container is
	//     byte-unchanged (the live runners are untouched).
	if b.SecurityNesting {
		for _, kv := range [][2]string{
			{"security.nesting", "true"},
			{"security.syscalls.intercept.mknod", "true"},
			{"security.syscalls.intercept.setxattr", "true"},
		} {
			if out, err := b.run(ctx, "", "config", "set", args.Name, kv[0], kv[1]); err != nil {
				_ = b.forceDelete(ctx, args.Name)
				return Instance{}, fmt.Errorf("incus config set %s=%s: %w: %s", kv[0], kv[1], err, strings.TrimSpace(out))
			}
		}
	}

	// 4e. Nested KVM (the `runs-on: incus` nested-VM path — HR2). Expose the
	//     host `/dev/kvm` character device into the container so an in-guest
	//     `qemu-system-* -enable-kvm` gets hardware-accelerated virtualisation,
	//     and ensure `security.nesting=true` (an unprivileged nested container
	//     needs the nesting seam for the in-guest hypervisor's namespaces/mounts
	//     — it reuses the same seam SecurityNesting sets; setting it here is
	//     idempotent when both toggles are on). Done pre-start so the device is
	//     present on first boot. Default OFF ⇒ this block is skipped and the
	//     container is byte-unchanged (the live runners are untouched).
	if b.NestedKvm {
		if out, err := b.run(ctx, "", "config", "set", args.Name, "security.nesting", "true"); err != nil {
			_ = b.forceDelete(ctx, args.Name)
			return Instance{}, fmt.Errorf("incus config set security.nesting=true: %w: %s", err, strings.TrimSpace(out))
		}
		if out, err := b.run(ctx, "", "config", "device", "add", args.Name, "kvm", "unix-char",
			"source=/dev/kvm", "path=/dev/kvm", "mode=0666"); err != nil {
			_ = b.forceDelete(ctx, args.Name)
			return Instance{}, fmt.Errorf("incus config device add kvm: %w: %s", err, strings.TrimSpace(out))
		}
	}

	// 5. start — cloud-init consumes the injected user-data on first boot.
	if out, err := b.run(ctx, "", "start", args.Name); err != nil {
		_ = b.forceDelete(ctx, args.Name)
		return Instance{}, fmt.Errorf("incus start %s: %w: %s", args.Name, err, strings.TrimSpace(out))
	}

	// Incus' unix-char device is requested with mode=0666 above, but the
	// container's device setup can still settle /dev/kvm to the host udev mode
	// (0660 root:kvm). Cloud-init also reapplies the default runner groups and
	// can remove the image-baked kvm membership. Converge the guest-local mode
	// after start, before Create returns and GARM can assign a job. This affects
	// only the dedicated NestedKvm class; the plain runner remains unchanged.
	if b.NestedKvm {
		ready := false
		for i := 0; i < 30; i++ {
			if _, err := b.run(ctx, "", "exec", args.Name, "--", "true"); err == nil {
				ready = true
				break
			}
			time.Sleep(time.Second)
		}
		if !ready {
			_ = b.forceDelete(ctx, args.Name)
			return Instance{}, fmt.Errorf("incus container %s did not become ready for nested KVM setup", args.Name)
		}
		if out, err := b.run(ctx, "", "exec", args.Name, "--", "chmod", "0666", "/dev/kvm"); err != nil {
			_ = b.forceDelete(ctx, args.Name)
			return Instance{}, fmt.Errorf("nested KVM access setup on %s failed: %w: %s", args.Name, err, strings.TrimSpace(out))
		}
	}

	// 6. Shared Nix client onto STANDARD paths (post-start). Mounting the host
	//    store + daemon socket is not sufficient when the Debian runner image
	//    has no Nix client of its own: setup-nix otherwise tries a single-user
	//    install and hits EXDEV moving from /nix/temp-install-dir into the
	//    separately-mounted /nix/store. Install small wrappers in /usr/local/bin
	//    that execute the host's immutable Nix clients through the store mount
	//    and always select the shared host daemon. Do this before Create returns,
	//    so GARM cannot hand a GitHub job to a runner that lacks a usable `nix`.
	if b.ShareHostNixStore {
		ready := false
		for i := 0; i < 30; i++ {
			if _, err := b.run(ctx, "", "exec", args.Name, "--", "true"); err == nil {
				ready = true
				break
			}
			time.Sleep(time.Second)
		}
		if !ready {
			_ = b.forceDelete(ctx, args.Name)
			return Instance{}, fmt.Errorf("incus container %s did not become ready for shared Nix client setup", args.Name)
		}
		nixBinDir, err := resolveHostNixBinDir()
		if err != nil {
			_ = b.forceDelete(ctx, args.Name)
			return Instance{}, err
		}
		setup := fmt.Sprintf(
			"set -eu; nix_bin_dir=%q; "+
				"for tool in nix nix-build nix-channel nix-collect-garbage nix-copy-closure nix-env nix-hash nix-instantiate nix-prefetch-url nix-shell nix-store; do "+
				"target=\"$nix_bin_dir/$tool\"; [ -x \"$target\" ] || continue; "+
				"rm -f \"/usr/local/bin/$tool\"; "+
				"printf '#!/bin/sh\\nexport NIX_REMOTE=daemon\\nexec \"%%s\" \"$@\"\\n' \"$target\" > \"/usr/local/bin/$tool\"; "+
				"chmod 0755 \"/usr/local/bin/$tool\"; done",
			nixBinDir,
		)
		if out, err := b.run(ctx, "", "exec", args.Name, "--", "bash", "-c", setup); err != nil {
			_ = b.forceDelete(ctx, args.Name)
			return Instance{}, fmt.Errorf("shared Nix client setup on %s failed: %w: %s", args.Name, err, strings.TrimSpace(out))
		}
	}

	// 7. GPU userspace onto STANDARD paths (post-start). The pre-start
	//    environment.PATH/LD_LIBRARY_PATH only reach the container's PID1 (init);
	//    the GARM runner runs as a systemd service, which gets a clean env and
	//    does NOT inherit them — so a job step's `nvidia-smi` was "command not
	//    found" even though /dev/nvidia* was shared. Put the host driver
	//    userspace where systemd's DEFAULT search paths find it: symlink
	//    nvidia-smi into /usr/local/bin (on the default PATH) and register the
	//    driver lib dir via ld.so.conf.d (so libcuda.so.1 resolves without
	//    LD_LIBRARY_PATH). Both targets are the resolved /nix/store paths reached
	//    through the read-only /nix/store mount. Best-effort + ordered AFTER
	//    start: the job step runs many seconds later (after runner registration +
	//    job assignment), so this always lands before any GPU use; a failure here
	//    leaves the shared /dev/nvidia* + env fallback intact rather than killing
	//    an otherwise-usable runner.
	if b.GpuPassthrough {
		ldLibraryPath, nvidiaSmiBinDir := resolveHostGpuUserspace()
		for i := 0; i < 30; i++ {
			if _, err := b.run(ctx, "", "exec", args.Name, "--", "true"); err == nil {
				break
			}
			time.Sleep(time.Second)
		}
		setup := fmt.Sprintf(
			"ln -sf %s/nvidia-smi /usr/local/bin/nvidia-smi; "+
				"printf '%%s\\n' %s > /etc/ld.so.conf.d/nvidia-gpu.conf; "+
				"ldconfig",
			nvidiaSmiBinDir, ldLibraryPath,
		)
		if out, err := b.run(ctx, "", "exec", args.Name, "--", "bash", "-c", setup); err != nil {
			// Non-fatal: the GPU device is shared and the env fallback is set;
			// surface the detail so a genuinely broken setup is diagnosable.
			fmt.Printf("garm-provider-vmharness: WARNING: GPU userspace setup on %s failed: %v: %s\n",
				args.Name, err, strings.TrimSpace(out))
		}
	}

	return b.Get(ctx, args.Name)
}

// addDisk attaches a host directory to the container as a `disk` device before
// start (PM2/PM3 shared stores). The device name must be unique per container;
// source is the host path, path the in-guest mount point. When readonly is
// true the mount is immutable from the guest (used for /nix/store, which the
// guest reads directly); when false the guest can write (the nix-daemon socket
// dir, and the content-addressed reprobuild CAS — both self-validating so a
// write cannot corrupt existing data).
func (b *IncusBackend) addDisk(ctx context.Context, container, device, source, guestPath string, readonly bool) error {
	dargs := []string{"config", "device", "add", container, device, "disk",
		"source=" + source, "path=" + guestPath}
	if readonly {
		dargs = append(dargs, "readonly=true")
	}
	if out, err := b.run(ctx, "", dargs...); err != nil {
		return fmt.Errorf("incus config device add %s (disk %s->%s ro=%t): %w: %s",
			device, source, guestPath, readonly, err, strings.TrimSpace(out))
	}
	return nil
}

// forceDelete is the one-shot teardown primitive: it folds the stop into the
// delete. It is the CREATE-path ROLLBACK (a half-built container whose state is
// unknown and which no job ever reached), and the last-resort fallback at the
// end of Delete. The ordered teardown lives in Delete, not here.
func (b *IncusBackend) forceDelete(ctx context.Context, name string) error {
	_, err := b.run(ctx, "", "delete", "--force", name)
	return err
}

// Teardown tuning. These bound the ORDERED delete below; they are not a
// substitute for GARM's own retry ladder (workers/provider/instance_manager.go:
// 1 s doubling, capped at 5 min, unbounded), which still applies if every
// attempt here fails. The point of a SHORT local ladder is that a transient
// busy dataset resolves in seconds instead of escalating into that 5-minute
// cap.
const (
	// How long to wait for incusd to report the container `Stopped` after the
	// stop is issued. A container whose rootfs is referenced by hundreds of
	// processes across dozens of mount namespaces (security.nesting + nested
	// KVM + Docker) takes real time to unwind.
	incusStopSettleTimeout = 30 * time.Second
	incusStopPollInterval  = 500 * time.Millisecond
	// Bounded local delete retries: 1 s, 2 s, 4 s, 8 s between five attempts.
	incusDeleteAttempts    = 5
	incusDeleteBackoffBase = time.Second
	// incusStopCommandTimeout bounds the `stop --force` COMMAND itself, which
	// the ordered teardown places BEFORE the last-resort force delete. Without
	// it, a container wedged in an uninterruptible unmount — exactly the case
	// this reordering targets — would block the teardown indefinitely at a
	// point the previous one-shot `delete --force` never reached, i.e. the
	// reordering itself would introduce a new way to reclaim nothing.
	incusStopCommandTimeout = 30 * time.Second
	// incusLastResortTimeout budgets the final force delete. That call runs on
	// a context deliberately NOT cancelled by the caller's (see Delete, step
	// 4), so it cannot inherit a deadline and needs one of its own.
	incusLastResortTimeout = 30 * time.Second
)

// providerAttachedDevices are exactly the device names Create attaches. Delete
// detaches THESE and nothing else: `root` and `eth0` come from the `default`
// profile and are not ours to remove, and removing a device this provider did
// not add would be a mutation of somebody else's container.
var providerAttachedDevices = []string{"nixstore", "nixdaemon", "reprostore", "kvm", "gpu"}

// gone reports whether the container is absent (which every teardown step
// treats as success — Delete is idempotent by contract).
func (b *IncusBackend) gone(ctx context.Context, idOrName string) bool {
	_, err := b.findExact(ctx, idOrName)
	return err == garmErrors.ErrNotFound
}

// waitStopped polls incusd until the container reports `Stopped` (or vanishes).
// Returns false if it is still not stopped when the budget runs out; the caller
// proceeds anyway, because the force fallback at the end of Delete can still
// finish the job.
func (b *IncusBackend) waitStopped(ctx context.Context, idOrName string) bool {
	deadline := time.Now().Add(b.stopSettleTimeout())
	for {
		c, err := b.findExact(ctx, idOrName)
		if err == garmErrors.ErrNotFound {
			return true
		}
		if err == nil && strings.EqualFold(strings.TrimSpace(c.Status), "stopped") {
			return true
		}
		if !time.Now().Before(deadline) {
			return false
		}
		select {
		case <-ctx.Done():
			return false
		case <-time.After(incusStopPollInterval):
		}
	}
}

// Delete removes the container with an ORDERED teardown: stop and WAIT for the
// daemon to confirm it, detach the devices this provider attached, then delete.
// Idempotent: a missing container is treated as already-deleted success.
//
// WHY THE ORDER MATTERS — measured, not assumed. The previous implementation
// was a single unconditional `incus delete --force`, which folds the stop into
// the delete: incusd races its own unmount of the container rootfs against the
// references still held by the container's own processes, and ZFS refuses the
// destroy. Over 16 days on high-mem-server that produced 8786 distinct delete
// failures across 1333 of the 14447 instances deleted (9.2%), 96.7% of them
// `zfs destroy ...: dataset is busy`, retried a median of 7 and up to 30 times
// each. They retry to success — the holders drain — so nothing leaked
// permanently, but every one of them re-entered GARM's ladder and held the
// instance in `deleting` for minutes.
//
// SCOPE LIMIT, stated so nobody writes a success criterion this cannot meet:
// the other failure mode in that window (108 `context deadline exceeded`, of
// which 84 are the `incus list` READ PROBE in findExact timing out before any
// delete is attempted) is incus DATABASE contention, not teardown ordering.
// Reordering the teardown does not address it and it will not go to zero.
func (b *IncusBackend) Delete(ctx context.Context, idOrName string) error {
	c, err := b.findExact(ctx, idOrName)
	if err != nil {
		if err == garmErrors.ErrNotFound {
			return nil
		}
		return err
	}

	// 1. Stop, and WAIT for the daemon to confirm it. A stop error is not
	//    fatal here: the container may already be stopping, or may have
	//    vanished, and the force fallback below is the backstop.
	if !strings.EqualFold(strings.TrimSpace(c.Status), "stopped") {
		// `--force` because this is a teardown of an EPHEMERAL one-job
		// container whose job has already finished and whose storage volume is
		// about to be destroyed: there is no in-guest state worth a graceful
		// shutdown's wall-clock, and holding the slot longer is the risk this
		// change has to stay clear of.
		//
		// The stop runs on its OWN bounded context. `b.run` has no per-command
		// timeout and the provider's own context has no deadline today, so an
		// unbounded stop of a wedged container would hang the teardown here —
		// upstream of the force fallback that the previous implementation
		// reached immediately. Bounding it keeps the fallback reachable.
		stopCtx, cancelStop := context.WithTimeout(ctx, incusStopCommandTimeout)
		_, serr := b.run(stopCtx, "", "stop", "--force", idOrName)
		cancelStop()
		if serr != nil {
			if b.gone(ctx, idOrName) {
				return nil
			}
		}
		if !b.waitStopped(ctx, idOrName) && b.gone(ctx, idOrName) {
			return nil
		}
	}

	// 2. Detach the devices Create attached, so the delete has no device
	//    references left to unwind. Best-effort by design: a device that is
	//    already absent is the desired state, and a detach failure must never
	//    prevent the delete.
	if c.Devices != nil {
		for _, dev := range providerAttachedDevices {
			if _, ok := c.Devices[dev]; !ok {
				continue
			}
			_, _ = b.run(ctx, "", "config", "device", "remove", idOrName, dev)
		}
	}

	// 3. Delete, with a SHORT bounded local retry. Plain `delete` (no
	//    `--force`) because the container is stopped by now: if it is not, the
	//    error is worth surfacing to the retry rather than papering over.
	var lastErr error
	backoff := b.deleteRetryBackoff()
retry:
	for attempt := 0; attempt < incusDeleteAttempts; attempt++ {
		if attempt > 0 {
			select {
			case <-ctx.Done():
				// BREAK, never return. Returning here would skip step 4, and
				// step 4 is the entire basis of the "can never reclaim fewer
				// containers than the one-shot force delete" guarantee. A
				// cancelled caller context is precisely the situation in which
				// the old code would still have force-deleted the container
				// (it issued its single command at t=0), so it is precisely
				// the situation in which the new code must not give up.
				if lastErr == nil {
					lastErr = ctx.Err()
				}
				break retry
			case <-time.After(backoff):
			}
			backoff *= 2
		}
		out, derr := b.run(ctx, "", "delete", idOrName)
		if derr == nil {
			return nil
		}
		lastErr = fmt.Errorf("incus delete %s: %w: %s", idOrName, derr, strings.TrimSpace(out))
		// A container that vanished between attempts is success.
		if b.gone(ctx, idOrName) {
			return nil
		}
	}

	// 4. Last resort: exactly the pre-fix behaviour, and the reason the ordered
	//    path can never reclaim FEWER containers than the one-shot force
	//    delete it replaces. The worst case degrades to the old behaviour plus
	//    a bounded delay, never to a new failure.
	//
	//    That guarantee is NOT free, and the way it is bought is worth stating
	//    because it is easy to delete by accident. The old code issued its one
	//    force delete at t=0. The ordered path spends real time first — up to
	//    incusStopCommandTimeout stopping, incusStopSettleTimeout waiting, and
	//    ~15 s of backoff — so any deadline on the caller's context that the
	//    old code would have beaten, the new code can run past. If this call
	//    inherited that context, an expired one would make the fallback fail
	//    to even spawn (exec.CommandContext refuses to start on a done
	//    context) and the container would survive a teardown that the old code
	//    completed. So the fallback runs on a context derived from the
	//    caller's but explicitly NOT cancelled by it, with a budget of its own.
	//
	//    This matters in practice rather than in theory: GARM's external
	//    provider wrapper applies `exec_timeout_seconds` to this process and
	//    kills the child on expiry. That key is unset today, but the in-process
	//    half of the guarantee must not depend on it staying unset.
	lastResort, cancelLastResort := context.WithTimeout(
		context.WithoutCancel(ctx), incusLastResortTimeout)
	defer cancelLastResort()
	if ferr := b.forceDelete(lastResort, idOrName); ferr != nil {
		if b.gone(lastResort, idOrName) {
			return nil
		}
		return fmt.Errorf("%w (force fallback after %d ordered attempts; last ordered error: %v)",
			ferr, incusDeleteAttempts, lastErr)
	}
	return nil
}

// Get returns one container's stateless view. ErrNotFound when absent.
func (b *IncusBackend) Get(ctx context.Context, idOrName string) (Instance, error) {
	c, err := b.findExact(ctx, idOrName)
	if err != nil {
		return Instance{}, err
	}
	return toInstance(c), nil
}

// List returns all containers tagged with poolID.
func (b *IncusBackend) List(ctx context.Context, poolID string) ([]Instance, error) {
	return b.listFiltered(ctx, func(c incusContainer) bool {
		return c.Config[incusMetaPrefix+"pool_id"] == poolID
	})
}

// ListByController returns all containers tagged with controllerID.
func (b *IncusBackend) ListByController(ctx context.Context, controllerID string) ([]Instance, error) {
	return b.listFiltered(ctx, func(c incusContainer) bool {
		return c.Config[incusMetaPrefix+"controller_id"] == controllerID
	})
}

func (b *IncusBackend) listFiltered(ctx context.Context, keep func(incusContainer) bool) ([]Instance, error) {
	cs, err := b.listContainers(ctx, "")
	if err != nil {
		return nil, err
	}
	var out []Instance
	for _, c := range cs {
		// Only consider containers we own (a garm identity tag present).
		if c.Config[incusMetaPrefix+"controller_id"] == "" && c.Config[incusMetaPrefix+"pool_id"] == "" {
			continue
		}
		if keep(c) {
			out = append(out, toInstance(c))
		}
	}
	return out, nil
}

// Start boots the container.
func (b *IncusBackend) Start(ctx context.Context, idOrName string) error {
	if _, err := b.findExact(ctx, idOrName); err != nil {
		return err
	}
	out, err := b.run(ctx, "", "start", idOrName)
	if err != nil && !strings.Contains(strings.ToLower(out), "already running") {
		return err
	}
	return nil
}

// Stop shuts the container down (graceful) or force-stops it.
func (b *IncusBackend) Stop(ctx context.Context, idOrName string, force bool) error {
	if _, err := b.findExact(ctx, idOrName); err != nil {
		return err
	}
	args := []string{"stop", idOrName}
	if force {
		args = append(args, "--force")
	}
	out, err := b.run(ctx, "", args...)
	if err != nil && !strings.Contains(strings.ToLower(out), "not running") {
		return err
	}
	return nil
}
