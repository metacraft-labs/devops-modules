package backend

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// GATE t_vmharness_image_is_honoured, assertion (a): "the local-exec provider
// passes the configured image on the flag vm-harness actually resolves from".
// The gate is wired as checks.t_vmharness_image_is_honoured in
// nixos-modules/checks/vmharness-image-is-honoured.nix, which selects every
// TestVMHarnessImageIsHonoured* test in this package; assertions (b) and (c)
// live in remote_test.go and in vm-harness'
// tests/unit/t_vmharness_image_is_honoured.nim respectively.
//
// vm-harness resolves the golden from --source-image, not --baseline: cli.nim's
// applyDefaults maps the two flags to BaselineSpec.sourceImage and
// BaselineSpec.name respectively. Passing only --baseline left sourceImage
// empty, and the tart backends answer that by substituting their built-in
// cirruslabs golden, so the configured image was silently discarded and macOS
// runners booted an image nobody declared. Assert both flags carry it, for
// every backend id the provider drives over the local-exec path — the argv is
// built once but the Windows branch appends a different tail, so covering only
// a tart id would leave the qemu-windows-arm argv unproven.
func TestVMHarnessImageIsHonouredLocalExecPassesSourceImage(t *testing.T) {
	cases := []struct {
		backendID string
		guestOS   string
		osName    string
		bootstrap string
	}{
		{"tart-macos", "macos", "macos", "#!/bin/sh\necho hi\n"},
		{"tart-linux-arm", "linux", "linux", "#!/bin/sh\necho hi\n"},
		{"qemu-windows-arm", "windows", "windows", "echo hi\n"},
	}
	for _, tc := range cases {
		t.Run(tc.backendID, func(t *testing.T) {
			t.Setenv("VM_HARNESS_DARWIN_ASUSER_UID", "")
			tmp := t.TempDir()
			logPath := filepath.Join(tmp, "argv.log")
			mock := filepath.Join(tmp, "vm-harness")
			script := "#!/bin/sh\n" +
				"printf '%s\\n' \"$@\" > " + shellSingleQuote(logPath) + "\n" +
				"sleep 30\n"
			if err := os.WriteFile(mock, []byte(script), 0o755); err != nil {
				t.Fatal(err)
			}

			const wantImage = "ghcr.io/metacraft-labs/macos-tart-runner:tahoe-nix-v1"
			b := &VMHarnessRunBackend{
				VMHarnessPath: mock,
				BackendID:     tc.backendID,
				GuestOS:       tc.guestOS,
				StateDir:      filepath.Join(tmp, "state"),
			}
			inst, err := b.Create(context.Background(), CreateArgs{
				Name:        "garm-source-image-test",
				SourceImage: wantImage,
				OSName:      tc.osName,
				Bootstrap:   []byte(tc.bootstrap),
			})
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = b.Delete(context.Background(), inst.Name) }()

			var argv string
			deadline := time.Now().Add(3 * time.Second)
			for time.Now().Before(deadline) {
				if data, err := os.ReadFile(logPath); err == nil {
					argv = string(data)
					break
				}
				time.Sleep(25 * time.Millisecond)
			}
			if argv == "" {
				t.Fatal("mock vm-harness did not record argv")
			}
			if !strings.Contains(argv, "--source-image\n"+wantImage+"\n") {
				t.Fatalf("Create did not pass --source-image; vm-harness would fall back to its\nbuilt-in golden and ignore the configured image. argv:\n%s", argv)
			}
			if !strings.Contains(argv, "--baseline\n"+wantImage+"\n") {
				t.Fatalf("Create dropped --baseline, which the qemu-windows-arm backend\nresolves the golden directory from. argv:\n%s", argv)
			}
		})
	}
}

// GATE t_vmharness_image_is_honoured — the negative half of assertion (a): a
// Create with no configured image must not reach vm-harness at all. An empty
// --source-image reads as "configured, to the empty string" rather than as
// absent, which is the shape that let a default be substituted in the first
// place.
func TestVMHarnessImageIsHonouredLocalExecRefusesEmptyImage(t *testing.T) {
	t.Setenv("VM_HARNESS_DARWIN_ASUSER_UID", "")
	tmp := t.TempDir()
	mock := filepath.Join(tmp, "vm-harness")
	if err := os.WriteFile(mock, []byte("#!/bin/sh\nsleep 30\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	b := &VMHarnessRunBackend{
		VMHarnessPath: mock,
		BackendID:     "tart-macos",
		GuestOS:       "macos",
		StateDir:      filepath.Join(tmp, "state"),
	}
	_, err := b.Create(context.Background(), CreateArgs{
		Name:      "garm-no-image",
		OSName:    "macos",
		Bootstrap: []byte("#!/bin/sh\necho hi\n"),
	})
	if err == nil {
		t.Fatal("Create with no SourceImage should fail rather than let vm-harness pick a default")
	}
	if !strings.Contains(err.Error(), "SourceImage") {
		t.Fatalf("Create error does not name the missing image: %v", err)
	}
}

// GATE t_vmharness_create_fails_on_dead_guest — "a vm-harness that exits during
// baseline validation makes Create return an error carrying the child's exit
// status and log tail, and persists NO instance state". Wired as
// checks.t_vmharness_create_fails_on_dead_guest in
// nixos-modules/checks/vmharness-image-is-honoured.nix.
//
// A guest that dies during vm-harness' own baseline validation — a missing or
// unreadable golden being the case seen in production — must surface as a
// failed Create. Reporting success there recorded a dead instance as healthy,
// so GARM waited out the full bootstrap timeout, reaped it, and immediately
// created another, looping indefinitely with no provider error ever recorded.
func TestVMHarnessCreateFailsOnDeadGuest(t *testing.T) {
	t.Setenv("VM_HARNESS_DARWIN_ASUSER_UID", "")
	tmp := t.TempDir()
	mock := filepath.Join(tmp, "vm-harness")
	script := "#!/bin/sh\n" +
		"echo 'Error: unhandled exception: baseline directory must contain windows.qcow2' >&2\n" +
		"exit 1\n"
	if err := os.WriteFile(mock, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}

	stateDir := filepath.Join(tmp, "state")
	b := &VMHarnessRunBackend{
		VMHarnessPath: mock,
		BackendID:     "qemu-windows-arm",
		GuestOS:       "windows",
		StateDir:      stateDir,
	}
	const name = "garm-dead-on-arrival"
	_, err := b.Create(context.Background(), CreateArgs{
		Name:         name,
		SourceImage:  filepath.Join(tmp, "golden", "win-arm-runner"),
		OSName:       "windows",
		ControllerID: "ctrl-1",
		PoolID:       "pool-1",
		Bootstrap:    []byte("echo hi\n"),
	})
	if err == nil {
		t.Fatal("Create reported success for a vm-harness that exited immediately")
	}
	if !strings.Contains(err.Error(), "exit status 1") {
		t.Fatalf("Create error lost the child's exit status: %v", err)
	}
	if !strings.Contains(err.Error(), "windows.qcow2") {
		t.Fatalf("Create error did not carry the vm-harness log tail, which is the\nonly place the actual cause appears: %v", err)
	}

	// NO instance state. Assert it at the path the backend really writes
	// (StateDir/instances/<name>/state.json) and, independently, through the
	// two read paths GARM uses — a stat of a path the backend never writes to
	// would pass no matter what Create persisted.
	if _, statErr := os.Stat(filepath.Join(stateDir, "instances", name, "state.json")); statErr == nil {
		t.Fatal("Create persisted state for an instance that never started")
	}
	if _, getErr := b.Get(context.Background(), name); getErr == nil {
		t.Fatal("Get resolved an instance whose Create failed")
	}
	if insts, listErr := b.List(context.Background(), "pool-1"); listErr != nil || len(insts) != 0 {
		t.Fatalf("List returned %d instances (err %v) after a failed Create", len(insts), listErr)
	}
	if insts, listErr := b.ListByController(context.Background(), "ctrl-1"); listErr != nil || len(insts) != 0 {
		t.Fatalf("ListByController returned %d instances (err %v) after a failed Create", len(insts), listErr)
	}
}

func TestVMHarnessChildEnvDropsSharedNixStoreOnlyForTartGuests(t *testing.T) {
	t.Setenv("MCL_RUNNER_SHARED_NIX_STORE", "/nix/store")

	hasSharedStore := func(env []string) bool {
		for _, entry := range env {
			if entry == "MCL_RUNNER_SHARED_NIX_STORE=/nix/store" {
				return true
			}
		}
		return false
	}

	for _, backendID := range []string{"tart-macos", "tart-linux-arm"} {
		if hasSharedStore(vmHarnessChildEnv(backendID)) {
			t.Fatalf("%s child retained the incomplete shared Nix store", backendID)
		}
	}
	if !hasSharedStore(vmHarnessChildEnv("qemu-windows-arm")) {
		t.Fatal("non-Tart child unexpectedly lost the shared Nix store environment")
	}
}

func TestVMHarnessRunBackendMacOSCreateCommand(t *testing.T) {
	t.Setenv("VM_HARNESS_DARWIN_ASUSER_UID", "")
	oldTartHome, hadTartHome := os.LookupEnv("TART_HOME")
	if err := os.Unsetenv("TART_HOME"); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if hadTartHome {
			_ = os.Setenv("TART_HOME", oldTartHome)
		} else {
			_ = os.Unsetenv("TART_HOME")
		}
	})
	tmp := t.TempDir()
	logPath := filepath.Join(tmp, "argv.log")
	envPath := filepath.Join(tmp, "env.log")
	mock := filepath.Join(tmp, "vm-harness")
	script := "#!/bin/sh\n" +
		"printf '%s\\n' \"$@\" > " + shellSingleQuote(logPath) + "\n" +
		"env > " + shellSingleQuote(envPath) + "\n" +
		"sleep 30\n"
	if err := os.WriteFile(mock, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("XPC_SERVICE_NAME", "org.nixos.garm")
	t.Setenv("VM_HARNESS_TART_STATE_DIR", filepath.Join(tmp, "tart-home"))
	t.Setenv("VM_HARNESS_TEST_KEEP", "yes")
	t.Setenv("MCL_RUNNER_SHARED_NIX_STORE", "/nix/store")

	b := &VMHarnessRunBackend{
		VMHarnessPath: mock,
		BackendID:     "tart-macos",
		GuestOS:       "macos",
		StateDir:      filepath.Join(tmp, "state"),
	}
	inst, err := b.Create(context.Background(), CreateArgs{
		Name:         "garm-macos-test",
		ControllerID: "controller",
		PoolID:       "pool",
		SourceImage:  "ghcr.io/cirruslabs/macos-tahoe-base:latest",
		OSName:       "macos",
		OSVersion:    "tahoe",
		OSArch:       "arm64",
		Bootstrap:    []byte("#!/bin/sh\necho macos\n"),
	})
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		_ = b.Delete(context.Background(), inst.Name)
	}()

	deadline := time.Now().Add(3 * time.Second)
	var argv string
	for time.Now().Before(deadline) {
		data, err := os.ReadFile(logPath)
		if err == nil {
			argv = string(data)
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if argv == "" {
		t.Fatal("mock vm-harness did not record argv")
	}
	var envData []byte
	for time.Now().Before(deadline) {
		data, err := os.ReadFile(envPath)
		if err == nil && strings.Contains(string(data), "VM_HARNESS_TEST_KEEP=yes") {
			envData = data
			break
		}
		time.Sleep(25 * time.Millisecond)
	}
	if len(envData) == 0 {
		t.Fatal("mock vm-harness did not record its complete environment")
	}
	if strings.Contains(string(envData), "XPC_SERVICE_NAME=") {
		t.Fatalf("vm-harness child env leaked launchd XPC identity:\n%s", string(envData))
	}
	if !strings.Contains(string(envData), "VM_HARNESS_TEST_KEEP=yes") {
		t.Fatalf("vm-harness child env dropped unrelated environment:\n%s", string(envData))
	}
	if !strings.Contains(string(envData), "TART_HOME="+filepath.Join(tmp, "tart-home")) {
		t.Fatalf("vm-harness child env did not derive TART_HOME from VM_HARNESS_TART_STATE_DIR:\n%s", string(envData))
	}
	if strings.Contains(string(envData), "MCL_RUNNER_SHARED_NIX_STORE=") {
		t.Fatalf("Tart vm-harness child retained the host Nix store mount:\n%s", string(envData))
	}
	for _, want := range []string{
		"run\n",
		"--backend\n",
		"tart-macos\n",
		"--guest\n",
		"macos\n",
		"--baseline\n",
		"ghcr.io/cirruslabs/macos-tahoe-base:latest\n",
		"--ephemeral-prefix\n",
		"repro-vm-tart-macos-garm-macos-test\n",
		"--copy-to\n",
		"/tmp/garm-bootstrap.sh\n",
		"--\n",
		"/bin/sh\n",
		"-c\n",
		"chmod +x /tmp/garm-bootstrap.sh && exec /tmp/garm-bootstrap.sh\n",
	} {
		if !strings.Contains(argv, want) {
			t.Fatalf("argv missing %q:\n%s", want, argv)
		}
	}

	st, err := b.load("garm-macos-test")
	if err != nil {
		t.Fatal(err)
	}
	if st.OSName != "macos" || st.OSArch != "arm64" {
		t.Fatalf("state OS metadata = %s/%s, want macos/arm64", st.OSName, st.OSArch)
	}
	if st.EphemeralPrefix != "repro-vm-tart-macos-garm-macos-test" {
		t.Fatalf("state ephemeral prefix = %q", st.EphemeralPrefix)
	}
	if data, err := os.ReadFile(st.Bootstrap); err != nil || !strings.Contains(string(data), "echo macos") {
		t.Fatalf("bootstrap not written correctly: err=%v data=%q", err, string(data))
	}
}

func TestVMHarnessRunBackendDarwinAsUserWrapper(t *testing.T) {
	tmp := t.TempDir()
	logPath := filepath.Join(tmp, "launchctl.log")
	cwdPath := filepath.Join(tmp, "launchctl.cwd")
	mockLaunchctl := filepath.Join(tmp, "launchctl")
	script := "#!/bin/sh\n" +
		"printf '%s\\n' \"$@\" > " + shellSingleQuote(logPath) + "\n" +
		"pwd > " + shellSingleQuote(cwdPath) + "\n" +
		"sleep 30\n"
	if err := os.WriteFile(mockLaunchctl, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	uid := os.Getuid()
	t.Setenv("VM_HARNESS_DARWIN_ASUSER_UID", fmt.Sprintf("%d", uid))
	t.Setenv("VM_HARNESS_DARWIN_LAUNCHCTL", mockLaunchctl)

	b := &VMHarnessRunBackend{
		VMHarnessPath: "/nix/store/test-vm-harness/bin/vm-harness",
		BackendID:     "tart-macos",
		GuestOS:       "macos",
		StateDir:      filepath.Join(tmp, "state"),
	}
	inst, err := b.Create(context.Background(), CreateArgs{
		Name:         "garm-macos-asuser-test",
		ControllerID: "controller",
		PoolID:       "pool",
		SourceImage:  "ghcr.io/cirruslabs/macos-tahoe-base:latest",
		OSName:       "macos",
		OSVersion:    "tahoe",
		OSArch:       "arm64",
		Bootstrap:    []byte("#!/bin/sh\necho macos\n"),
	})
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		_ = b.Delete(context.Background(), inst.Name)
	}()

	deadline := time.Now().Add(3 * time.Second)
	var argv string
	for time.Now().Before(deadline) {
		data, err := os.ReadFile(logPath)
		if err == nil {
			argv = string(data)
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if argv == "" {
		t.Fatal("mock launchctl did not record argv")
	}
	cwd, err := os.ReadFile(cwdPath)
	if err != nil {
		t.Fatal(err)
	}
	wantCWD, err := filepath.EvalSymlinks(filepath.Join(tmp, "state", "instances", "garm-macos-asuser-test", "run"))
	if err != nil {
		t.Fatal(err)
	}
	if got, want := strings.TrimSpace(string(cwd)), wantCWD; got != want {
		t.Fatalf("console-user wrapper cwd = %q, want %q", got, want)
	}
	for _, want := range []string{
		"asuser\n",
		fmt.Sprintf("%d\n", uid),
		"/usr/bin/sudo\n",
		"-E\n",
		"-u\n",
		fmt.Sprintf("#%d\n", uid),
		"--\n",
		"/nix/store/test-vm-harness/bin/vm-harness\n",
		"run\n",
		"tart-macos\n",
		"--timeout-sec\n",
		runnerTimeoutSec + "\n",
	} {
		if !strings.Contains(argv, want) {
			t.Fatalf("launchctl argv missing %q:\n%s", want, argv)
		}
	}
}

func TestVMHarnessRunBackendWindowsCreateCommandWaitsAfterBootstrap(t *testing.T) {
	t.Setenv("VM_HARNESS_DARWIN_ASUSER_UID", "")
	tmp := t.TempDir()
	logPath := filepath.Join(tmp, "argv.log")
	mock := filepath.Join(tmp, "vm-harness")
	script := "#!/bin/sh\n" +
		"printf '%s\\n' \"$@\" > " + shellSingleQuote(logPath) + "\n" +
		"sleep 30\n"
	if err := os.WriteFile(mock, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}

	b := &VMHarnessRunBackend{
		VMHarnessPath: mock,
		BackendID:     "qemu-windows-arm",
		GuestOS:       "windows",
		StateDir:      filepath.Join(tmp, "state"),
	}
	inst, err := b.Create(context.Background(), CreateArgs{
		Name:         "garm-windows-test",
		ControllerID: "controller",
		PoolID:       "pool",
		SourceImage:  filepath.Join(tmp, "golden"),
		OSName:       "windows",
		OSVersion:    "11-arm64",
		OSArch:       "arm64",
		Bootstrap:    []byte("Write-Output 'bootstrap'\n"),
	})
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		_ = b.Delete(context.Background(), inst.Name)
	}()

	deadline := time.Now().Add(3 * time.Second)
	var argv string
	for time.Now().Before(deadline) {
		data, err := os.ReadFile(logPath)
		if err == nil {
			argv = string(data)
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if argv == "" {
		t.Fatal("mock vm-harness did not record argv")
	}
	for _, want := range []string{
		"run\n",
		"--backend\n",
		"qemu-windows-arm\n",
		"--guest\n",
		"windows\n",
		"--timeout-sec\n",
		runnerTimeoutSec + "\n",
		"--copy-to\n",
		"garm-bootstrap.ps1:C:\\garm-bootstrap.ps1\n",
		"--\n",
		"powershell.exe\n",
		"-NoProfile\n",
		"-ExecutionPolicy\n",
		"Bypass\n",
		"-Command\n",
		"$bootstrapExitCode = $null",
		"& 'C:\\garm-bootstrap.ps1'",
		"$bootstrapExitCode = $LASTEXITCODE",
		"exit $bootstrapExitCode",
		"Get-Service -Name 'actions.runner.*'",
		"Get-Process -Name 'Runner.Listener'",
		"GitHub Actions runner service/process did not start after bootstrap",
		"Start-Sleep -Seconds 30",
	} {
		if !strings.Contains(argv, want) {
			t.Fatalf("windows argv missing %q:\n%s", want, argv)
		}
	}
	if strings.Contains(argv, "-File\nC:\\garm-bootstrap.ps1\n") {
		t.Fatalf("windows argv still exits immediately after bootstrap:\n%s", argv)
	}
	for _, forbidden := range []string{
		"$ErrorActionPreference = 'Stop'",
		"try {",
		"} catch {",
		"GitHub Actions runner bootstrap failed:",
	} {
		if strings.Contains(argv, forbidden) {
			t.Fatalf("windows argv wraps bootstrap with fatal error handling %q:\n%s", forbidden, argv)
		}
	}
}

func TestVMHarnessRunBackendDeleteCleansTartEphemeralsByPrefix(t *testing.T) {
	tmp := t.TempDir()
	tartLog := filepath.Join(tmp, "tart.log")
	tart := filepath.Join(tmp, "tart")
	script := "#!/bin/sh\n" +
		"printf '%s\\n' \"$@\" >> " + shellSingleQuote(tartLog) + "\n" +
		"if [ \"$1\" = list ]; then\n" +
		"  echo 'Source Name Disk Size SizeOnDisk State'\n" +
		"  echo 'local repro-vm-tart-macos-garm-delete-test-123 50 32 32 running'\n" +
		"  echo 'local repro-vm-tart-macos-other-123 50 32 32 running'\n" +
		"fi\n"
	if err := os.WriteFile(tart, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", tmp+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("VM_HARNESS_TART_STATE_DIR", filepath.Join(tmp, "tart-home"))

	b := &VMHarnessRunBackend{
		VMHarnessPath: "/bin/sleep",
		BackendID:     "tart-macos",
		GuestOS:       "macos",
		StateDir:      filepath.Join(tmp, "state"),
	}
	st := vmhState{
		ProviderID:      "garm-delete-test",
		Name:            "garm-delete-test",
		ControllerID:    "controller",
		PoolID:          "pool",
		OSName:          "macos",
		OSVersion:       "tahoe",
		OSArch:          "arm64",
		PID:             -1,
		EphemeralPrefix: "repro-vm-tart-macos-garm-delete-test",
	}
	if err := b.save(st); err != nil {
		t.Fatal(err)
	}
	if err := b.Delete(context.Background(), st.Name); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(tartLog)
	if err != nil {
		t.Fatal(err)
	}
	log := string(data)
	if !strings.Contains(log, "stop\nrepro-vm-tart-macos-garm-delete-test-123\n") {
		t.Fatalf("Delete did not stop matching Tart VM:\n%s", log)
	}
	if !strings.Contains(log, "delete\nrepro-vm-tart-macos-garm-delete-test-123\n") {
		t.Fatalf("Delete did not delete matching Tart VM:\n%s", log)
	}
	if strings.Contains(log, "stop\nrepro-vm-tart-macos-other-123") ||
		strings.Contains(log, "delete\nrepro-vm-tart-macos-other-123") {
		t.Fatalf("Delete touched non-matching Tart VM:\n%s", log)
	}
	if _, err := os.Stat(b.instanceDir(st.Name)); !os.IsNotExist(err) {
		t.Fatalf("instance dir still exists after Delete: err=%v", err)
	}
}

func TestVMHarnessRunBackendDoneMarkerOverridesLivePID(t *testing.T) {
	tmp := t.TempDir()
	outputDir := filepath.Join(tmp, "run")
	if err := os.MkdirAll(outputDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(outputDir, "DONE"), nil, 0o644); err != nil {
		t.Fatal(err)
	}

	b := &VMHarnessRunBackend{StateDir: filepath.Join(tmp, "state")}
	inst := b.toInstance(vmhState{
		ProviderID: "finished-instance",
		Name:       "finished-instance",
		PoolID:     "pool",
		PID:        os.Getpid(), // definitely alive; DONE must still win
		OutputDir:  outputDir,
	})
	if inst.Status != "stopped" {
		t.Fatalf("terminal vm-harness run status = %q, want stopped", inst.Status)
	}
}

func shellSingleQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'"
}

// TestVMHarnessRunBackendSweepInvokesPrune asserts that Sweep shells
// `vm-harness prune` scoped to the backend's shared ephemeral prefix, so a
// hard-killed launcher's leaked orphans get reclaimed without ever touching a
// live instance or another project's resources.
func TestVMHarnessRunBackendSweepInvokesPrune(t *testing.T) {
	cases := []struct {
		backendID   string
		wantStem    string
		wantBackend string
	}{
		{"tart-macos", "repro-vm-tart-macos", "tart"},
		{"tart-linux-arm", "repro-vm-tart-linux", "tart"},
		{"qemu-windows-arm", "repro-vm-qemu-windows-arm", "qemu-windows-arm"},
	}
	for _, tc := range cases {
		t.Run(tc.backendID, func(t *testing.T) {
			tmp := t.TempDir()
			logPath := filepath.Join(tmp, "argv.log")
			mock := filepath.Join(tmp, "vm-harness")
			script := "#!/bin/sh\nprintf '%s\\n' \"$@\" > " +
				shellSingleQuote(logPath) + "\n"
			if err := os.WriteFile(mock, []byte(script), 0o755); err != nil {
				t.Fatal(err)
			}
			b := &VMHarnessRunBackend{
				VMHarnessPath: mock,
				BackendID:     tc.backendID,
				StateDir:      filepath.Join(tmp, "state"),
			}
			b.Sweep(context.Background())

			data, err := os.ReadFile(logPath)
			if err != nil {
				t.Fatalf("mock vm-harness was not invoked: %v", err)
			}
			argv := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
			if len(argv) == 0 || argv[0] != "prune" {
				t.Fatalf("expected first arg 'prune', got %v", argv)
			}
			assertFlag := func(flag, want string) {
				for i, a := range argv {
					if a == flag {
						if i+1 < len(argv) && argv[i+1] == want {
							return
						}
						t.Fatalf("%s: expected %s %q, got %v", tc.backendID, flag, want, argv)
					}
				}
				t.Fatalf("%s: missing flag %s in %v", tc.backendID, flag, argv)
			}
			assertFlag("--ephemeral-prefix", tc.wantStem)
			assertFlag("--backend", tc.wantBackend)
			hasSweepTmp := false
			for _, a := range argv {
				if a == "--sweep-tmp" {
					hasSweepTmp = true
				}
			}
			if !hasSweepTmp {
				t.Fatalf("%s: expected --sweep-tmp in %v", tc.backendID, argv)
			}
		})
	}
}

// TestVMHarnessRunBackendSweepNoopForNonEphemeralBackend ensures Sweep does
// nothing (and never shells out) for a backend with no vm-harness ephemerals.
func TestVMHarnessRunBackendSweepNoopForNonEphemeralBackend(t *testing.T) {
	tmp := t.TempDir()
	logPath := filepath.Join(tmp, "argv.log")
	mock := filepath.Join(tmp, "vm-harness")
	script := "#!/bin/sh\nprintf '%s\\n' \"$@\" > " + shellSingleQuote(logPath) + "\n"
	if err := os.WriteFile(mock, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	b := &VMHarnessRunBackend{VMHarnessPath: mock, BackendID: "libvirt"}
	b.Sweep(context.Background())
	if _, err := os.Stat(logPath); err == nil {
		t.Fatal("Sweep unexpectedly invoked vm-harness for a non-ephemeral backend")
	}
}
