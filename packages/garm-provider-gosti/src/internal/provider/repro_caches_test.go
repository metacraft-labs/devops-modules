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

package provider

// Tests for the guest caches.conf delivery (repro_caches.go).
//
// The bootstraps are rendered through the same functions CreateInstance uses,
// against GARM's real wrapper and served templates (testdata/garm-upstream,
// verbatim copies of the packaged GARM source). No fakes: the PowerShell
// cases run the rendered snippets in a real pwsh against real files, and skip
// only when pwsh is not on PATH. The whole bootstrap cannot run off Windows
// (it downloads with `wget`, a Windows PowerShell alias, and registers a real
// runner), so the real-guest half of this contract is qualified on
// eph-win-x64 (WR4's gates), not here.

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	commonParams "github.com/cloudbase/garm-provider-common/params"

	"github.com/metacraft-labs/garm-provider-gosti/internal/config"
)

const testCachesConf = "# Rendered by services/github-runners/windows.nix\n" +
	"[repro-cache]\n" +
	"url = \"http://192.168.122.1:7881\"\n" +
	"trusted-public-keys = \"04aa, 04bb\"\n" +
	"priority = 20\n"

type reproCachesPath struct {
	name        string
	backend     config.BackendKind
	params      commonParams.BootstrapInstance
	ownTemplate bool
	wrapper     bool
}

func reproCachesPaths(t *testing.T) []reproCachesPath {
	winFile := "actions-runner-win-x64-" + offeredVersion + ".zip"
	winArmFile := "actions-runner-win-arm64-" + offeredVersion + ".zip"
	win := guardBootstrap(commonParams.Windows, commonParams.Amd64, "win", "x64", winFile, releaseURL(winFile))
	return []reproCachesPath{
		{name: "garm-wrapper-libvirt", backend: config.BackendLibvirt,
			params:  withGarmWrapper(t, win, garmWrapper(t, commonParams.Windows, win.MetadataURL, win.CallbackURL)),
			wrapper: true},
		{name: "garm-wrapper-remote", backend: config.BackendRemote,
			params:  withGarmWrapper(t, win, garmWrapper(t, commonParams.Windows, win.MetadataURL, win.CallbackURL)),
			wrapper: true},
		{name: "upstream-default-libvirt", backend: config.BackendLibvirt, params: win},
		{name: "own-windows-qemu-arm", backend: config.BackendQemuWindowsArm,
			params:      guardBootstrap(commonParams.Windows, commonParams.Arm64, "win", "arm64", winArmFile, releaseURL(winArmFile)),
			ownTemplate: true},
	}
}

func renderWithReproCaches(t *testing.T, p reproCachesPath, conf []byte, guestPath string) (plain, withConf []byte) {
	t.Helper()
	tools, err := pickTools(p.params)
	if err != nil {
		t.Fatal(err)
	}
	plain, err = renderRunnerBootstrapForBackend(p.backend, p.params, tools, p.params.Name)
	if err != nil {
		t.Fatalf("render: %v", err)
	}
	withConf, err = applyGuestReproCaches(plain, p.params.OSType, isGostiWindowsBackend(p.backend), conf, guestPath)
	if err != nil {
		t.Fatalf("applyGuestReproCaches: %v", err)
	}
	return plain, withConf
}

// Off is byte-identical: WR4's gates run with every live lane unchanged.
func TestGuestReproCachesOffIsByteIdentical(t *testing.T) {
	for _, p := range reproCachesPaths(t) {
		t.Run(p.name, func(t *testing.T) {
			plain, out := renderWithReproCaches(t, p, nil, "")
			if string(plain) != string(out) {
				t.Fatalf("no caches.conf configured, but the bootstrap changed")
			}
		})
	}
	linux := guardBootstrap(commonParams.Linux, commonParams.Amd64, "linux", "x64", "r.tar.gz", releaseURL("r.tar.gz"))
	script := []byte("#!/bin/bash\necho hi\n")
	out, err := applyGuestReproCaches(script, linux.OSType, false, []byte(testCachesConf), "")
	if err != nil || string(out) != string(script) {
		t.Fatalf("a Linux guest must be unchanged even when a caches.conf is configured: %v", err)
	}
}

func TestGuestReproCachesRenderedShape(t *testing.T) {
	for _, p := range reproCachesPaths(t) {
		t.Run(p.name, func(t *testing.T) {
			_, out := renderWithReproCaches(t, p, []byte(testCachesConf), DefaultGuestReproCachesConfPath)
			text := string(out)
			if !strings.HasPrefix(text, windowsUserDataHeader+"\n"+reproCachesPreludeMarker) {
				t.Fatalf("the prelude must follow the #ps1_sysnative line directly:\n%.400s", text)
			}
			if n := strings.Count(text, reproCachesPreludeMarker); n != 1 {
				t.Fatalf("prelude rendered %d times", n)
			}
			// Trust only: nothing that would let the guest publish.
			for _, banned := range []string{"REPRO_BINARY_CACHE_URL", "REPRO_BINARY_CACHE_KEY_PATH", "REPRO_BINARY_CACHE_CERT_PATH"} {
				if strings.Contains(text, banned) {
					t.Fatalf("bootstrap mentions %s; a read-only guest gets REPRO_CACHES_CONFIG only", banned)
				}
			}
			dotEnv := reproCachesDotEnvLine(DefaultGuestReproCachesConfPath)
			switch {
			case p.ownTemplate:
				if strings.Contains(text, ".env") {
					t.Fatalf("the foreground template inherits the prelude's environment; it needs no .env")
				}
			case p.wrapper:
				if !isGarmInstallScriptWrapper(commonParams.Windows, out) {
					t.Fatalf("the result is no longer GARM's wrapper")
				}
				splice := strings.Index(text, reproCachesEnvSpliceMarker)
				run := strings.Index(text, garmWindowsWrapperAnchor)
				if splice < 0 || run < splice {
					t.Fatalf("the .env splice must sit before the wrapper runs the served script")
				}
				if n := strings.Count(text, reproCachesEnvSpliceMarker); n != 1 {
					t.Fatalf(".env splice rendered %d times", n)
				}
				// The version guard's splice is still there too.
				if !strings.Contains(text, garmWrapperSpliceMarker) {
					t.Fatalf("the cached-runner version guard splice was lost")
				}
			default:
				envAt := strings.Index(text, dotEnv)
				svcAt := strings.Index(text, upstreamWindowsServiceNameAnchor)
				if envAt < 0 || svcAt < envAt {
					t.Fatalf("the .env line must come before upstream creates the runner service")
				}
			}
		})
	}
}

func TestGuestReproCachesRefusesACustomTemplateWithoutTheServiceStep(t *testing.T) {
	script := []byte(windowsUserDataHeader + "\nWrite-Host 'operator template'\n")
	if _, err := applyGuestReproCaches(script, commonParams.Windows, false, []byte(testCachesConf), ""); err == nil {
		t.Fatalf("a template the runner cannot be handed REPRO_CACHES_CONFIG through must be refused")
	}
	if _, err := applyGuestReproCaches([]byte("Write-Host x\n"), commonParams.Windows, true, []byte(testCachesConf), ""); err == nil {
		t.Fatalf("a Windows bootstrap without #ps1_sysnative must be refused")
	}
}

func TestLoadGuestReproCachesConf(t *testing.T) {
	dir := t.TempDir()
	if b, err := loadGuestReproCachesConf(""); b != nil || err != nil {
		t.Fatalf("empty path is off: %q %v", b, err)
	}
	if _, err := loadGuestReproCachesConf(filepath.Join(dir, "absent")); err == nil {
		t.Fatalf("a configured but missing file must fail CreateInstance")
	}
	empty := filepath.Join(dir, "empty")
	writeFile(t, empty, " \n")
	if _, err := loadGuestReproCachesConf(empty); err == nil {
		t.Fatalf("an empty file must be refused")
	}
	big := filepath.Join(dir, "big")
	writeFile(t, big, strings.Repeat("x", maxGuestReproCachesConfBytes+1))
	if _, err := loadGuestReproCachesConf(big); err == nil {
		t.Fatalf("an oversized file must be refused")
	}
	ok := filepath.Join(dir, "caches.conf")
	writeFile(t, ok, testCachesConf)
	if b, err := loadGuestReproCachesConf(ok); err != nil || string(b) != testCachesConf {
		t.Fatalf("load: %q %v", b, err)
	}
}

func TestConfigGuestReproCachesValidation(t *testing.T) {
	base := "backend = \"libvirt\"\n"
	cfg, err := config.ParseBytes([]byte(base + "guest_repro_caches_conf_file = \"/etc/caches.conf\"\n"))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.GuestReproCachesConfPath != DefaultGuestReproCachesConfPath {
		t.Fatalf("default guest path: %q", cfg.GuestReproCachesConfPath)
	}
	for _, bad := range []string{
		"guest_repro_caches_conf_path = 'C:\\x\\caches.conf'\n",
		"guest_repro_caches_conf_file = \"/etc/c\"\nguest_repro_caches_conf_path = 'caches.conf'\n",
		"guest_repro_caches_conf_file = \"/etc/c\"\nguest_repro_caches_conf_path = 'C:\\$env\\caches.conf'\n",
		"guest_repro_caches_conf_file = \"/etc/c\"\nguest_repro_caches_conf_path = \"C:\\\\it's\\\\caches.conf\"\n",
	} {
		if _, err := config.ParseBytes([]byte(base + bad)); err == nil {
			t.Fatalf("accepted %q", bad)
		}
	}
}

// The prelude, run for real: the file lands byte-for-byte and the process
// environment carries REPRO_CACHES_CONFIG. (Off Windows, .NET ignores the
// Machine target, so only the process half is observable here.)
func TestGuestReproCachesPreludeExecutesInPowerShell(t *testing.T) {
	pwsh := findShell(t, "pwsh")
	dir := t.TempDir()
	guestPath := filepath.Join(dir, "dev-deps", "repro", "caches.conf")
	conf := testCachesConf + "# bytes that would end a here-string:\n'@\n\"@\n$env:X `n\n"
	driver := "$ErrorActionPreference = 'Stop'\n" + windowsReproCachesPrelude([]byte(conf), guestPath) +
		"Write-Host \"ENV=$env:REPRO_CACHES_CONFIG\"\n"
	driverPath := filepath.Join(dir, "driver.ps1")
	writeFile(t, driverPath, driver)
	outB, err := exec.Command(pwsh, "-NoProfile", "-NonInteractive", "-File", driverPath).CombinedOutput()
	log := string(outB)
	if err != nil {
		t.Fatalf("prelude failed: %v\n%s", err, log)
	}
	got, err := os.ReadFile(guestPath)
	if err != nil || string(got) != conf {
		t.Fatalf("caches.conf not written verbatim (%v):\n%s\n--- log ---\n%s", err, got, log)
	}
	if !strings.Contains(log, "ENV="+guestPath) {
		t.Fatalf("REPRO_CACHES_CONFIG not exported:\n%s", log)
	}

	// A write failure is reported and does not stop the bootstrap.
	blocker := filepath.Join(dir, "blocker")
	writeFile(t, blocker, "a file, not a directory")
	driver = "$ErrorActionPreference = 'Stop'\n" + windowsReproCachesPrelude([]byte(conf), filepath.Join(blocker, "caches.conf")) +
		"Write-Host BOOTSTRAP-CONTINUES\n"
	writeFile(t, driverPath, driver)
	outB, err = exec.Command(pwsh, "-NoProfile", "-NonInteractive", "-File", driverPath).CombinedOutput()
	log = string(outB)
	if err != nil || !strings.Contains(log, "not provisioned") || !strings.Contains(log, "BOOTSTRAP-CONTINUES") {
		t.Fatalf("a failed write must be reported and must not fail the bootstrap: %v\n%s", err, log)
	}
}

// The wrapper's .env splice, run for real against GARM's served github_windows
// template: it adds exactly one line, right before the service is created,
// and the script still parses.
func TestGuestReproCachesWrapperSpliceAgainstServedTemplate(t *testing.T) {
	pwsh := findShell(t, "pwsh")
	p := reproCachesPaths(t)[0]
	_, out := renderWithReproCaches(t, p, []byte(testCachesConf), DefaultGuestReproCachesConfPath)
	text := string(out)
	start := strings.Index(text, reproCachesEnvSpliceMarker)
	end := strings.Index(text, garmWindowsWrapperAnchor)
	splice := text[start:end]
	tools, _ := pickTools(p.params)
	served := renderGarmTemplate(t, "github_windows_userdata.tmpl", map[string]any{
		"CallbackURL": p.params.CallbackURL, "MetadataURL": p.params.MetadataURL,
		"CallbackToken": "instance-token", "DownloadURL": tools.GetDownloadURL(),
		"FileName": tools.GetFilename(), "TempDownloadToken": "", "RepoURL": p.params.RepoURL,
		"RunnerName": p.params.Name, "RunnerLabels": "self-hosted", "GitHubRunnerGroup": "",
		"UseJITConfig": true, "AgentMode": false, "CACertBundle": "",
	})
	for _, c := range []struct {
		name    string
		served  string
		spliced bool
	}{
		{"upstream-template", served, true},
		{"custom-template", strings.Replace(served, upstreamWindowsServiceNameAnchor, "# operator's own service logic", 1), false},
	} {
		t.Run(c.name, func(t *testing.T) {
			dir := t.TempDir()
			installScript := filepath.Join(dir, "garm-install.ps1")
			writeFile(t, installScript, c.served)
			driver := "$ErrorActionPreference = 'Stop'\n$installScript = " + powershellQuote(installScript) + "\n" +
				splice + "Write-Host SPLICE-DONE\n" +
				"$parseErrors = $null\n" +
				"[void][System.Management.Automation.Language.Parser]::ParseFile($installScript, [ref]$null, [ref]$parseErrors)\n" +
				"Write-Host \"PARSE-ERRORS: $($parseErrors.Count)\"\n"
			driverPath := filepath.Join(dir, "driver.ps1")
			writeFile(t, driverPath, driver)
			outB, err := exec.Command(pwsh, "-NoProfile", "-NonInteractive", "-File", driverPath).CombinedOutput()
			log := string(outB)
			if err != nil || !strings.Contains(log, "SPLICE-DONE") || !strings.Contains(log, "PARSE-ERRORS: 0") {
				t.Fatalf("splice step failed: %v\n%s", err, log)
			}
			result, _ := os.ReadFile(installScript)
			got := strings.ReplaceAll(string(result), "\r\n", "\n")
			line := reproCachesDotEnvLine(DefaultGuestReproCachesConfPath)
			if !c.spliced {
				if strings.Contains(got, line) || !strings.Contains(log, "not handed to the runner service") {
					t.Fatalf("custom template must run as served, with a notice:\n%s", log)
				}
				return
			}
			if n := strings.Count(got, line); n != 1 {
				t.Fatalf(".env line spliced %d times:\n%s", n, got)
			}
			lineAt := strings.Index(got, line)
			svcAt := strings.Index(got, upstreamWindowsServiceNameAnchor)
			proxyEnvAt := strings.Index(got, `Set-Content -Path (Join-Path $runnerDir ".env")`)
			if !(lineAt < svcAt && (proxyEnvAt < 0 || proxyEnvAt < lineAt)) {
				t.Fatalf(".env line must follow upstream's own .env write and precede the service creation")
			}
			// Apart from the inserted line, the served script is unchanged.
			lineStart := strings.LastIndex(got[:lineAt], "\n") + 1
			stripped := strings.TrimSuffix(got[:lineStart]+got[strings.Index(got[lineAt:], "\n")+lineAt+1:], "\n")
			if stripped != strings.TrimSuffix(strings.ReplaceAll(c.served, "\r\n", "\n"), "\n") {
				t.Fatalf("splice changed the served script beyond inserting the line")
			}
		})
	}
}
