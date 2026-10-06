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
// process per call exactly as GARM does.
//
// TestAgentharborGateEphemeralRunnerLifecycle follows one ephemeral runner
// through its whole life: launched as a sandbox job, REGISTERS (fetches its
// JIT credentials from GARM's metadata endpoint into RUNNER_ROOT, reports
// idle), SERVES a job, exits cleanly, is reported STOPPED, is REAPED by
// DeleteInstance, and leaves NO RESIDUE: no process, no workspace, no
// provider-side file. A second runner is reaped mid-job.
//
// TestAgentharborGateRealNixRunner runs the REAL nixpkgs `github-runner`
// (GARM_AH_E2E_GITHUB_RUNNER, set by the Nix check) through the same payload,
// in the Nix build sandbox: an environment with no /bin/bash and no FHS
// libraries, which is exactly what defeated the upstream actions/runner
// tarball on a NixOS ah host. The runner starts from the store, loads the JIT
// credentials the payload laid out (the fake GitHub verifies the RS256 client
// assertion it signs with the key from .credentials_rsaparams), is then told
// its registration was deleted (`invalid_client`), exits with its own
// TerminatedError, and the provider reports that crash to GARM as an ERROR
// instance with the reason, not as a clean stop.
//
// MOCK JUSTIFICATION (workspace rule: every mock is justified here). Each
// stand-in sits at the narrowest seam that keeps the gate hermetic:
//
//  1. ahmock (agent-harbor REST). The real `ah daemon serve` is not packaged
//     in this repo (agent-harbor is a separate, AGPL code base) and its
//     local-sandbox substrate needs user namespaces and a delegated cgroup
//     scope unavailable in a Nix build sandbox. The mock implements the
//     Direct-Sandbox-Launch.md contract, including the launcher's 0/1
//     exitCode with the command's own commandExitCode/commandSignal, and
//     EXECUTES the job for real: the provider's payload runs under `bash -s`
//     in a fresh per-job directory with the spec's environment, and the
//     process group + directory are freed on exit/destroy. Only the isolation
//     layer is absent; that is agent-harbor's own AH4 gate. The live
//     end-to-end run against a real `ah daemon serve` is Sovereign-CI-Fleet
//     AH3 step 4, outside this hermetic gate.
//  2. Fake GARM metadata/callback endpoints. GARM itself would need a GitHub
//     App and a forge to mint JIT configs; the provider only ever hands the
//     payload GARM's URLs + instance token, so an HTTP endpoint serving the
//     same paths (credentials/runner, credentials/credentials,
//     credentials/credentials_rsaparams, callbacks/status, system-info) and
//     checking the bearer token is the exact boundary the payload talks to.
//  3. Fake GitHub. The real runner needs github.com. For the real-runner
//     test the fake implements the first step of the runner's protocol (the
//     OAuth JWT-bearer token exchange, with real signature verification) and
//     then answers the way GitHub answers a deleted registration.
//  4. Fake Nix runner package (lifecycle test only). Serving a job with the
//     real runner needs GitHub's job-dispatch protocol, which a fake cannot
//     reproduce faithfully; the lifecycle test therefore uses a stand-in
//     package with the real package's layout (bin/Runner.Listener,
//     lib/github-runner/Runner.Listener.deps.json) whose listener enforces
//     the same contract the payload must meet for the real one (invoked as
//     `run --startuptype service`, RUNNER_ROOT holding the three JIT files,
//     HOME/working directory = the work dir with the credentials linked), then
//     long-polls one job and exits 0. The real runner is exercised by
//     TestAgentharborGateRealNixRunner and the live step-4 run.
//
// Everything else is real: the provider binary, the HTTP sockets, the Ed25519
// manifest signature, the payload script, bash, curl and coreutils.
package protocoltest

import (
	"bytes"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"math/big"
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
	ahRunnerVersion = "2.336.0"
	ahTTLSeconds    = 5400
)

// fakeListener is the stand-in package's bin/Runner.Listener (see MOCK
// JUSTIFICATION 4). It refuses to start unless the payload set it up the way
// the NixOS module sets up the real one, then acquires ONE job (ephemeral)
// from the server named in .runner, holds it until the fake GitHub completes
// it, and exits 0. The shebang is filled in with the resolved bash.
const fakeListener = `#!@BASH@
set -euo pipefail
[ "$*" = "run --startuptype service" ] || { echo "unexpected listener args: $*" >&2; exit 64; }
[ -n "${RUNNER_ROOT:-}" ] || { echo "RUNNER_ROOT is not set" >&2; exit 65; }
for f in .runner .credentials .credentials_rsaparams; do
  test -s "$RUNNER_ROOT/$f" || { echo "runner is not registered: $RUNNER_ROOT/$f missing" >&2; exit 3; }
  test -L "$PWD/$f" || { echo "$f is not linked into the work directory" >&2; exit 66; }
done
[ "$HOME" = "$PWD" ] || { echo "HOME ($HOME) is not the work directory ($PWD)" >&2; exit 67; }
[ "$(readlink "$PWD/_diag")" != "" ] || { echo "_diag is not linked" >&2; exit 68; }
server=$(sed -n 's/.*"serverUrl": *"\([^"]*\)".*/\1/p' "$RUNNER_ROOT/.runner")
name=$(sed -n 's/.*"agentName": *"\([^"]*\)".*/\1/p' "$RUNNER_ROOT/.runner")
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
	// Real-runner JIT material (TestAgentharborGateRealNixRunner).
	jitKey     *rsa.PrivateKey
	clientID   string
	oauthCalls []string // verdict of each OAuth token request
	other      []string // every other fake-GitHub request
}

func newFakeGARM(t *testing.T) *fakeGARM {
	g := &fakeGARM{statuses: map[string][]string{}, acquired: map[string]string{}, release: map[string]chan struct{}{}}
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
	if p == "/real-github/oauth/token" {
		g.serveOAuth(w, r)
		return
	}
	if strings.HasPrefix(p, "/real-github/") {
		g.mu.Lock()
		g.other = append(g.other, r.Method+" "+p)
		g.mu.Unlock()
		// Unauthenticated: the runner's OAuth credential treats a Bearer
		// challenge as its cue to exchange its JWT for a token.
		w.Header().Set("WWW-Authenticate", "Bearer")
		w.WriteHeader(http.StatusUnauthorized)
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
		if g.jitKey != nil {
			g.serveRealJIT(w, name, file)
			return
		}
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

// b64Int is the .NET RSAParameters encoding of a big integer.
func b64Int(n *big.Int) string { return base64.StdEncoding.EncodeToString(n.Bytes()) }

// enableRealJIT makes the metadata endpoint serve JIT material in the exact
// shape GitHub's generate-jitconfig emits, pointing the runner at this fake.
func (g *fakeGARM) enableRealJIT(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	key.Precompute()
	g.mu.Lock()
	g.jitKey = key
	g.clientID = "8d2b5a1e-0000-4000-8000-0000000000a3"
	g.mu.Unlock()
}

func (g *fakeGARM) serveRealJIT(w http.ResponseWriter, name, file string) {
	k := g.jitKey
	var doc any
	switch file {
	case "credentials/runner":
		doc = map[string]any{
			"agentId": 42, "agentName": name, "poolId": 1, "poolName": "Default",
			"ephemeral": true, "disableUpdate": true,
			"serverUrl":  g.srv.URL + "/real-github/runner-service",
			"gitHubUrl":  "https://github.com/example-org/repo",
			"workFolder": "_work",
		}
	case "credentials/credentials":
		doc = map[string]any{"scheme": "OAuth", "data": map[string]string{
			"clientId":                g.clientID,
			"authorizationUrl":        g.srv.URL + "/real-github/oauth/token",
			"requireFipsCryptography": "False",
		}}
	case "credentials/credentials_rsaparams":
		doc = map[string]string{
			"d": b64Int(k.D), "dp": b64Int(k.Precomputed.Dp), "dq": b64Int(k.Precomputed.Dq),
			"exponent": b64Int(big.NewInt(int64(k.E))), "inverseQ": b64Int(k.Precomputed.Qinv),
			"modulus": b64Int(k.N), "p": b64Int(k.Primes[0]), "q": b64Int(k.Primes[1]),
		}
	default:
		w.WriteHeader(http.StatusNotFound)
		return
	}
	_ = json.NewEncoder(w).Encode(doc)
}

// serveOAuth verifies the runner's RS256 JWT client assertion against the JIT
// key (so it proves the runner loaded .credentials and .credentials_rsaparams
// from where the payload put them) and then answers as GitHub does for a
// deleted registration: invalid_client, which the runner treats as fatal.
func (g *fakeGARM) serveOAuth(w http.ResponseWriter, r *http.Request) {
	verdict := "unverified"
	if err := r.ParseForm(); err == nil {
		verdict = g.verifyAssertion(r.PostForm.Get("client_assertion"), r.PostForm.Get("client_assertion_type"))
	}
	g.mu.Lock()
	g.oauthCalls = append(g.oauthCalls, verdict)
	g.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusBadRequest)
	_, _ = io.WriteString(w, `{"error":"invalid_client","error_description":"the runner registration was deleted (fake GitHub)"}`)
}

func (g *fakeGARM) verifyAssertion(assertion, assertionType string) string {
	if assertionType != "urn:ietf:params:oauth:client-assertion-type:jwt-bearer" {
		return "bad assertion type " + assertionType
	}
	parts := strings.Split(assertion, ".")
	if len(parts) != 3 {
		return "not a JWT"
	}
	dec := func(s string) []byte { b, _ := base64.RawURLEncoding.DecodeString(s); return b }
	var hdr struct {
		Alg string `json:"alg"`
	}
	var claims struct {
		Iss string `json:"iss"`
		Sub string `json:"sub"`
	}
	if json.Unmarshal(dec(parts[0]), &hdr) != nil || json.Unmarshal(dec(parts[1]), &claims) != nil {
		return "undecodable JWT"
	}
	if hdr.Alg != "RS256" {
		return "alg " + hdr.Alg
	}
	sum := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if err := rsa.VerifyPKCS1v15(&g.jitKey.PublicKey, crypto.SHA256, sum[:], dec(parts[2])); err != nil {
		return "signature does not verify against the JIT key"
	}
	if claims.Sub != g.clientID || claims.Iss != g.clientID {
		return "claims name " + claims.Iss + "/" + claims.Sub
	}
	return "verified"
}

func (g *fakeGARM) realState() (oauth, other []string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	return append([]string(nil), g.oauthCalls...), append([]string(nil), g.other...)
}

// fakeRunnerPackage lays out the stand-in Nix runner package (MOCK
// JUSTIFICATION 4) and returns its bin/Runner.Listener.
func fakeRunnerPackage(t *testing.T, version string) string {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Fatal(err)
	}
	pkg := filepath.Join(t.TempDir(), "fake-github-runner-"+version)
	for _, d := range []string{"bin", "lib/github-runner"} {
		if err := os.MkdirAll(filepath.Join(pkg, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	listener := filepath.Join(pkg, "bin", "Runner.Listener")
	if err := os.WriteFile(listener, []byte(strings.Replace(fakeListener, "@BASH@", bash, 1)), 0o755); err != nil {
		t.Fatal(err)
	}
	deps := `{"libraries":{"Runner.Listener/` + version + `.0":{"type":"project"}}}`
	if err := os.WriteFile(filepath.Join(pkg, "lib/github-runner/Runner.Listener.deps.json"), []byte(deps), 0o644); err != nil {
		t.Fatal(err)
	}
	return listener
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

// newAHHarness starts the mocks and writes a provider config whose [runner]
// is the given Nix runner package (listener path + version).
func newAHHarness(t *testing.T, listener, version string) *ahHarness {
	t.Helper()
	for _, tool := range []string{"bash", "curl", "sed", "mkdir", "ln", "chmod", "head"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Fatalf("the gate needs %s on PATH to execute the payload: %v", tool, err)
		}
	}
	// The job PATH, as services.garm renders it from the module's `path`.
	var runnerPath []string
	for _, d := range filepath.SplitList(os.Getenv("PATH")) {
		if filepath.IsAbs(d) {
			runnerPath = append(runnerPath, d)
		}
	}
	pathTOML, _ := json.Marshal(runnerPath)
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

[runner]
listener = "` + listener + `"
version = "` + version + `"
path = ` + string(pathTOML) + `
env = { DOTNET_CLI_TELEMETRY_OPTOUT = "1" }
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

// bootstrapJSON is GARM's BootstrapInstance; GARM offers the newest runner
// (offered), which the provider's version guard judges the Nix runner against.
func (h *ahHarness) bootstrapJSON(name, offered string) string {
	file := "actions-runner-linux-x64-" + offered + ".tar.gz"
	b, _ := json.Marshal(map[string]any{
		"name": name,
		"tools": []map[string]string{{
			"os": "linux", "architecture": "x64",
			"download_url": "https://github.com/actions/runner/releases/download/v" + offered + "/" + file,
			"filename":     file,
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
	h := newAHHarness(t, fakeRunnerPackage(t, ahRunnerVersion), ahRunnerVersion)

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
	r := h.run("CreateInstance", h.bootstrapJSON(name, "2.337.0"), "GARM_POOL_ID="+ahPool)
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
	if !strings.Contains(stdin, "credentials/runner") || !strings.Contains(stdin, "fake-github-runner-"+ahRunnerVersion+"/bin/Runner.Listener") {
		t.Fatalf("launch stdin is not the JIT runner payload:\n%s", stdin)
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
	r = h.run("CreateInstance", h.bootstrapJSON(busy, "2.337.0"), "GARM_POOL_ID="+ahPool)
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

	// ---- A stale Nix runner is refused before anything launches (the
	// persistent runners' pin-check rule: two minors behind what GitHub
	// offers).
	before := len(h.ah.Requests())
	r = h.run("CreateInstance", h.bootstrapJSON("garm-ah-e2e-stale", "2.338.0"), "GARM_POOL_ID="+ahPool)
	if r.code == 0 || !strings.Contains(r.stdout+r.stderr, "behind") {
		t.Fatalf("CreateInstance with a stale Nix runner: exit %d, %s %s", r.code, r.stdout, r.stderr)
	}
	for _, req := range h.ah.Requests()[before:] {
		if req.Method == "POST" && req.Path == "/sandbox-jobs" {
			t.Fatal("a stale Nix runner was launched")
		}
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

func TestAgentharborGateRealNixRunner(t *testing.T) {
	pkg := os.Getenv("GARM_AH_E2E_GITHUB_RUNNER")
	version := os.Getenv("GARM_AH_E2E_GITHUB_RUNNER_VERSION")
	if pkg == "" || version == "" {
		t.Skip("GARM_AH_E2E_GITHUB_RUNNER(_VERSION) unset: the Nix check sets them (and asserts this test ran)")
	}
	h := newAHHarness(t, filepath.Join(pkg, "bin", "Runner.Listener"), version)
	h.garm.enableRealJIT(t)

	const name = "garm-ah-e2e-real"
	r := h.run("CreateInstance", h.bootstrapJSON(name, version), "GARM_POOL_ID="+ahPool)
	if r.code != 0 {
		t.Fatalf("CreateInstance exit %d: %s", r.code, r.stderr)
	}
	providerID, _ := decodeInstance(t, r)["provider_id"].(string)
	if !h.ah.WaitExited(providerID, 180*time.Second) {
		t.Fatalf("the real runner never exited\nlog:\n%s", h.ah.JobLog(providerID))
	}
	log := h.ah.JobLog(providerID)
	statuses, _, _ := h.garm.state(name)
	oauth, other := h.garm.realState()
	diag := func() string {
		return "statuses: " + strings.Join(statuses, ",") + "\noauth: " + strings.Join(oauth, ",") +
			"\nother requests: " + strings.Join(other, ",") + "\njob log:\n" + log
	}
	// The payload reached the exec (it reported idle, not failed) ...
	if !contains(statuses, "idle") || contains(statuses, "failed") {
		t.Fatalf("payload did not hand over to the runner cleanly\n%s", diag())
	}
	// ... and the real runner started from the store and loaded the JIT
	// credentials from RUNNER_ROOT: it signed a JWT with the JIT key.
	if !contains(oauth, "verified") {
		t.Fatalf("the real runner never presented a verifiable JWT client assertion\n%s", diag())
	}
	// It exited with its own TerminatedError, and GARM is told that it
	// CRASHED (error + reason), which a clean ephemeral exit never is.
	r = h.run("GetInstance", "", "GARM_INSTANCE_ID="+providerID, "GARM_POOL_ID="+ahPool)
	inst := decodeInstance(t, r)
	if r.code != 0 || inst["status"] != "error" {
		t.Fatalf("crashed runner reported %v (exit %d), want error\n%s", inst["status"], r.code, diag())
	}
	// ProviderFault is []byte, so it travels base64-encoded.
	rawFault, _ := inst["provider_fault"].(string)
	faultBytes, _ := base64.StdEncoding.DecodeString(rawFault)
	fault := string(faultBytes)
	if !strings.Contains(fault, "code 1 (TerminatedError") {
		t.Fatalf("crash reason %q does not name the runner's exit\n%s", fault, diag())
	}
	r = h.run("ListInstances", "", "GARM_POOL_ID="+ahPool)
	var list []map[string]any
	if r.code != 0 || json.Unmarshal([]byte(r.stdout), &list) != nil || len(list) != 1 || list[0]["status"] != "error" {
		t.Fatalf("ListInstances does not report the crash: %+v", r)
	}

	// Reaped, no residue.
	if r := h.run("DeleteInstance", "", "GARM_INSTANCE_ID="+providerID); r.code != 0 {
		t.Fatalf("DeleteInstance exit %d: %s", r.code, r.stderr)
	}
	if pids := h.ah.LivePIDs(); len(pids) != 0 {
		t.Fatalf("runner processes survived: %v", pids)
	}
	entries, _ := os.ReadDir(h.workDir)
	for _, e := range entries {
		if e.IsDir() {
			t.Fatalf("job workspace left behind: %s", e.Name())
		}
	}
}
