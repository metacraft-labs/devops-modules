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

// Instance-lifecycle tests for the remote backend: visibility, pool scoping,
// fail-closed enumeration, and honest teardown.
//
// WHAT THESE REPRODUCE (central GARM on high-mem-server, 2026-09-22/23):
//
//   - RemoteBackend.List returned an EMPTY LIST unconditionally. GARM's
//     orphaned-runner sweep (runner/pool cleanupOrphanedGithubRunners) treats
//     "offline in GitHub for >5 min and absent from ListInstances" as "the
//     provider already lost it" and deletes the DB row WITHOUT calling
//     DeleteInstance. Every Windows runner is still booting at 5 minutes, so
//     each was forgotten while its libvirt domain ran on: garm-qglasrc9bvey
//     was created 08:24:15 and dropped 08:30:16; ~210 domains / 55 GiB leaked.
//     TestRemoteListMakesCreatedInstanceVisible reproduces the drop decision
//     with GARM's own predicate (instanceInList by name).
//
//   - RemoteBackend.Delete treated a non-zero `ephemeral-destroy` exit as
//     idempotent success, so a teardown that failed (incus `dataset is busy`)
//     let GARM forget a still-existing STOPPED container; ~100 filled
//     gpu-server-001/002's pool. TestRemoteDeleteSurfacesFailedTeardown.
//
// MOCK JUSTIFICATION (workspace test policy). The fixture is an in-process
// HTTP server speaking the real `vm-harness serve` /v1 wire contract (bearer
// auth, chunked NDJSON exec stream). Behind it, instead of spawning the
// vm-harness CLI, it emulates the four verbs this backend drives
// (`run --ephemeral`, `ephemeral-label`, `ephemeral-list`,
// `ephemeral-destroy`) over an in-memory host, reproducing their documented
// exit codes and result line (vm-harness docs/ephemeral-lifecycle-and-cleanup.md
// §5.1, gated on the vm-harness side by tests/unit/t_ephemeral_inventory.nim).
// This is necessary because the failures under test — an unenumerable host, a
// daemon too old to know a verb, a teardown that fails transiently — cannot be
// produced on demand against a real daemon, and the unit tier must not need a
// hypervisor. The real daemon is exercised by the nix gate
// t_garm_provider_remote (checks/garm-provider-remote.nix).
//
// OLD-DAEMON AND USAGE-ERROR OUTPUT IS NOT EMULATED, IT IS REPLAYED. The first
// version of this fixture made up the old daemon's answer ("unknown subcommand
// 'ephemeral-label'"); the real old binary never prints that for the
// provider's argv (its parser rejects `--label` before dispatch), the tests
// passed, and the 2026-09-24 rollout failed every create on gpu-server-001/002.
// So those responses are now the BYTE-EXACT /v1/exec NDJSON streams captured
// from real daemons (testdata/serve-<rev>/, provenance in
// testdata/README.provenance), written to the wire verbatim. The real old
// binary is additionally driven end to end by t_garm_provider_remote_old_daemon
// (checks/garm-provider-remote-old-daemon.nix).
package backend

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	garmErrors "github.com/cloudbase/garm-provider-common/errors"
)

type hostInstance struct {
	state  string
	labels map[string]string
}

// fakeHost is an in-memory daemon host behind a real /v1 HTTP endpoint.
type fakeHost struct {
	mu        sync.Mutex
	instances map[string]*hostInstance
	labels    map[string]map[string]string // label records (may outlive instances)
	argv      [][]string

	listExit      int    // non-zero: ephemeral-list cannot enumerate
	listNoResult  bool   // exit 0 but no result line (protocol violation)
	oldDaemon     bool   // predates ephemeral-list / ephemeral-label: replays serve-e337cb6
	labelExit     int    // non-zero: ephemeral-label fails with a non-usage error
	labelReplay   string // non-empty: ephemeral-label answers with this captured stream
	destroyFailsN int    // remaining destroys that fail (transient busy)
}

func newFakeHost() *fakeHost {
	return &fakeHost{instances: map[string]*hostInstance{}, labels: map[string]map[string]string{}}
}

func flagValues(argv []string, flag string) []string {
	var out []string
	for i := 0; i+1 < len(argv); i++ {
		if argv[i] == flag {
			out = append(out, argv[i+1])
		}
	}
	return out
}

// Captured /v1/exec streams (see testdata/README.provenance).
const (
	// gosti e337cb6 — the serve the fleet ran on 2026-09-24.
	replayOldLabel    = "testdata/serve-e337cb6/ephemeral-label.ndjson"     // ephemeral-label … --label …
	replayOldListPool = "testdata/serve-e337cb6/ephemeral-list-pool.ndjson" // ephemeral-list … --label …
	replayOldListName = "testdata/serve-e337cb6/ephemeral-list-name.ndjson" // ephemeral-list … --name …
	// gosti 4d69242 — a CURRENT daemon's genuine usage errors (exit 2).
	replayNewLabelBadValue = "testdata/serve-4d69242/label-bad-value.ndjson"
	replayNewLabelBadKey   = "testdata/serve-4d69242/label-bad-key.ndjson"
)

// replay returns the captured stream to send verbatim for argv, or "".
func (h *fakeHost) replay(argv []string) string {
	h.mu.Lock()
	defer h.mu.Unlock()
	switch {
	case h.oldDaemon && argv[0] == "ephemeral-label":
		return replayOldLabel
	case h.oldDaemon && argv[0] == "ephemeral-list" && len(flagValues(argv, "--label")) > 0:
		return replayOldListPool
	case h.oldDaemon && argv[0] == "ephemeral-list":
		return replayOldListName
	case h.labelReplay != "" && argv[0] == "ephemeral-label":
		return h.labelReplay
	}
	return ""
}

// run emulates one vm-harness invocation: returns log lines and exit code.
func (h *fakeHost) run(argv []string) ([]string, int) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.argv = append(h.argv, argv)
	name := ""
	if v := flagValues(argv, "--baseline"); len(v) > 0 {
		name = v[0]
	}
	switch argv[0] {
	case "run", "provision":
		h.instances[name] = &hostInstance{state: "running"}
		return []string{`{"level":"info","msg":"ephemeral clone: kept running"}`}, 0
	case "ephemeral-label":
		if h.labelExit != 0 {
			return []string{"cannot write label record"}, h.labelExit
		}
		l := map[string]string{}
		for _, kv := range flagValues(argv, "--label") {
			k, v, _ := strings.Cut(kv, "=")
			l[k] = v
		}
		h.labels[name] = l
		return nil, 0
	case "ephemeral-list":
		if h.listExit != 0 {
			return []string{`{"level":"error","msg":"ephemeral-list: enumeration failed","error":"virsh: failed to connect to the hypervisor"}`}, h.listExit
		}
		if h.listNoResult {
			return []string{"some unrelated output"}, 0
		}
		want := flagValues(argv, "--label")
		only := flagValues(argv, "--name")
		type row struct {
			Name   string            `json:"name"`
			State  string            `json:"state"`
			Labels map[string]string `json:"labels"`
		}
		rows := []row{}
		for n, inst := range h.instances {
			if len(only) > 0 && only[0] != n {
				continue
			}
			l := h.labels[n]
			ok := true
			for _, kv := range want {
				k, v, _ := strings.Cut(kv, "=")
				if l[k] != v {
					ok = false
				}
			}
			if ok {
				rows = append(rows, row{Name: n, State: inst.state, Labels: l})
			}
		}
		b, _ := json.Marshal(map[string]any{"vmhEphemeralList": 1, "backend": "libvirt", "instances": rows})
		return []string{`{"level":"info","msg":"noise before the result"}`, string(b)}, 0
	case "ephemeral-destroy":
		if _, ok := h.instances[name]; !ok {
			delete(h.labels, name)
			return nil, 0 // absent is success — idempotence lives here
		}
		if h.destroyFailsN > 0 {
			h.destroyFailsN--
			return []string{"incus delete " + name + " did not complete: dataset is busy"}, 1
		}
		delete(h.instances, name)
		delete(h.labels, name)
		return nil, 0
	}
	return []string{"vm-harness: unknown subcommand"}, 2
}

func (h *fakeHost) server(t *testing.T) (*RemoteBackend, func()) {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/exec", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+testToken {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		var req execRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		if f := h.replay(req.Argv); f != "" {
			h.mu.Lock()
			h.argv = append(h.argv, req.Argv)
			h.mu.Unlock()
			raw, err := os.ReadFile(filepath.FromSlash(f))
			if err != nil {
				t.Errorf("replay fixture: %v", err)
				w.WriteHeader(http.StatusInternalServerError)
				return
			}
			w.Header().Set("Content-Type", "application/x-ndjson")
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write(raw)
			return
		}
		lines, code := h.run(req.Argv)
		w.Header().Set("Content-Type", "application/x-ndjson")
		w.WriteHeader(http.StatusOK)
		for _, l := range lines {
			b, _ := json.Marshal(map[string]any{"v": "1", "type": "log", "line": l})
			_, _ = fmt.Fprintf(w, "%s\n", b)
		}
		b, _ := json.Marshal(map[string]any{"v": "1", "type": "exit", "code": code})
		_, _ = fmt.Fprintf(w, "%s\n", b)
	})
	srv := httptest.NewServer(mux)
	return &RemoteBackend{
		Client:        NewServeClient(strings.TrimPrefix(srv.URL, "http://"), testToken, 0),
		TargetBackend: "libvirt",
		GuestOS:       "windows",
	}, srv.Close
}

// garmDropsInstance is GARM's own decision in cleanupOrphanedGithubRunners for
// a runner that is offline in GitHub and older than 5 minutes: if the name is
// not in the pool's ListInstances, the record is deleted and the provider's
// DeleteInstance is never called (instanceInList matches by name).
func garmDropsInstance(list []Instance, name string) bool {
	for _, i := range list {
		if i.Name == name {
			return false
		}
	}
	return true
}

func TestRemoteListMakesCreatedInstanceVisible(t *testing.T) {
	h := newFakeHost()
	b, done := h.server(t)
	defer done()
	ctx := context.Background()

	if _, err := b.Create(ctx, CreateArgs{Name: "garm-qglasrc9bvey", PoolID: "66190210", ControllerID: "ctrl"}); err != nil {
		t.Fatalf("Create: %v", err)
	}
	list, err := b.List(ctx, "66190210")
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if garmDropsInstance(list, "garm-qglasrc9bvey") {
		t.Fatalf("a freshly created, still-running instance is absent from its pool's ListInstances (%+v): GARM would forget it and leak the VM", list)
	}
	if list[0].Status != "running" || list[0].PoolID != "66190210" || list[0].ControllerID != "ctrl" || list[0].OSName != "windows" {
		t.Fatalf("listed instance=%+v", list[0])
	}

	// A guest that has stopped is reported as stopped, not omitted.
	h.instances["garm-qglasrc9bvey"].state = "stopped"
	list, err = b.List(ctx, "66190210")
	if err != nil || len(list) != 1 || list[0].Status != "stopped" {
		t.Fatalf("stopped instance: list=%+v err=%v", list, err)
	}
}

func TestRemoteListIsScopedToThePool(t *testing.T) {
	// GARM's scale-set worker DELETES listed instances it has no record of, so
	// a host-wide list would let one pool destroy another's runners.
	h := newFakeHost()
	b, done := h.server(t)
	defer done()
	ctx := context.Background()
	for _, c := range []struct{ name, pool string }{{"garm-a1", "A"}, {"garm-a2", "A"}, {"garm-b1", "B"}} {
		if _, err := b.Create(ctx, CreateArgs{Name: c.name, PoolID: c.pool, ControllerID: "ctrl"}); err != nil {
			t.Fatal(err)
		}
	}
	h.instances["win-ci-vm-001"] = &hostInstance{state: "running"} // durable, not GARM's

	a, err := b.List(ctx, "A")
	if err != nil || len(a) != 2 {
		t.Fatalf("pool A list=%+v err=%v", a, err)
	}
	for _, i := range a {
		if i.PoolID != "A" {
			t.Fatalf("pool A was shown %+v", i)
		}
	}
	if bl, _ := b.List(ctx, "B"); len(bl) != 1 || bl[0].Name != "garm-b1" {
		t.Fatalf("pool B list=%+v", bl)
	}
	ctl, err := b.ListByController(ctx, "ctrl")
	if err != nil || len(ctl) != 3 {
		t.Fatalf("controller list=%+v err=%v (the unattributed durable VM must never be included)", ctl, err)
	}
	if _, err := b.List(ctx, ""); err == nil {
		t.Fatal("List without a pool ID must refuse (a host-wide list is unsafe)")
	}
	if _, err := b.ListByController(ctx, ""); err == nil {
		t.Fatal("ListByController without a controller ID must refuse")
	}
}

func TestRemoteListFailsClosed(t *testing.T) {
	// GARM reads "absent from ListInstances" as "already gone". Every way of
	// NOT KNOWING must therefore be an error — never an empty list — and never
	// ErrNotFound.
	cases := map[string]func(h *fakeHost){
		"host cannot enumerate": func(h *fakeHost) { h.listExit = 1 },
		"daemon predates verb":  func(h *fakeHost) { h.oldDaemon = true },
		"no result line":        func(h *fakeHost) { h.listNoResult = true },
	}
	for name, breakIt := range cases {
		t.Run(name, func(t *testing.T) {
			h := newFakeHost()
			h.instances["garm-live"] = &hostInstance{state: "running"}
			h.labels["garm-live"] = map[string]string{labelPool: "P"}
			breakIt(h)
			b, done := h.server(t)
			defer done()
			list, err := b.List(context.Background(), "P")
			if err == nil {
				t.Fatalf("List succeeded with %+v on a host it could not enumerate", list)
			}
			if !errors.Is(err, ErrEnumerationUnavailable) || errors.Is(err, garmErrors.ErrNotFound) {
				t.Fatalf("err=%v: want ErrEnumerationUnavailable and NOT ErrNotFound", err)
			}
			// Only a POSITIVELY identified old daemon is reported as one.
			if got, want := errors.Is(err, ErrDaemonPredatesInventory), name == "daemon predates verb"; got != want {
				t.Fatalf("err=%v: ErrDaemonPredatesInventory=%v, want %v", err, got, want)
			}
			_, err = b.Get(context.Background(), "garm-live")
			if err == nil || errors.Is(err, garmErrors.ErrNotFound) {
				t.Fatalf("Get on an unenumerable host must fail, not report not-found: %v", err)
			}
			if got, want := errors.Is(err, ErrDaemonPredatesInventory), name == "daemon predates verb"; got != want {
				t.Fatalf("Get err=%v: ErrDaemonPredatesInventory=%v, want %v", err, got, want)
			}
		})
	}

	t.Run("daemon unreachable", func(t *testing.T) {
		h := newFakeHost()
		b, done := h.server(t)
		done() // connection refused from here on
		if _, err := b.List(context.Background(), "P"); err == nil || !errors.Is(err, ErrEnumerationUnavailable) {
			t.Fatalf("unreachable daemon: err=%v", err)
		}
	})
}

func TestRemoteGetDistinguishesAbsentFromUnknown(t *testing.T) {
	h := newFakeHost()
	b, done := h.server(t)
	defer done()
	ctx := context.Background()
	if _, err := b.Create(ctx, CreateArgs{Name: "garm-g1", PoolID: "P"}); err != nil {
		t.Fatal(err)
	}
	inst, err := b.Get(ctx, "garm-g1")
	if err != nil || inst.Status != "running" {
		t.Fatalf("Get present: %+v %v", inst, err)
	}
	if _, err := b.Get(ctx, "garm-nope"); !errors.Is(err, garmErrors.ErrNotFound) {
		t.Fatalf("Get absent: want ErrNotFound, got %v", err)
	}
}

func TestRemoteDeleteSurfacesFailedTeardown(t *testing.T) {
	h := newFakeHost()
	b, done := h.server(t)
	defer done()
	ctx := context.Background()
	if _, err := b.Create(ctx, CreateArgs{Name: "garm-busy", PoolID: "P"}); err != nil {
		t.Fatal(err)
	}
	h.destroyFailsN = 1
	if err := b.Delete(ctx, "garm-busy"); err == nil {
		t.Fatal("a teardown that exited non-zero was reported as success; GARM would forget a container that still exists")
	}
	if _, ok := h.instances["garm-busy"]; !ok {
		t.Fatal("fixture: instance should still exist after the failed teardown")
	}
	// GARM retries; the retry succeeds and the instance is gone.
	if err := b.Delete(ctx, "garm-busy"); err != nil {
		t.Fatalf("retry Delete: %v", err)
	}
	// Idempotent: deleting an absent instance is success (vm-harness exits 0).
	if err := b.Delete(ctx, "garm-busy"); err != nil {
		t.Fatalf("Delete of an absent instance: %v", err)
	}
	if l, _ := b.List(ctx, "P"); len(l) != 0 {
		t.Fatalf("deleted instance still listed: %+v", l)
	}
}

func TestRemoteCreateLabelsAndToleratesOnlyAnOldDaemon(t *testing.T) {
	t.Run("labels are recorded", func(t *testing.T) {
		h := newFakeHost()
		b, done := h.server(t)
		defer done()
		if _, err := b.Create(context.Background(), CreateArgs{Name: "garm-l", PoolID: "P", ControllerID: "C"}); err != nil {
			t.Fatal(err)
		}
		want := []string{"ephemeral-label", "--backend", "libvirt", "--baseline", "garm-l",
			"--label", "garm-pool=P", "--label", "garm-controller=C", "--log-format", "json"}
		if got := h.argv[1]; strings.Join(got, " ") != strings.Join(want, " ") {
			t.Fatalf("label argv=%v want %v", got, want)
		}
	})
	t.Run("old daemon: create still succeeds", func(t *testing.T) {
		h := newFakeHost()
		h.oldDaemon = true
		b, done := h.server(t)
		defer done()
		if _, err := b.Create(context.Background(), CreateArgs{Name: "garm-o", PoolID: "P"}); err != nil {
			t.Fatalf("Create against a daemon without ephemeral-label must not fail: %v", err)
		}
	})
	t.Run("old daemon: label-less create is attempted and still succeeds", func(t *testing.T) {
		// Controller-only attribution (no pool) takes the same path.
		h := newFakeHost()
		h.oldDaemon = true
		b, done := h.server(t)
		defer done()
		if _, err := b.Create(context.Background(), CreateArgs{Name: "garm-oc", ControllerID: "C"}); err != nil {
			t.Fatalf("controller-only create against an old daemon: %v", err)
		}
		if _, labelled := h.labels["garm-oc"]; labelled {
			t.Fatal("fixture: an old daemon cannot have recorded a label")
		}
	})
	for name, fixture := range map[string]string{
		"bad value": replayNewLabelBadValue,
		"bad key":   replayNewLabelBadKey,
	} {
		t.Run("a usage error from a CURRENT daemon fails the create ("+name+")", func(t *testing.T) {
			// Exit 2 is every usage error, not just an old daemon: only the old
			// binary's exact text may be tolerated. These are a real 4d69242
			// daemon's answers to a malformed --label.
			h := newFakeHost()
			h.labelReplay = fixture
			b, done := h.server(t)
			defer done()
			if _, err := b.Create(context.Background(), CreateArgs{Name: "garm-u", PoolID: "P"}); err == nil {
				t.Fatal("a rejected --label (exit 2) was mistaken for an old daemon and the instance left unattributed")
			}
		})
	}
	t.Run("label write failure fails the create", func(t *testing.T) {
		h := newFakeHost()
		h.labelExit = 1
		b, done := h.server(t)
		defer done()
		if _, err := b.Create(context.Background(), CreateArgs{Name: "garm-f", PoolID: "P"}); err == nil {
			t.Fatal("an unattributable instance must fail the create, not become invisible to its pool")
		}
	})
}

// TestOldDaemonFixturesAreTheRealOutput pins what the captured streams say, so a
// re-capture that changed them (or a hand edit) is loud. These strings are the
// contract isOldDaemonUsage is written against.
func TestOldDaemonFixturesAreTheRealOutput(t *testing.T) {
	for f, want := range map[string]string{
		replayOldLabel:         "vm-harness: Unknown flag: '--label'",
		replayOldListPool:      "vm-harness: Unknown flag: '--label'",
		replayOldListName:      "vm-harness: unknown subcommand 'ephemeral-list'",
		replayNewLabelBadValue: "vm-harness: --label expects key=value, got 'garm-pool'",
		replayNewLabelBadKey:   "vm-harness: --label key has invalid characters: bad key",
	} {
		raw, err := os.ReadFile(filepath.FromSlash(f))
		if err != nil {
			t.Fatal(err)
		}
		lines := strings.Split(strings.TrimSpace(string(raw)), "\n")
		var first, last wireEvent
		if err := json.Unmarshal([]byte(lines[0]), &first); err != nil {
			t.Fatalf("%s: %v", f, err)
		}
		if err := json.Unmarshal([]byte(lines[len(lines)-1]), &last); err != nil {
			t.Fatalf("%s: %v", f, err)
		}
		if first.Type != "log" || first.Line != want {
			t.Errorf("%s: first event %+v, want log %q", f, first, want)
		}
		if last.Type != "exit" || last.Code != usageExitCode {
			t.Errorf("%s: last event %+v, want exit %d", f, last, usageExitCode)
		}
	}
}

func TestIsOldDaemonUsage(t *testing.T) {
	cases := []struct {
		name  string
		verb  string
		code  int
		lines []string
		want  bool
	}{
		{"old: --label rejected by the parser (label)", "ephemeral-label", 2, []string{"vm-harness: Unknown flag: '--label'", "vm-harness <subcommand> [flags]"}, true},
		{"old: --label rejected by the parser (list)", "ephemeral-list", 2, []string{"vm-harness: Unknown flag: '--label'"}, true},
		{"old: unknown verb (list --name)", "ephemeral-list", 2, []string{"vm-harness: unknown subcommand 'ephemeral-list'"}, true},
		{"old marker but not a usage exit", "ephemeral-label", 1, []string{"vm-harness: Unknown flag: '--label'"}, false},
		{"another verb's unknown-subcommand", "ephemeral-label", 2, []string{"vm-harness: unknown subcommand 'ephemeral-list'"}, false},
		{"current: bad --label value", "ephemeral-label", 2, []string{"vm-harness: --label expects key=value, got 'garm-pool'"}, false},
		{"current: a different unknown flag", "ephemeral-list", 2, []string{"vm-harness: Unknown flag: '--labels'"}, false},
		{"success", "ephemeral-list", 0, nil, false},
	}
	for _, c := range cases {
		if got := isOldDaemonUsage(c.verb, c.code, c.lines); got != c.want {
			t.Errorf("%s: isOldDaemonUsage=%v want %v", c.name, got, c.want)
		}
	}
}

// TestMixedFleetRollout is the 2026-09-24 rollout: the NEW provider driving one
// host whose serve is already upgraded and one still on the old binary. Order
// must not matter: creates succeed on both, the upgraded host lists its pool,
// and the old host fails closed with the distinguishable error (so GARM's
// reconcile skips it rather than recycling its runners).
func TestMixedFleetRollout(t *testing.T) {
	ctx := context.Background()
	newHost, oldHost := newFakeHost(), newFakeHost()
	oldHost.oldDaemon = true
	nb, doneN := newHost.server(t)
	defer doneN()
	ob, doneO := oldHost.server(t)
	defer doneO()

	if _, err := nb.Create(ctx, CreateArgs{Name: "garm-n1", PoolID: "P", ControllerID: "C"}); err != nil {
		t.Fatalf("create on upgraded host: %v", err)
	}
	if _, err := ob.Create(ctx, CreateArgs{Name: "garm-o1", PoolID: "P", ControllerID: "C"}); err != nil {
		t.Fatalf("create on old host (the outage): %v", err)
	}
	if l, err := nb.List(ctx, "P"); err != nil || len(l) != 1 || l[0].Name != "garm-n1" {
		t.Fatalf("upgraded host list=%+v err=%v", l, err)
	}
	for _, list := range []func() ([]Instance, error){
		func() ([]Instance, error) { return ob.List(ctx, "P") },
		func() ([]Instance, error) { return ob.ListByController(ctx, "C") },
	} {
		l, err := list()
		if err == nil || !errors.Is(err, ErrDaemonPredatesInventory) || !errors.Is(err, ErrEnumerationUnavailable) {
			t.Fatalf("old host list=%+v err=%v: want fail-closed ErrDaemonPredatesInventory", l, err)
		}
	}
	if err := ob.Delete(ctx, "garm-o1"); err != nil {
		t.Fatalf("delete on old host: %v", err)
	}
}
