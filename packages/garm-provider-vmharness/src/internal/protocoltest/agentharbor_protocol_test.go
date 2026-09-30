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

// Sovereign-CI-Fleet AH3 gate `t_garm_provider_agentharbor` (end-to-end half;
// the behavioural matrix is internal/agentharbor/provider_test.go).
//
// It drives the BUILT garm-provider-agentharbor binary through GARM's real
// v0.1.1 external-provider protocol (GARM_* env, BootstrapInstance JSON on
// stdin, ProviderInstance JSON on stdout, exit codes 0/30/31), one fresh
// process per call exactly as GARM does, and follows one ephemeral runner
// through its whole life: launched as a sandbox job, REGISTERS (fetches its
// JIT credentials from GARM's metadata endpoint, reports idle), SERVES a job
// (acquires it from a fake GitHub and holds it), finishes, is reported
// stopped, is REAPED by DeleteInstance, and leaves NO RESIDUE: no process, no
// workspace, no provider-side file. A second runner is reaped mid-job.
//
// MOCK JUSTIFICATION (workspace rule: every mock is justified here). Three
// stand-ins, each at the narrowest seam that keeps the gate hermetic:
//
//  1. ahmock (agent-harbor REST). The real `ah daemon serve` is not packaged
//     in this repo and its local-sandbox substrate needs user namespaces and a
//     delegated cgroup scope unavailable in a Nix build sandbox. The mock
//     implements the Direct-Sandbox-Launch.md contract and, crucially, EXECUTES
//     the job for real: the provider's rendered install script runs under
//     `bash -s` in a fresh per-job directory with the spec's environment, and
//     the process group + directory are freed on exit/destroy. Only the
//     isolation layer is absent; that is agent-harbor's own AH4 gate.
//  2. Fake GARM metadata/callback endpoints. GARM itself would need a GitHub
//     App and a forge to mint JIT configs; the provider only ever hands the
//     script GARM's URLs + instance token, so an HTTP endpoint serving the
//     same paths (credentials/runner, credentials/credentials,
//     credentials/credentials_rsaparams, callbacks/status, system-info) and
//     checking the bearer token is the exact boundary the script talks to.
//  3. Fake actions/runner tarball + fake GitHub job endpoint. The real runner
//     needs github.com; the fake run.sh refuses to start unless the three JIT
//     credential files were installed, then long-polls a job from the fake
//     GitHub, which is what "serves" means at this boundary.
//
// Everything else is real: the provider binary, the HTTP sockets, the Ed25519
// manifest signature, the shell script, curl, tar and sha256sum.
package protocoltest

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/metacraft-labs/garm-provider-vmharness/internal/agentharbor/ahmock"
)

const (
	ahController    = "ctrl-ah3-e2e"
	ahPool          = "pool-ah3-e2e"
	ahInstanceToken = "garm-instance-jwt-e2e"
	ahAPIKey        = "e2e-api-key-not-a-secret"
	ahRunnerVersion = "2.330.0"
	ahTTLSeconds    = 5400
)

// fakeRunnerRunSh is the fake actions/runner entrypoint. Like the real one it
// cannot start unregistered; registered, it acquires ONE job (ephemeral) from
// the server named in .runner, holds it until the fake GitHub completes it,
// and exits. The shebang is filled in with the resolved bash (see
// buildRunnerTarball).
const fakeRunnerRunSh = `#!@BASH@
set -euo pipefail
for f in .runner .credentials .credentials_rsaparams; do
  test -s "$f" || { echo "runner is not registered: $f missing" >&2; exit 3; }
done
server=$(sed -n 's/.*"serverUrl": *"\([^"]*\)".*/\1/p' .runner)
name=$(sed -n 's/.*"agentName": *"\([^"]*\)".*/\1/p' .runner)
echo "listening for jobs as $name"
curl -fsS --max-time 120 -X POST "$server/acquirejob?runner=$name&sandbox_job=${AH_SANDBOX_JOB_ID:-}" >/dev/null
echo "job completed"
`

type fakeGARM struct {
	srv      *httptest.Server
	mu       sync.Mutex
	statuses map[string][]string // runner name -> reported statuses
	acquired map[string]string   // runner name -> AH_SANDBOX_JOB_ID seen
	release  map[string]chan struct{}
	tarball  []byte
	sha      string
}

func newFakeGARM(t *testing.T) *fakeGARM {
	g := &fakeGARM{statuses: map[string][]string{}, acquired: map[string]string{}, release: map[string]chan struct{}{}}
	g.tarball = buildRunnerTarball(t)
	sum := sha256.Sum256(g.tarball)
	g.sha = hex.EncodeToString(sum[:])
	g.srv = httptest.NewServer(http.HandlerFunc(g.serve))
	t.Cleanup(func() {
		g.mu.Lock()
		for _, ch := range g.release {
			select {
			case <-ch:
			default:
				close(ch)
			}
		}
		g.mu.Unlock()
		g.srv.Close()
	})
	return g
}

func (g *fakeGARM) releaseCh(name string) chan struct{} {
	g.mu.Lock()
	defer g.mu.Unlock()
	ch, ok := g.release[name]
	if !ok {
		ch = make(chan struct{})
		g.release[name] = ch
	}
	return ch
}

// serve routes the fake GARM + fake GitHub endpoints. The runner name is a
// path segment of the per-instance metadata/callback URLs, and the JIT .runner
// file hands it back to run.sh.
func (g *fakeGARM) serve(w http.ResponseWriter, r *http.Request) {
	p := r.URL.Path
	if strings.HasPrefix(p, "/runner/") {
		_, _ = w.Write(g.tarball)
		return
	}
	if strings.HasPrefix(p, "/github/acquirejob") {
		name := r.URL.Query().Get("runner")
		g.mu.Lock()
		g.acquired[name] = r.URL.Query().Get("sandbox_job")
		g.mu.Unlock()
		select {
		case <-g.releaseCh(name):
		case <-time.After(110 * time.Second):
		}
		w.WriteHeader(http.StatusOK)
		return
	}
	if r.Header.Get("Authorization") != "Bearer "+ahInstanceToken {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	// /api/v1/metadata/<runner>/credentials/<file> — the provider hands the
	// script a per-runner metadata URL (GARM's real one is per-instance via
	// the token; a path segment keeps the fake simple and checkable).
	if rest, ok := strings.CutPrefix(p, "/api/v1/metadata/"); ok {
		name, file, _ := strings.Cut(rest, "/")
		switch file {
		case "credentials/runner":
			_ = json.NewEncoder(w).Encode(map[string]string{"agentName": name, "serverUrl": g.srv.URL + "/github"})
		case "credentials/credentials", "credentials/credentials_rsaparams":
			_, _ = io.WriteString(w, `{"scheme":"OAuth","data":{"clientId":"fake"}}`)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
		return
	}
	if rest, ok := strings.CutPrefix(p, "/api/v1/callbacks/"); ok {
		name, what, _ := strings.Cut(rest, "/")
		if strings.HasPrefix(what, "status") {
			var body struct {
				Status string `json:"status"`
			}
			raw, _ := io.ReadAll(r.Body)
			_ = json.Unmarshal(raw, &body)
			g.mu.Lock()
			g.statuses[name] = append(g.statuses[name], body.Status)
			g.mu.Unlock()
		}
		w.WriteHeader(http.StatusOK)
		return
	}
	w.WriteHeader(http.StatusNotFound)
}

func (g *fakeGARM) state(name string) (statuses []string, acquiredBy string, acquired bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	acquiredBy, acquired = g.acquired[name]
	return append([]string(nil), g.statuses[name]...), acquiredBy, acquired
}

func buildRunnerTarball(t *testing.T) []byte {
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	add := func(name string, mode int64, body string) {
		if err := tw.WriteHeader(&tar.Header{Name: name, Mode: mode, Size: int64(len(body)), Typeflag: tar.TypeReg}); err != nil {
			t.Fatal(err)
		}
		if _, err := io.WriteString(tw, body); err != nil {
			t.Fatal(err)
		}
	}
	// The real actions/runner scripts start with #!/bin/bash. Neither a Nix
	// build sandbox nor a NixOS host has /bin/bash, so the fake uses the
	// resolved bash. (A NixOS sandbox host running the REAL runner needs an
	// FHS /bin/bash inside the sandbox; see the AH7 notes in the module.)
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Fatal(err)
	}
	add("run.sh", 0o755, strings.Replace(fakeRunnerRunSh, "@BASH@", bash, 1))
	add("config.sh", 0o755, "#!"+bash+"\necho 'config.sh must not run in JIT mode' >&2\nexit 9\n")
	add("bin/Runner.Listener.deps.json", 0o644, `{"libraries":{"Runner.Listener/`+ahRunnerVersion+`":{}}}`)
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

type ahHarness struct {
	t       *testing.T
	binary  string
	env     []string
	cwd     string
	home    string
	ah      *ahmock.Server
	garm    *fakeGARM
	workDir string
}

type ahResult struct {
	stdout, stderr string
	code           int
}

// providerBinary is the packaged binary when the gate runs from Nix
// (GARM_PROVIDER_AGENTHARBOR_BIN), else one built from this source tree
// (which is what the negative controls mutate).
func providerBinary(t *testing.T) string {
	if bin := os.Getenv("GARM_PROVIDER_AGENTHARBOR_BIN"); bin != "" {
		return bin
	}
	binary := filepath.Join(t.TempDir(), "garm-provider-agentharbor")
	build := exec.Command("go", "build", "-o", binary, "../../cmd/garm-provider-agentharbor")
	build.Env = append(os.Environ(), "CGO_ENABLED=0")
	var stderr bytes.Buffer
	build.Stderr = &stderr
	if err := build.Run(); err != nil {
		t.Fatalf("building garm-provider-agentharbor: %v\n%s", err, stderr.String())
	}
	return binary
}

func newAHHarness(t *testing.T) *ahHarness {
	t.Helper()
	for _, tool := range []string{"bash", "curl", "tar", "gzip", "sha256sum", "sed", "mktemp"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Fatalf("the gate needs %s on PATH to execute the install script: %v", tool, err)
		}
	}
	tmp := t.TempDir()
	h := &ahHarness{t: t, binary: providerBinary(t), garm: newFakeGARM(t)}
	h.workDir = filepath.Join(tmp, "ah-work")
	h.cwd = filepath.Join(tmp, "provider-cwd")
	h.home = filepath.Join(tmp, "provider-home")
	for _, d := range []string{h.workDir, h.cwd, h.home} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	h.ah = &ahmock.Server{APIKey: ahAPIKey, Exec: true, WorkRoot: h.workDir}
	h.ah.Start()
	t.Cleanup(h.ah.Close)

	tokenFile := filepath.Join(tmp, "ah-api-key")
	if err := os.WriteFile(tokenFile, []byte(ahAPIKey+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := `endpoint = "` + h.ah.URL() + `"
auth_scheme = "apikey"
auth_token_file = "` + tokenFile + `"
substrate = "local-sandbox"
ttl_seconds = ` + itoa(ahTTLSeconds) + `
request_timeout_sec = 60

[sandbox]
allow_network = true
pids_max = 4096

[capabilities]
key_id = "` + h.ah.KeyID() + `"
public_key = "` + h.ah.PublicKey() + `"
`
	configFile := filepath.Join(tmp, "provider.toml")
	if err := os.WriteFile(configFile, []byte(cfg), 0o644); err != nil {
		t.Fatal(err)
	}
	h.env = []string{
		"GARM_INTERFACE_VERSION=v0.1.1",
		"GARM_PROVIDER_CONFIG_FILE=" + configFile,
		"GARM_CONTROLLER_ID=" + ahController,
		"PATH=" + os.Getenv("PATH"),
		"HOME=" + h.home,
		"TMPDIR=" + h.home,
	}
	return h
}

func itoa(n int) string {
	b, _ := json.Marshal(n)
	return string(b)
}

func (h *ahHarness) run(command string, stdin string, extra ...string) ahResult {
	h.t.Helper()
	cmd := exec.Command(h.binary)
	cmd.Dir = h.cwd
	cmd.Env = append(append(append([]string{}, h.env...), "GARM_COMMAND="+command), extra...)
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err := cmd.Run()
	code := 0
	if err != nil {
		ee, ok := err.(*exec.ExitError)
		if !ok {
			h.t.Fatalf("running provider: %v", err)
		}
		code = ee.ExitCode()
	}
	return ahResult{stdout.String(), stderr.String(), code}
}

func (h *ahHarness) bootstrapJSON(name string) string {
	tarURL := h.garm.srv.URL + "/runner/actions-runner-linux-x64-" + ahRunnerVersion + ".tar.gz"
	b, _ := json.Marshal(map[string]any{
		"name": name,
		"tools": []map[string]string{{
			"os": "linux", "architecture": "x64",
			"download_url":    tarURL,
			"filename":        "actions-runner-linux-x64-" + ahRunnerVersion + ".tar.gz",
			"sha256_checksum": h.garm.sha,
		}},
		"repo_url":           "https://github.com/example-org/repo",
		"callback-url":       h.garm.srv.URL + "/api/v1/callbacks/" + name,
		"metadata-url":       h.garm.srv.URL + "/api/v1/metadata/" + name,
		"instance-token":     ahInstanceToken,
		"os_type":            "linux",
		"arch":               "amd64",
		"flavor":             "default",
		"image":              "host",
		"labels":             []string{"self-hosted", "ah-sandbox", "ah-substrate-local-sandbox", "linux", "x64"},
		"pool_id":            ahPool,
		"jit_config_enabled": true,
	})
	return string(b)
}

func decodeInstance(t *testing.T, r ahResult) map[string]any {
	t.Helper()
	var out map[string]any
	if err := json.Unmarshal([]byte(r.stdout), &out); err != nil {
		t.Fatalf("bad ProviderInstance JSON %q (stderr %q): %v", r.stdout, r.stderr, err)
	}
	return out
}

func waitFor(t *testing.T, what string, timeout time.Duration, cond func() bool, diag func() string) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s\n%s", what, diag())
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func TestAgentharborGateEphemeralRunnerLifecycle(t *testing.T) {
	h := newAHHarness(t)

	// Introspection commands.
	if r := h.run("GetVersion", ""); r.code != 0 || !strings.HasPrefix(r.stdout, "v") {
		t.Fatalf("GetVersion: %+v", r)
	}
	if r := h.run("GetSupportedInterfaceVersions", ""); r.code != 0 || !strings.Contains(r.stdout, "v0.1.1") {
		t.Fatalf("GetSupportedInterfaceVersions: %+v", r)
	}
	for _, c := range []string{"GetConfigJSONSchema", "GetExtraSpecsJSONSchema"} {
		r := h.run(c, "")
		var schema map[string]any
		if r.code != 0 || json.Unmarshal([]byte(r.stdout), &schema) != nil {
			t.Fatalf("%s: %+v", c, r)
		}
	}

	// ---- CreateInstance: the runner-install payload goes to the launch.
	const name = "garm-ah-e2e-0001"
	r := h.run("CreateInstance", h.bootstrapJSON(name), "GARM_POOL_ID="+ahPool)
	if r.code != 0 {
		t.Fatalf("CreateInstance exit %d: %s", r.code, r.stderr)
	}
	inst := decodeInstance(t, r)
	providerID, _ := inst["provider_id"].(string)
	if !strings.HasPrefix(providerID, "sbj_") || inst["name"] != name || inst["status"] != "running" || inst["os_type"] != "linux" {
		t.Fatalf("CreateInstance returned %v", inst)
	}
	var launch map[string]any
	for _, req := range h.ah.Requests() {
		if req.Method == "POST" && req.Path == "/sandbox-jobs" {
			if req.Header.Get("Authorization") != "ApiKey "+ahAPIKey {
				t.Fatal("launch not authenticated with the configured API key")
			}
			_ = json.Unmarshal(req.Body, &launch)
		}
	}
	stdin, _ := launch["stdin"].(string)
	if !strings.Contains(stdin, "credentials/runner") || !strings.Contains(stdin, h.garm.sha) {
		t.Fatalf("launch stdin is not the JIT runner-install script:\n%s", stdin)
	}
	if launch["ttlSeconds"] != float64(ahTTLSeconds) {
		t.Fatalf("launch ttlSeconds = %v, want %d", launch["ttlSeconds"], ahTTLSeconds)
	}
	if lbl, _ := launch["labels"].(map[string]any); lbl["garm-pool-id"] != ahPool || lbl["garm-controller-id"] != ahController {
		t.Fatalf("launch owner labels = %v", launch["labels"])
	}
	var capsFetched bool
	for _, req := range h.ah.Requests() {
		capsFetched = capsFetched || req.Path == "/sandbox/capabilities"
	}
	if !capsFetched {
		t.Fatal("the pinned capability manifest was not checked before launch")
	}

	// ---- The runner REGISTERS and SERVES a job inside the sandbox job.
	waitFor(t, "the runner to acquire a job", 60*time.Second, func() bool {
		_, _, ok := h.garm.state(name)
		return ok
	}, func() string { return "job log:\n" + h.ah.JobLog(providerID) })
	statuses, sandboxJob, _ := h.garm.state(name)
	if sandboxJob != providerID {
		t.Fatalf("job acquired from sandbox job %q, want %q", sandboxJob, providerID)
	}
	if !contains(statuses, "idle") || contains(statuses, "failed") {
		t.Fatalf("runner statuses %v: want an idle registration and no failure\nlog:\n%s", statuses, h.ah.JobLog(providerID))
	}

	// Serving: GetInstance / ListInstances report it running.
	r = h.run("GetInstance", "", "GARM_INSTANCE_ID="+name, "GARM_POOL_ID="+ahPool)
	if r.code != 0 || decodeInstance(t, r)["status"] != "running" {
		t.Fatalf("GetInstance while serving: %+v", r)
	}
	r = h.run("ListInstances", "", "GARM_POOL_ID="+ahPool)
	var list []map[string]any
	if r.code != 0 || json.Unmarshal([]byte(r.stdout), &list) != nil || len(list) != 1 || list[0]["provider_id"] != providerID {
		t.Fatalf("ListInstances(pool): %+v", r)
	}
	r = h.run("ListInstances", "", "GARM_POOL_ID=another-pool")
	if r.code != 0 || strings.TrimSpace(r.stdout) != "[]" {
		t.Fatalf("ListInstances(other pool): %+v", r)
	}

	// ---- The job completes; the ephemeral runner exits; ah frees the job.
	close(h.garm.releaseCh(name))
	if !h.ah.WaitExited(providerID, 30*time.Second) {
		t.Fatal("the runner did not exit after its one job")
	}
	r = h.run("GetInstance", "", "GARM_INSTANCE_ID="+providerID, "GARM_POOL_ID="+ahPool)
	if got := decodeInstance(t, r)["status"]; r.code != 0 || got != "stopped" {
		t.Fatalf("finished runner reported %v (exit %d), want stopped", got, r.code)
	}
	if !strings.Contains(h.ah.JobLog(providerID), "job completed") {
		t.Fatalf("runner log lacks the served job:\n%s", h.ah.JobLog(providerID))
	}

	// ---- GARM reaps it: DeleteInstance, idempotent, 404 is success.
	for i, ref := range []string{name, providerID} {
		if r := h.run("DeleteInstance", "", "GARM_INSTANCE_ID="+ref, "GARM_POOL_ID="+ahPool); r.code != 0 {
			t.Fatalf("DeleteInstance #%d exit %d: %s", i+1, r.code, r.stderr)
		}
	}
	if r := h.run("GetInstance", "", "GARM_INSTANCE_ID="+providerID, "GARM_POOL_ID="+ahPool); r.code != 30 {
		t.Fatalf("GetInstance after delete: exit %d, want 30 (NotFound)", r.code)
	}
	h.ah.ExpireTombstones()
	if r := h.run("DeleteInstance", "", "GARM_INSTANCE_ID="+providerID); r.code != 0 {
		t.Fatalf("DeleteInstance after tombstone expiry (404) exit %d, want 0: %s", r.code, r.stderr)
	}
	if r := h.run("GetInstance", "", "GARM_INSTANCE_ID=never-existed"); r.code != 30 {
		t.Fatalf("GetInstance(unknown): exit %d, want 30", r.code)
	}

	// ---- A second runner is reaped MID-JOB (GARM scale-down / timeout).
	const busy = "garm-ah-e2e-0002"
	r = h.run("CreateInstance", h.bootstrapJSON(busy), "GARM_POOL_ID="+ahPool)
	if r.code != 0 {
		t.Fatalf("CreateInstance(busy) exit %d: %s", r.code, r.stderr)
	}
	busyID, _ := decodeInstance(t, r)["provider_id"].(string)
	waitFor(t, "the second runner to acquire a job", 60*time.Second, func() bool {
		_, _, ok := h.garm.state(busy)
		return ok
	}, func() string { return "job log:\n" + h.ah.JobLog(busyID) })
	if r := h.run("DeleteInstance", "", "GARM_INSTANCE_ID="+busyID); r.code != 0 {
		t.Fatalf("DeleteInstance(busy) exit %d: %s", r.code, r.stderr)
	}
	if !h.ah.WaitExited(busyID, 15*time.Second) {
		t.Fatal("the busy runner survived its DeleteInstance")
	}
	if r := h.run("ListInstances", "", "GARM_POOL_ID="+ahPool); strings.TrimSpace(r.stdout) != "[]" {
		t.Fatalf("instances left after reaping: %s", r.stdout)
	}

	// ---- No residue: no process, no workspace, no provider-side state.
	if pids := h.ah.LivePIDs(); len(pids) != 0 {
		t.Fatalf("runner processes survived: %v", pids)
	}
	entries, _ := os.ReadDir(h.workDir)
	for _, e := range entries {
		if e.IsDir() {
			t.Fatalf("job workspace left behind: %s", e.Name())
		}
	}
	for _, d := range []string{h.cwd, h.home} {
		if left, _ := os.ReadDir(d); len(left) != 0 {
			t.Fatalf("stateless provider wrote into %s: %v", d, left)
		}
	}
}

func contains(xs []string, want string) bool {
	for _, x := range xs {
		if x == want {
			return true
		}
	}
	return false
}
