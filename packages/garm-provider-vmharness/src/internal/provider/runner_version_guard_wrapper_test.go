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

// Tests for the cached-runner version guard on GARM's install-script route.
//
// GARM >= 0.2 hands the provider a WRAPPER as the pool's runner_install_template
// (GARM util.MaybeAddWrapperToExtraSpecs). In the guest the wrapper fetches the
// real install script GARM renders from the pool's stored template at
// "$METADATA_URL/install-script/" and runs it. The guard used to be skipped
// for every such pool, because a non-empty runner_install_template was taken
// to be a custom template, and so every remote-incus runner reused the image's
// stale runner. These tests drive that route with GARM's REAL template text:
// the wrapper and the stored system templates in testdata/garm-upstream are
// verbatim copies of the packaged GARM source, and the
// t_garm_install_script_template_fixtures check fails when they drift. They
// are rendered with text/template, exactly as GARM renders them (GARM uses no
// FuncMap).
//
// Fakes, and why:
//   - GARM's metadata and callback API is an httptest server. It serves the
//     install script and records the status callbacks, which are the only
//     evidence GARM ever gets of what the guard did. Running real GARM here
//     would need its database and a GitHub App, and what is under test is the
//     wrapper/served-script pair, not GARM's HTTP stack.
//   - The rendered text gets five substitutions, all named where they are
//     made: the served script's RUN_HOME (the guest's /home/runner) and the
//     guard's chown owner (the guest's runner user) point at the test's own
//     temp dir and uid, the wrapper's fixed /tmp paths move into the temp dir,
//     the served script's #!/bin/bash names the test's bash (NixOS builders
//     have no /bin/bash), and the served script is cut right after its
//     cached-runner decision, because it would next register a real runner
//     with GitHub.
//   - The runner archive is a real tar.gz fetched with the real curl over
//     file://, as in the other guard tests.

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"text/template"

	commonParams "github.com/cloudbase/garm-provider-common/params"

	"github.com/metacraft-labs/garm-provider-vmharness/internal/config"
)

const garmUpstreamFixtures = "testdata/garm-upstream"

func garmFixture(t *testing.T, name string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(garmUpstreamFixtures, name))
	if err != nil {
		t.Fatalf("reading GARM template fixture: %v", err)
	}
	return string(data)
}

func renderGarmTemplate(t *testing.T, name string, ctx map[string]any) string {
	t.Helper()
	tpl, err := template.New(name).Parse(garmFixture(t, name))
	if err != nil {
		t.Fatalf("parsing %s: %v", name, err)
	}
	var b strings.Builder
	if err := tpl.Execute(&b, ctx); err != nil {
		t.Fatalf("rendering %s: %v", name, err)
	}
	return b.String()
}

// garmWrapper renders GARM's install-script wrapper for osType, the way
// templates.RenderRunnerInstallWrapper does (WrapperContext, no proxy, no CA).
func garmWrapper(t *testing.T, osType commonParams.OSType, metadataURL, callbackURL string) string {
	t.Helper()
	name := "linux_wrapper.tmpl"
	if osType == commonParams.Windows {
		name = "windows_wrapper.tmpl"
	}
	return renderGarmTemplate(t, name, map[string]any{
		"MetadataURL":   metadataURL,
		"CallbackURL":   callbackURL,
		"CallbackToken": "instance-token",
		"HTTPProxy":     "",
		"HTTPSProxy":    "",
		"NoProxy":       "",
		"CACertBundle":  "",
	})
}

// withGarmWrapper sets the pool's extra specs the way GARM does before it calls
// the provider: runner_install_template is the wrapper ([]byte, so base64 in
// JSON).
func withGarmWrapper(t *testing.T, params commonParams.BootstrapInstance, wrapper string) commonParams.BootstrapInstance {
	t.Helper()
	specs, err := json.Marshal(map[string]any{"runner_install_template": []byte(wrapper)})
	if err != nil {
		t.Fatal(err)
	}
	params.ExtraSpecs = specs
	return params
}

func wrapperAnchorFor(osType commonParams.OSType) string {
	if osType == commonParams.Windows {
		return garmWindowsWrapperAnchor
	}
	return garmLinuxWrapperAnchor
}

func isUpstreamPath(p guardPath) bool {
	return strings.HasPrefix(p.name, "upstream-")
}

// TestRunnerVersionGuardReachesGarmInstallScriptWrapper pins the 2026-10-08
// finding: with GARM's wrapper as runner_install_template, every render path
// must still carry the guard exactly once, with the offered version. On the
// upstream paths it travels inside the splice step, between the wrapper's
// fetch and its run, and the wrapper is otherwise unchanged.
func TestRunnerVersionGuardReachesGarmInstallScriptWrapper(t *testing.T) {
	for _, p := range guardPaths() {
		t.Run(p.name, func(t *testing.T) {
			osType := p.params.OSType
			wrapper := garmWrapper(t, osType, p.params.MetadataURL, p.params.CallbackURL)
			p.params = withGarmWrapper(t, p.params, wrapper)
			text := renderGuardPath(t, p)

			if n := strings.Count(text, guardMarker); n != 1 {
				t.Fatalf("guard marker appears %d times with GARM's wrapper as runner_install_template, want 1:\n%s", n, text)
			}
			if !strings.Contains(text[strings.Index(text, guardMarker):], p.offeredDecl) {
				t.Fatalf("guard does not declare offered version %q", p.offeredDecl)
			}
			if !isUpstreamPath(p) {
				return
			}
			anchor := wrapperAnchorFor(osType)
			at := strings.Index(wrapper, anchor)
			if at < 0 {
				t.Fatalf("GARM wrapper fixture lost its anchor %q", anchor)
			}
			if !strings.HasPrefix(text, wrapper[:at]) || !strings.HasSuffix(text, wrapper[at:]) {
				t.Fatalf("the wrapper must be unchanged apart from the inserted splice step:\n%s", text)
			}
			splice := text[at : len(text)-len(wrapper[at:])]
			if !strings.HasPrefix(splice, garmWrapperSpliceMarker) || !strings.Contains(splice, guardMarker) {
				t.Fatalf("inserted text is not the guard splice step:\n%s", splice)
			}
		})
	}
}

// TestCustomTemplateStillUntouchedNextToWrapperSupport: recognising GARM's
// wrapper must not widen the guard to genuinely custom templates, including
// ones that merely mention the install-script endpoint.
func TestCustomTemplateStillUntouchedNextToWrapperSupport(t *testing.T) {
	custom := map[commonParams.OSType]string{
		commonParams.Linux:   "#!/bin/bash\ncurl \"$METADATA_URL/install-script/\" | bash\n",
		commonParams.Windows: "wget -Uri \"$MetadataUrl/install-script/\" -OutFile $installScript\n& $installScript\n",
	}
	for _, p := range guardPaths()[:3] {
		t.Run(p.name, func(t *testing.T) {
			want := custom[p.params.OSType]
			p.params = withGarmWrapper(t, p.params, want)
			if got := renderGuardPath(t, p); got != want {
				t.Fatalf("custom template was altered:\n%s", got)
			}
		})
	}
}

// fakeGarm is GARM's metadata + callback API as the guest sees it.
type fakeGarm struct {
	srv           *httptest.Server
	installScript string
	mu            sync.Mutex
	statuses      []map[string]any
	badAuth       []string
}

func newFakeGarm(t *testing.T, installScript string) *fakeGarm {
	t.Helper()
	g := &fakeGarm{installScript: installScript}
	g.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer instance-token" {
			g.mu.Lock()
			g.badAuth = append(g.badAuth, r.URL.Path)
			g.mu.Unlock()
			http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
			return
		}
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/metadata/install-script/":
			_, _ = io.WriteString(w, g.installScript)
		case r.Method == http.MethodPost && r.URL.Path == "/api/v1/callbacks/status":
			var body map[string]any
			data, _ := io.ReadAll(r.Body)
			if err := json.Unmarshal(data, &body); err != nil {
				body = map[string]any{"unparseable": string(data)}
			}
			g.mu.Lock()
			g.statuses = append(g.statuses, body)
			g.mu.Unlock()
			_, _ = io.WriteString(w, "{}")
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(g.srv.Close)
	return g
}

func (g *fakeGarm) statusLog() string {
	g.mu.Lock()
	defer g.mu.Unlock()
	var b strings.Builder
	for _, s := range g.statuses {
		fmt.Fprintf(&b, "%v: %v\n", s["status"], s["message"])
	}
	return b.String()
}

// servedLinuxScript renders GARM's stored github_linux template as GARM serves
// it, then applies the RUN_HOME substitution and the cut described in the
// file header.
func servedLinuxScript(t *testing.T, g *fakeGarm, tools commonParams.RunnerApplicationDownload, runHome, bash string) string {
	t.Helper()
	script := renderGarmTemplate(t, "github_linux_userdata.tmpl", map[string]any{
		"CallbackURL":            g.srv.URL + "/api/v1/callbacks",
		"MetadataURL":            g.srv.URL + "/api/v1/metadata",
		"CallbackToken":          "instance-token",
		"RunnerUsername":         "runner",
		"RunnerGroup":            "runner",
		"DownloadURL":            tools.GetDownloadURL(),
		"FileName":               tools.GetFilename(),
		"TempDownloadToken":      "",
		"RepoURL":                "https://github.com/example-org/example-repo",
		"RunnerName":             "garm-guard-1",
		"RunnerLabels":           "self-hosted",
		"GitHubRunnerGroup":      "",
		"UseJITConfig":           true,
		"EnableBootDebug":        false,
		"AgentMode":              false,
		"ForceInsecureGARMAgent": false,
		"AgentDownloadURL":       "",
		"AgentURL":               "",
		"AgentToken":             "",
		"AgentShell":             "false",
		"CACertBundle":           "",
	})
	if !strings.HasPrefix(script, "#!/bin/bash\n") {
		t.Fatalf("served script no longer starts with #!/bin/bash")
	}
	script = "#!" + bash + strings.TrimPrefix(script, "#!/bin/bash")
	runHomeLine := `RUN_HOME="/home/runner/actions-runner"`
	if strings.Count(script, runHomeLine) != 1 {
		t.Fatalf("served script lost its %s line", runHomeLine)
	}
	script = strings.Replace(script, runHomeLine, "RUN_HOME="+shellQuote(runHome), 1)
	cut := `sendStatus "configuring runner"`
	if strings.Count(script, cut) != 1 {
		t.Fatalf("served script lost its %s line", cut)
	}
	return strings.Replace(script, cut,
		`echo "CONFIGURE-REACHED runner=$(sed -n 's|.*"Runner\.Listener/\([0-9.]*\)".*|\1|p' "$RUN_HOME/bin/Runner.Listener.deps.json" | head -n 1)"`+"\nexit 0", 1)
}

// awkVariants: the guest is Debian (mawk); the splice must work with every
// awk it may meet.
func awkVariants(t *testing.T) map[string]string {
	t.Helper()
	dirs := map[string]string{}
	link := func(name, body string) {
		dir := t.TempDir()
		writeFile(t, filepath.Join(dir, "awk"), body)
		dirs[name] = dir
	}
	for _, name := range []string{"mawk", "gawk"} {
		if p, err := exec.LookPath(name); err == nil {
			link(name, "#!/bin/sh\nexec "+shellQuote(p)+" \"$@\"\n")
		}
	}
	if p, err := exec.LookPath("busybox"); err == nil {
		link("busybox", "#!/bin/sh\nexec "+shellQuote(p)+" awk \"$@\"\n")
	}
	if len(dirs) == 0 {
		if _, err := exec.LookPath("awk"); err != nil {
			t.Skip("no awk on PATH")
		}
		dirs["awk"] = ""
	}
	return dirs
}

// TestGarmWrapperGuardExecutesAgainstServedTemplate runs the wrapper the
// provider emits, as the guest runs it (bash, the wrapper's own `set -ex`),
// against GARM's real github_linux template served over HTTP. A stale runner
// baked into the image must be replaced BEFORE the served script's
// cached-runner branch reuses it. This is the outage scenario of 2026-09-24
// on the route the remote-incus pools actually use.
func TestGarmWrapperGuardExecutesAgainstServedTemplate(t *testing.T) {
	bash := findShell(t, "bash", "CONFIG_SHELL", "SHELL")
	if _, err := exec.LookPath("curl"); err != nil {
		t.Skip("curl not found on PATH")
	}
	fixtures := t.TempDir()
	goodTar, goodSHA := runnerTarball(t, fixtures, offeredVersion)

	cases := []struct {
		name          string
		url           string
		staged        string // "" = no runner home in the image
		customServed  bool   // the pool's stored template is not upstream's
		wantExit      bool   // the bootstrap must fail
		wantVersion   string // runner version the served script configures
		wantStatuses  []string
		forbidStatues []string
	}{
		{name: "stale-image-runner-replaced", url: "file://" + goodTar, staged: "2.328.0", wantVersion: offeredVersion,
			wantStatuses: []string{"cached runner 2.328.0", "!= offered " + offeredVersion, "replacing runner binaries in place", "using cached runner found in"}},
		{name: "current-image-runner-kept", url: "file://" + goodTar, staged: offeredVersion, wantVersion: offeredVersion,
			wantStatuses: []string{"using cached runner found in"}, forbidStatues: []string{"!= offered"}},
		{name: "replacement-download-fails-bootstrap", url: "file://" + filepath.Join(fixtures, "absent.tar.gz"), staged: "2.328.0", wantExit: true,
			wantStatuses: []string{"failed to download runner " + offeredVersion}, forbidStatues: []string{"using cached runner found in"}},
		{name: "custom-stored-template-runs-as-served", url: "file://" + goodTar, staged: "2.328.0", customServed: true, wantVersion: "2.328.0",
			wantStatuses: []string{"cached-runner version guard not applied"}},
	}
	for awkName, awkDir := range awkVariants(t) {
		for _, c := range cases {
			t.Run(awkName+"/"+c.name, func(t *testing.T) {
				dir := t.TempDir()
				home := filepath.Join(dir, "actions-runner")
				if c.staged != "" {
					stagedRunner(c.staged, "run.sh")(t, home)
				}

				file := "actions-runner-linux-x64-" + offeredVersion + ".tar.gz"
				params := guardBootstrap(commonParams.Linux, commonParams.Amd64, "linux", "x64", file, c.url)
				params.Tools[0].SHA256Checksum = strptr(goodSHA)
				tools, err := pickTools(params)
				if err != nil {
					t.Fatal(err)
				}

				g := newFakeGarm(t, "")
				served := servedLinuxScript(t, g, tools, home, bash)
				if c.customServed {
					// A stored template of the operator's own: no upstream
					// cached-runner check, so nothing to splice into.
					served = strings.Replace(served, upstreamLinuxGuardAnchor, `if test ! -d "$RUN_HOME"; then`, 1)
				}
				g.installScript = served

				params.MetadataURL = g.srv.URL + "/api/v1/metadata"
				params.CallbackURL = g.srv.URL + "/api/v1/callbacks"
				params = withGarmWrapper(t, params, garmWrapper(t, commonParams.Linux, params.MetadataURL, params.CallbackURL))
				out, err := renderRunnerBootstrapForBackend(config.BackendRemote, params, tools, params.Name)
				if err != nil {
					t.Fatalf("render: %v", err)
				}
				bootstrap := string(out)
				owner := "GARM_RUNNER_OWNER='runner:runner'"
				// (Presence of the guard is TestRunnerVersionGuardReachesGarmInstallScriptWrapper's
				// job; this test judges only what the bootstrap DOES.)
				if strings.Count(bootstrap, owner) > 1 {
					t.Fatalf("bootstrap chowns to the guest runner user more than once (%q):\n%s", owner, bootstrap)
				}
				bootstrap = strings.Replace(bootstrap, owner, fmt.Sprintf("GARM_RUNNER_OWNER='%d:%d'", os.Getuid(), os.Getgid()), 1)
				for _, tmpPath := range []string{"/tmp/real-install.sh", "/tmp/garm-runner-version-guard.sh"} {
					bootstrap = strings.ReplaceAll(bootstrap, tmpPath, filepath.Join(dir, filepath.Base(tmpPath)))
				}
				scriptPath := filepath.Join(dir, "garm-bootstrap.sh")
				writeFile(t, scriptPath, bootstrap)

				cmd := exec.Command(bash, scriptPath)
				path := os.Getenv("PATH")
				if awkDir != "" {
					path = awkDir + string(os.PathListSeparator) + path
				}
				cmd.Env = append(os.Environ(), "PATH="+path, "TMPDIR="+dir)
				outB, runErr := cmd.CombinedOutput()
				log := string(outB) + "\n--- statuses ---\n" + g.statusLog()

				if len(g.badAuth) > 0 {
					t.Fatalf("requests without the instance token: %v\n%s", g.badAuth, log)
				}
				statuses := g.statusLog()
				for _, w := range c.wantStatuses {
					if !strings.Contains(statuses, w) {
						t.Fatalf("no status containing %q reached GARM:\n%s", w, log)
					}
				}
				for _, f := range c.forbidStatues {
					if strings.Contains(statuses, f) {
						t.Fatalf("unexpected status containing %q:\n%s", f, log)
					}
				}
				if c.wantExit {
					if runErr == nil || strings.Contains(string(outB), "CONFIGURE-REACHED") {
						t.Fatalf("bootstrap went on to configure the runner after a failed replacement:\n%s", log)
					}
					return
				}
				if runErr != nil {
					t.Fatalf("bootstrap failed: %v\n%s", runErr, log)
				}
				want := "CONFIGURE-REACHED runner=" + c.wantVersion
				if !strings.Contains(string(outB), want) {
					t.Fatalf("served script did not configure runner %s (%q missing):\n%s", c.wantVersion, want, log)
				}
				for _, leftover := range []string{"real-install.sh", "real-install.sh.guarded", "garm-runner-version-guard.sh"} {
					if exists(filepath.Join(dir, leftover)) {
						t.Fatalf("%s left behind:\n%s", leftover, log)
					}
				}
			})
		}
	}
}

// TestGarmWindowsWrapperSpliceAgainstServedTemplate runs the Windows splice
// step exactly as rendered into GARM's windows wrapper (pwsh, under the
// wrapper's $ErrorActionPreference = "Stop") against GARM's real
// github_windows template as GARM serves it. The whole wrapper cannot run
// here: it downloads with `wget`, a Windows PowerShell alias. The guard itself
// is executed by TestRunnerVersionGuardExecutesInPowerShell; this pins where
// it lands and that the result still parses.
func TestGarmWindowsWrapperSpliceAgainstServedTemplate(t *testing.T) {
	pwsh := findShell(t, "pwsh")
	winFile := "actions-runner-win-x64-" + offeredVersion + ".zip"
	params := guardBootstrap(commonParams.Windows, commonParams.Amd64, "win", "x64", winFile, releaseURL(winFile))
	params = withGarmWrapper(t, params, garmWrapper(t, commonParams.Windows, params.MetadataURL, params.CallbackURL))
	tools, err := pickTools(params)
	if err != nil {
		t.Fatal(err)
	}
	out, err := renderRunnerBootstrapForBackend(config.BackendRemote, params, tools, params.Name)
	if err != nil {
		t.Fatalf("render: %v", err)
	}
	text := string(out)
	start := strings.Index(text, garmWrapperSpliceMarker)
	end := strings.Index(text, garmWindowsWrapperAnchor)
	if start < 0 || end < start {
		t.Fatalf("no splice step before the wrapper's run line:\n%s", text)
	}
	splice := text[start:end]

	served := renderGarmTemplate(t, "github_windows_userdata.tmpl", map[string]any{
		"CallbackURL":       params.CallbackURL,
		"MetadataURL":       params.MetadataURL,
		"CallbackToken":     "instance-token",
		"DownloadURL":       tools.GetDownloadURL(),
		"FileName":          tools.GetFilename(),
		"TempDownloadToken": "",
		"RepoURL":           params.RepoURL,
		"RunnerName":        params.Name,
		"RunnerLabels":      "self-hosted",
		"GitHubRunnerGroup": "",
		"UseJITConfig":      true,
		"AgentMode":         false,
		"CACertBundle":      "",
	})

	for _, c := range []struct {
		name    string
		served  string
		spliced bool
	}{
		{"upstream-template", served, true},
		{"custom-template", strings.Replace(served, upstreamWindowsGuardAnchor, "# operator's own cache logic", 1), false},
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
			if err != nil || !strings.Contains(log, "SPLICE-DONE") {
				t.Fatalf("splice step failed: %v\n%s", err, log)
			}
			if !strings.Contains(log, "PARSE-ERRORS: 0") {
				t.Fatalf("install script does not parse after the splice:\n%s", log)
			}
			result, err := os.ReadFile(installScript)
			if err != nil {
				t.Fatal(err)
			}
			got := strings.ReplaceAll(string(result), "\r\n", "\n")
			if !c.spliced {
				if strings.Contains(got, guardMarker) || !strings.Contains(log, "guard not applied") {
					t.Fatalf("custom template must run as served, with a notice:\n%s", log)
				}
				return
			}
			if n := strings.Count(got, guardMarker); n != 1 {
				t.Fatalf("guard spliced %d times, want 1:\n%s", n, got)
			}
			guardAt := strings.Index(got, guardMarker)
			dirAt := strings.Index(got, upstreamWindowsRunnerDirLine)
			anchorAt := strings.Index(got, upstreamWindowsGuardAnchor)
			if !(dirAt >= 0 && dirAt < guardAt && guardAt < anchorAt) {
				t.Fatalf("guard must sit between %q and %q (at %d, %d, %d):\n%s", upstreamWindowsRunnerDirLine, upstreamWindowsGuardAnchor, dirAt, guardAt, anchorAt, got)
			}
			for _, need := range []string{"$garmOfferedRunnerVersion = '" + offeredVersion + "'", "Update-GarmStatus -CallbackURL $CallbackURL"} {
				if !strings.Contains(got[guardAt:anchorAt], need) {
					t.Fatalf("spliced guard lacks %q:\n%s", need, got[guardAt:anchorAt])
				}
			}
			// Apart from the inserted guard, the served script is unchanged: the
			// guard starts after the anchor line's indent and ends at the anchor.
			// (WriteAllLines ends the last line, which the template leaves open.)
			stripped := strings.TrimSuffix(got[:guardAt]+got[anchorAt:], "\n")
			if stripped != strings.TrimSuffix(strings.ReplaceAll(c.served, "\r\n", "\n"), "\n") {
				t.Fatalf("splice changed the served script beyond inserting the guard:\n%s", stripped)
			}
		})
	}
}
