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

// Behavioural tests of garm-provider-agentharbor against the REST contract
// (part of the AH3 gate t_garm_provider_agentharbor).
//
// MOCK JUSTIFICATION (workspace rule: every mock is justified here).
// These tests use ONE mock: ahmock, an in-process HTTP emulation of
// agent-harbor's direct sandbox-launch endpoints. It stands in for the real
// Rust `ah daemon serve` because (a) that server is not packaged in this repo
// and (b) its local-sandbox substrate needs user namespaces and a delegated
// cgroup scope that a Nix build sandbox does not provide. The mock is the
// narrowest possible seam: the provider under test is the unmodified
// production code, it talks to the mock over a real loopback HTTP socket, and
// the manifest signatures are real Ed25519. The mock's lifecycle, idempotency,
// tombstone and error-model behaviour follows Direct-Sandbox-Launch.md
// section by section, and fault injection is used only for answers the real
// server gives under conditions a test cannot provoke cheaply (503 admission
// shed, a 5xx during DELETE, a non-Problem+JSON proxy error). Real process
// execution of the runner-install script is covered by the protocol-level
// gate in internal/protocoltest, which drives the built binary.
package agentharbor

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	garmErrors "github.com/cloudbase/garm-provider-common/errors"
	commonExecution "github.com/cloudbase/garm-provider-common/execution/common"
	commonParams "github.com/cloudbase/garm-provider-common/params"

	"github.com/metacraft-labs/garm-provider-vmharness/internal/agentharbor/ahmock"
)

const (
	testController = "ctrl-ah3"
	testPool       = "pool-ah3"
	testAPIKey     = "test-api-key-not-a-secret"
)

func startMock(t *testing.T, mutate func(*ahmock.Server)) *ahmock.Server {
	t.Helper()
	m := &ahmock.Server{APIKey: testAPIKey}
	if mutate != nil {
		mutate(m)
	}
	m.Start()
	t.Cleanup(m.Close)
	return m
}

func newProvider(t *testing.T, m *ahmock.Server, extraTOML string) *Provider {
	t.Helper()
	t.Setenv("GARM_CONTROLLER_ID", testController)
	dir := t.TempDir()
	tokenFile := filepath.Join(dir, "token")
	if err := os.WriteFile(tokenFile, []byte(testAPIKey+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := ParseBytes([]byte(`endpoint = "` + m.URL() + `"
auth_token_file = "` + tokenFile + `"
ttl_seconds = 3600
` + extraTOML))
	if err != nil {
		t.Fatalf("config: %v", err)
	}
	p, err := NewWithConfig(cfg)
	if err != nil {
		t.Fatalf("provider: %v", err)
	}
	return p
}

func bootstrap(name string) commonParams.BootstrapInstance {
	return commonParams.BootstrapInstance{
		Name: name,
		Tools: []commonParams.RunnerApplicationDownload{{
			OS:           ptr("linux"),
			Architecture: ptr("x64"),
			DownloadURL:  ptr("https://github.com/actions/runner/releases/download/v2.330.0/actions-runner-linux-x64-2.330.0.tar.gz"),
			Filename:     ptr("actions-runner-linux-x64-2.330.0.tar.gz"),
		}},
		RepoURL:          "https://github.com/example-org/repo",
		CallbackURL:      "https://garm.example.test/api/v1/callbacks",
		MetadataURL:      "https://garm.example.test/api/v1/metadata",
		InstanceToken:    "instance-jwt",
		OSType:           commonParams.Linux,
		OSArch:           commonParams.Amd64,
		Image:            "ubuntu-24.04",
		Flavor:           "default",
		Labels:           []string{"self-hosted", "ah-sandbox", "ah-substrate-local-sandbox"},
		PoolID:           testPool,
		JitConfigEnabled: true,
	}
}

func ptr[T any](v T) *T { return &v }

func lastCreate(t *testing.T, m *ahmock.Server) (ahmock.Recorded, map[string]any) {
	t.Helper()
	var rec *ahmock.Recorded
	for _, r := range m.Requests() {
		if r.Method == "POST" && r.Path == "/sandbox-jobs" {
			r := r
			rec = &r
		}
	}
	if rec == nil {
		t.Fatal("no launch request recorded")
	}
	var body map[string]any
	if err := json.Unmarshal(rec.Body, &body); err != nil {
		t.Fatal(err)
	}
	return *rec, body
}

func TestCreateHandsRunnerInstallScriptToLaunch(t *testing.T) {
	m := startMock(t, nil)
	p := newProvider(t, m, "")
	inst, err := p.CreateInstance(context.Background(), bootstrap("runner-a"))
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if !strings.HasPrefix(inst.ProviderID, "sbj_") || inst.Name != "runner-a" || inst.Status != commonParams.InstanceRunning {
		t.Fatalf("unexpected instance %+v", inst)
	}
	rec, body := lastCreate(t, m)
	if got := rec.Header.Get("Authorization"); got != "ApiKey "+testAPIKey {
		t.Fatalf("Authorization header = %q", got)
	}
	if got := rec.Header.Get("Idempotency-Key"); got != "garm-"+testController+"-runner-a" {
		t.Fatalf("Idempotency-Key = %q", got)
	}
	if body["substrate"] != "local-sandbox" || body["name"] != "runner-a" {
		t.Fatalf("launch body: %v", body)
	}
	if cmd, _ := json.Marshal(body["command"]); string(cmd) != `["bash","-s"]` {
		t.Fatalf("command = %s", cmd)
	}
	stdin, _ := body["stdin"].(string)
	for _, want := range []string{
		"METADATA_URL='https://garm.example.test/api/v1/metadata'",
		`get_metadata_file "credentials/runner"`,
		"actions-runner-linux-x64-2.330.0.tar.gz",
		`RUN_HOME="${PWD}/actions-runner"`,
		"exec ./run.sh",
	} {
		if !strings.Contains(stdin, want) {
			t.Errorf("install script lacks %q", want)
		}
	}
	// No privileged step. (The shared cached-runner version guard keeps a
	// `|| sudo -n ...` fallback after a failed unprivileged rm/tar; in a fresh
	// per-job workspace that branch cannot fire, so it is not forbidden here.)
	for _, forbidden := range []string{"useradd", "groupadd", "exec sudo", "sudo -u", "/etc/sudoers.d", "installdependencies.sh"} {
		if strings.Contains(stdin, forbidden) {
			t.Errorf("rootless sandbox script contains %q", forbidden)
		}
	}
	// The instance token rides only in stdin — never in env, labels or argv,
	// which the server may log or echo back.
	for _, field := range []string{"env", "labels", "command"} {
		raw, _ := json.Marshal(body[field])
		if strings.Contains(string(raw), "instance-jwt") {
			t.Errorf("instance token leaked into %s", field)
		}
	}
	labels, _ := body["labels"].(map[string]any)
	if labels[LabelController] != testController || labels[LabelPool] != testPool {
		t.Fatalf("owner labels = %v", labels)
	}
	if _, hasImage := body["image"]; hasImage {
		t.Fatal("image must not be sent for local-sandbox (the server answers 422)")
	}
}

func TestCreatePassesTTLAndRequiresCleanupToken(t *testing.T) {
	m := startMock(t, nil)
	p := newProvider(t, m, "idle_timeout_seconds = 900\n")
	b := bootstrap("runner-ttl")
	inst, err := p.CreateInstance(context.Background(), b)
	if err != nil {
		t.Fatal(err)
	}
	_, body := lastCreate(t, m)
	if body["ttlSeconds"] != float64(3600) || body["idleTimeoutSeconds"] != float64(900) {
		t.Fatalf("ttl/idle not passed: ttl=%v idle=%v", body["ttlSeconds"], body["idleTimeoutSeconds"])
	}
	job, err := p.client.GetJob(context.Background(), inst.ProviderID)
	if err != nil {
		t.Fatal(err)
	}
	if job.CleanupToken == "" || job.ExpiresAt.Sub(job.CreatedAt) != time.Hour {
		t.Fatalf("job lacks cleanupToken or the passed TTL: token=%q ttl=%s", job.CleanupToken, job.ExpiresAt.Sub(job.CreatedAt))
	}

	// A pool extra spec overrides the TTL.
	b2 := bootstrap("runner-ttl2")
	b2.ExtraSpecs = json.RawMessage(`{"ttl_seconds": 120}`)
	if _, err := p.CreateInstance(context.Background(), b2); err != nil {
		t.Fatal(err)
	}
	_, body = lastCreate(t, m)
	if body["ttlSeconds"] != float64(120) {
		t.Fatalf("extra_specs ttl not applied: %v", body["ttlSeconds"])
	}

	// The server's TTL sweeper destroys the job; GARM then sees it gone.
	m.SweepExpired(time.Now().Add(2 * time.Hour))
	if _, err := p.GetInstance(context.Background(), inst.ProviderID); !errors.Is(err, garmErrors.ErrNotFound) {
		t.Fatalf("after TTL expiry want NotFound, got %v", err)
	}
}

func TestCreateRefusesJobWithoutCleanupToken(t *testing.T) {
	m := startMock(t, func(s *ahmock.Server) { s.OmitCleanupToken = true })
	p := newProvider(t, m, "")
	inst, err := p.CreateInstance(context.Background(), bootstrap("runner-notoken"))
	if err == nil || inst.Status != commonParams.InstanceError {
		t.Fatalf("want refusal, got %+v, %v", inst, err)
	}
	jobs, _ := p.client.ListJobs(context.Background(), nil)
	if len(jobs) != 0 {
		t.Fatalf("the unreapable job was not torn down: %d live", len(jobs))
	}
}

func TestGetAndListMapJobStates(t *testing.T) {
	cases := map[string]commonParams.InstanceStatus{
		StatePending:    commonParams.InstancePendingCreate,
		StateStarting:   commonParams.InstanceCreating,
		StateRunning:    commonParams.InstanceRunning,
		StateExited:     commonParams.InstanceStopped,
		StateFailed:     commonParams.InstanceError,
		StateDestroying: commonParams.InstanceDeleting,
		StateDestroyed:  commonParams.InstanceDeleted,
		"bogus":         commonParams.InstanceStatusUnknown,
	}
	for state, want := range cases {
		if got := GARMStatus(state); got != want {
			t.Errorf("GARMStatus(%q) = %q, want %q", state, got, want)
		}
	}

	m := startMock(t, nil)
	p := newProvider(t, m, "")
	ctx := context.Background()
	a, err := p.CreateInstance(ctx, bootstrap("runner-get"))
	if err != nil {
		t.Fatal(err)
	}
	for _, ref := range []string{"runner-get", a.ProviderID} {
		got, err := p.GetInstance(ctx, ref)
		if err != nil || got.ProviderID != a.ProviderID || got.Status != commonParams.InstanceRunning ||
			got.OSType != commonParams.Linux || got.OSArch != commonParams.Amd64 {
			t.Fatalf("GetInstance(%s) = %+v, %v", ref, got, err)
		}
	}
	other := bootstrap("runner-other-pool")
	other.PoolID = "pool-other"
	if _, err := p.CreateInstance(ctx, other); err != nil {
		t.Fatal(err)
	}
	list, err := p.ListInstances(ctx, testPool)
	if err != nil || len(list) != 1 || list[0].Name != "runner-get" {
		t.Fatalf("ListInstances(pool) = %+v, %v", list, err)
	}
	// A job of ANOTHER controller in the same pool is not ours to list.
	t.Setenv("GARM_CONTROLLER_ID", "ctrl-someone-else")
	list, err = p.ListInstances(ctx, testPool)
	if err != nil || len(list) != 0 {
		t.Fatalf("foreign controller sees %d instances", len(list))
	}
	t.Setenv("GARM_CONTROLLER_ID", testController)

	if err := p.DeleteInstance(ctx, "runner-get"); err != nil {
		t.Fatal(err)
	}
	if _, err := p.GetInstance(ctx, a.ProviderID); !errors.Is(err, garmErrors.ErrNotFound) {
		t.Fatalf("tombstone must read as NotFound, got %v", err)
	}
	list, _ = p.ListInstances(ctx, testPool)
	if len(list) != 0 {
		t.Fatalf("tombstone listed: %+v", list)
	}
}

func TestDeleteIsIdempotentAndNotFoundIsSuccess(t *testing.T) {
	m := startMock(t, nil)
	p := newProvider(t, m, "")
	ctx := context.Background()
	inst, err := p.CreateInstance(ctx, bootstrap("runner-del"))
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ { // live, then tombstone
		if err := p.DeleteInstance(ctx, inst.ProviderID); err != nil {
			t.Fatalf("delete #%d: %v", i+1, err)
		}
	}
	m.ExpireTombstones()
	if err := p.DeleteInstance(ctx, inst.ProviderID); err != nil {
		t.Fatalf("delete after tombstone expiry (404) must succeed: %v", err)
	}
	if err := p.DeleteInstance(ctx, "never-existed"); err != nil {
		t.Fatalf("delete of an unknown job must succeed: %v", err)
	}
}

func TestDeleteFallsBackToCleanupToken(t *testing.T) {
	m := startMock(t, nil)
	p := newProvider(t, m, "")
	ctx := context.Background()
	inst, err := p.CreateInstance(ctx, bootstrap("runner-fallback"))
	if err != nil {
		t.Fatal(err)
	}
	m.Inject(ahmock.Fault{Method: "DELETE", Prefix: "/sandbox-jobs/", Status: 500, Code: "internal", Detail: "ledger write failed"})
	if err := p.DeleteInstance(ctx, inst.ProviderID); err != nil {
		t.Fatalf("delete with a failing DELETE must fall back to the cleanup token: %v", err)
	}
	var redeemed bool
	for _, r := range m.Requests() {
		if r.Method == "POST" && r.Path == "/sandbox-jobs/cleanup" {
			redeemed = true
		}
	}
	job, gerr := p.client.GetJob(ctx, inst.ProviderID)
	if !redeemed || gerr != nil || job.State != StateDestroyed {
		t.Fatalf("cleanup token not redeemed (redeemed=%v state=%q err=%v)", redeemed, job.State, gerr)
	}
}

func TestRetriedCreateNeverDoubleLaunches(t *testing.T) {
	m := startMock(t, nil)
	p := newProvider(t, m, "")
	ctx := context.Background()
	first, err := p.CreateInstance(ctx, bootstrap("runner-retry"))
	if err != nil {
		t.Fatal(err)
	}
	// GARM retries the same (controller, name): the deterministic
	// Idempotency-Key makes the server replay the original job.
	second, err := p.CreateInstance(ctx, bootstrap("runner-retry"))
	if err != nil || second.ProviderID != first.ProviderID {
		t.Fatalf("idempotent replay: %+v, %v", second, err)
	}
	// Without the idempotency record (another key) the server's own guard is
	// the 409 name-conflict naming the live job.
	req, err := p.buildCreateRequest(bootstrap("runner-retry"), testController)
	if err != nil {
		t.Fatal(err)
	}
	_, err = p.client.CreateJob(ctx, req, "another-key")
	var apiErr *APIError
	if !errors.As(err, &apiErr) || apiErr.Code != CodeNameConflict || apiErr.ExistingJobID != first.ProviderID {
		t.Fatalf("want name-conflict naming %s, got %v", first.ProviderID, err)
	}
	if m.Launches() != 1 {
		t.Fatalf("launches = %d, want 1", m.Launches())
	}
}

func TestNameConflictAdoptsOwnJobAndRejectsForeign(t *testing.T) {
	m := startMock(t, nil)
	p := newProvider(t, m, "")
	ctx := context.Background()
	orig, err := p.CreateInstance(ctx, bootstrap("runner-409"))
	if err != nil {
		t.Fatal(err)
	}
	// The idempotency record can be gone (server restart, 24 h window) while
	// the job lives on; the server then answers 409 name-conflict.
	m.Inject(ahmock.Fault{Method: "POST", Prefix: "/sandbox-jobs", Status: 409, Code: CodeNameConflict})
	// The injected 409 lacks existingJobId: the provider falls back to the name.
	adopted, err := p.CreateInstance(ctx, bootstrap("runner-409"))
	if err != nil || adopted.ProviderID != orig.ProviderID {
		t.Fatalf("own job not adopted: %+v, %v", adopted, err)
	}
	// A foreign controller hitting the same name gets Duplicate (exit 31).
	t.Setenv("GARM_CONTROLLER_ID", "ctrl-foreign")
	m.Inject(ahmock.Fault{Method: "POST", Prefix: "/sandbox-jobs", Status: 409, Code: CodeNameConflict})
	_, err = p.CreateInstance(ctx, bootstrap("runner-409"))
	if !errors.Is(err, garmErrors.ErrDuplicateEntity) || commonExecution.ResolveErrorToExitCode(err) != commonExecution.ExitCodeDuplicate {
		t.Fatalf("foreign name conflict: want Duplicate, got %v", err)
	}
	if m.Launches() != 1 {
		t.Fatalf("launches = %d, want 1", m.Launches())
	}
}

func TestErrorMappingFollowsSpecErrorModel(t *testing.T) {
	type check struct {
		name     string
		fault    ahmock.Fault
		wantKind error // nil => plain provider error
		wantExit int
		wantText string
	}
	checks := []check{
		{"400 invalid-request", ahmock.Fault{Method: "POST", Status: 400, Code: CodeInvalidRequest, Detail: "bad label"}, garmErrors.ErrBadRequest, 1, "invalid-request"},
		{"403 forbidden", ahmock.Fault{Method: "POST", Status: 403, Code: CodeForbidden}, garmErrors.ErrUnauthorized, 1, "forbidden"},
		{"404 not-found", ahmock.Fault{Method: "POST", Status: 404, Code: CodeNotFound}, garmErrors.ErrNotFound, commonExecution.ExitCodeNotFound, "not-found"},
		{"422 invalid-sandbox-option", ahmock.Fault{Method: "POST", Status: 422, Code: CodeInvalidSandboxOption, Detail: "ttl too large"}, garmErrors.ErrBadRequest, 1, "invalid-sandbox-option"},
		{"501 substrate-unavailable", ahmock.Fault{Method: "POST", Status: 501, Code: CodeSubstrateUnavailable}, garmErrors.ErrBadRequest, 1, "substrate-unavailable"},
		{"503 admission-shed", ahmock.Fault{Method: "POST", Status: 503, Code: CodeAdmissionShed}, nil, 1, "transient"},
		{"503 capacity-exhausted", ahmock.Fault{Method: "POST", Status: 503, Code: CodeCapacityExhausted}, nil, 1, "capacity-exhausted"},
		{"502 proxy page", ahmock.Fault{Method: "POST", Status: 502}, nil, 1, "HTTP 502"},
	}
	for _, c := range checks {
		t.Run(c.name, func(t *testing.T) {
			m := startMock(t, nil)
			p := newProvider(t, m, "")
			m.Inject(c.fault)
			inst, err := p.CreateInstance(context.Background(), bootstrap("runner-err"))
			if err == nil {
				t.Fatal("want an error")
			}
			if inst.Status != commonParams.InstanceError || len(inst.ProviderFault) == 0 {
				t.Fatalf("failed create must report status=error with a fault: %+v", inst)
			}
			if c.wantKind != nil && !errors.Is(err, c.wantKind) {
				t.Fatalf("kind: want %T, got %v", c.wantKind, err)
			}
			if got := commonExecution.ResolveErrorToExitCode(err); got != c.wantExit {
				t.Fatalf("exit code %d, want %d (%v)", got, c.wantExit, err)
			}
			if !strings.Contains(err.Error(), c.wantText) {
				t.Fatalf("error %q lacks %q", err, c.wantText)
			}
		})
	}

	// Real server-side validations, not injected: a TTL above the host's max
	// (422) and an unavailable substrate (501, answered before any ledger
	// entry — nothing launched).
	m := startMock(t, func(s *ahmock.Server) { s.MaxTTLSeconds = 600 })
	p := newProvider(t, m, "")
	if _, err := p.CreateInstance(context.Background(), bootstrap("runner-bigttl")); !errors.Is(err, garmErrors.ErrBadRequest) ||
		!strings.Contains(err.Error(), CodeInvalidSandboxOption) {
		t.Fatalf("ttl over max: %v", err)
	}
	pvm := newProvider(t, m, "substrate = \"vm\"\n")
	b := bootstrap("runner-vm")
	if _, err := pvm.CreateInstance(context.Background(), b); !errors.Is(err, garmErrors.ErrBadRequest) ||
		!strings.Contains(err.Error(), CodeSubstrateUnavailable) {
		t.Fatalf("unavailable substrate: %v", err)
	}
	if m.Launches() != 0 {
		t.Fatalf("rejected launches must not reach the substrate: %d", m.Launches())
	}
	// A wrong credential is an auth failure.
	m.APIKey = "rotated"
	if _, err := p.GetInstance(context.Background(), "x"); !errors.Is(err, garmErrors.ErrUnauthorized) {
		t.Fatalf("bad credential: %v", err)
	}
}

func TestFailedLaunchReportsErrorInstance(t *testing.T) {
	m := startMock(t, func(s *ahmock.Server) { s.FailLaunch = "spawn: no such file or directory" })
	p := newProvider(t, m, "")
	inst, err := p.CreateInstance(context.Background(), bootstrap("runner-fail"))
	if err == nil || inst.Status != commonParams.InstanceError || !strings.HasPrefix(inst.ProviderID, "sbj_") ||
		!strings.Contains(string(inst.ProviderFault), "no such file") {
		t.Fatalf("failed launch: %+v, %v", inst, err)
	}
	// The failed job is a real ledger entry GARM can delete.
	if err := p.DeleteInstance(context.Background(), inst.ProviderID); err != nil {
		t.Fatal(err)
	}
}

func TestCapabilityManifestGatesLaunch(t *testing.T) {
	ctx := context.Background()
	pinned := func(m *ahmock.Server) string {
		return "[capabilities]\nkey_id = \"" + m.KeyID() + "\"\npublic_key = \"" + m.PublicKey() + "\"\n"
	}

	m := startMock(t, nil)
	p := newProvider(t, m, pinned(m))
	if _, err := p.CreateInstance(ctx, bootstrap("runner-cap-ok")); err != nil {
		t.Fatalf("verified manifest must allow launch: %v", err)
	}

	reject := func(name string, m *ahmock.Server, cfg string, b commonParams.BootstrapInstance, want string) {
		t.Helper()
		p := newProvider(t, m, cfg)
		before := m.Launches()
		_, err := p.CreateInstance(ctx, b)
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Fatalf("%s: want rejection containing %q, got %v", name, want, err)
		}
		if m.Launches() != before {
			t.Fatalf("%s: a rejected host was launched on", name)
		}
	}

	other := startMock(t, nil) // a different signing key
	reject("wrong key", m, pinned(other), bootstrap("r1"), "is pinned")

	tampered := startMock(t, func(s *ahmock.Server) { s.TamperManifest = true })
	reject("tampered payload", tampered, pinned(tampered), bootstrap("r2"), "does not verify")

	expired := startMock(t, func(s *ahmock.Server) { s.ManifestTTL = -time.Minute })
	reject("expired", expired, pinned(expired), bootstrap("r3"), "expired")

	noLocal := startMock(t, func(s *ahmock.Server) {
		s.Substrates = []ahmock.Substrate{{Name: "local-sandbox", Available: false}}
	})
	reject("substrate unavailable", noLocal, pinned(noLocal), bootstrap("r4"), "does not offer substrate")

	b := bootstrap("r5")
	b.Labels = append(b.Labels, "ah-substrate-vm")
	reject("label not granted", m, pinned(m), b, "ah-substrate-vm")

	// Labels derive only from AVAILABLE substrates.
	env, err := p.client.Capabilities(ctx)
	if err != nil {
		t.Fatal(err)
	}
	man, err := VerifyManifest(env, p.cfg.Capabilities, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	d := man.DerivedLabels()
	if !d["ah-sandbox"] || !d["ah-substrate-local-sandbox"] || !d["linux"] || !d["x64"] || d["ah-substrate-vm"] {
		t.Fatalf("derived labels %v", d)
	}
}

func TestProviderKeepsNoState(t *testing.T) {
	// Two independent provider instances (as two GARM invocations are two
	// processes) see the same world: everything is recomputed from the REST
	// API, nothing is cached or written locally.
	m := startMock(t, nil)
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("TMPDIR", home)
	a := newProvider(t, m, "")
	inst, err := a.CreateInstance(context.Background(), bootstrap("runner-stateless"))
	if err != nil {
		t.Fatal(err)
	}
	b := newProvider(t, m, "")
	got, err := b.GetInstance(context.Background(), inst.ProviderID)
	if err != nil || got.Name != "runner-stateless" {
		t.Fatalf("a fresh provider cannot see the instance: %+v, %v", got, err)
	}
	if err := b.DeleteInstance(context.Background(), "runner-stateless"); err != nil {
		t.Fatal(err)
	}
	if _, err := a.GetInstance(context.Background(), inst.ProviderID); !errors.Is(err, garmErrors.ErrNotFound) {
		t.Fatalf("provider a holds stale state: %v", err)
	}
	entries, _ := os.ReadDir(home)
	if len(entries) != 0 {
		t.Fatalf("provider wrote local state: %v", entries)
	}
}

func TestRemoveAllInstancesOnlyTouchesOwnController(t *testing.T) {
	m := startMock(t, nil)
	p := newProvider(t, m, "")
	ctx := context.Background()
	for _, n := range []string{"runner-x", "runner-y"} {
		if _, err := p.CreateInstance(ctx, bootstrap(n)); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("GARM_CONTROLLER_ID", "ctrl-other")
	if _, err := p.CreateInstance(ctx, bootstrap("runner-z")); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GARM_CONTROLLER_ID", testController)
	if err := p.RemoveAllInstances(ctx); err != nil {
		t.Fatal(err)
	}
	live, _ := p.client.ListJobs(ctx, nil)
	if len(live) != 1 || live[0].Name != "runner-z" {
		t.Fatalf("RemoveAllInstances left %+v", live)
	}
}

func TestValidatePoolInfoAndConfig(t *testing.T) {
	m := startMock(t, nil)
	p := newProvider(t, m, "")
	ctx := context.Background()
	if err := p.ValidatePoolInfo(ctx, "any", "", "", `{"ttl_seconds": 60, "runner_install_template": "x"}`); err != nil {
		t.Fatalf("valid extra specs rejected: %v", err)
	}
	if err := p.ValidatePoolInfo(ctx, "any", "", "", `{"runner_template": "upstream"}`); err == nil {
		t.Fatal("upstream (root) template must be rejected for local-sandbox")
	}
	if err := p.ValidatePoolInfo(ctx, "any", "", "", `{"ttl_seconds": 0}`); err == nil {
		t.Fatal("ttl 0 must be rejected")
	}
	for _, bad := range []string{
		`endpoint = "ftp://x"`,
		`endpoint = "http://x"` + "\nsubstrate = \"container\"",
		`endpoint = "http://x"` + "\n[capabilities]\nkey_id = \"ahcap-0000000000000000\"",
		`endpoint = "http://x"` + "\nunknown_key = 1",
	} {
		if _, err := ParseBytes([]byte(bad)); err == nil {
			t.Errorf("config accepted: %s", bad)
		}
	}
	cfg, err := ParseBytes([]byte(`endpoint = "http://127.0.0.1:1"` + "\nsubstrate = \"vm\""))
	if err != nil || cfg.RunnerTemplate != TemplateUpstream || cfg.TTLSeconds != DefaultTTLSeconds {
		t.Fatalf("vm defaults: %+v, %v", cfg, err)
	}
}
