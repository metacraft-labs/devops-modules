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
package backend

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
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

	listExit      int  // non-zero: ephemeral-list cannot enumerate
	listNoResult  bool // exit 0 but no result line (protocol violation)
	oldDaemon     bool // predates ephemeral-list / ephemeral-label (usage exit 2)
	labelExit     int  // non-zero: ephemeral-label fails
	destroyFailsN int  // remaining destroys that fail (transient busy)
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
		if h.oldDaemon {
			return []string{"vm-harness: unknown subcommand 'ephemeral-label'"}, 2
		}
		if h.labelExit == 2 {
			return []string{"vm-harness: --label expects key=value, got 'garm-pool'"}, 2
		}
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
		if h.oldDaemon {
			return []string{"vm-harness: unknown subcommand 'ephemeral-list'"}, 2
		}
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
			if _, err := b.Get(context.Background(), "garm-live"); err == nil || errors.Is(err, garmErrors.ErrNotFound) {
				t.Fatalf("Get on an unenumerable host must fail, not report not-found: %v", err)
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
	t.Run("a usage error from a CURRENT daemon fails the create", func(t *testing.T) {
		// Exit 2 is every usage error, not just an unknown verb: only the old
		// daemon's "unknown subcommand" message may be tolerated.
		h := newFakeHost()
		h.labelExit = 2
		b, done := h.server(t)
		defer done()
		if _, err := b.Create(context.Background(), CreateArgs{Name: "garm-u", PoolID: "P"}); err == nil {
			t.Fatal("a rejected --label (exit 2) was mistaken for an old daemon and the instance left unattributed")
		}
	})
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
