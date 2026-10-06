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
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	garmErrors "github.com/cloudbase/garm-provider-common/errors"
)

// mockIncusScript is a self-contained POSIX-sh emulation of the subset of the
// `incus` CLI the IncusBackend drives (init / config set [from stdin] / start /
// stop / delete --force / list [filter] --format json). It persists container
// state + the user.garm.* config keys under $MOCK_INCUS_STATE so the STATELESS
// provider (which never persists anything itself) has a real backend to
// recompute from — the same idea as the mock virsh, but for containers. It
// emits JSON that matches `incus list --format json` closely enough for the
// backend's parser (name / status / config / state.network eth0 inet address).
const mockIncusScript = `#!/bin/sh
set -eu
STATE="${MOCK_INCUS_STATE:?MOCK_INCUS_STATE unset}"
mkdir -p "$STATE"

cmd="${1:-}"; shift || true

# Every invocation is appended to $MOCK_INCUS_CMDLOG (when set) so a test can
# assert the ORDER of the teardown steps, not merely their end state. The
# end state cannot distinguish "stopped, then deleted" from "force-deleted".
if [ -n "${MOCK_INCUS_CMDLOG:-}" ]; then
  printf '%s %s\n' "$cmd" "$*" >> "$MOCK_INCUS_CMDLOG"
fi

case "$cmd" in
  init)
    # init <image> <name>
    image="$1"; name="$2"
    d="$STATE/$name"
    if [ -d "$d" ]; then echo "Error: Instance '$name' already exists" >&2; exit 1; fi
    mkdir -p "$d"
    echo "$image" > "$d/image"
    echo "Stopped" > "$d/status"
    : > "$d/config"
    ;;
  config)
    sub="$1"; shift
    if [ "$sub" = "device" ]; then
      if [ "${1:-}" = "remove" ]; then
        # config device remove <name> <devname>
        name="$2"; devname="$3"
        d="$STATE/$name"
        [ -d "$d" ] || { echo "Error: Instance '$name' not found" >&2; exit 1; }
        if [ ! -f "$d/devices" ] || ! grep -q "^$devname	" "$d/devices"; then
          echo "Error: Device '$devname' doesn't exist" >&2; exit 1
        fi
        grep -v "^$devname	" "$d/devices" > "$d/devices.tmp" || true
        mv "$d/devices.tmp" "$d/devices"
      else
        # config device add <name> <devname> <devtype> [k=v ...]
        action="$1"; name="$2"; devname="$3"; devtype="$4"; shift 4 || true
        d="$STATE/$name"
        [ -d "$d" ] || { echo "Error: Instance '$name' not found" >&2; exit 1; }
        if [ "$action" = "add" ]; then
          printf '%s\t%s\t%s\n' "$devname" "$devtype" "$*" >> "$d/devices"
        fi
      fi
    else
      # config set <name> <key> <value|->   OR   config set <name> <key=val>
      name="$1"; key="$2"; val="${3:-}"
      d="$STATE/$name"
      [ -d "$d" ] || { echo "Error: Instance '$name' not found" >&2; exit 1; }
      if [ "$val" = "-" ]; then
        cat > "$d/cfgfile.$(echo "$key" | tr '/.' '__')"
      else
        case "$key" in
          *=*) v="${key#*=}"; k="${key%%=*}" ;;
          *)   k="$key"; v="$val" ;;
        esac
        # keep only the newest value per key
        grep -v "^$k	" "$d/config" > "$d/config.tmp" 2>/dev/null || true
        mv "$d/config.tmp" "$d/config" 2>/dev/null || true
        printf '%s\t%s\n' "$k" "$v" >> "$d/config"
      fi
    fi
    ;;
  start)
    name="$1"; d="$STATE/$name"
    [ -d "$d" ] || { echo "Error: Instance '$name' not found" >&2; exit 1; }
    echo "Running" > "$d/status"
    ;;
  exec)
    name="$1"; shift
    d="$STATE/$name"
    [ -d "$d" ] || { echo "Error: Instance '$name' not found" >&2; exit 1; }
    printf '%s\n' "$*" >> "$d/execs"
    ;;
  stop)
    # stop [--force] <name>
    name=""
    for a in "$@"; do case "$a" in --*) ;; *) name="$a"; break;; esac; done
    d="$STATE/$name"
    [ -d "$d" ] || { echo "Error: Instance '$name' not found" >&2; exit 1; }
    if [ -n "${MOCK_INCUS_STOP_FAILS:-}" ]; then
      echo "Error: The instance is busy running a command" >&2; exit 1
    fi
    # Real incusd does not settle instantly: a container whose rootfs is
    # referenced across many mount namespaces takes time to report Stopped.
    # MOCK_INCUS_STOP_SETTLE_POLLS makes the mock report Stopping for that
    # many subsequent 'list' calls, so waitStopped is actually exercised.
    if [ -n "${MOCK_INCUS_STOP_SETTLE_POLLS:-}" ]; then
      echo "$MOCK_INCUS_STOP_SETTLE_POLLS" > "$d/settle"
      echo "Stopping" > "$d/status"
    else
      echo "Stopped" > "$d/status"
    fi
    ;;
  delete)
    # delete [--force] <name>
    force=0; name=""
    for a in "$@"; do
      case "$a" in
        --force) force=1 ;;
        --*) ;;
        *) [ -n "$name" ] || name="$a" ;;
      esac
    done
    d="$STATE/$name"
    [ -d "$d" ] || { echo "Error: Instance '$name' not found" >&2; exit 1; }
    st=$(cat "$d/status" 2>/dev/null || echo Stopped)
    if [ "$st" != "Stopped" ] && [ "$force" = 0 ]; then
      echo "Error: The instance is currently running, stop it first or pass --force" >&2; exit 1
    fi
    # Failure injection: the FIRST $MOCK_INCUS_DELETE_FAILURES delete attempts
    # fail exactly the way the host does (ZFS refusing a busy dataset), so the
    # bounded local retry ladder is exercised against the real error text.
    if [ -n "${MOCK_INCUS_DELETE_FAILURES:-}" ]; then
      n=$(cat "$STATE/.delete-failures" 2>/dev/null || echo 0)
      if [ "$n" -lt "$MOCK_INCUS_DELETE_FAILURES" ]; then
        echo $(( n + 1 )) > "$STATE/.delete-failures"
        echo "Error: Failed to delete instance \"$name\": Failed to run: zfs destroy -r zroot/root/var/lib/incus-storage/containers/$name: exit status 1 (cannot destroy 'zroot/root/var/lib/incus-storage/containers/$name': dataset is busy)" >&2
        exit 1
      fi
    fi
    rm -rf "$d"
    ;;
  list)
    # list [filter] --format json
    filter=""
    if [ "${1:-}" != "--format" ]; then filter="$1"; shift; fi
	if [ -n "${MOCK_INCUS_LIST_DELAY:-}" ]; then sleep "$MOCK_INCUS_LIST_DELAY"; fi
    printf '['
    first=1
    for d in "$STATE"/*/; do
      [ -d "$d" ] || continue
      n=$(basename "$d")
      if [ -n "$filter" ] && [ "$n" != "$filter" ]; then continue; fi
      st=$(cat "$d/status" 2>/dev/null || echo Stopped)
      # Honour a pending stop-settle countdown: report Stopping until it runs
      # out, then Stopped. Decremented per observation, like a real poll.
      if [ -f "$d/settle" ]; then
        s=$(cat "$d/settle")
        if [ "$s" -gt 0 ]; then
          echo $(( s - 1 )) > "$d/settle"
        else
          rm -f "$d/settle"
          echo "Stopped" > "$d/status"
          st="Stopped"
        fi
      fi
      [ "$first" = 1 ] || printf ','
      first=0
      printf '{"name":"%s","status":"%s","devices":{' "$n" "$st"
      dfirst=1
      if [ -f "$d/devices" ]; then
        while IFS='	' read -r dn dt drest; do
          [ -n "$dn" ] || continue
          [ "$dfirst" = 1 ] || printf ','
          dfirst=0
          printf '"%s":{"type":"%s"}' "$dn" "$dt"
        done < "$d/devices"
      fi
      printf '},"config":{'
      ip=""
      cfirst=1
      while IFS='	' read -r k v; do
        [ -n "$k" ] || continue
        [ "$cfirst" = 1 ] || printf ','
        cfirst=0
        printf '"%s":"%s"' "$k" "$v"
        if [ "$k" = "user.garm.ipv4" ]; then ip="$v"; fi
      done < "$d/config"
      printf '}'
      if [ -n "$ip" ]; then
        printf ',"state":{"network":{"eth0":{"addresses":[{"family":"inet","address":"%s"}]}}}' "$ip"
      else
        printf ',"state":null'
      fi
      printf '}'
    done
    printf ']'
    ;;
  *)
    echo "mock incus: unsupported cmd '$cmd'" >&2; exit 1;;
esac
`

func writeMockIncus(t *testing.T) (cmd []string, stateDir string) {
	t.Helper()
	dir := t.TempDir()
	script := filepath.Join(dir, "incus")
	if err := os.WriteFile(script, []byte(mockIncusScript), 0o755); err != nil {
		t.Fatalf("write mock incus: %v", err)
	}
	stateDir = filepath.Join(dir, "state")
	t.Setenv("MOCK_INCUS_STATE", stateDir)
	return []string{script}, stateDir
}

func newTestIncusBackend(cmd []string) *IncusBackend {
	return &IncusBackend{
		IncusCmd:    cmd,
		Bridge:      "incusbr0",
		IPv4CIDR:    "10.0.100.0/24",
		IPv4Gateway: "10.0.100.1",
		RangeStart:  "10.0.100.200",
		RangeEnd:    "10.0.100.250",
		Nameservers: []string{"1.1.1.1", "8.8.8.8"},
	}
}

func TestIncusCreateGetDeleteLifecycle(t *testing.T) {
	cmd, _ := writeMockIncus(t)
	b := newTestIncusBackend(cmd)
	ctx := context.Background()

	inst, err := b.Create(ctx, CreateArgs{
		Name:         "garm-linux-1",
		ControllerID: "ctrl-A",
		PoolID:       "pool-1",
		SourceImage:  "runner-linux",
		OSName:       "linux",
		OSVersion:    "debian12",
		Bootstrap:    []byte("#!/bin/bash\necho hi\n"),
	})
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if inst.Name != "garm-linux-1" || inst.PoolID != "pool-1" || inst.ControllerID != "ctrl-A" {
		t.Fatalf("identity not tagged/recovered: %+v", inst)
	}
	if inst.OSName != "linux" {
		t.Fatalf("os_name not recovered: %+v", inst)
	}
	if inst.Status != "running" {
		t.Fatalf("expected running, got %q", inst.Status)
	}
	if len(inst.Addresses) != 1 || inst.Addresses[0] != "10.0.100.200" {
		t.Fatalf("expected static IP 10.0.100.200, got %v", inst.Addresses)
	}

	got, err := b.Get(ctx, "garm-linux-1")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if got.Name != inst.Name {
		t.Fatalf("Get mismatch: %+v", got)
	}

	if err := b.Delete(ctx, "garm-linux-1"); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if _, err := b.Get(ctx, "garm-linux-1"); err != garmErrors.ErrNotFound {
		t.Fatalf("expected ErrNotFound after delete, got %v", err)
	}
	// idempotent: deleting a missing container is success.
	if err := b.Delete(ctx, "garm-linux-1"); err != nil {
		t.Fatalf("second Delete not idempotent: %v", err)
	}
}

func TestIncusConcurrentCreatesAllocateDistinctIPv4(t *testing.T) {
	cmd, _ := writeMockIncus(t)
	t.Setenv("MOCK_INCUS_LIST_DELAY", "0.2")
	lockPath := filepath.Join(t.TempDir(), "incus-ip.lock")
	ctx := context.Background()

	type result struct {
		inst Instance
		err  error
	}
	results := make(chan result, 2)
	var ready sync.WaitGroup
	ready.Add(2)
	start := make(chan struct{})
	for _, name := range []string{"garm-concurrent-1", "garm-concurrent-2"} {
		name := name
		go func() {
			ready.Done()
			<-start
			b := newTestIncusBackend(cmd)
			b.IPAllocationLockPath = lockPath
			inst, err := b.Create(ctx, CreateArgs{Name: name, SourceImage: "runner-linux"})
			results <- result{inst: inst, err: err}
		}()
	}
	ready.Wait()
	close(start)

	addresses := map[string]bool{}
	for i := 0; i < 2; i++ {
		r := <-results
		if r.err != nil {
			t.Fatalf("concurrent Create: %v", r.err)
		}
		if len(r.inst.Addresses) != 1 {
			t.Fatalf("expected one address, got %+v", r.inst)
		}
		addresses[r.inst.Addresses[0]] = true
	}
	if !addresses["10.0.100.200"] || !addresses["10.0.100.201"] || len(addresses) != 2 {
		t.Fatalf("expected distinct lowest addresses, got %v", addresses)
	}
}

// TestIncusGpuPassthroughSharedUserspace proves the `incus-gpu` class path: the
// PROVEN shared-GPU recipe (guest nvidia-smi/CUDA see the host GPU while the
// host keeps using it, no driver-version coupling). With GpuPassthrough set,
// Create BEFORE start (i) shares /dev/nvidia* via a `gpu` device, (ii) mounts
// the host /nix/store READ-ONLY so the Nix-ELF loader + driver .so resolve, and
// (iii) sets environment.LD_LIBRARY_PATH (driver libs) + environment.PATH
// (nvidia-smi bin dir prepended). It MUST NOT set nvidia.runtime (incus-lts has
// no CDI; the hook does not inject the userspace on NixOS). Without the toggle
// the plain `incus` class touches none of this.
func TestIncusGpuPassthroughSharedUserspace(t *testing.T) {
	cmd, stateDir := writeMockIncus(t)
	b := newTestIncusBackend(cmd)
	b.GpuPassthrough = true
	ctx := context.Background()

	if _, err := b.Create(ctx, CreateArgs{
		Name:        "garm-gpu-1",
		SourceImage: "runner-linux",
		OSName:      "linux",
		OSVersion:   "debian12",
	}); err != nil {
		t.Fatalf("Create (gpu): %v", err)
	}

	devices, err := os.ReadFile(filepath.Join(stateDir, "garm-gpu-1", "devices"))
	if err != nil {
		t.Fatalf("expected gpu devices to be added, but no devices file: %v", err)
	}
	dev := string(devices)
	// (i) cooperative /dev/nvidia* share.
	if !strings.Contains(dev, "gpu\tgpu") {
		t.Fatalf("expected a `gpu` device of type `gpu`, got: %q", dev)
	}
	// (ii) /nix/store READ-ONLY so the driver .so files resolve.
	if !strings.Contains(dev, "nixstore\tdisk\tsource=/nix/store path=/nix/store readonly=true") {
		t.Fatalf("expected /nix/store read-only mount, got: %q", dev)
	}

	config, err := os.ReadFile(filepath.Join(stateDir, "garm-gpu-1", "config"))
	if err != nil {
		t.Fatalf("read config: %v", err)
	}
	cfg := string(config)
	// It must NOT use nvidia.runtime (the discredited CDI path).
	if strings.Contains(cfg, "nvidia.runtime") {
		t.Fatalf("GPU recipe must NOT set nvidia.runtime (no CDI on incus-lts), got config: %q", cfg)
	}
	// (iii) driver LD_LIBRARY_PATH (a …/lib dir) + nvidia-smi on PATH.
	if !strings.Contains(cfg, "environment.LD_LIBRARY_PATH\t") {
		t.Fatalf("expected environment.LD_LIBRARY_PATH to be set, got config: %q", cfg)
	}
	ld := configValue(cfg, "environment.LD_LIBRARY_PATH")
	if !strings.HasSuffix(ld, "/lib") {
		t.Fatalf("expected LD_LIBRARY_PATH to be a driver …/lib dir, got %q", ld)
	}
	if !strings.Contains(cfg, "environment.PATH\t") {
		t.Fatalf("expected environment.PATH to be set, got config: %q", cfg)
	}
	pathVal := configValue(cfg, "environment.PATH")
	if !strings.HasSuffix(pathVal, gpuGuestPath) || !strings.Contains(pathVal, ":") {
		t.Fatalf("expected PATH to prepend a bin dir before the default PATH, got %q", pathVal)
	}

	// Composition with ShareHostNixStore: the /nix/store mount is added exactly
	// ONCE (guarded by device name), not double-added.
	both := newTestIncusBackend(cmd)
	both.GpuPassthrough = true
	both.ShareHostNixStore = true
	if _, err := both.Create(ctx, CreateArgs{Name: "garm-gpu-both", SourceImage: "runner-linux"}); err != nil {
		t.Fatalf("Create (gpu+shared store): %v", err)
	}
	bothDev, _ := os.ReadFile(filepath.Join(stateDir, "garm-gpu-both", "devices"))
	if n := strings.Count(string(bothDev), "nixstore\tdisk\t"); n != 1 {
		t.Fatalf("expected the /nix/store mount added exactly once with gpu+shared-store, got %d:\n%s", n, string(bothDev))
	}

	// The plain (non-GPU) backend must NOT attach any device or GPU env.
	plain := newTestIncusBackend(cmd)
	if _, err := plain.Create(ctx, CreateArgs{
		Name:        "garm-plain-1",
		SourceImage: "runner-linux",
		OSName:      "linux",
		OSVersion:   "debian12",
	}); err != nil {
		t.Fatalf("Create (plain): %v", err)
	}
	if _, err := os.Stat(filepath.Join(stateDir, "garm-plain-1", "devices")); err == nil {
		t.Fatalf("plain incus class must not attach any device")
	}
	pcfg, _ := os.ReadFile(filepath.Join(stateDir, "garm-plain-1", "config"))
	if strings.Contains(string(pcfg), "environment.LD_LIBRARY_PATH") {
		t.Fatalf("plain incus class must not set GPU env, got: %q", string(pcfg))
	}
}

// configValue extracts the value for a "<key>\t<value>" line from the mock
// incus config dump.
func configValue(cfg, key string) string {
	for _, line := range strings.Split(cfg, "\n") {
		if strings.HasPrefix(line, key+"\t") {
			return strings.TrimPrefix(line, key+"\t")
		}
	}
	return ""
}

// TestIncusSecurityNestingEnablesNesting proves the HR1 nested-Docker path:
// with SecurityNesting set, Create sets `security.nesting=true` plus the two
// fuse-overlayfs syscall intercepts (mknod + setxattr) on the container BEFORE
// start. Without it, none are present (the plain `incus` class stays
// byte-unchanged — the live runners are untouched).
func TestIncusSecurityNestingEnablesNesting(t *testing.T) {
	cmd, stateDir := writeMockIncus(t)
	b := newTestIncusBackend(cmd)
	b.SecurityNesting = true
	ctx := context.Background()

	if _, err := b.Create(ctx, CreateArgs{
		Name:        "garm-nest-1",
		SourceImage: "runner-linux",
		OSName:      "linux",
		OSVersion:   "debian12",
	}); err != nil {
		t.Fatalf("Create (nesting): %v", err)
	}

	config, err := os.ReadFile(filepath.Join(stateDir, "garm-nest-1", "config"))
	if err != nil {
		t.Fatalf("read config: %v", err)
	}
	cfg := string(config)
	for _, want := range []string{
		"security.nesting\ttrue",
		"security.syscalls.intercept.mknod\ttrue",
		"security.syscalls.intercept.setxattr\ttrue",
	} {
		if !strings.Contains(cfg, want) {
			t.Fatalf("expected config %q with nesting on, got config:\n%s", want, cfg)
		}
	}

	// The plain (default-OFF) backend must NOT set any nesting/intercept key:
	// the existing live runners stay byte-unchanged until the toggle is enabled.
	plain := newTestIncusBackend(cmd)
	if _, err := plain.Create(ctx, CreateArgs{
		Name:        "garm-nest-plain",
		SourceImage: "runner-linux",
	}); err != nil {
		t.Fatalf("Create (plain): %v", err)
	}
	pcfg, err := os.ReadFile(filepath.Join(stateDir, "garm-nest-plain", "config"))
	if err != nil {
		t.Fatalf("read plain config: %v", err)
	}
	if strings.Contains(string(pcfg), "security.nesting") ||
		strings.Contains(string(pcfg), "security.syscalls.intercept") {
		t.Fatalf("plain incus class must not set any nesting/intercept key (default OFF), got:\n%s", string(pcfg))
	}
}

// TestIncusNestedKvmAttachesKvmDevice proves the HR2 nested-VM path: with
// NestedKvm set, Create adds a `/dev/kvm` unix-char device AND sets
// `security.nesting=true` on the container BEFORE start (so an in-guest
// `qemu-system-* -enable-kvm` gets hardware-accelerated virtualisation).
// Without it, neither the kvm device nor security.nesting is present (the
// plain `incus` class stays byte-unchanged — the live runners are untouched).
func TestIncusNestedKvmAttachesKvmDevice(t *testing.T) {
	cmd, stateDir := writeMockIncus(t)
	b := newTestIncusBackend(cmd)
	b.NestedKvm = true
	ctx := context.Background()

	if _, err := b.Create(ctx, CreateArgs{
		Name:        "garm-kvm-1",
		SourceImage: "runner-linux",
		OSName:      "linux",
		OSVersion:   "debian12",
	}); err != nil {
		t.Fatalf("Create (nested-kvm): %v", err)
	}

	devices, err := os.ReadFile(filepath.Join(stateDir, "garm-kvm-1", "devices"))
	if err != nil {
		t.Fatalf("expected a kvm device to be added, but no devices file: %v", err)
	}
	// devices file rows are: <devname>\t<devtype>\t<k=v ...>
	if !strings.Contains(string(devices), "kvm\tunix-char") ||
		!strings.Contains(string(devices), "source=/dev/kvm") ||
		!strings.Contains(string(devices), "path=/dev/kvm") ||
		!strings.Contains(string(devices), "mode=0666") {
		t.Fatalf("expected a `kvm` unix-char device sourcing /dev/kvm, got: %q", string(devices))
	}

	config, err := os.ReadFile(filepath.Join(stateDir, "garm-kvm-1", "config"))
	if err != nil {
		t.Fatalf("read config: %v", err)
	}
	if !strings.Contains(string(config), "security.nesting\ttrue") {
		t.Fatalf("expected security.nesting=true with nested-kvm on, got config:\n%s", string(config))
	}
	execs, err := os.ReadFile(filepath.Join(stateDir, "garm-kvm-1", "execs"))
	if err != nil {
		t.Fatalf("expected post-start nested KVM access setup, but no execs file: %v", err)
	}
	if !strings.Contains(string(execs), "-- chmod 0666 /dev/kvm") {
		t.Fatalf("expected guest-local /dev/kvm mode convergence before Create returns, got: %q", string(execs))
	}

	// The plain (default-OFF) backend must NOT add a kvm device or set
	// security.nesting: the existing live runners stay byte-unchanged.
	plain := newTestIncusBackend(cmd)
	if _, err := plain.Create(ctx, CreateArgs{
		Name:        "garm-kvm-plain",
		SourceImage: "runner-linux",
	}); err != nil {
		t.Fatalf("Create (plain): %v", err)
	}
	if _, err := os.Stat(filepath.Join(stateDir, "garm-kvm-plain", "devices")); err == nil {
		t.Fatalf("plain incus class must not attach any device (default OFF)")
	}
	pcfg, err := os.ReadFile(filepath.Join(stateDir, "garm-kvm-plain", "config"))
	if err != nil {
		t.Fatalf("read plain config: %v", err)
	}
	if strings.Contains(string(pcfg), "security.nesting") {
		t.Fatalf("plain incus class must not set security.nesting (default OFF), got:\n%s", string(pcfg))
	}
}

// TestIncusSharedStoresAttachStoreDisks proves the PM2/PM3 shared-store path
// (writable-by-design, safe): with ShareHostNixStore + ReprobuildStore set,
// Create attaches, before start, the host `/nix/store` READ-ONLY (the guest
// reads prebuilt paths directly), the host nix-daemon socket dir READ-WRITE
// (so guest builds/writes route through the host daemon and persist to the
// shared store), and the reprobuild CAS READ-WRITE (self-verifying content-
// addressed writes). Without the toggles, no store device is attached (the
// plain `incus` class is byte-unchanged).
func TestIncusSharedStoresAttachStoreDisks(t *testing.T) {
	cmd, stateDir := writeMockIncus(t)
	b := newTestIncusBackend(cmd)
	b.ShareHostNixStore = true
	b.ReprobuildStore = "/var/lib/reprobuild/shared-store"
	b.ReprobuildStoreGuestPath = "/srv/repro-store"
	ctx := context.Background()

	if _, err := b.Create(ctx, CreateArgs{
		Name:        "garm-store-1",
		SourceImage: "runner-linux",
		OSName:      "linux",
		OSVersion:   "debian12",
	}); err != nil {
		t.Fatalf("Create (shared stores): %v", err)
	}

	devices, err := os.ReadFile(filepath.Join(stateDir, "garm-store-1", "devices"))
	if err != nil {
		t.Fatalf("expected store disk devices to be added, but no devices file: %v", err)
	}
	dev := string(devices)
	// /nix/store READ-ONLY; the nix-daemon socket dir READ-WRITE (no
	// readonly=true — the guest must connect() through it); reprobuild CAS
	// READ-WRITE (self-verifying content-addressed writes persist).
	for _, want := range []string{
		"nixstore\tdisk\tsource=/nix/store path=/nix/store readonly=true",
		"nixdaemon\tdisk\tsource=/nix/var/nix/daemon-socket path=/nix/var/nix/daemon-socket",
		"reprostore\tdisk\tsource=/var/lib/reprobuild/shared-store path=/srv/repro-store",
	} {
		if !strings.Contains(dev, want) {
			t.Fatalf("expected device line %q, got devices:\n%s", want, dev)
		}
	}
	// /nix/store MUST be read-only (raw store bytes immutable from the guest —
	// all mutation goes through the validating daemon).
	for _, line := range strings.Split(strings.TrimSpace(dev), "\n") {
		if strings.HasPrefix(line, "nixstore\tdisk\t") && !strings.Contains(line, "readonly=true") {
			t.Fatalf("nixstore share must be read-only, got: %q", line)
		}
	}
	// The nix-daemon socket + reprobuild CAS MUST be writable (NOT readonly) so
	// guest builds/adds can flow through the daemon / persist to the CAS.
	for _, dname := range []string{"nixdaemon", "reprostore"} {
		for _, line := range strings.Split(strings.TrimSpace(dev), "\n") {
			if strings.HasPrefix(line, dname+"\tdisk\t") && strings.Contains(line, "readonly=true") {
				t.Fatalf("%s share must be read-write (writable-by-design), got: %q", dname, line)
			}
		}
	}

	// The Debian runner image intentionally carries no private Nix install.
	// Shared-store mode must expose the host's immutable clients on the normal
	// job PATH and force every invocation through the mounted host daemon.
	execs, err := os.ReadFile(filepath.Join(stateDir, "garm-store-1", "execs"))
	if err != nil {
		t.Fatalf("expected shared Nix client setup execs: %v", err)
	}
	execText := string(execs)
	for _, want := range []string{
		"/usr/local/bin/$tool",
		"NIX_REMOTE=daemon",
		"nix-store",
	} {
		if !strings.Contains(execText, want) {
			t.Fatalf("expected shared Nix client setup to contain %q, got:\n%s", want, execText)
		}
	}

	// Reprobuild guest path defaults to the host path when unset.
	b2 := newTestIncusBackend(cmd)
	b2.ReprobuildStore = "/host/repro"
	if _, err := b2.Create(ctx, CreateArgs{Name: "garm-store-2", SourceImage: "runner-linux"}); err != nil {
		t.Fatalf("Create (repro default guest path): %v", err)
	}
	d2, _ := os.ReadFile(filepath.Join(stateDir, "garm-store-2", "devices"))
	if !strings.Contains(string(d2), "reprostore\tdisk\tsource=/host/repro path=/host/repro") {
		t.Fatalf("expected reprostore to mirror host path when guest path unset, got:\n%s", string(d2))
	}

	// The plain (default-OFF) backend must NOT attach any store device: the
	// existing live runners stay byte-unchanged until the toggle is enabled.
	plain := newTestIncusBackend(cmd)
	if _, err := plain.Create(ctx, CreateArgs{Name: "garm-plain-store", SourceImage: "runner-linux"}); err != nil {
		t.Fatalf("Create (plain): %v", err)
	}
	if _, err := os.Stat(filepath.Join(stateDir, "garm-plain-store", "devices")); err == nil {
		t.Fatalf("plain incus class must not attach any store device (default OFF)")
	}
}

func TestIncusDistinctIPAllocationAndListFilter(t *testing.T) {
	cmd, _ := writeMockIncus(t)
	b := newTestIncusBackend(cmd)
	ctx := context.Background()

	for _, n := range []string{"garm-a", "garm-b"} {
		if _, err := b.Create(ctx, CreateArgs{
			Name: n, ControllerID: "ctrl-A", PoolID: "pool-1",
			SourceImage: "runner-linux", OSName: "linux",
		}); err != nil {
			t.Fatalf("Create %s: %v", n, err)
		}
	}
	// A container in a different pool + controller must not leak into pool-1.
	if _, err := b.Create(ctx, CreateArgs{
		Name: "garm-c", ControllerID: "ctrl-B", PoolID: "pool-2",
		SourceImage: "runner-linux", OSName: "linux",
	}); err != nil {
		t.Fatalf("Create garm-c: %v", err)
	}

	a, _ := b.Get(ctx, "garm-a")
	bb, _ := b.Get(ctx, "garm-b")
	if len(a.Addresses) == 0 || len(bb.Addresses) == 0 || a.Addresses[0] == bb.Addresses[0] {
		t.Fatalf("expected distinct static IPs, got %v and %v", a.Addresses, bb.Addresses)
	}
	if a.Addresses[0] != "10.0.100.200" || bb.Addresses[0] != "10.0.100.201" {
		t.Fatalf("expected sequential lowest-free IPs, got %v %v", a.Addresses, bb.Addresses)
	}

	pool1, err := b.List(ctx, "pool-1")
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(pool1) != 2 {
		t.Fatalf("expected 2 in pool-1, got %d", len(pool1))
	}
	ctrlB, err := b.ListByController(ctx, "ctrl-B")
	if err != nil {
		t.Fatalf("ListByController: %v", err)
	}
	if len(ctrlB) != 1 || ctrlB[0].Name != "garm-c" {
		t.Fatalf("expected only garm-c for ctrl-B, got %+v", ctrlB)
	}
}

func TestIncusNetworkConfigRendersStaticIP(t *testing.T) {
	b := newTestIncusBackend([]string{"incus"})
	nc := b.networkConfig("10.0.100.207")
	for _, want := range []string{
		"dhcp4: false",
		"addresses: [10.0.100.207/24]",
		"to: 0.0.0.0/0",
		"via: 10.0.100.1",
		"addresses: [1.1.1.1, 8.8.8.8]",
	} {
		if !strings.Contains(nc, want) {
			t.Fatalf("network-config missing %q:\n%s", want, nc)
		}
	}
}

// ---------------------------------------------------------------------------
// CIR-M1 — CPU cap + ordered teardown
// ---------------------------------------------------------------------------

// readCmdLog returns the mock incus command log as a slice of lines.
func readCmdLog(t *testing.T, path string) []string {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read cmdlog %s: %v", path, err)
	}
	var lines []string
	for _, l := range strings.Split(string(raw), "\n") {
		if strings.TrimSpace(l) != "" {
			lines = append(lines, l)
		}
	}
	return lines
}

// indexOfLine returns the index of the first log line containing every needle,
// or -1.
func indexOfLine(lines []string, needles ...string) int {
	for i, l := range lines {
		all := true
		for _, n := range needles {
			if !strings.Contains(l, n) {
				all = false
				break
			}
		}
		if all {
			return i
		}
	}
	return -1
}

func withCmdLog(t *testing.T) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "cmdlog")
	t.Setenv("MOCK_INCUS_CMDLOG", p)
	if err := os.WriteFile(p, nil, 0o644); err != nil {
		t.Fatalf("seed cmdlog: %v", err)
	}
	return p
}

// TestIncusLimitsCpuIsSetBeforeStart proves the CPU cap that CIR-M1 needs on
// high-mem-server: `limits.cpu` is applied to the per-job container BEFORE
// `incus start`, so the cap is in the container's cgroup from PID 1 onward and
// `nproc` — which every build tool self-sizes from — reports the capped count
// rather than all 32 host threads.
//
// The negative control is in the same test rather than in a reviewer's notes:
// with LimitsCPU left at its zero value the backend must issue NO limits.cpu
// command at all, so a provider that does not ask for a cap gets a container
// byte-identical to the one it got before this key existed.
func TestIncusLimitsCpuIsSetBeforeStart(t *testing.T) {
	cmd, _ := writeMockIncus(t)
	log := withCmdLog(t)
	b := newTestIncusBackend(cmd)
	b.LimitsCPU = "8"
	ctx := context.Background()

	if _, err := b.Create(ctx, CreateArgs{Name: "garm-capped", SourceImage: "runner-linux"}); err != nil {
		t.Fatalf("Create: %v", err)
	}

	lines := readCmdLog(t, log)
	set := indexOfLine(lines, "config set garm-capped limits.cpu 8")
	if set < 0 {
		t.Fatalf("limits.cpu was never set; log:\n%s", strings.Join(lines, "\n"))
	}
	start := indexOfLine(lines, "start garm-capped")
	if start < 0 {
		t.Fatalf("container never started; log:\n%s", strings.Join(lines, "\n"))
	}
	if set > start {
		t.Fatalf("limits.cpu set AFTER start (set=%d start=%d): a cap applied post-boot lets cloud-init and the runner start-up see every host thread\n%s",
			set, start, strings.Join(lines, "\n"))
	}

	// ---- negative control: no cap requested => no cap applied -------------
	cmd2, _ := writeMockIncus(t)
	log2 := withCmdLog(t)
	b2 := newTestIncusBackend(cmd2)
	if _, err := b2.Create(ctx, CreateArgs{Name: "garm-uncapped", SourceImage: "runner-linux"}); err != nil {
		t.Fatalf("Create (uncapped): %v", err)
	}
	if i := indexOfLine(readCmdLog(t, log2), "limits.cpu"); i >= 0 {
		t.Fatalf("LimitsCPU unset but the backend still set limits.cpu; this key must be inert by default\n%s",
			strings.Join(readCmdLog(t, log2), "\n"))
	}
}

// TestIncusDeleteStopsAndWaitsBeforeDeleting is the H7 teardown-ordering gate.
//
// The old implementation was a single unconditional `incus delete --force`,
// which folds the stop into the delete and races incusd's unmount against the
// container's own references — 96.7% of the 8786 delete failures measured over
// 16 days on high-mem-server were `zfs destroy ...: dataset is busy`.
//
// NON-VACUITY IS STRUCTURAL, not asserted: the mock refuses a plain `delete` of
// a RUNNING container exactly as incusd does, so a Delete that skipped the stop
// could not reach a successful plain delete at all. And the mock reports
// `Stopping` for two polls after the stop, so a Delete that issued the stop but
// did not WAIT would delete while the container was still stopping.
func TestIncusDeleteStopsAndWaitsBeforeDeleting(t *testing.T) {
	cmd, _ := writeMockIncus(t)
	t.Setenv("MOCK_INCUS_STOP_SETTLE_POLLS", "2")
	log := withCmdLog(t)
	b := newTestIncusBackend(cmd)
	ctx := context.Background()

	if _, err := b.Create(ctx, CreateArgs{Name: "garm-td", SourceImage: "runner-linux"}); err != nil {
		t.Fatalf("Create: %v", err)
	}
	if err := b.Delete(ctx, "garm-td"); err != nil {
		t.Fatalf("Delete: %v", err)
	}

	lines := readCmdLog(t, log)
	stop := indexOfLine(lines, "stop", "garm-td")
	del := indexOfLine(lines, "delete", "garm-td")
	if stop < 0 {
		t.Fatalf("teardown never stopped the container; log:\n%s", strings.Join(lines, "\n"))
	}
	if del < 0 {
		t.Fatalf("teardown never deleted the container; log:\n%s", strings.Join(lines, "\n"))
	}
	if stop > del {
		t.Fatalf("stop issued AFTER delete (stop=%d delete=%d)\n%s", stop, del, strings.Join(lines, "\n"))
	}
	// The happy path must NOT use --force: force is the fallback, and if the
	// ordered path silently reached for it we would be back to the behaviour
	// this change exists to replace.
	if i := indexOfLine(lines, "delete", "--force"); i >= 0 {
		t.Fatalf("ordered teardown used `delete --force` on the happy path (line %d); that is the pre-fix behaviour\n%s",
			i, strings.Join(lines, "\n"))
	}
	// The wait must be a real poll, not a single look: with two settle polls
	// injected, at least three `list` probes must separate stop from delete.
	probes := 0
	for _, l := range lines[stop:del] {
		if strings.HasPrefix(l, "list ") {
			probes++
		}
	}
	if probes < 3 {
		t.Fatalf("only %d status probes between stop and delete; the teardown is not waiting for `Stopped`\n%s",
			probes, strings.Join(lines, "\n"))
	}
	if _, err := b.Get(ctx, "garm-td"); err != garmErrors.ErrNotFound {
		t.Fatalf("container survived Delete: %v", err)
	}
}

// TestIncusDeleteDetachesOnlyProviderAttachedDevices proves the middle step of
// the ordered teardown: the devices Create attached are removed before the
// delete, and nothing else is touched. Removing a device this provider did not
// add would be a mutation of somebody else's container.
func TestIncusDeleteDetachesOnlyProviderAttachedDevices(t *testing.T) {
	cmd, _ := writeMockIncus(t)
	log := withCmdLog(t)
	b := newTestIncusBackend(cmd)
	// GpuPassthrough attaches `gpu` + `nixstore`, ReprobuildStore attaches
	// `reprostore`, NestedKvm attaches `kvm` — four of the five devices Create
	// can attach, with no dependency on a NixOS host path. `nixdaemon` (the
	// fifth) is deliberately absent so the "detach it only if it is still
	// present" guard is exercised too.
	b.GpuPassthrough = true
	b.ReprobuildStore = t.TempDir()
	b.ReprobuildStoreGuestPath = "/srv/repro-store"
	b.NestedKvm = true
	ctx := context.Background()

	if _, err := b.Create(ctx, CreateArgs{Name: "garm-dev", SourceImage: "runner-linux"}); err != nil {
		t.Fatalf("Create: %v", err)
	}
	if err := b.Delete(ctx, "garm-dev"); err != nil {
		t.Fatalf("Delete: %v", err)
	}

	lines := readCmdLog(t, log)
	del := indexOfLine(lines, "delete", "garm-dev")
	for _, dev := range []string{"nixstore", "reprostore", "kvm", "gpu"} {
		i := indexOfLine(lines, "config device remove garm-dev "+dev)
		if i < 0 {
			t.Fatalf("device %q was never detached before delete\n%s", dev, strings.Join(lines, "\n"))
		}
		if i > del {
			t.Fatalf("device %q detached AFTER delete (%d > %d)\n%s", dev, i, del, strings.Join(lines, "\n"))
		}
	}
	// A provider device that was never attached must not be detached either:
	// the teardown removes what is present, it does not fire blind.
	if i := indexOfLine(lines, "config device remove garm-dev nixdaemon"); i >= 0 {
		t.Fatalf("teardown tried to remove a device that was never attached (line %d)\n%s",
			i, strings.Join(lines, "\n"))
	}
	// Never the profile-inherited devices.
	for _, dev := range []string{"eth0", "root"} {
		if i := indexOfLine(lines, "config device remove garm-dev "+dev); i >= 0 {
			t.Fatalf("teardown removed profile-inherited device %q (line %d); only provider-attached devices are ours\n%s",
				dev, i, strings.Join(lines, "\n"))
		}
	}
}

// TestIncusDeleteRetriesBusyDatasetLocally proves the bounded local ladder: a
// transient `zfs destroy ...: dataset is busy` resolves inside one Delete call
// instead of returning an error that escalates into GARM's unbounded 1 s→5 min
// retry ladder (workers/provider/instance_manager.go:127-136), which is what
// produced a median of 7 and up to 30 retries per instance on the host.
func TestIncusDeleteRetriesBusyDatasetLocally(t *testing.T) {
	cmd, _ := writeMockIncus(t)
	t.Setenv("MOCK_INCUS_DELETE_FAILURES", "3")
	log := withCmdLog(t)
	b := newTestIncusBackend(cmd)
	b.DeleteRetryBackoff = 5 * time.Millisecond
	ctx := context.Background()

	if _, err := b.Create(ctx, CreateArgs{Name: "garm-busy", SourceImage: "runner-linux"}); err != nil {
		t.Fatalf("Create: %v", err)
	}
	if err := b.Delete(ctx, "garm-busy"); err != nil {
		t.Fatalf("Delete did not absorb 3 transient busy-dataset failures: %v", err)
	}
	lines := readCmdLog(t, log)
	deletes := 0
	for _, l := range lines {
		if strings.HasPrefix(l, "delete ") {
			deletes++
		}
	}
	if deletes != 4 {
		t.Fatalf("expected 4 delete attempts (3 failed + 1 success), got %d\n%s", deletes, strings.Join(lines, "\n"))
	}
	if _, err := b.Get(ctx, "garm-busy"); err != garmErrors.ErrNotFound {
		t.Fatalf("container survived Delete: %v", err)
	}
}

// TestIncusDeleteFallsBackToForce proves the change can never delete FEWER
// containers than the one-shot `delete --force` it replaces: when the whole
// ordered ladder is exhausted, the pre-fix behaviour still runs as a last
// resort.
func TestIncusDeleteFallsBackToForce(t *testing.T) {
	cmd, _ := writeMockIncus(t)
	// One more failure than the ordered ladder has attempts, so every ordered
	// attempt fails and only the force fallback can succeed.
	t.Setenv("MOCK_INCUS_DELETE_FAILURES", "5")
	log := withCmdLog(t)
	b := newTestIncusBackend(cmd)
	b.DeleteRetryBackoff = 5 * time.Millisecond
	ctx := context.Background()

	if _, err := b.Create(ctx, CreateArgs{Name: "garm-stuck", SourceImage: "runner-linux"}); err != nil {
		t.Fatalf("Create: %v", err)
	}
	if err := b.Delete(ctx, "garm-stuck"); err != nil {
		t.Fatalf("Delete: force fallback did not run or did not succeed: %v", err)
	}
	lines := readCmdLog(t, log)
	if i := indexOfLine(lines, "delete", "--force", "garm-stuck"); i < 0 {
		t.Fatalf("force fallback never ran\n%s", strings.Join(lines, "\n"))
	}
	if _, err := b.Get(ctx, "garm-stuck"); err != garmErrors.ErrNotFound {
		t.Fatalf("container survived Delete: %v", err)
	}
}

// TestIncusDeleteReclaimsEvenWhenTheCallerContextExpires is the regression test
// for the ONE guarantee the ordered teardown makes to the rest of the system:
// it can never reclaim FEWER containers than the single unconditional
// `incus delete --force` it replaces.
//
// The guarantee is not self-evident, and it was briefly FALSE. The old code
// issued its one command at t=0 and beat any deadline the caller had. The
// ordered path spends real time first — stopping, waiting for `Stopped`, and
// backing off between attempts — so a caller deadline the old code beat is one
// the new code can run past. If the last-resort force delete inherited that
// expired context, `exec.CommandContext` would refuse to even spawn it and the
// container would survive a teardown that the old code completed. That is a
// reclamation REGRESSION produced by a change whose entire purpose is to
// reclaim better.
//
// This test pins the fix: a caller context that expires DURING the ordered
// teardown must still end with the container gone and `delete --force` issued.
// GARM's external-provider wrapper applies `exec_timeout_seconds` to this
// process, so the deadline is one config key away from being real.
func TestIncusDeleteReclaimsEvenWhenTheCallerContextExpires(t *testing.T) {
	cmd, _ := writeMockIncus(t)
	// Make the stop settle slowly enough that the caller's budget is consumed
	// inside the ordered path rather than before it starts.
	t.Setenv("MOCK_INCUS_STOP_SETTLE_POLLS", "200")
	log := withCmdLog(t)
	b := newTestIncusBackend(cmd)
	b.StopSettleTimeout = 10 * time.Second
	b.DeleteRetryBackoff = 5 * time.Millisecond

	if _, err := b.Create(context.Background(), CreateArgs{
		Name: "garm-ctxexpiry", SourceImage: "runner-linux",
	}); err != nil {
		t.Fatalf("Create: %v", err)
	}

	// A budget the old one-shot force delete would have met comfortably.
	ctx, cancel := context.WithTimeout(context.Background(), 400*time.Millisecond)
	defer cancel()
	derr := b.Delete(ctx, "garm-ctxexpiry")

	lines := readCmdLog(t, log)
	if i := indexOfLine(lines, "delete", "--force", "garm-ctxexpiry"); i < 0 {
		t.Fatalf("the caller's context expired and the last-resort force delete was SKIPPED, so this teardown reclaimed less than the one-shot force delete it replaces (Delete err: %v)\n%s",
			derr, strings.Join(lines, "\n"))
	}
	if _, err := b.Get(context.Background(), "garm-ctxexpiry"); err != garmErrors.ErrNotFound {
		t.Fatalf("container SURVIVED a teardown the pre-fix code would have completed: %v", err)
	}
	if derr != nil {
		t.Fatalf("container was reclaimed but Delete reported failure: %v", derr)
	}
}

// TestIncusDeleteSurfacesPersistentFailure is the counterpart negative control:
// when NOTHING can delete the container, Delete must report an error rather
// than silently returning success. A teardown that always returns nil would
// pass every test above and leak every container.
func TestIncusDeleteSurfacesPersistentFailure(t *testing.T) {
	cmd, _ := writeMockIncus(t)
	t.Setenv("MOCK_INCUS_DELETE_FAILURES", "99")
	b := newTestIncusBackend(cmd)
	b.DeleteRetryBackoff = 5 * time.Millisecond
	ctx := context.Background()

	if _, err := b.Create(ctx, CreateArgs{Name: "garm-perma", SourceImage: "runner-linux"}); err != nil {
		t.Fatalf("Create: %v", err)
	}
	err := b.Delete(ctx, "garm-perma")
	if err == nil {
		t.Fatal("Delete returned success while the container still exists")
	}
	if !strings.Contains(err.Error(), "dataset is busy") {
		t.Fatalf("error lost the underlying cause, which is what the operator needs: %v", err)
	}
	if _, gerr := b.Get(ctx, "garm-perma"); gerr != nil {
		t.Fatalf("container should still exist after a failed delete: %v", gerr)
	}
}

// TestIncusDeleteToleratesStopFailure proves a stop that cannot be issued does
// not abort the teardown: the force fallback still reclaims the container. A
// teardown that turned a stop error into a hard failure would REGRESS against
// the one-shot force delete it replaces.
func TestIncusDeleteToleratesStopFailure(t *testing.T) {
	cmd, _ := writeMockIncus(t)
	log := withCmdLog(t)
	b := newTestIncusBackend(cmd)
	b.DeleteRetryBackoff = 5 * time.Millisecond
	b.StopSettleTimeout = 50 * time.Millisecond
	ctx := context.Background()

	if _, err := b.Create(ctx, CreateArgs{Name: "garm-nostop", SourceImage: "runner-linux"}); err != nil {
		t.Fatalf("Create: %v", err)
	}
	t.Setenv("MOCK_INCUS_STOP_FAILS", "1")
	if err := b.Delete(ctx, "garm-nostop"); err != nil {
		t.Fatalf("Delete: a stop failure must not abort teardown: %v", err)
	}
	if i := indexOfLine(readCmdLog(t, log), "delete", "--force", "garm-nostop"); i < 0 {
		t.Fatalf("expected the force fallback to reclaim the still-running container\n%s",
			strings.Join(readCmdLog(t, log), "\n"))
	}
	if _, err := b.Get(ctx, "garm-nostop"); err != garmErrors.ErrNotFound {
		t.Fatalf("container survived Delete: %v", err)
	}
}
