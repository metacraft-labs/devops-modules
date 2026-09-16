package provider

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/cloudbase/garm-provider-common/cloudconfig"
	commonParams "github.com/cloudbase/garm-provider-common/params"

	"github.com/metacraft-labs/garm-provider-vmharness/internal/backend"
	"github.com/metacraft-labs/garm-provider-vmharness/internal/config"
)

func strptr(v string) *string { return &v }

// assertNothingDetached enforces what the old blanket ban on the substring
// "Start-Process" was standing in for: nothing in a FOREGROUND bootstrap
// template may be launched and left running.
//
// The blanket ban was a proxy, and it became a false positive the moment the
// template legitimately needed to run a synchronous helper process (extracting
// the pinned PortableGit self-extractor, which PowerShell's call operator does
// not wait for because the extractor is a GUI subsystem binary). Banning a
// cmdlet name is not the same as forbidding detachment, so assert the actual
// property: every Start-Process is waited on.
//
// The runner's own foreground launch stays pinned independently, by the
// positive assertions on the ComSpec/run.cmd line, $LASTEXITCODE capture, and
// the non-zero-exit Fail-Install, all of which remain unchanged.
func assertNothingDetached(t *testing.T, text string) {
	t.Helper()
	for _, line := range strings.Split(text, "\n") {
		if !strings.Contains(line, "Start-Process") {
			continue
		}
		if !strings.Contains(line, "-Wait") {
			t.Fatalf("bootstrap starts a process without -Wait (detached):\n%s", line)
		}
	}
}

func shellSingleQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'"
}

func TestConfigSchemaIncludesQemuWindowsArm(t *testing.T) {
	var schema struct {
		Properties map[string]struct {
			Enum []string `json:"enum"`
		} `json:"properties"`
	}
	if err := json.Unmarshal([]byte(configJSONSchema), &schema); err != nil {
		t.Fatal(err)
	}
	for _, got := range schema.Properties["backend"].Enum {
		if got == string(config.BackendQemuWindowsArm) {
			return
		}
	}
	t.Fatalf("backend enum missing %q: %#v", config.BackendQemuWindowsArm, schema.Properties["backend"].Enum)
}

func TestConfigSchemaIncludesGuestURLOverrides(t *testing.T) {
	var schema struct {
		Properties map[string]json.RawMessage `json:"properties"`
	}
	if err := json.Unmarshal([]byte(configJSONSchema), &schema); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"guest_metadata_url", "guest_callback_url"} {
		if _, ok := schema.Properties[key]; !ok {
			t.Fatalf("schema missing %q", key)
		}
	}
}

func TestQemuWindowsArmProviderFactoryDispatch(t *testing.T) {
	p, err := NewWithConfig(&config.Config{
		Backend:       config.BackendQemuWindowsArm,
		VMHarnessPath: "/nix/store/test/bin/vm-harness",
		StateDir:      "/tmp/garm-provider-vmharness/qemu-windows-arm",
	})
	if err != nil {
		t.Fatal(err)
	}
	b, ok := p.backend.(*backend.VMHarnessRunBackend)
	if !ok {
		t.Fatalf("backend type=%T want *backend.VMHarnessRunBackend", p.backend)
	}
	if b.BackendID != string(config.BackendQemuWindowsArm) {
		t.Fatalf("BackendID=%q want %q", b.BackendID, config.BackendQemuWindowsArm)
	}
	if b.GuestOS != "windows" {
		t.Fatalf("GuestOS=%q want windows", b.GuestOS)
	}
	if b.VMHarnessPath != "/nix/store/test/bin/vm-harness" {
		t.Fatalf("VMHarnessPath=%q", b.VMHarnessPath)
	}
	if b.StateDir != "/tmp/garm-provider-vmharness/qemu-windows-arm" {
		t.Fatalf("StateDir=%q", b.StateDir)
	}
}

func TestQemuWindowsArmBootstrapUsesWindowsPath(t *testing.T) {
	params := commonParams.BootstrapInstance{
		Name:             "garm-win-arm-1",
		RepoURL:          "https://github.com/example-org/example-repo",
		CallbackURL:      "https://garm.example.test/api/v1/callbacks",
		MetadataURL:      "https://garm.example.test/api/v1/metadata",
		InstanceToken:    "instance-token",
		OSType:           commonParams.Windows,
		OSArch:           commonParams.Arm64,
		Labels:           []string{"self-hosted", "windows", "arm64", "win-arm"},
		JitConfigEnabled: true,
		Tools: []commonParams.RunnerApplicationDownload{
			{
				OS:             strptr("win"),
				Architecture:   strptr("arm64"),
				DownloadURL:    strptr("https://example.invalid/actions-runner-win-arm64.zip"),
				Filename:       strptr("actions-runner-win-arm64.zip"),
				SHA256Checksum: strptr(""),
			},
		},
	}

	tools, err := pickTools(params)
	if err != nil {
		t.Fatal(err)
	}
	if tools.GetOS() != "win" || tools.GetArchitecture() != "arm64" {
		t.Fatalf("picked %s/%s, want win/arm64", tools.GetOS(), tools.GetArchitecture())
	}
	script, err := renderRunnerBootstrapForBackend(config.BackendQemuWindowsArm, params, tools, params.Name)
	if err != nil {
		t.Fatal(err)
	}
	text := string(script)
	for _, want := range []string{
		"https://example.invalid/actions-runner-win-arm64.zip",
		"#ps1_sysnative",
		"Get-MetadataFile -Path 'credentials/runner'",
		"Get-MetadataFile -Path 'credentials/credentials'",
		`"$MetadataURL/credentials/credentials_rsaparams"`,
		`$rsaParamsPath = Join-Path $RunHome '.credentials_rsaparams'`,
		`$rsaParamsTmp = [System.IO.Path]::GetTempFileName()`,
		`Add-Type -AssemblyName System.Security`,
		`-Destination $rsaParamsTmp`,
		`$rsaBytes = [System.IO.File]::ReadAllBytes($rsaParamsTmp)`,
		`$protectedBytes = [System.Security.Cryptography.ProtectedData]::Protect($rsaBytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)`,
		`[System.IO.File]::WriteAllBytes($rsaParamsPath, $protectedBytes)`,
		`Remove-Item -Force $rsaParamsTmp -ErrorAction SilentlyContinue`,
		"Send-SystemInfo",
		"Send-Status -Status 'idle' -Message 'runner configured'",
		"Set-Location $RunHome",
		"& \"$env:ComSpec\" /d /c run.cmd",
		"Fail-Install \"runner exited with code $runnerExitCode\"",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("qemu Windows ARM bootstrap missing %q:\n%s", want, text)
		}
	}
	for _, unwanted := range []string{
		"exec ./run.sh",
		"systemctl",
		"/metadata/install-script/",
		"New-Service",
		"RunnerService.exe",
		"Get-MetadataFile -Path 'credentials/credentials_rsaparams'",
		"$encodedBytes",
		"[Text.Encoding]::UTF8.GetBytes($rsaResponse.Content)",
		"[System.Text.Encoding]::UTF8.GetBytes($rsaResponse.Content)",
		"$rsaResponse.Content",
		"[System.IO.File]::WriteAllText",
	} {
		if strings.Contains(text, unwanted) {
			t.Fatalf("qemu Windows ARM bootstrap used non-Windows path %q:\n%s", unwanted, text)
		}
	}
}

func TestQemuWindowsArmBootstrapUsesGuestURLOverrides(t *testing.T) {
	params := commonParams.BootstrapInstance{
		Name:             "garm-win-arm-1",
		RepoURL:          "https://github.com/example-org/example-repo",
		CallbackURL:      "http://192.168.64.1:9997/api/v1/callbacks",
		MetadataURL:      "http://192.168.64.1:9997/api/v1/metadata",
		InstanceToken:    "instance-token",
		OSType:           commonParams.Windows,
		OSArch:           commonParams.Arm64,
		Labels:           []string{"self-hosted", "windows", "arm64", "win-arm"},
		JitConfigEnabled: true,
		Tools: []commonParams.RunnerApplicationDownload{
			{
				OS:             strptr("win"),
				Architecture:   strptr("arm64"),
				DownloadURL:    strptr("https://example.invalid/actions-runner-win-arm64.zip"),
				Filename:       strptr("actions-runner-win-arm64.zip"),
				SHA256Checksum: strptr(""),
			},
		},
	}
	overridden := applyGuestURLOverrides(params, &config.Config{
		Backend:          config.BackendQemuWindowsArm,
		GuestMetadataURL: "http://10.0.2.2:9997/api/v1/metadata",
		GuestCallbackURL: "http://10.0.2.2:9997/api/v1/callbacks",
	})

	tools, err := pickTools(overridden)
	if err != nil {
		t.Fatal(err)
	}
	script, err := renderRunnerBootstrapForBackend(config.BackendQemuWindowsArm, overridden, tools, overridden.Name)
	if err != nil {
		t.Fatal(err)
	}
	text := string(script)
	for _, want := range []string{
		`$CallbackURL='http://10.0.2.2:9997/api/v1/callbacks'`,
		`$MetadataURL='http://10.0.2.2:9997/api/v1/metadata'`,
		`function Invoke-FileDownload`,
		`for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++)`,
		`Invoke-FileDownload -Uri $DownloadURL -Headers $headers -Destination $archive`,
		`Get-MetadataFile -Path 'credentials/runner' -Destination (Join-Path $RunHome '.runner')`,
		`Get-MetadataFile -Path 'credentials/credentials' -Destination (Join-Path $RunHome '.credentials')`,
		`Invoke-FileDownload -Uri "$MetadataURL/credentials/credentials_rsaparams"`,
		`$rsaParamsPath = Join-Path $RunHome '.credentials_rsaparams'`,
		`$rsaParamsTmp = [System.IO.Path]::GetTempFileName()`,
		`Add-Type -AssemblyName System.Security`,
		`-Destination $rsaParamsTmp`,
		`$rsaBytes = [System.IO.File]::ReadAllBytes($rsaParamsTmp)`,
		`$protectedBytes = [System.Security.Cryptography.ProtectedData]::Protect($rsaBytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)`,
		`[System.IO.File]::WriteAllBytes($rsaParamsPath, $protectedBytes)`,
		`Remove-Item -Force $rsaParamsTmp -ErrorAction SilentlyContinue`,
		`Invoke-GarmCallback -Path 'system-info/'`,
		`Send-Status -Status 'idle' -Message 'runner configured'`,
		`Set-Location $RunHome`,
		`& "$env:ComSpec" /d /c run.cmd`,
		`$runnerExitCode = $LASTEXITCODE`,
		`Fail-Install "runner exited with code $runnerExitCode"`,
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("qemu Windows ARM bootstrap missing override %q:\n%s", want, text)
		}
	}
	assertNothingDetached(t, text)
	if strings.Contains(text, "/metadata/install-script/") {
		t.Fatalf("qemu Windows ARM bootstrap still relies on GARM second-stage install script:\n%s", text)
	}
	if strings.Contains(text, "Get-MetadataFile -Path 'credentials/credentials_rsaparams'") {
		t.Fatalf("qemu Windows ARM bootstrap uses generic metadata file handling for credentials_rsaparams:\n%s", text)
	}
	for _, forbidden := range []string{
		"$encodedBytes",
		"[Text.Encoding]::UTF8.GetBytes($rsaResponse.Content)",
		"[System.Text.Encoding]::UTF8.GetBytes($rsaResponse.Content)",
		"$rsaResponse.Content",
		"[System.IO.File]::WriteAllText",
	} {
		if strings.Contains(text, forbidden) {
			t.Fatalf("qemu Windows ARM bootstrap uses unsafe credentials_rsaparams handling via %q:\n%s", forbidden, text)
		}
	}
	if strings.Contains(text, "http://192.168.64.1:9997") {
		t.Fatalf("qemu Windows ARM bootstrap retained global guest URL:\n%s", text)
	}
}

func TestQemuWindowsArmBootstrapRejectsNonJIT(t *testing.T) {
	params := commonParams.BootstrapInstance{
		Name:          "garm-win-arm-1",
		RepoURL:       "https://github.com/example-org/example-repo",
		CallbackURL:   "http://10.0.2.2:9997/api/v1/callbacks",
		MetadataURL:   "http://10.0.2.2:9997/api/v1/metadata",
		InstanceToken: "instance-token",
		OSType:        commonParams.Windows,
		OSArch:        commonParams.Arm64,
		Tools: []commonParams.RunnerApplicationDownload{
			{
				OS:           strptr("win"),
				Architecture: strptr("arm64"),
				DownloadURL:  strptr("https://example.invalid/actions-runner-win-arm64.zip"),
				Filename:     strptr("actions-runner-win-arm64.zip"),
			},
		},
	}
	tools, err := pickTools(params)
	if err != nil {
		t.Fatal(err)
	}
	_, err = renderRunnerBootstrapForBackend(config.BackendQemuWindowsArm, params, tools, params.Name)
	if err == nil || !strings.Contains(err.Error(), "non-JIT Windows vm-harness runners are not supported") {
		t.Fatalf("renderRunnerBootstrapForBackend error=%v, want non-JIT unsupported", err)
	}
}

func TestQemuWindowsArmCreateInstanceWritesBootstrapWithGuestURLOverrides(t *testing.T) {
	t.Setenv("VM_HARNESS_DARWIN_ASUSER_UID", "")
	tmp := t.TempDir()
	logPath := filepath.Join(tmp, "vm-harness.argv")
	mock := filepath.Join(tmp, "vm-harness")
	script := "#!/bin/sh\n" +
		"printf '%s\\n' \"$@\" > " + shellSingleQuote(logPath) + "\n" +
		"sleep 30\n"
	if err := os.WriteFile(mock, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}

	p, err := NewWithConfig(&config.Config{
		Backend:          config.BackendQemuWindowsArm,
		VMHarnessPath:    mock,
		StateDir:         filepath.Join(tmp, "state"),
		GuestMetadataURL: "http://10.0.2.2:9997/api/v1/metadata",
		GuestCallbackURL: "http://10.0.2.2:9997/api/v1/callbacks",
		Images: map[string]config.GoldenImage{
			"win-arm-runner": {
				SourceImage: filepath.Join(tmp, "golden"),
				OSName:      "windows",
				OSVersion:   "11-arm64",
			},
		},
	})
	if err != nil {
		t.Fatal(err)
	}

	extraSpecs, err := json.Marshal(cloudconfig.CloudConfigSpec{
		RunnerInstallTemplate: []byte(`#ps1_sysnative
$CallbackURL="{{.CallbackURL}}"
$MetadataURL="{{.MetadataURL}}"
$installScript = "$env:TEMP\install-runner.ps1"
wget -UseBasicParsing -Headers @{"Accept"="application/json"; "Authorization"="Bearer {{.CallbackToken}}"} -Uri http://192.168.64.1:9997/api/v1/metadata/install-script/ -OutFile $installScript
Invoke-WebRequest -UseBasicParsing -Method Post -Uri http://192.168.64.1:9997/api/v1/callbacks/status -Body "{}"
powershell.exe -Sta -NonInteractive -ExecutionPolicy RemoteSigned -File $installScript
`),
	})
	if err != nil {
		t.Fatal(err)
	}

	params := commonParams.BootstrapInstance{
		Name:             "garm-win-arm-1",
		Image:            "win-arm-runner",
		RepoURL:          "https://github.com/example-org/example-repo",
		CallbackURL:      "http://192.168.64.1:9997/api/v1/callbacks",
		MetadataURL:      "http://192.168.64.1:9997/api/v1/metadata",
		InstanceToken:    "instance-token",
		OSType:           commonParams.Windows,
		OSArch:           commonParams.Arm64,
		Labels:           []string{"self-hosted", "windows", "arm64", "win-arm"},
		JitConfigEnabled: true,
		ExtraSpecs:       extraSpecs,
		Tools: []commonParams.RunnerApplicationDownload{
			{
				OS:             strptr("win"),
				Architecture:   strptr("arm64"),
				DownloadURL:    strptr("https://example.invalid/actions-runner-win-arm64.zip"),
				Filename:       strptr("actions-runner-win-arm64.zip"),
				SHA256Checksum: strptr(""),
			},
		},
	}
	inst, err := p.CreateInstance(context.Background(), params)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = p.DeleteInstance(context.Background(), inst.Name) }()

	deadline := time.Now().Add(3 * time.Second)
	for {
		if _, err := os.Stat(logPath); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("mock vm-harness did not run: %v", os.ErrNotExist)
		}
		time.Sleep(50 * time.Millisecond)
	}

	bootstrapPath := filepath.Join(tmp, "state", "instances", params.Name, "garm-bootstrap.ps1")
	data, err := os.ReadFile(bootstrapPath)
	if err != nil {
		t.Fatal(err)
	}
	text := string(data)
	for _, want := range []string{
		`$CallbackURL='http://10.0.2.2:9997/api/v1/callbacks'`,
		`$MetadataURL='http://10.0.2.2:9997/api/v1/metadata'`,
		`function Invoke-FileDownload`,
		`for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++)`,
		`Invoke-FileDownload -Uri $DownloadURL -Headers $headers -Destination $archive`,
		`Get-MetadataFile -Path 'credentials/runner' -Destination (Join-Path $RunHome '.runner')`,
		`Get-MetadataFile -Path 'credentials/credentials' -Destination (Join-Path $RunHome '.credentials')`,
		`Invoke-FileDownload -Uri "$MetadataURL/credentials/credentials_rsaparams"`,
		`$rsaParamsPath = Join-Path $RunHome '.credentials_rsaparams'`,
		`$rsaParamsTmp = [System.IO.Path]::GetTempFileName()`,
		`Add-Type -AssemblyName System.Security`,
		`-Destination $rsaParamsTmp`,
		`$rsaBytes = [System.IO.File]::ReadAllBytes($rsaParamsTmp)`,
		`$protectedBytes = [System.Security.Cryptography.ProtectedData]::Protect($rsaBytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)`,
		`[System.IO.File]::WriteAllBytes($rsaParamsPath, $protectedBytes)`,
		`Remove-Item -Force $rsaParamsTmp -ErrorAction SilentlyContinue`,
		`Invoke-GarmCallback -Path 'system-info/'`,
		`Send-Status -Status 'idle' -Message 'runner configured'`,
		`Set-Location $RunHome`,
		`& "$env:ComSpec" /d /c run.cmd`,
		`$runnerExitCode = $LASTEXITCODE`,
		`Fail-Install "runner exited with code $runnerExitCode"`,
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("CreateInstance bootstrap missing override %q:\n%s", want, text)
		}
	}
	assertNothingDetached(t, text)
	if strings.Contains(text, "/metadata/install-script/") {
		t.Fatalf("CreateInstance bootstrap still relies on GARM second-stage install script:\n%s", text)
	}
	if strings.Contains(text, "Get-MetadataFile -Path 'credentials/credentials_rsaparams'") {
		t.Fatalf("CreateInstance bootstrap uses generic metadata file handling for credentials_rsaparams:\n%s", text)
	}
	for _, forbidden := range []string{
		"$encodedBytes",
		"[Text.Encoding]::UTF8.GetBytes($rsaResponse.Content)",
		"[System.Text.Encoding]::UTF8.GetBytes($rsaResponse.Content)",
		"$rsaResponse.Content",
		"[System.IO.File]::WriteAllText",
	} {
		if strings.Contains(text, forbidden) {
			t.Fatalf("CreateInstance bootstrap uses unsafe credentials_rsaparams handling via %q:\n%s", forbidden, text)
		}
	}
	if strings.Contains(text, "http://192.168.64.1:9997") {
		t.Fatalf("CreateInstance bootstrap retained global guest URL:\n%s", text)
	}
}

func TestGuestURLOverridesDefaultToGARMParams(t *testing.T) {
	params := commonParams.BootstrapInstance{
		CallbackURL: "http://192.168.64.1:9997/api/v1/callbacks",
		MetadataURL: "http://192.168.64.1:9997/api/v1/metadata",
	}
	got := applyGuestURLOverrides(params, &config.Config{Backend: config.BackendTartLinuxArm})
	if got.MetadataURL != params.MetadataURL {
		t.Fatalf("MetadataURL=%q want %q", got.MetadataURL, params.MetadataURL)
	}
	if got.CallbackURL != params.CallbackURL {
		t.Fatalf("CallbackURL=%q want %q", got.CallbackURL, params.CallbackURL)
	}
}

func TestMacOSProviderInstanceMapping(t *testing.T) {
	got := toProviderInstance(backend.Instance{
		ProviderID: "mac-1",
		Name:       "mac-1",
		OSName:     "macos",
		OSVersion:  "tahoe",
		OSArch:     "arm64",
		Status:     "running",
	})
	if got.OSType != commonParams.OSType("macos") {
		t.Fatalf("OSType=%q want macos", got.OSType)
	}
	if got.OSArch != commonParams.Arm64 {
		t.Fatalf("OSArch=%q want arm64", got.OSArch)
	}
}

func TestMacOSPickToolsAndBootstrap(t *testing.T) {
	params := commonParams.BootstrapInstance{
		Name:             "garm-macos-1",
		RepoURL:          "https://github.com/example-org/example-repo",
		CallbackURL:      "https://garm.example.test/api/v1/callbacks",
		MetadataURL:      "https://garm.example.test/api/v1/metadata",
		InstanceToken:    "instance-token",
		OSType:           commonParams.OSType("macos"),
		OSArch:           commonParams.Arm64,
		Labels:           []string{"self-hosted", "macos", "arm64", "macos-tart"},
		JitConfigEnabled: true,
		Tools: []commonParams.RunnerApplicationDownload{
			{
				OS:             strptr("linux"),
				Architecture:   strptr("arm64"),
				DownloadURL:    strptr("https://example.invalid/linux.tar.gz"),
				Filename:       strptr("actions-runner-linux-arm64.tar.gz"),
				SHA256Checksum: strptr(""),
			},
			{
				OS:             strptr("osx"),
				Architecture:   strptr("arm64"),
				DownloadURL:    strptr("https://example.invalid/osx.tar.gz"),
				Filename:       strptr("actions-runner-osx-arm64.tar.gz"),
				SHA256Checksum: strptr(""),
			},
		},
	}

	tools, err := pickTools(params)
	if err != nil {
		t.Fatal(err)
	}
	if tools.GetOS() != "osx" || tools.GetArchitecture() != "arm64" {
		t.Fatalf("picked %s/%s, want osx/arm64", tools.GetOS(), tools.GetArchitecture())
	}

	script, err := renderRunnerBootstrapForBackend(config.BackendTartMacos, params, tools, params.Name)
	if err != nil {
		t.Fatal(err)
	}
	text := string(script)
	for _, want := range []string{
		`export PATH="/nix/var/nix/profiles/default/bin:/opt/homebrew/bin`,
		"command -v gh",
		"command -v git-lfs",
		"https://install.determinate.systems/nix",
		`sh "$nix_installer" install macos --no-confirm --prefer-upstream-nix --encrypt false`,
		"get_metadata_file \"credentials/runner\"",
		"exec ./run.sh",
		"https://example.invalid/osx.tar.gz",
		"runner configured",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("macOS bootstrap missing %q:\n%s", want, text)
		}
	}
	if strings.Contains(text, "systemctl") || strings.Contains(text, "svc.sh") {
		t.Fatalf("macOS bootstrap must not use Linux/Windows service managers:\n%s", text)
	}
	// Runner-Fleet-M3-ARM-Wave MA11 — THE macOS POOL'S ONE REMAINING LANDMINE,
	// pinned here so it stays defused. GARM's vendored
	// garm-provider-common `util.GetTools()` rejects any OSType that is not
	// Linux or Windows, and `githubOSTypeMap` has no `osx` entry, so the two
	// metadata endpoints that call it — `/metadata/runner-metadata/` and
	// `/metadata/install-script/` — return 500 for a macOS instance. Admitting
	// macOS to the POOL path (packages/garm/patches/allow-macos-pools.patch)
	// is only safe because THIS provider never sends a macOS guest to either:
	// it picks the `osx` tarball itself via pickTools and renders the
	// bootstrap itself via renderMacOSRunnerInstallScript, and the guest only
	// ever fetches `credentials/*` and `runner-registration-token/`.
	//
	// That is the whole safety argument, and until now it held only by
	// inspection. Note the wrapper GARM injects into
	// ExtraSpecs["runner_install_template"] DOES curl
	// `$METADATA_URL/install-script/` — it is inert purely because the macOS
	// branch short-circuits before any extra-spec consumption. So if someone
	// ever routes macOS through the generic cloudconfig path, this assertion
	// is what says so, instead of a 500 at first boot on a live runner.
	// The Windows-ARM tests above carry the identical guard.
	for _, forbidden := range []string{
		"/metadata/install-script/",
		"/metadata/runner-metadata/",
	} {
		if strings.Contains(text, forbidden) {
			t.Fatalf("macOS bootstrap reaches %q, an endpoint util.GetTools() 500s on for macOS:\n%s", forbidden, text)
		}
	}
}

func TestLinuxBootstrapCreatesRunnerHomeBeforeDownload(t *testing.T) {
	params := commonParams.BootstrapInstance{
		Name:             "garm-linux-1",
		RepoURL:          "https://github.com/example-org/example-repo",
		CallbackURL:      "https://garm.example.test/api/v1/callbacks",
		MetadataURL:      "https://garm.example.test/api/v1/metadata",
		InstanceToken:    "instance-token",
		OSType:           commonParams.Linux,
		OSArch:           commonParams.Arm64,
		Labels:           []string{"self-hosted", "linux", "arm64", "tart-linux-arm"},
		JitConfigEnabled: true,
		Tools: []commonParams.RunnerApplicationDownload{
			{
				OS:             strptr("linux"),
				Architecture:   strptr("arm64"),
				DownloadURL:    strptr("https://example.invalid/linux.tar.gz"),
				Filename:       strptr("actions-runner-linux-arm64.tar.gz"),
				SHA256Checksum: strptr(""),
			},
		},
	}

	tools, err := pickTools(params)
	if err != nil {
		t.Fatal(err)
	}
	script, err := renderRunnerBootstrapForBackend(config.BackendTartLinuxArm, params, tools, params.Name)
	if err != nil {
		t.Fatal(err)
	}
	text := string(script)
	for _, want := range []string{
		"RUN_HOME=\"${RUNNER_HOME}/actions-runner\"",
		`exec sudo -E bash "$0" "$@"`,
		"groupadd \"$RUNNER_GROUP\"",
		"useradd -m -s /bin/bash -g \"$RUNNER_GROUP\" \"$RUNNER_USER\"",
		`printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$RUNNER_USER"`,
		`chmod 0440 "/etc/sudoers.d/90-garm-${RUNNER_USER}"`,
		"get_metadata_file \"credentials/runner\"",
		"call_status '{\"status\":\"idle\",\"message\":\"runner configured\"}'",
		"exec sudo -u \"$RUNNER_USER\" -H ./run.sh",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("linux bootstrap missing foreground-runner behavior %q:\n%s", want, text)
		}
	}
	for _, unwanted := range []string{"systemctl", "svc.sh", "systemd/unit-file"} {
		if strings.Contains(text, unwanted) {
			t.Fatalf("linux bootstrap must not use service manager path %q:\n%s", unwanted, text)
		}
	}
	if strings.Index(text, "get_metadata_file \"credentials/runner\"") > strings.Index(text, "exec sudo -u \"$RUNNER_USER\" -H ./run.sh") {
		t.Fatalf("linux bootstrap starts runner before writing JIT credentials:\n%s", text)
	}
}

func TestLinuxBootstrapForegroundRunnerIsTartOnly(t *testing.T) {
	params := commonParams.BootstrapInstance{
		Name:          "garm-linux-incus-1",
		RepoURL:       "https://github.com/example-org/example-repo",
		CallbackURL:   "https://garm.example.test/api/v1/callbacks",
		MetadataURL:   "https://garm.example.test/api/v1/metadata",
		InstanceToken: "instance-token",
		OSType:        commonParams.Linux,
		OSArch:        commonParams.Arm64,
		Labels:        []string{"self-hosted", "linux", "arm64", "incus-arm"},
		Tools: []commonParams.RunnerApplicationDownload{
			{
				OS:             strptr("linux"),
				Architecture:   strptr("arm64"),
				DownloadURL:    strptr("https://example.invalid/linux.tar.gz"),
				Filename:       strptr("actions-runner-linux-arm64.tar.gz"),
				SHA256Checksum: strptr(""),
			},
		},
	}

	tools, err := pickTools(params)
	if err != nil {
		t.Fatal(err)
	}
	script, err := renderRunnerBootstrapForBackend(config.BackendIncus, params, tools, params.Name)
	if err != nil {
		t.Fatal(err)
	}
	text := string(script)
	for _, unwanted := range []string{
		"exec sudo -u \"$RUNNER_USER\" -H ./run.sh",
		"get_metadata_file \"credentials/runner\"",
	} {
		if strings.Contains(text, unwanted) {
			t.Fatalf("non-Tart Linux bootstrap must not use Tart foreground path %q:\n%s", unwanted, text)
		}
	}
	for _, want := range []string{
		"sudo ./svc.sh install runner",
		"sudo ./svc.sh start",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("non-Tart Linux bootstrap should use upstream service path %q:\n%s", want, text)
		}
	}
	if !strings.Contains(text, "runner-registration-token") {
		t.Fatalf("non-Tart Linux bootstrap should use upstream cloudconfig path:\n%s", text)
	}
}
