// Copyright 2026 Metacraft Labs
//
//    Licensed under the Apache License, Version 2.0 (the "License"); you may
//    not use this file except in compliance with the License. You may obtain a
//    copy of the License at
//
//         http://www.apache.org/licenses/LICENSE-2.0
//
//    Unless required by applicable law or agreed to in writing, software
//    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
//    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.

package backend

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	garmErrors "github.com/cloudbase/garm-provider-common/errors"
)

// GitHub Actions jobs may run for up to six hours by default. Keep every
// one-shot guest alive beyond that boundary so boot, package installation, and
// runner cleanup do not consume part of the job's usable window. vm-harness'
// default is only 600 seconds, which deterministically terminates long Linux
// and macOS jobs while the foreground ephemeral runner is still busy.
const runnerTimeoutSec = "43200"

// VMHarnessRunBackend drives vm-harness backends whose lifecycle is already
// one-shot and self-cleaning. It starts `vm-harness run` in the background and
// records only a pid + metadata file under StateDir, keeping the provider
// stateless with respect to GARM's own DB.
type VMHarnessRunBackend struct {
	VMHarnessPath string
	BackendID     string
	GuestOS       string
	StateDir      string
}

type vmhState struct {
	ProviderID      string   `json:"provider_id"`
	Name            string   `json:"name"`
	ControllerID    string   `json:"controller_id"`
	PoolID          string   `json:"pool_id"`
	OSName          string   `json:"os_name"`
	OSVersion       string   `json:"os_version"`
	OSArch          string   `json:"os_arch"`
	PID             int      `json:"pid"`
	OutputDir       string   `json:"output_dir"`
	Bootstrap       string   `json:"bootstrap"`
	EphemeralPrefix string   `json:"ephemeral_prefix,omitempty"`
	Addresses       []string `json:"addresses"`
}

func (b *VMHarnessRunBackend) instanceDir(name string) string {
	return filepath.Join(b.StateDir, "instances", name)
}

func (b *VMHarnessRunBackend) statePath(name string) string {
	return filepath.Join(b.instanceDir(name), "state.json")
}

func (b *VMHarnessRunBackend) tartEphemeralPrefix(name string) string {
	switch b.BackendID {
	case "tart-macos":
		return "repro-vm-tart-macos-" + name
	case "tart-linux-arm":
		return "repro-vm-tart-linux-" + name
	default:
		return ""
	}
}

func (b *VMHarnessRunBackend) load(name string) (vmhState, error) {
	data, err := os.ReadFile(b.statePath(name))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return vmhState{}, garmErrors.ErrNotFound
		}
		return vmhState{}, err
	}
	var st vmhState
	if err := json.Unmarshal(data, &st); err != nil {
		return vmhState{}, err
	}
	return st, nil
}

func (b *VMHarnessRunBackend) save(st vmhState) error {
	if err := os.MkdirAll(b.instanceDir(st.Name), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(b.statePath(st.Name), data, 0o644)
}

func processRunning(pid int) bool {
	if pid <= 0 {
		return false
	}
	p, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	return p.Signal(syscall.Signal(0)) == nil
}

func vmHarnessChildEnv(backendID string) []string {
	env := os.Environ()
	out := make([]string, 0, len(env))
	hasTartHome := false
	tartStateDir := ""
	for _, entry := range env {
		if strings.HasPrefix(entry, "XPC_SERVICE_NAME=") {
			continue
		}
		if strings.HasPrefix(entry, "TART_HOME=") {
			hasTartHome = true
		}
		// The Cirrus Tart bases do not ship a Nix client/daemon. Mounting only
		// the host's read-only store therefore leaves /nix unusable and makes
		// the standard Nix installer fail. Keep Tart guests isolated with a
		// writable guest-local store until the backend can safely expose a
		// complete daemon-backed shared store.
		if (backendID == "tart-macos" || backendID == "tart-linux-arm") && strings.HasPrefix(entry, "MCL_RUNNER_SHARED_NIX_STORE=") {
			continue
		}
		if strings.HasPrefix(entry, "VM_HARNESS_TART_STATE_DIR=") {
			tartStateDir = strings.TrimPrefix(entry, "VM_HARNESS_TART_STATE_DIR=")
		}
		out = append(out, entry)
	}
	if !hasTartHome && tartStateDir != "" {
		out = append(out, "TART_HOME="+tartStateDir)
	}
	return out
}

func powerShellSingleQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}

func windowsBootstrapCommand(guestPath string) []string {
	script := strings.Join([]string{
		"$bootstrapExitCode = $null",
		"& " + powerShellSingleQuote(guestPath),
		"$bootstrapExitCode = $LASTEXITCODE",
		"if ($bootstrapExitCode -ne $null -and $bootstrapExitCode -ne 0) { exit $bootstrapExitCode }",
		"$deadline = (Get-Date).AddMinutes(10)",
		"$runnerService = $null",
		"$runnerProcess = $null",
		"while ((Get-Date) -lt $deadline) {",
		"  $runnerService = Get-Service -Name 'actions.runner.*' -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' } | Select-Object -First 1",
		"  $runnerProcess = Get-Process -Name 'Runner.Listener' -ErrorAction SilentlyContinue | Select-Object -First 1",
		"  if ($runnerService -or $runnerProcess) { break }",
		"  Start-Sleep -Seconds 5",
		"}",
		"if (-not $runnerService -and -not $runnerProcess) {",
		"  Write-Host 'GitHub Actions runner service/process did not start after bootstrap'",
		"  exit 1",
		"}",
		"while ($true) {",
		"  $runnerService = Get-Service -Name 'actions.runner.*' -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' } | Select-Object -First 1",
		"  $runnerProcess = Get-Process -Name 'Runner.Listener' -ErrorAction SilentlyContinue | Select-Object -First 1",
		"  if (-not $runnerService -and -not $runnerProcess) { break }",
		"  Start-Sleep -Seconds 30",
		"}",
	}, "; ")
	return []string{"powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script}
}

func (b *VMHarnessRunBackend) toInstance(st vmhState) Instance {
	status := "stopped"
	// vm-harness writes DONE only after the guest command has exited and its
	// cleanup has completed.  Prefer that durable terminal marker over kill(0):
	// on Darwin a released child may remain visible as a zombie (or its PID may
	// be reused), which otherwise leaves a failed runner stuck as "running" and
	// permanently consumes scale-set capacity.
	_, terminalErr := os.Stat(filepath.Join(st.OutputDir, "DONE"))
	terminal := terminalErr == nil
	if !terminal && processRunning(st.PID) {
		status = "running"
	}
	return Instance{
		ProviderID:   st.ProviderID,
		Name:         st.Name,
		ControllerID: st.ControllerID,
		PoolID:       st.PoolID,
		OSName:       st.OSName,
		OSVersion:    st.OSVersion,
		OSArch:       st.OSArch,
		Status:       status,
		Addresses:    st.Addresses,
	}
}

func (b *VMHarnessRunBackend) Create(ctx context.Context, args CreateArgs) (Instance, error) {
	if args.SourceImage == "" {
		return Instance{}, fmt.Errorf("vm-harness Create: SourceImage (baseline/golden) is required")
	}
	dir := b.instanceDir(args.Name)
	outDir := filepath.Join(dir, "run")
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return Instance{}, err
	}

	guestPath := "/tmp/garm-bootstrap.sh"
	bootstrapPath := filepath.Join(dir, "garm-bootstrap.sh")
	// --baseline names the baseline; --source-image is what vm-harness
	// actually resolves the golden from (cli.nim applyDefaults maps them to
	// BaselineSpec.name and BaselineSpec.sourceImage respectively). Passing
	// only --baseline left sourceImage empty, and the two backends disagreed
	// about that: qemu-windows-arm falls back to spec.name, but the tart
	// backends silently substituted their built-in cirruslabs golden and
	// ignored the configured image entirely. Pass both.
	argv := []string{
		"run", "--backend", b.BackendID, "--guest", b.GuestOS,
		"--baseline", args.SourceImage, "--source-image", args.SourceImage,
		"--output-dir", outDir,
		"--timeout-sec", runnerTimeoutSec,
	}
	ephemeralPrefix := b.tartEphemeralPrefix(args.Name)
	if ephemeralPrefix != "" {
		argv = append(argv, "--ephemeral-prefix", ephemeralPrefix)
	}
	if strings.EqualFold(args.OSName, "windows") || b.GuestOS == "windows" {
		guestPath = `C:\garm-bootstrap.ps1`
		bootstrapPath = filepath.Join(dir, "garm-bootstrap.ps1")
		argv = append(argv, "--copy-to", bootstrapPath+":"+guestPath, "--")
		argv = append(argv, windowsBootstrapCommand(guestPath)...)
	} else {
		argv = append(argv, "--copy-to", bootstrapPath+":"+guestPath, "--", "/bin/sh", "-c", "chmod +x "+guestPath+" && exec "+guestPath)
	}
	if err := os.WriteFile(bootstrapPath, args.Bootstrap, 0o755); err != nil {
		return Instance{}, err
	}

	cmdPath := b.VMHarnessPath
	cmdArgs := argv
	runAsConsoleUser := false
	if uid := os.Getenv("VM_HARNESS_DARWIN_ASUSER_UID"); uid != "" {
		launchctl := os.Getenv("VM_HARNESS_DARWIN_LAUNCHCTL")
		if launchctl == "" {
			launchctl = "/bin/launchctl"
		}
		cmdPath = launchctl
		if ephemeralPrefix != "" {
			// Tart links AppKit even for --no-graphics. Merely entering the
			// console user's bootstrap namespace while retaining uid 0 can
			// deadlock AppKit/LaunchServices during NSApplication startup on
			// current macOS releases. Run Tart's vm-harness process as the
			// actual console user and preserve the explicitly allow-listed
			// provider environment through sudo. Windows QEMU remains root.
			uidNum, err := strconv.Atoi(uid)
			if err != nil || uidNum < 0 {
				return Instance{}, fmt.Errorf("invalid VM_HARNESS_DARWIN_ASUSER_UID %q", uid)
			}
			if err := os.Chown(outDir, uidNum, -1); err != nil {
				return Instance{}, fmt.Errorf("chown vm-harness output directory to uid %d: %w", uidNum, err)
			}
			runAsConsoleUser = true
			cmdArgs = append([]string{"asuser", uid, "/usr/bin/sudo", "-E", "-u", "#" + uid, "--", b.VMHarnessPath}, argv...)
		} else {
			cmdArgs = append([]string{"asuser", uid, b.VMHarnessPath}, argv...)
		}
	}
	cmd := exec.Command(cmdPath, cmdArgs...)
	if runAsConsoleUser {
		// GARM's service working directory is deliberately root-only. A child
		// after setuid cannot even resolve that inherited cwd, and Nim calls
		// getCurrentDir before launching Tart. The per-instance output directory
		// was just chowned to the console user and is otherwise self-contained.
		cmd.Dir = outDir
	}
	cmd.Env = vmHarnessChildEnv(b.BackendID)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	logFile, err := os.OpenFile(filepath.Join(dir, "vm-harness.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return Instance{}, err
	}
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	if err := cmd.Start(); err != nil {
		_ = logFile.Close()
		return Instance{}, err
	}
	_ = logFile.Close()

	if err := waitPastStartup(cmd.Process.Pid, filepath.Join(dir, "vm-harness.log")); err != nil {
		return Instance{}, err
	}

	st := vmhState{
		ProviderID:      args.Name,
		Name:            args.Name,
		ControllerID:    args.ControllerID,
		PoolID:          args.PoolID,
		OSName:          args.OSName,
		OSVersion:       args.OSVersion,
		OSArch:          args.OSArch,
		PID:             cmd.Process.Pid,
		OutputDir:       outDir,
		Bootstrap:       bootstrapPath,
		EphemeralPrefix: ephemeralPrefix,
	}
	if err := b.save(st); err != nil {
		return Instance{}, err
	}
	if err := cmd.Process.Release(); err != nil {
		return Instance{}, err
	}
	return b.toInstance(st), nil
}

// defaultStartupGrace bounds how long Create watches a freshly started
// vm-harness before accepting it as launched. Every backend keeps the direct
// child alive for the whole guest lifetime — Delete and ListInstances already
// depend on that — so a child that is gone this early has failed, not
// daemonised. VMH_PROVIDER_STARTUP_GRACE_SEC is the escape hatch if a future
// backend ever forks and exits instead.
//
// The faults this catches (an absent or unreadable golden) abort vm-harness
// during argument and baseline validation, well inside a second. The window is
// deliberately not widened further: it is paid in full on every healthy
// Create, and later failures remain the bootstrap timeout's job.
const defaultStartupGrace = 2 * time.Second

const startupPollInterval = 100 * time.Millisecond

func startupGrace() time.Duration {
	if v := os.Getenv("VMH_PROVIDER_STARTUP_GRACE_SEC"); v != "" {
		if secs, err := strconv.Atoi(v); err == nil && secs >= 0 {
			return time.Duration(secs) * time.Second
		}
	}
	return defaultStartupGrace
}

// waitPastStartup fails when vm-harness exits during the grace window.
//
// Create previously returned success as soon as cmd.Start() succeeded, so a
// guest that died immediately — a missing or invalid golden being the common
// case — was recorded as a healthy instance. GARM then waited out the full
// runner bootstrap timeout, reaped the instance and created another, giving an
// unbounded retry loop that surfaced on no provider error metric at all.
// Anything that kills vm-harness this early is a provisioning fault.
func waitPastStartup(pid int, logPath string) error {
	deadline := time.Now().Add(startupGrace())
	for {
		var ws syscall.WaitStatus
		wpid, err := syscall.Wait4(pid, &ws, syscall.WNOHANG, nil)
		if err != nil {
			// Not reapable from here. Prefer accepting a launch that may be
			// healthy over failing one that is.
			return nil
		}
		if wpid == pid {
			return fmt.Errorf(
				"vm-harness exited during startup (%s): %s",
				describeWaitStatus(ws), tailFile(logPath, 2048))
		}
		if !time.Now().Before(deadline) {
			return nil
		}
		time.Sleep(startupPollInterval)
	}
}

func describeWaitStatus(ws syscall.WaitStatus) string {
	if ws.Signaled() {
		return "killed by signal " + ws.Signal().String()
	}
	return "exit status " + strconv.Itoa(ws.ExitStatus())
}

// tailFile returns up to max trailing bytes of path for use in error messages.
func tailFile(path string, max int64) string {
	f, err := os.Open(path)
	if err != nil {
		return "(no vm-harness log)"
	}
	defer func() { _ = f.Close() }()
	fi, err := f.Stat()
	if err != nil {
		return "(no vm-harness log)"
	}
	if fi.Size() > max {
		if _, err := f.Seek(-max, io.SeekEnd); err != nil {
			return "(no vm-harness log)"
		}
	}
	data, err := io.ReadAll(f)
	if err != nil || len(data) == 0 {
		return "(empty vm-harness log)"
	}
	return strings.TrimSpace(string(data))
}

func (b *VMHarnessRunBackend) Delete(ctx context.Context, idOrName string) error {
	st, err := b.load(idOrName)
	if err != nil {
		return nil
	}
	if st.PID > 0 {
		// The process-group leader (vm-harness) can exit before a Tart child.
		// Signal the group even when kill(pid, 0) says the leader is gone.
		_ = syscall.Kill(-st.PID, syscall.SIGTERM)
	}
	if processRunning(st.PID) {
		if p, err := os.FindProcess(st.PID); err == nil {
			_ = p.Signal(syscall.SIGTERM)
		}
	}
	if st.EphemeralPrefix != "" {
		b.cleanupTartEphemerals(ctx, st.EphemeralPrefix)
	}
	return os.RemoveAll(b.instanceDir(st.Name))
}

func (b *VMHarnessRunBackend) cleanupTartEphemerals(ctx context.Context, prefix string) {
	if prefix == "" {
		return
	}
	cmd := exec.CommandContext(ctx, "tart", "list")
	cmd.Env = vmHarnessChildEnv(b.BackendID)
	out, err := cmd.Output()
	if err != nil {
		return
	}
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 || !strings.EqualFold(fields[0], "local") || !strings.HasPrefix(fields[1], prefix) {
			continue
		}
		stop := exec.CommandContext(ctx, "tart", "stop", fields[1])
		stop.Env = vmHarnessChildEnv(b.BackendID)
		_ = stop.Run()
		del := exec.CommandContext(ctx, "tart", "delete", fields[1])
		del.Env = vmHarnessChildEnv(b.BackendID)
		_ = del.Run()
	}
}

// pruneStem is the shared ephemeral-name prefix vm-harness stamps onto every
// instance this backend starts. Per-instance Create prefixes extend it with
// the runner name, so the stem matches all of a backend's ephemerals at once.
// Empty means the backend has no vm-harness-managed ephemerals to reclaim.
func (b *VMHarnessRunBackend) pruneStem() string {
	switch b.BackendID {
	case "tart-macos":
		return "repro-vm-tart-macos"
	case "tart-linux-arm":
		return "repro-vm-tart-linux"
	case "qemu-windows-arm":
		// qemu-windows-arm Create passes no --ephemeral-prefix, so vm-harness
		// uses its DefaultQemuWindowsArmPrefix for every instance.
		return "repro-vm-qemu-windows-arm"
	default:
		return ""
	}
}

func (b *VMHarnessRunBackend) pruneBackendArg() string {
	switch b.BackendID {
	case "tart-macos", "tart-linux-arm":
		return "tart"
	case "qemu-windows-arm":
		return "qemu-windows-arm"
	default:
		return "all"
	}
}

// Sweep reclaims ephemeral resources leaked by vm-harness launchers that were
// hard-killed (host crash, OOM, service restart) before their own teardown —
// and before Delete — could run: orphaned qemu overlay directories, stranded
// Tart clones, and stale SSH-password/scratch files in the temp dir. It shells
// `vm-harness prune`, scoped to this backend's shared ephemeral prefix so it
// never touches another project's resources, and is safe to call at any time:
// vm-harness refuses to remove any instance whose owner is still alive (advisory
// lock held, or creator PID live). Best-effort — failures are swallowed.
func (b *VMHarnessRunBackend) Sweep(ctx context.Context) {
	stem := b.pruneStem()
	if stem == "" {
		return
	}
	argv := []string{
		"prune",
		"--ephemeral-prefix", stem,
		"--backend", b.pruneBackendArg(),
		"--sweep-tmp",
		"--log-format", "json",
	}
	// qemu-windows-arm keeps its overlay instances under vm-harness' own state
	// dir. Point prune at the same one the run path uses when it is overridden;
	// otherwise both default off the shared HOME and agree implicitly.
	if b.BackendID == "qemu-windows-arm" {
		if sd := os.Getenv("VM_HARNESS_QEMU_WINDOWS_ARM_STATE_DIR"); sd != "" {
			argv = append(argv, "--state-dir", sd)
		}
	}
	cmd := exec.CommandContext(ctx, b.VMHarnessPath, argv...)
	cmd.Env = vmHarnessChildEnv(b.BackendID)
	_ = cmd.Run()
}

func (b *VMHarnessRunBackend) Get(ctx context.Context, idOrName string) (Instance, error) {
	st, err := b.load(idOrName)
	if err != nil {
		return Instance{}, err
	}
	return b.toInstance(st), nil
}

func (b *VMHarnessRunBackend) listFiltered(keep func(vmhState) bool) ([]Instance, error) {
	root := filepath.Join(b.StateDir, "instances")
	entries, err := os.ReadDir(root)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	var out []Instance
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		st, err := b.load(e.Name())
		if err != nil || !keep(st) {
			continue
		}
		out = append(out, b.toInstance(st))
	}
	return out, nil
}

func (b *VMHarnessRunBackend) List(ctx context.Context, poolID string) ([]Instance, error) {
	return b.listFiltered(func(st vmhState) bool { return st.PoolID == poolID })
}

func (b *VMHarnessRunBackend) ListByController(ctx context.Context, controllerID string) ([]Instance, error) {
	return b.listFiltered(func(st vmhState) bool { return st.ControllerID == controllerID })
}

func (b *VMHarnessRunBackend) Start(ctx context.Context, idOrName string) error {
	st, err := b.load(idOrName)
	if err != nil {
		return err
	}
	if processRunning(st.PID) {
		return nil
	}
	return fmt.Errorf("vm-harness instance %s has exited; create a replacement runner", idOrName)
}

func (b *VMHarnessRunBackend) Stop(ctx context.Context, idOrName string, force bool) error {
	return b.Delete(ctx, idOrName)
}
