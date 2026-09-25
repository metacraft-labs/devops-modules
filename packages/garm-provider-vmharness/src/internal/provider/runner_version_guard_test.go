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

// Tests for the cached-runner version guard (runner_version_guard.go).
//
// GitHub refuses to deliver jobs to deprecated actions/runner releases. Every
// bootstrap template -- GARM upstream's Windows/Linux ones and this provider's
// own -- reuses a runner pre-staged in the golden after checking only that it
// EXISTS, so a golden carrying an old runner kills every clone. These tests pin
// that each render path carries the guard, with the offered version, BEFORE
// the download decision, and they EXECUTE the guard exactly as rendered (bash
// and sh always; PowerShell when pwsh is on PATH) against real directories.
//
// Fakes, and why: the executed snippets call the enclosing template's status /
// failure functions (sendStatus, status, fail, Update-GarmStatus, Send-Status,
// Fail-Install), which in the guest POST to the GARM callback URL. The tests
// replace them with functions that print to stdout, because the thing under
// test is the guard's filesystem decision, not GARM's HTTP callback, and there
// is no GARM to call. The runner installs are real directory trees on disk
// with a Runner.Listener.deps.json shaped like the one a real 2.337.0 install
// ships (`"Runner.Listener/2.337.0": {`); only the runner binaries are absent,
// which the guard never touches (it must not execute the runner).

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	commonParams "github.com/cloudbase/garm-provider-common/params"

	"github.com/metacraft-labs/garm-provider-vmharness/internal/config"
)

const (
	guardMarker    = "# garm-provider-vmharness: cached-runner version guard"
	offeredVersion = "2.337.0"
)

func guardBootstrap(osType commonParams.OSType, arch commonParams.OSArch, toolsOS, toolsArch, filename, url string) commonParams.BootstrapInstance {
	return commonParams.BootstrapInstance{
		Name:             "garm-guard-1",
		RepoURL:          "https://github.com/example-org/example-repo",
		CallbackURL:      "http://192.168.122.1:9997/api/v1/callbacks",
		MetadataURL:      "http://192.168.122.1:9997/api/v1/metadata",
		InstanceToken:    "instance-token",
		OSType:           osType,
		OSArch:           arch,
		Labels:           []string{"self-hosted"},
		JitConfigEnabled: true,
		Tools: []commonParams.RunnerApplicationDownload{{
			OS:           strptr(toolsOS),
			Architecture: strptr(toolsArch),
			DownloadURL:  strptr(url),
			Filename:     strptr(filename),
		}},
	}
}

type guardPath struct {
	name    string
	backend config.BackendKind
	params  commonParams.BootstrapInstance
	// before: text that must precede the guard (the variable/functions it uses).
	before []string
	// decision: the download decision the guard must precede.
	decision string
	// marker proving the guard is instantiated for this template's style.
	offeredDecl string
}

func releaseURL(file string) string {
	return "https://github.com/actions/runner/releases/download/v" + offeredVersion + "/" + file
}

func guardPaths() []guardPath {
	winFile := "actions-runner-win-x64-" + offeredVersion + ".zip"
	winArmFile := "actions-runner-win-arm64-" + offeredVersion + ".zip"
	linFile := "actions-runner-linux-x64-" + offeredVersion + ".tar.gz"
	linArmFile := "actions-runner-linux-arm64-" + offeredVersion + ".tar.gz"
	osxFile := "actions-runner-osx-arm64-" + offeredVersion + ".tar.gz"
	return []guardPath{
		{
			name:        "upstream-windows-libvirt",
			backend:     config.BackendLibvirt,
			params:      guardBootstrap(commonParams.Windows, commonParams.Amd64, "win", "x64", winFile, releaseURL(winFile)),
			before:      []string{"function Update-GarmStatus()", `$runnerDir = "C:\actions-runner"`},
			decision:    "if (-not (Test-Path $runnerDir)) {",
			offeredDecl: "$garmOfferedRunnerVersion = '" + offeredVersion + "'",
		},
		{
			name:        "upstream-windows-remote-hyperv",
			backend:     config.BackendRemote,
			params:      guardBootstrap(commonParams.Windows, commonParams.Amd64, "win", "x64", winFile, releaseURL(winFile)),
			before:      []string{"function Update-GarmStatus()", `$runnerDir = "C:\actions-runner"`},
			decision:    "if (-not (Test-Path $runnerDir)) {",
			offeredDecl: "$garmOfferedRunnerVersion = '" + offeredVersion + "'",
		},
		{
			name:        "upstream-linux-incus",
			backend:     config.BackendIncus,
			params:      guardBootstrap(commonParams.Linux, commonParams.Amd64, "linux", "x64", linFile, releaseURL(linFile)),
			before:      []string{"function sendStatus()", "function fail()", `RUN_HOME="/home/`},
			decision:    `if [ ! -d "$RUN_HOME" ];then`,
			offeredDecl: "GARM_OFFERED_RUNNER_VERSION='" + offeredVersion + "'",
		},
		{
			name:        "own-linux-foreground-tart",
			backend:     config.BackendTartLinuxArm,
			params:      guardBootstrap(commonParams.Linux, commonParams.Arm64, "linux", "arm64", linArmFile, releaseURL(linArmFile)),
			before:      []string{"status() {", "fail() {", `mkdir -p "$RUN_HOME"`},
			decision:    `if [ ! -x "$RUN_HOME/run.sh" ]; then`,
			offeredDecl: "GARM_OFFERED_RUNNER_VERSION='" + offeredVersion + "'",
		},
		{
			name:        "own-macos-tart",
			backend:     config.BackendTartMacos,
			params:      guardBootstrap(commonParams.OSType("macos"), commonParams.Arm64, "osx", "arm64", osxFile, releaseURL(osxFile)),
			before:      []string{"status() {", "fail() {", `cd "$RUN_HOME"`},
			decision:    "if [ ! -x ./run.sh ]; then",
			offeredDecl: "GARM_OFFERED_RUNNER_VERSION='" + offeredVersion + "'",
		},
		{
			name:        "own-windows-qemu-arm",
			backend:     config.BackendQemuWindowsArm,
			params:      guardBootstrap(commonParams.Windows, commonParams.Arm64, "win", "arm64", winArmFile, releaseURL(winArmFile)),
			before:      []string{"function Send-Status {", "function Fail-Install {", "Set-Location $RunHome"},
			decision:    "if (-not (Test-Path (Join-Path $RunHome 'run.cmd'))) {",
			offeredDecl: "$garmOfferedRunnerVersion = '" + offeredVersion + "'",
		},
	}
}

func renderGuardPath(t *testing.T, p guardPath) string {
	t.Helper()
	tools, err := pickTools(p.params)
	if err != nil {
		t.Fatalf("%s: pickTools: %v", p.name, err)
	}
	out, err := renderRunnerBootstrapForBackend(p.backend, p.params, tools, p.params.Name)
	if err != nil {
		t.Fatalf("%s: render: %v", p.name, err)
	}
	return string(out)
}

// TestRunnerVersionGuardPrecedesDownloadDecision pins, for every render path,
// that the guard is present exactly once, carries the offered version, sees
// the variables/functions it uses, and runs before the "is a runner cached?"
// decision it exists to correct.
func TestRunnerVersionGuardPrecedesDownloadDecision(t *testing.T) {
	for _, p := range guardPaths() {
		t.Run(p.name, func(t *testing.T) {
			text := renderGuardPath(t, p)
			if n := strings.Count(text, guardMarker); n != 1 {
				t.Fatalf("guard marker appears %d times, want 1:\n%s", n, text)
			}
			guardAt := strings.Index(text, guardMarker)
			if !strings.Contains(text[guardAt:], p.offeredDecl) {
				t.Fatalf("guard does not declare offered version %q", p.offeredDecl)
			}
			if !strings.Contains(text[guardAt:], "Runner.Listener") {
				t.Fatalf("guard does not read Runner.Listener.deps.json")
			}
			for _, b := range p.before {
				i := strings.Index(text, b)
				if i < 0 || i > guardAt {
					t.Fatalf("%q must appear before the guard (at %d, guard at %d)", b, i, guardAt)
				}
			}
			d := strings.Index(text, p.decision)
			if d < 0 {
				t.Fatalf("download decision %q not found", p.decision)
			}
			if d < guardAt {
				t.Fatalf("guard (at %d) must precede download decision %q (at %d)", guardAt, p.decision, d)
			}
		})
	}
}

// TestRunnerVersionGuardOmittedWithoutOfferedVersion: when the tools entry
// carries no derivable version the guard is omitted and every path renders
// exactly as before -- the guard must never be what blocks a bootstrap.
func TestRunnerVersionGuardOmittedWithoutOfferedVersion(t *testing.T) {
	for _, p := range guardPaths() {
		t.Run(p.name, func(t *testing.T) {
			tool := p.params.Tools[0]
			file := *tool.Filename
			bare := strings.Replace(file, "-"+offeredVersion, "", 1)
			p.params.Tools = []commonParams.RunnerApplicationDownload{{
				OS:           tool.OS,
				Architecture: tool.Architecture,
				Filename:     strptr(bare),
				DownloadURL:  strptr("https://example.invalid/" + bare),
			}}
			text := renderGuardPath(t, p)
			if strings.Contains(text, guardMarker) || strings.Contains(text, "RUNNER_VERSION") || strings.Contains(text, "RunnerVersion") {
				t.Fatalf("guard rendered despite no derivable version:\n%s", text)
			}
		})
	}
}

// TestRunnerVersionGuardSkipsCustomUpstreamTemplate: a pool-supplied
// runner_install_template owns its own cache logic, so no injection happens
// (and no anchor is demanded of it).
func TestRunnerVersionGuardSkipsCustomUpstreamTemplate(t *testing.T) {
	for _, p := range guardPaths()[:3] {
		t.Run(p.name, func(t *testing.T) {
			// base64 of "echo custom {{ .RunnerName }}"
			p.params.ExtraSpecs = []byte(`{"runner_install_template":"ZWNobyBjdXN0b20ge3sgLlJ1bm5lck5hbWUgfX0="}`)
			text := renderGuardPath(t, p)
			if text != "echo custom garm-guard-1" {
				t.Fatalf("custom template was altered: %q", text)
			}
		})
	}
}

func TestOfferedRunnerVersion(t *testing.T) {
	cases := []struct {
		file, url, want string
	}{
		{"actions-runner-win-x64-2.337.0.zip", "", "2.337.0"},
		{"actions-runner-linux-arm64-2.328.0.tar.gz", "https://x/v9.9.9/y", "2.328.0"},
		{"actions-runner-win-x64.zip", "https://github.com/actions/runner/releases/download/v2.337.0/actions-runner-win-x64-2.337.0.zip", "2.337.0"},
		{"actions-runner-win-x64.zip", "https://example.invalid/actions-runner-win-x64.zip", ""},
		{"", "", ""},
	}
	for _, c := range cases {
		tools := commonParams.RunnerApplicationDownload{Filename: strptr(c.file), DownloadURL: strptr(c.url)}
		if got := offeredRunnerVersion(tools); got != c.want {
			t.Errorf("offeredRunnerVersion(%q, %q) = %q, want %q", c.file, c.url, got, c.want)
		}
	}
}

func TestInjectBeforeAnchor(t *testing.T) {
	script := "a\n\t\tprev\n\t\tANCHOR\n\t\tafter\n"
	out, err := injectBeforeAnchor([]byte(script), "ANCHOR", "prev", "x\n\ty\n\n")
	if err != nil {
		t.Fatalf("inject: %v", err)
	}
	want := "a\n\t\tprev\n\t\tx\n\t\t\ty\n\n\t\tANCHOR\n\t\tafter\n"
	if string(out) != want {
		t.Fatalf("inject = %q, want %q", out, want)
	}

	if _, err := injectBeforeAnchor([]byte("a\nb\n"), "ANCHOR", "", "x\n"); err == nil || !strings.Contains(err.Error(), "not found") {
		t.Fatalf("missing anchor: err = %v, want not-found error", err)
	}
	if _, err := injectBeforeAnchor([]byte("ANCHOR\n  ANCHOR\n"), "ANCHOR", "", "x\n"); err == nil || !strings.Contains(err.Error(), "more than once") {
		t.Fatalf("duplicate anchor: err = %v, want more-than-once error", err)
	}
	if _, err := injectBeforeAnchor([]byte("other\nANCHOR\n"), "ANCHOR", "prev", "x\n"); err == nil || !strings.Contains(err.Error(), "not preceded") {
		t.Fatalf("wrong predecessor: err = %v, want not-preceded error", err)
	}
	if _, err := injectBeforeAnchor([]byte("ANCHOR\n"), "ANCHOR", "prev", "x\n"); err == nil {
		t.Fatalf("anchor on first line with required predecessor: want error")
	}
}

// TestUpstreamGuardFailsLoudlyWhenAnchorMissing: a default-template render
// whose anchor has moved (eg a vendored-upstream bump) must be an error, not a
// silently unguarded script.
func TestUpstreamGuardFailsLoudlyWhenAnchorMissing(t *testing.T) {
	for _, p := range guardPaths()[:3] {
		t.Run(p.name, func(t *testing.T) {
			tools, err := pickTools(p.params)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := guardUpstreamRunnerInstallScript(p.params, tools, []byte("#!/bin/bash\necho no anchors here\n")); err == nil {
				t.Fatalf("want an error when the upstream anchor is missing")
			}
		})
	}
}

// ---- execution tests -------------------------------------------------------

// extractGuard returns the rendered guard exactly as it appears in the
// bootstrap: from its marker up to (not including) the download decision.
func extractGuard(t *testing.T, p guardPath) string {
	t.Helper()
	text := renderGuardPath(t, p)
	start := strings.Index(text, guardMarker)
	if start < 0 {
		t.Fatalf("%s: guard not rendered", p.name)
	}
	end := strings.Index(text[start:], p.decision)
	if end < 0 {
		t.Fatalf("%s: decision not found after guard", p.name)
	}
	body := text[start : start+end]
	// Drop the (indented) start of the decision line.
	return body[:strings.LastIndex(body, "\n")+1]
}

func findShell(t *testing.T, name string, fallbackEnv ...string) string {
	t.Helper()
	if p, err := exec.LookPath(name); err == nil {
		return p
	}
	for _, env := range fallbackEnv {
		if v := os.Getenv(env); v != "" && filepath.Base(v) == name {
			return v
		}
	}
	t.Skipf("%s not found on PATH", name)
	return ""
}

func depsJSON(version string) string {
	return `{
  "runtimeTarget": {
    "name": ".NETCoreApp,Version=v8.0/linux-x64",
    "signature": ""
  },
  "compilationOptions": {},
  "targets": {
    ".NETCoreApp,Version=v8.0": {},
    ".NETCoreApp,Version=v8.0/linux-x64": {
      "Runner.Listener/` + version + `": {
        "dependencies": {
          "Runner.Common": "` + version + `",
          "Runner.Sdk": "` + version + `"
        },
        "runtime": {
          "Runner.Listener.dll": {}
        }
      }
    }
  },
  "libraries": {
    "Runner.Listener/` + version + `": {
      "type": "project",
      "serviceable": false,
      "sha512": ""
    }
  }
}
`
}

type guardCase struct {
	name string
	// setup builds the runner home under dir (may leave it absent).
	setup func(t *testing.T, home string)
	// discarded: the runner payload must be gone afterwards.
	discarded bool
	// wantStatus: substrings the reported status must contain ("" = no status).
	wantStatus []string
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o755); err != nil {
		t.Fatal(err)
	}
}

func stagedRunner(version, launcher string) func(t *testing.T, home string) {
	return func(t *testing.T, home string) {
		writeFile(t, filepath.Join(home, launcher), "#!/bin/sh\n")
		writeFile(t, filepath.Join(home, "externals", "node20", "bin", "node"), "")
		writeFile(t, filepath.Join(home, ".env"), "LANG=C.UTF-8\n")
		if version != "" {
			writeFile(t, filepath.Join(home, "bin", "Runner.Listener.deps.json"), depsJSON(version))
		} else {
			writeFile(t, filepath.Join(home, "bin", "Runner.Listener.dll"), "")
		}
	}
}

func guardCases(launcher string) []guardCase {
	return []guardCase{
		{name: "matching-version-kept", setup: stagedRunner(offeredVersion, launcher)},
		{name: "older-version-discarded", setup: stagedRunner("2.328.0", launcher), discarded: true,
			wantStatus: []string{"cached runner 2.328.0", "offered " + offeredVersion, "discarding"}},
		{name: "missing-deps-discarded", setup: stagedRunner("", launcher), discarded: true,
			wantStatus: []string{"cached runner unknown", "offered " + offeredVersion}},
		{name: "no-runner-untouched", setup: func(*testing.T, string) {}},
	}
}

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// checkGuardOutcome asserts the post-run filesystem state. wholeDir: the
// template discards the entire runner home; otherwise only the payload.
func checkGuardOutcome(t *testing.T, c guardCase, home, launcher, out string, wholeDir bool) {
	t.Helper()
	staged := c.name != "no-runner-untouched"
	if !c.discarded {
		if staged {
			for _, rel := range []string{launcher, "bin", "externals", ".env"} {
				if !exists(filepath.Join(home, rel)) {
					t.Fatalf("%s was removed although the cached runner matches:\n%s", rel, out)
				}
			}
		} else if wholeDir && exists(home) {
			t.Fatalf("guard created %s:\n%s", home, out)
		}
		if strings.Contains(out, "STATUS:") || strings.Contains(out, "FAIL:") {
			t.Fatalf("guard reported status although nothing was discarded:\n%s", out)
		}
		return
	}
	if wholeDir {
		if exists(home) {
			t.Fatalf("cached runner dir %s was not discarded:\n%s", home, out)
		}
	} else {
		for _, rel := range []string{launcher, "bin", "externals"} {
			if exists(filepath.Join(home, rel)) {
				t.Fatalf("%s survived the discard:\n%s", rel, out)
			}
		}
		if !exists(filepath.Join(home, ".env")) {
			t.Fatalf(".env must be kept when only the runner payload is discarded:\n%s", out)
		}
	}
	for _, w := range c.wantStatus {
		if !strings.Contains(out, w) {
			t.Fatalf("status output missing %q:\n%s", w, out)
		}
	}
	if strings.Contains(out, "FAIL:") {
		t.Fatalf("guard failed:\n%s", out)
	}
}

// TestRunnerVersionGuardExecutesInShell runs each POSIX-shell guard exactly as
// rendered, under the enclosing template's strictness (`set -e`, pipefail for
// bash, `set -eu` for the macOS sh template).
func TestRunnerVersionGuardExecutesInShell(t *testing.T) {
	type shellPath struct {
		pathName string
		shell    string
		prelude  string
		statusFn string
		wholeDir bool
	}
	paths := map[string]guardPath{}
	for _, p := range guardPaths() {
		paths[p.name] = p
	}
	for _, sp := range []shellPath{
		{"upstream-linux-incus", "bash", "set -e\nset -o pipefail\n", "sendStatus", true},
		{"own-linux-foreground-tart", "bash", "set -e\nset -o pipefail\n", "status", false},
		{"own-macos-tart", "sh", "set -eu\n", "status", false},
	} {
		p := paths[sp.pathName]
		guard := extractGuard(t, p)
		for _, c := range guardCases("run.sh") {
			t.Run(sp.pathName+"/"+c.name, func(t *testing.T) {
				shell := findShell(t, sp.shell, "CONFIG_SHELL", "SHELL")
				dir := t.TempDir()
				home := filepath.Join(dir, "actions-runner")
				c.setup(t, home)
				script := sp.prelude +
					sp.statusFn + "() { echo \"STATUS: $1\"; }\n" +
					"fail() { echo \"FAIL: $1\"; exit 1; }\n" +
					"RUN_HOME=" + shellQuote(home) + "\n" +
					guard +
					"echo GUARD-DONE\n"
				cmd := exec.Command(shell, "-c", script)
				outB, err := cmd.CombinedOutput()
				out := string(outB)
				if err != nil {
					t.Fatalf("guard exited with %v:\n%s\n--- script ---\n%s", err, out, script)
				}
				if !strings.Contains(out, "GUARD-DONE") {
					t.Fatalf("guard did not run to completion:\n%s", out)
				}
				checkGuardOutcome(t, c, home, "run.sh", out, sp.wholeDir)
			})
		}
	}
}

// TestRunnerVersionGuardExecutesInPowerShell runs each PowerShell guard exactly
// as rendered under $ErrorActionPreference = 'Stop' (as both Windows templates
// set it), when pwsh is available.
func TestRunnerVersionGuardExecutesInPowerShell(t *testing.T) {
	paths := map[string]guardPath{}
	for _, p := range guardPaths() {
		paths[p.name] = p
	}
	type psPath struct {
		pathName string
		homeVar  string
		stubs    string
		wholeDir bool
	}
	for _, pp := range []psPath{
		{"upstream-windows-libvirt", "runnerDir",
			"function Update-GarmStatus { param([string]$CallbackURL, [string]$Message) Write-Host \"STATUS: $Message\" }\n" +
				"$CallbackURL = 'http://callback.invalid'\n", true},
		{"own-windows-qemu-arm", "RunHome",
			"function Send-Status { param([string]$Status, [string]$Message) Write-Host \"STATUS: $Message\" }\n" +
				"function Fail-Install { param([string]$Message) Write-Host \"FAIL: $Message\"; exit 1 }\n", false},
	} {
		p := paths[pp.pathName]
		guard := extractGuard(t, p)
		for _, c := range guardCases("run.cmd") {
			t.Run(pp.pathName+"/"+c.name, func(t *testing.T) {
				pwsh := findShell(t, "pwsh")
				dir := t.TempDir()
				home := filepath.Join(dir, "actions-runner")
				c.setup(t, home)
				script := "$ErrorActionPreference = 'Stop'\n" + pp.stubs +
					"$" + pp.homeVar + " = " + powershellQuote(home) + "\n" +
					"try {\n" + guard + "} catch { Write-Host \"FAIL: $_\"; exit 1 }\n" +
					"Write-Host GUARD-DONE\n"
				scriptPath := filepath.Join(dir, "guard.ps1")
				writeFile(t, scriptPath, script)
				outB, err := exec.Command(pwsh, "-NoProfile", "-NonInteractive", "-File", scriptPath).CombinedOutput()
				out := string(outB)
				if err != nil {
					t.Fatalf("guard exited with %v:\n%s\n--- script ---\n%s", err, out, script)
				}
				if !strings.Contains(out, "GUARD-DONE") {
					t.Fatalf("guard did not run to completion:\n%s", out)
				}
				checkGuardOutcome(t, c, home, "run.cmd", out, pp.wholeDir)
			})
		}
	}
}
