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

// Package ahmock is a TEST-ONLY emulation of agent-harbor's direct
// sandbox-launch REST endpoints (agent-harbor specs/REST-Service/
// Direct-Sandbox-Launch.md). It is imported only by tests; the provider binary
// never links it.
//
// WHY A MOCK. The real server is agent-harbor's Rust `ah daemon serve` /
// `ah server`, which is not packaged in this repo and whose local-sandbox
// substrate needs user namespaces + a delegated cgroup scope that a Nix build
// sandbox does not provide. The provider under test only ever sees the HTTP
// contract, so the mock implements that contract faithfully: the ledger with
// ids/names, the lifecycle states, record-before-launch, Idempotency-Key
// replay, the 409 name-conflict with existingJobId, idempotent DELETE with
// tombstones that expire into 404, cleanup-token redemption, TTL bookkeeping,
// the Problem+JSON error model with its stable `code`s, ApiKey auth, and a
// REAL Ed25519-signed capability manifest.
//
// WHAT IS REAL. With Exec enabled the mock really runs the job: the argv is
// exec'd (no shell) in a fresh per-job working directory, stdin is the
// request's stdin, the environment is the spec's allow-listed base + the
// caller's env + AH_SANDBOX_JOB_ID/AH_SANDBOX_JOB_NAME, and the process group
// is killed and the directory deleted on exit/destroy (free-on-completion, R2).
// What it does NOT provide is isolation (namespaces, cgroups, default-deny
// filesystem): that is agent-harbor's own AH4 gate, not this provider's.
package ahmock

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Fault is an injected answer for the next matching request.
type Fault struct {
	Method string // "" matches any
	Prefix string // path prefix after /api/v1, "" matches any
	Status int
	Code   string // "" => a non-Problem+JSON body (a proxy error page)
	Detail string
}

// Substrate availability advertised in the manifest.
type Substrate struct {
	Name      string
	Available bool
}

// Recorded is one received request.
type Recorded struct {
	Method   string
	Path     string
	Header   http.Header
	Body     []byte
	RawQuery string
}

type job struct {
	ID                 string            `json:"id"`
	Name               string            `json:"name"`
	Substrate          string            `json:"substrate"`
	State              string            `json:"state"`
	TerminationReason  *string           `json:"terminationReason"`
	ExitCode           *int              `json:"exitCode"`
	Error              *string           `json:"error"`
	Labels             map[string]string `json:"labels"`
	Command            []string          `json:"command"`
	CreatedAt          time.Time         `json:"createdAt"`
	StartedAt          *time.Time        `json:"startedAt"`
	EndedAt            *time.Time        `json:"endedAt"`
	ExpiresAt          time.Time         `json:"expiresAt"`
	TombstoneExpiresAt *time.Time        `json:"tombstoneExpiresAt"`
	TTLSeconds         uint64            `json:"ttlSeconds"`
	IdleTimeoutSeconds *uint64           `json:"idleTimeoutSeconds"`
	CleanupToken       string            `json:"cleanupToken"`
	Host               map[string]string `json:"host"`
	Addresses          []string          `json:"addresses"`
	Links              map[string]string `json:"links"`

	workdir string
	cmd     *exec.Cmd
	done    chan struct{}
	gone    bool // tombstone expired: answers 404
}

// Server is the mock. Configure the exported fields before Start.
type Server struct {
	APIKey            string // "" => no auth required
	ServerID          string
	Substrates        []Substrate
	ExtraLabels       []string
	ManifestTTL       time.Duration
	MaxTTLSeconds     uint64
	DefaultTTLSeconds uint64
	// Exec runs jobs for real (see package doc). Otherwise a launched job
	// just sits in `running` until destroyed.
	Exec bool
	// WorkRoot holds the per-job working directories (Exec only).
	WorkRoot string
	// FailLaunch makes every launch end in `failed` (a substrate spawn error),
	// reported as a 201 job, as the spec requires.
	FailLaunch string
	// OmitCleanupToken makes the server return jobs without a cleanupToken.
	OmitCleanupToken bool
	// TamperManifest flips a byte of the signed payload after signing.
	TamperManifest bool

	mu       sync.Mutex
	jobs     []*job
	idem     map[string]string // idempotency key -> job id
	faults   []Fault
	requests []Recorded
	launches int
	priv     ed25519.PrivateKey
	pub      ed25519.PublicKey
	http     *httptest.Server
}

// Start generates the signing key and starts listening on loopback.
func (s *Server) Start() {
	if s.ServerID == "" {
		s.ServerID = "ahsrv-mock"
	}
	if s.Substrates == nil {
		s.Substrates = []Substrate{
			{Name: "local-sandbox", Available: true},
			{Name: "vm", Available: false},
			{Name: "cloud-vm", Available: false},
		}
	}
	if s.ManifestTTL == 0 {
		s.ManifestTTL = 10 * time.Minute
	}
	if s.MaxTTLSeconds == 0 {
		s.MaxTTLSeconds = 86400
	}
	if s.DefaultTTLSeconds == 0 {
		s.DefaultTTLSeconds = 21600
	}
	s.idem = map[string]string{}
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		panic(err)
	}
	s.pub, s.priv = pub, priv
	s.http = httptest.NewServer(http.HandlerFunc(s.serve))
}

// URL is the base URL (no /api/v1).
func (s *Server) URL() string { return s.http.URL }

// Close stops the server and destroys every live job.
func (s *Server) Close() {
	s.mu.Lock()
	for _, j := range s.jobs {
		s.freeLocked(j)
	}
	s.mu.Unlock()
	s.http.Close()
}

// PublicKey is the base64url manifest signing key.
func (s *Server) PublicKey() string { return base64.RawURLEncoding.EncodeToString(s.pub) }

// KeyID is the spec key id of PublicKey.
func (s *Server) KeyID() string {
	sum := sha256.Sum256(s.pub)
	return "ahcap-" + hex.EncodeToString(sum[:])[:16]
}

// Inject queues a fault for the next matching request.
func (s *Server) Inject(f Fault) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.faults = append(s.faults, f)
}

// Requests returns a copy of every request received so far.
func (s *Server) Requests() []Recorded {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]Recorded(nil), s.requests...)
}

// Launches counts substrate launches (not idempotent replays).
func (s *Server) Launches() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.launches
}

// ExpireTombstones makes every tombstone answer 404 (retention elapsed).
func (s *Server) ExpireTombstones() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, j := range s.jobs {
		if j.State == "destroyed" {
			j.gone = true
		}
	}
}

// SweepExpired runs the server's TTL sweeper as of `now`.
func (s *Server) SweepExpired(now time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, j := range s.jobs {
		if !terminal(j.State) && j.State != "destroyed" && !now.Before(j.ExpiresAt) {
			s.destroyLocked(j, "ttlExpired")
		}
	}
}

// WaitExited blocks until the job's process exited (Exec only) or timeout.
func (s *Server) WaitExited(id string, timeout time.Duration) bool {
	s.mu.Lock()
	var done chan struct{}
	for _, j := range s.jobs {
		if j.ID == id {
			done = j.done
		}
	}
	s.mu.Unlock()
	if done == nil {
		return false
	}
	select {
	case <-done:
		return true
	case <-time.After(timeout):
		return false
	}
}

// LivePIDs returns the pids of LIVE processes that carry any job's owner tag
// (AH_SANDBOX_JOB_ID=<id> in their environment) — the spec's definition of a
// job's processes, and what its cleanup-token teardown sweeps. Zombies are not
// residue: a killed job's orphans are re-parented to the namespace's init,
// which (in a Nix build sandbox) may reap them late, and a zombie holds no
// resources but its pid.
func (s *Server) LivePIDs() []int {
	s.mu.Lock()
	tags := map[string]bool{}
	for _, j := range s.jobs {
		tags["AH_SANDBOX_JOB_ID="+j.ID] = true
	}
	s.mu.Unlock()
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return nil
	}
	var out []int
	for _, e := range entries {
		pid, err := strconv.Atoi(e.Name())
		if err != nil || pid == os.Getpid() {
			continue
		}
		stat, err := os.ReadFile(filepath.Join("/proc", e.Name(), "stat"))
		if err != nil {
			continue
		}
		// Field 3 (state) follows the parenthesised comm, which may hold spaces.
		if i := bytes.LastIndexByte(stat, ')'); i < 0 || i+2 >= len(stat) || stat[i+2] == 'Z' {
			continue
		}
		environ, err := os.ReadFile(filepath.Join("/proc", e.Name(), "environ"))
		if err != nil {
			continue
		}
		for _, kv := range bytes.Split(environ, []byte{0}) {
			if tags[string(kv)] {
				out = append(out, pid)
				break
			}
		}
	}
	return out
}

var (
	nameRe     = regexp.MustCompile(`^[A-Za-z0-9._-]{1,128}$`)
	labelKeyRe = regexp.MustCompile(`^[a-z0-9._/-]{1,63}$`)
)

func terminal(state string) bool { return state == "exited" || state == "failed" }

func problem(w http.ResponseWriter, status int, code, detail string, extra map[string]any) {
	body := map[string]any{
		"type":   "https://docs.agent-harbor.com/errors/sandbox-jobs/" + code,
		"title":  http.StatusText(status),
		"status": status,
		"detail": detail,
		"code":   code,
	}
	for k, v := range extra {
		body[k] = v
	}
	w.Header().Set("Content-Type", "application/problem+json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func (s *Server) serve(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	path := strings.TrimPrefix(r.URL.Path, "/api/v1")

	s.mu.Lock()
	s.requests = append(s.requests, Recorded{Method: r.Method, Path: path, Header: r.Header.Clone(), Body: body, RawQuery: r.URL.RawQuery})
	for i, f := range s.faults {
		if (f.Method == "" || f.Method == r.Method) && strings.HasPrefix(path, f.Prefix) {
			s.faults = append(s.faults[:i], s.faults[i+1:]...)
			s.mu.Unlock()
			if f.Code == "" {
				w.Header().Set("Content-Type", "text/html")
				w.WriteHeader(f.Status)
				_, _ = io.WriteString(w, "<html>upstream proxy error</html>")
				return
			}
			problem(w, f.Status, f.Code, f.Detail, nil)
			return
		}
	}
	s.mu.Unlock()

	if s.APIKey != "" && r.Header.Get("Authorization") != "ApiKey "+s.APIKey {
		problem(w, http.StatusUnauthorized, "unauthorized", "missing or invalid credentials", nil)
		return
	}

	switch {
	case r.Method == http.MethodGet && path == "/sandbox/capabilities":
		s.capabilities(w)
	case r.Method == http.MethodPost && path == "/sandbox-jobs":
		s.create(w, r, body)
	case r.Method == http.MethodPost && path == "/sandbox-jobs/cleanup":
		s.cleanup(w, body)
	case r.Method == http.MethodGet && path == "/sandbox-jobs":
		s.list(w, r)
	case strings.HasPrefix(path, "/sandbox-jobs/"):
		ref := strings.TrimPrefix(path, "/sandbox-jobs/")
		switch r.Method {
		case http.MethodGet:
			s.get(w, ref)
		case http.MethodDelete:
			s.destroy(w, ref, r.URL.Query().Get("wait") != "false")
		default:
			problem(w, http.StatusMethodNotAllowed, "invalid-request", "method not allowed", nil)
		}
	default:
		problem(w, http.StatusNotFound, "not-found", "no such endpoint", nil)
	}
}

func (s *Server) capabilities(w http.ResponseWriter) {
	now := time.Now().UTC()
	subs := []map[string]any{}
	labels := []string{"ah-sandbox"}
	for _, sub := range s.Substrates {
		e := map[string]any{"name": sub.Name, "available": sub.Available}
		if sub.Available {
			labels = append(labels, "ah-substrate-"+sub.Name)
		} else {
			e["reason"] = "not wired in the mock"
		}
		subs = append(subs, e)
	}
	labels = append(labels, "linux", "x64")
	labels = append(labels, s.ExtraLabels...)
	manifest := map[string]any{
		"schema":     "ah.sandbox.capabilities/v1",
		"serverId":   s.ServerID,
		"issuedAt":   now.Format(time.RFC3339),
		"expiresAt":  now.Add(s.ManifestTTL).Format(time.RFC3339),
		"os":         "linux",
		"arch":       "x86_64",
		"substrates": subs,
		"limits":     map[string]any{"maxTtlSeconds": s.MaxTTLSeconds, "defaultTtlSeconds": s.DefaultTTLSeconds},
		"labels":     labels,
	}
	payload, _ := json.Marshal(manifest)
	sig := ed25519.Sign(s.priv, payload)
	if s.TamperManifest {
		payload = []byte(strings.Replace(string(payload), `"available":false`, `"available":true`, 1))
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"payload":   base64.RawURLEncoding.EncodeToString(payload),
		"signature": base64.RawURLEncoding.EncodeToString(sig),
		"alg":       "Ed25519",
		"keyId":     s.KeyID(),
		"publicKey": s.PublicKey(),
		"manifest":  manifest,
	})
}

type createReq struct {
	Name               string            `json:"name"`
	Substrate          string            `json:"substrate"`
	Command            []string          `json:"command"`
	Stdin              *string           `json:"stdin"`
	Env                map[string]string `json:"env"`
	WorkingDirectory   *string           `json:"workingDirectory"`
	Labels             map[string]string `json:"labels"`
	TTLSeconds         *uint64           `json:"ttlSeconds"`
	IdleTimeoutSeconds *uint64           `json:"idleTimeoutSeconds"`
	Sandbox            map[string]any    `json:"sandbox"`
	Image              *string           `json:"image"`
	Flavor             *string           `json:"flavor"`
}

func (s *Server) create(w http.ResponseWriter, r *http.Request, body []byte) {
	var req createReq
	dec := json.NewDecoder(strings.NewReader(string(body)))
	dec.DisallowUnknownFields() // the real contract is deny_unknown_fields
	if err := dec.Decode(&req); err != nil {
		problem(w, http.StatusBadRequest, "invalid-request", err.Error(), nil)
		return
	}
	if !nameRe.MatchString(req.Name) || strings.HasPrefix(req.Name, "sbj_") {
		problem(w, http.StatusBadRequest, "invalid-request", "bad name", nil)
		return
	}
	if len(req.Command) == 0 || req.Command[0] == "" {
		problem(w, http.StatusBadRequest, "invalid-request", "command must be a non-empty argv", nil)
		return
	}
	if req.Stdin != nil && len(*req.Stdin) > 1024*1024 {
		problem(w, http.StatusBadRequest, "invalid-request", "stdin too large", nil)
		return
	}
	for k, v := range req.Labels {
		if !labelKeyRe.MatchString(k) || len(v) > 256 {
			problem(w, http.StatusBadRequest, "invalid-request", "bad label "+k, nil)
			return
		}
	}
	switch req.Substrate {
	case "local-sandbox", "vm", "cloud-vm":
	default:
		problem(w, http.StatusBadRequest, "invalid-request", "unknown substrate", nil)
		return
	}
	available := false
	for _, sub := range s.Substrates {
		if sub.Name == req.Substrate {
			available = sub.Available
		}
	}
	if !available {
		// Before any ledger entry: nothing recorded, nothing can leak.
		problem(w, http.StatusNotImplemented, "substrate-unavailable", "substrate "+req.Substrate+" has no backend", nil)
		return
	}
	if mode, ok := req.Sandbox["mode"]; ok && mode != "static" {
		problem(w, http.StatusUnprocessableEntity, "invalid-sandbox-option", "dynamic mode is not allowed", nil)
		return
	}
	if req.Substrate == "local-sandbox" && (req.Image != nil || req.Flavor != nil) {
		problem(w, http.StatusUnprocessableEntity, "invalid-sandbox-option", "image/flavor are not valid for local-sandbox", nil)
		return
	}
	ttl := s.DefaultTTLSeconds
	if req.TTLSeconds != nil {
		ttl = *req.TTLSeconds
	}
	if ttl == 0 {
		problem(w, http.StatusBadRequest, "invalid-request", "ttlSeconds must be > 0", nil)
		return
	}
	if ttl > s.MaxTTLSeconds {
		problem(w, http.StatusUnprocessableEntity, "invalid-sandbox-option", fmt.Sprintf("ttlSeconds %d exceeds maxTtlSeconds %d", ttl, s.MaxTTLSeconds), nil)
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if key := r.Header.Get("Idempotency-Key"); key != "" {
		if id, ok := s.idem[key]; ok {
			if j := s.findLocked(id); j != nil {
				writeJSON(w, http.StatusOK, j)
				return
			}
		}
	}
	for _, j := range s.jobs {
		if j.Name == req.Name && j.State != "destroyed" {
			problem(w, http.StatusConflict, "name-conflict", "name in use by a live job", map[string]any{"existingJobId": j.ID})
			return
		}
	}

	var idb [16]byte
	_, _ = rand.Read(idb[:])
	now := time.Now().UTC()
	j := &job{
		ID:                 "sbj_" + hex.EncodeToString(idb[:]),
		Name:               req.Name,
		Substrate:          req.Substrate,
		State:              "pending", // R1: record before create
		Labels:             req.Labels,
		Command:            req.Command,
		CreatedAt:          now,
		ExpiresAt:          now.Add(time.Duration(ttl) * time.Second),
		TTLSeconds:         ttl,
		IdleTimeoutSeconds: req.IdleTimeoutSeconds,
		Host:               map[string]string{"serverId": s.ServerID, "os": "linux", "arch": "x86_64"},
		Addresses:          []string{},
		done:               make(chan struct{}),
	}
	if j.Labels == nil {
		j.Labels = map[string]string{}
	}
	j.Links = map[string]string{"self": "/api/v1/sandbox-jobs/" + j.ID, "logs": "/api/v1/sandbox-jobs/" + j.ID + "/logs"}
	if !s.OmitCleanupToken {
		tok, _ := json.Marshal(map[string]any{"jobId": j.ID, "serverId": s.ServerID})
		j.CleanupToken = "local-sandbox.v1." + base64.RawURLEncoding.EncodeToString(tok)
	}
	s.jobs = append(s.jobs, j)
	if key := r.Header.Get("Idempotency-Key"); key != "" {
		s.idem[key] = j.ID
	}
	s.launches++

	j.State = "starting"
	if s.FailLaunch != "" {
		s.failLocked(j, s.FailLaunch)
		writeJSON(w, http.StatusCreated, j)
		return
	}
	if s.Exec {
		if err := s.spawnLocked(j, req); err != nil {
			s.failLocked(j, err.Error())
			writeJSON(w, http.StatusCreated, j)
			return
		}
	} else {
		close(j.done)
	}
	started := time.Now().UTC()
	j.StartedAt = &started
	j.State = "running"
	writeJSON(w, http.StatusCreated, j)
}

func (s *Server) failLocked(j *job, msg string) {
	reason := "launchFailed"
	j.State = "failed"
	j.TerminationReason = &reason
	j.Error = &msg
	ended := time.Now().UTC()
	j.EndedAt = &ended
	close(j.done) // nothing runs: the substrate is already freed
}

// allowedBase is the spec's allow-listed base environment.
var allowedBase = []string{"PATH", "HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"}

func (s *Server) spawnLocked(j *job, req createReq) error {
	dir, err := os.MkdirTemp(s.WorkRoot, "job-")
	if err != nil {
		return err
	}
	j.workdir = dir
	cmd := exec.Command(req.Command[0], req.Command[1:]...)
	cmd.Dir = dir
	env := []string{}
	for _, k := range allowedBase {
		if v, ok := os.LookupEnv(k); ok {
			env = append(env, k+"="+v)
		}
	}
	keys := make([]string, 0, len(req.Env))
	for k := range req.Env {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		env = append(env, k+"="+req.Env[k])
	}
	env = append(env, "AH_SANDBOX_JOB_ID="+j.ID, "AH_SANDBOX_JOB_NAME="+j.Name)
	cmd.Env = env
	if req.Stdin != nil {
		cmd.Stdin = strings.NewReader(*req.Stdin)
	}
	logf, err := os.Create(filepath.Join(s.WorkRoot, j.ID+".log"))
	if err != nil {
		_ = os.RemoveAll(dir)
		return err
	}
	cmd.Stdout = logf
	cmd.Stderr = logf
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		logf.Close()
		_ = os.RemoveAll(dir)
		return err
	}
	j.cmd = cmd
	go func() {
		werr := cmd.Wait()
		logf.Close()
		s.mu.Lock()
		defer s.mu.Unlock()
		if j.State == "running" {
			code := 0
			if werr != nil {
				code = 1
				if ee, ok := werr.(*exec.ExitError); ok {
					code = ee.ExitCode()
				}
			}
			reason := "completed"
			ended := time.Now().UTC()
			j.State = "exited"
			j.ExitCode = &code
			j.TerminationReason = &reason
			j.EndedAt = &ended
		}
		// R2: free the substrate on completion (process group + workspace).
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		_ = os.RemoveAll(j.workdir)
		close(j.done)
	}()
	return nil
}

// JobLog returns the combined stdout/stderr of an exec'd job.
func (s *Server) JobLog(id string) string {
	raw, _ := os.ReadFile(filepath.Join(s.WorkRoot, id+".log"))
	return string(raw)
}

func (s *Server) findLocked(ref string) *job {
	if strings.HasPrefix(ref, "sbj_") {
		for _, j := range s.jobs {
			if j.ID == ref && !j.gone {
				return j
			}
		}
		return nil
	}
	var found *job
	for _, j := range s.jobs {
		if j.Name == ref && !j.gone {
			if found == nil || found.State == "destroyed" {
				found = j
			}
		}
	}
	return found
}

func (s *Server) get(w http.ResponseWriter, ref string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	j := s.findLocked(ref)
	if j == nil {
		problem(w, http.StatusNotFound, "not-found", "unknown job", nil)
		return
	}
	writeJSON(w, http.StatusOK, j)
}

func (s *Server) list(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	type kv struct{ k, v string }
	var want []kv
	for _, l := range q["label"] {
		k, v, ok := strings.Cut(l, "=")
		if !ok {
			problem(w, http.StatusBadRequest, "invalid-request", "label must be <key>=<value>", nil)
			return
		}
		want = append(want, kv{k, v})
	}
	withTombstones := q.Get("includeTombstones") == "true"
	s.mu.Lock()
	defer s.mu.Unlock()
	items := []*job{}
	for _, j := range s.jobs {
		if j.gone || (j.State == "destroyed" && !withTombstones) {
			continue
		}
		match := true
		for _, c := range want {
			if v, ok := j.Labels[c.k]; !ok || v != c.v {
				match = false
			}
		}
		if match {
			items = append(items, j)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

// freeLocked kills the job's process group and removes its workspace.
func (s *Server) freeLocked(j *job) {
	if j.cmd != nil && j.cmd.Process != nil {
		_ = syscall.Kill(-j.cmd.Process.Pid, syscall.SIGKILL)
	}
	if j.workdir != "" {
		_ = os.RemoveAll(j.workdir)
	}
}

func (s *Server) destroyLocked(j *job, reason string) {
	if j.State == "destroyed" {
		return
	}
	if !terminal(j.State) {
		j.TerminationReason = &reason
		ended := time.Now().UTC()
		j.EndedAt = &ended
	}
	s.freeLocked(j)
	j.State = "destroyed"
	ts := time.Now().UTC().Add(time.Hour)
	j.TombstoneExpiresAt = &ts
}

func (s *Server) destroy(w http.ResponseWriter, ref string, wait bool) {
	s.mu.Lock()
	j := s.findLocked(ref)
	if j == nil {
		s.mu.Unlock()
		problem(w, http.StatusNotFound, "not-found", "unknown job", nil)
		return
	}
	s.destroyLocked(j, "destroyed")
	done := j.done
	s.mu.Unlock()
	if wait && done != nil {
		select {
		case <-done:
		case <-time.After(10 * time.Second):
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	writeJSON(w, http.StatusOK, j)
}

func (s *Server) cleanup(w http.ResponseWriter, body []byte) {
	var req struct {
		CleanupToken string `json:"cleanupToken"`
	}
	if err := json.Unmarshal(body, &req); err != nil || !strings.HasPrefix(req.CleanupToken, "local-sandbox.v1.") {
		problem(w, http.StatusBadRequest, "invalid-request", "malformed cleanup token", nil)
		return
	}
	raw, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(req.CleanupToken, "local-sandbox.v1."))
	var tok struct {
		JobID    string `json:"jobId"`
		ServerID string `json:"serverId"`
	}
	if err != nil || json.Unmarshal(raw, &tok) != nil {
		problem(w, http.StatusBadRequest, "invalid-request", "malformed cleanup token", nil)
		return
	}
	if tok.ServerID != s.ServerID {
		problem(w, http.StatusNotFound, "not-found", "foreign token", nil)
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, j := range s.jobs {
		if j.ID == tok.JobID {
			if j.State == "destroyed" {
				writeJSON(w, http.StatusOK, map[string]string{"outcome": "alreadyFreed"})
				return
			}
			s.destroyLocked(j, "reaped")
			writeJSON(w, http.StatusOK, map[string]string{"outcome": "freed"})
			return
		}
	}
	writeJSON(w, http.StatusOK, map[string]string{"outcome": "alreadyFreed"})
}
