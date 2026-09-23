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

// Hermetic wire-level tests for the RB1 remote-target backend + serve client.
//
// MOCK POLICY: the ONE fixture here is a minimal in-process HTTP server that
// speaks the RA1 `/v1` contract (bearer auth, `GET /v1/info`, chunked NDJSON
// `POST /v1/exec`). It stands in for a `vm-harness serve` daemon so the Go
// client's wire handling — bearer header, 401 → ServeAuthError, NDJSON event
// decoding, exit-code propagation, argv forwarding — is exercised WITHOUT a
// vm-harness binary or a hypervisor. The end-to-end gate `t_garm_provider_remote`
// (checks/garm-provider-remote.nix) complements this by driving the built
// provider against a REAL `vm-harness serve --backend noop`, so the full wire
// contract is also proven against the genuine daemon. This mock exists solely to
// give a fast, dependency-free unit that pins the client/backend logic.
package backend

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
)

const testToken = "unit-bearer-3f9a2c"

// fakeServe records exec argvs and replies with the RA1 wire contract.
type fakeServe struct {
	execArgv [][]string
	// execUserData records the /v1/exec `userData` field per request (parallel
	// to execArgv) so a test can prove the rendered bootstrap crosses the wire.
	execUserData []string
	exitCode     int
}

func (f *fakeServe) handler() http.Handler {
	mux := http.NewServeMux()
	auth := func(w http.ResponseWriter, r *http.Request) bool {
		if r.Header.Get("Authorization") != "Bearer "+testToken {
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = w.Write([]byte(`{"error":"unauthorized"}`))
			return false
		}
		return true
	}
	mux.HandleFunc("/v1/info", func(w http.ResponseWriter, r *http.Request) {
		if !auth(w, r) {
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"service":"vm-harness-serve","protocol":"1","host":"linux","backends":[{"id":"noop","available":true,"guests":["linux"]}]}`))
	})
	mux.HandleFunc("/v1/exec", func(w http.ResponseWriter, r *http.Request) {
		if !auth(w, r) {
			return
		}
		var req execRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		f.execArgv = append(f.execArgv, req.Argv)
		f.execUserData = append(f.execUserData, req.UserData)
		fl, _ := w.(http.Flusher)
		w.Header().Set("Content-Type", "application/x-ndjson")
		w.WriteHeader(http.StatusOK)
		// Two log lines then a terminal exit — chunked because we flush.
		writeEv := func(v any) {
			b, _ := json.Marshal(v)
			_, _ = fmt.Fprintf(w, "%s\n", b)
			if fl != nil {
				fl.Flush()
			}
		}
		writeEv(map[string]any{"v": "1", "type": "log", "line": "line-a " + strings.Join(req.Argv, " ")})
		writeEv(map[string]any{"v": "1", "type": "log", "line": "line-b"})
		writeEv(map[string]any{"v": "1", "type": "exit", "code": f.exitCode})
	})
	return mux
}

func newFakeBackend(t *testing.T, target string, exitCode int) (*RemoteBackend, *fakeServe, func()) {
	t.Helper()
	fs := &fakeServe{exitCode: exitCode}
	srv := httptest.NewServer(fs.handler())
	endpoint := strings.TrimPrefix(srv.URL, "http://")
	b := &RemoteBackend{
		Client:        NewServeClient(endpoint, testToken, 0),
		TargetBackend: target,
		GuestOS:       "linux",
	}
	return b, fs, srv.Close
}

func TestRemoteCreateDeleteNoop(t *testing.T) {
	b, fs, closeFn := newFakeBackend(t, "noop", 0)
	defer closeFn()
	ctx := context.Background()

	inst, err := b.Create(ctx, CreateArgs{Name: "garm-r-1", ControllerID: "ctrl", PoolID: "pool", OSArch: "amd64"})
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if inst.ProviderID != "garm-r-1" || inst.Name != "garm-r-1" || inst.Status != "running" {
		t.Fatalf("Create instance: %+v", inst)
	}
	if inst.OSName != "linux" {
		t.Fatalf("OSName=%q want linux", inst.OSName)
	}
	// The noop recipe stays byte-for-byte unchanged and cannot receive Incus
	// capability flags.
	wantCreate := []string{"provision", "--backend", "noop", "--baseline", "garm-r-1", "--log-format", "json"}
	if len(fs.execArgv) != 2 || !reflect.DeepEqual(fs.execArgv[0], wantCreate) {
		t.Fatalf("create argv=%v want exact %v", fs.execArgv, wantCreate)
	}
	// Then the ownership labels, so the pool's ListInstances can see it.
	wantLabel := []string{"ephemeral-label", "--backend", "noop", "--baseline", "garm-r-1",
		"--label", "garm-pool=pool", "--label", "garm-controller=ctrl", "--log-format", "json"}
	if !reflect.DeepEqual(fs.execArgv[1], wantLabel) {
		t.Fatalf("label argv=%v want exact %v", fs.execArgv[1], wantLabel)
	}

	if err := b.Delete(ctx, "garm-r-1"); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if len(fs.execArgv) != 3 || fs.execArgv[2][0] != "ephemeral-destroy" {
		t.Fatalf("delete argv=%v want ephemeral-destroy", fs.execArgv)
	}
	wantDelete := []string{"ephemeral-destroy", "--backend", "noop", "--baseline", "garm-r-1", "--log-format", "json"}
	if !reflect.DeepEqual(fs.execArgv[2], wantDelete) {
		t.Fatalf("delete argv=%v want exact %v", fs.execArgv[2], wantDelete)
	}
}

func TestRemoteCreateIncusRecipe(t *testing.T) {
	b, fs, closeFn := newFakeBackend(t, "incus", 0)
	defer closeFn()
	if _, err := b.Create(context.Background(), CreateArgs{Name: "job-42", SourceImage: "runner-linux"}); err != nil {
		t.Fatalf("Create: %v", err)
	}
	// DELIBERATE VECTOR CHANGE (MA0). `--source-image runner-linux` is new here
	// relative to the pre-MA0 argv: ephemeralRecipe is the fallback for every
	// non-noop target and every backend except incus resolves its golden from
	// --source-image, so the recipe now sends both aliases. incus reads
	// --base-image and ignores --source-image, so its behaviour is unchanged;
	// the pair is inserted immediately after --base-image and nothing else in
	// the vector moved. See TestVMHarnessImageIsHonouredRemoteRecipe* below.
	want := []string{
		"run", "--ephemeral", "--backend", "incus", "--baseline", "job-42",
		"--base-image", "runner-linux", "--source-image", "runner-linux",
		"--keep", "--log-format", "json",
	}
	if !reflect.DeepEqual(fs.execArgv[0], want) {
		t.Fatalf("default incus create argv=%v want byte-for-byte prior argv + the MA0 --source-image pair %v", fs.execArgv[0], want)
	}
}

func TestRemoteCreateIncusCapabilityFlagOrderAndDeleteIsolation(t *testing.T) {
	for _, tc := range []struct {
		name       string
		nesting    bool
		nestedKvm  bool
		capability []string
	}{
		{name: "nesting only", nesting: true, capability: []string{"--incus-security-nesting"}},
		{name: "nested KVM only", nestedKvm: true, capability: []string{"--incus-nested-kvm"}},
		{name: "both in fixed order", nesting: true, nestedKvm: true, capability: []string{"--incus-security-nesting", "--incus-nested-kvm"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			b, fs, closeFn := newFakeBackend(t, "incus", 0)
			defer closeFn()
			b.IncusSecurityNesting = tc.nesting
			b.IncusNestedKvm = tc.nestedKvm

			if _, err := b.Create(context.Background(), CreateArgs{Name: "job-cap"}); err != nil {
				t.Fatalf("Create: %v", err)
			}
			wantCreate := []string{"run", "--ephemeral", "--backend", "incus", "--baseline", "job-cap"}
			wantCreate = append(wantCreate, tc.capability...)
			wantCreate = append(wantCreate, "--keep", "--log-format", "json")
			if !reflect.DeepEqual(fs.execArgv[0], wantCreate) {
				t.Fatalf("create argv=%v want exact %v", fs.execArgv[0], wantCreate)
			}

			if err := b.Delete(context.Background(), "job-cap"); err != nil {
				t.Fatalf("Delete: %v", err)
			}
			wantDelete := []string{"ephemeral-destroy", "--backend", "incus", "--baseline", "job-cap", "--log-format", "json"}
			if !reflect.DeepEqual(fs.execArgv[1], wantDelete) {
				t.Fatalf("delete argv=%v want exact capability-free argv %v", fs.execArgv[1], wantDelete)
			}
		})
	}
}

func TestRemoteNonIncusRecipesNeverReceiveIncusCapabilities(t *testing.T) {
	for _, target := range []string{"noop", "libvirt", "hyperv", "tart-macos"} {
		t.Run(target, func(t *testing.T) {
			b, fs, closeFn := newFakeBackend(t, target, 0)
			defer closeFn()
			b.IncusSecurityNesting = true
			b.IncusNestedKvm = true

			if _, err := b.Create(context.Background(), CreateArgs{Name: "job-other"}); err != nil {
				t.Fatalf("Create: %v", err)
			}
			var want []string
			if target == "noop" {
				want = []string{"provision", "--backend", target, "--baseline", "job-other", "--log-format", "json"}
			} else {
				want = []string{"run", "--ephemeral", "--backend", target, "--baseline", "job-other", "--keep", "--log-format", "json"}
			}
			if !reflect.DeepEqual(fs.execArgv[0], want) {
				t.Fatalf("target %q argv=%v want exact capability-free argv %v", target, fs.execArgv[0], want)
			}
		})
	}
}

func TestRemoteCreateShipsBootstrapAsUserData(t *testing.T) {
	// RB2: the rendered runner bootstrap must cross the wire as /v1/exec
	// `userData` so the daemon can inject it as the guest's cloud-init user-data.
	b, fs, closeFn := newFakeBackend(t, "incus", 0)
	defer closeFn()
	const bootstrap = "#!/bin/bash\n# runner install (JIT token redacted)\n./config.sh --jitconfig XYZ\n"
	if _, err := b.Create(context.Background(), CreateArgs{
		Name:        "job-77",
		SourceImage: "runner-linux",
		Bootstrap:   []byte(bootstrap),
	}); err != nil {
		t.Fatalf("Create: %v", err)
	}
	if len(fs.execUserData) != 1 {
		t.Fatalf("expected 1 exec, got %d", len(fs.execUserData))
	}
	if fs.execUserData[0] != bootstrap {
		t.Fatalf("userData over the wire = %q, want the rendered bootstrap %q", fs.execUserData[0], bootstrap)
	}
	// The bootstrap travels alongside the argv, never inside it (the daemon
	// stages it to a file and appends --user-data itself).
	if hasFlag(fs.execArgv[0], "--user-data") {
		t.Fatalf("bootstrap must not be baked into argv: %v", fs.execArgv[0])
	}
}

func TestRemoteCreateWithoutBootstrapSendsNoUserData(t *testing.T) {
	// The noop test recipe (and any create with no rendered tools) sends an
	// empty userData, so the daemon appends no --user-data flag.
	b, fs, closeFn := newFakeBackend(t, "noop", 0)
	defer closeFn()
	if _, err := b.Create(context.Background(), CreateArgs{Name: "job-0"}); err != nil {
		t.Fatalf("Create: %v", err)
	}
	if len(fs.execUserData) != 1 || fs.execUserData[0] != "" {
		t.Fatalf("expected empty userData, got %q", fs.execUserData)
	}
}

// GATE t_vmharness_image_is_honoured, assertion (b): "the remote RPC recipe
// does the same for every non-incus target". Wired as
// checks.t_vmharness_image_is_honoured in
// nixos-modules/checks/vmharness-image-is-honoured.nix, which selects every
// TestVMHarnessImageIsHonoured* test in this package.
//
// The ephemeral recipe is the fallback for every non-noop target, not just
// incus. --base-image is the incus image alias; other backends resolve their
// golden from --source-image, which cli.nim maps to BaselineSpec.sourceImage
// (--baseline goes to .name). Sending only --base-image left sourceImage
// empty for tart and qemu-windows-arm, and the tart backends answer an empty
// image by substituting their built-in cirruslabs golden — silently running an
// image that appears in no configuration.
//
// "Every non-incus target" is asserted against the named production targets AND
// against targets the recipe table has never heard of, because b.recipe() sends
// everything except "noop" down this path: a future target must inherit the fix
// rather than have to be added to a list.
//
// ASSERTION STYLE. These assert the WHOLE argv with reflect.DeepEqual, matching
// the rest of this file: a containment check would pass even if the flag landed
// in the wrong position, and position is contractual here (see ephemeralRecipe's
// fixed flag order). Asserting the whole vector also makes every one of these
// sub-tests a second witness for the capability-isolation invariant — none of
// these targets is "incus", and no `--incus-*` flag may appear.
func TestVMHarnessImageIsHonouredRemoteRecipeCarriesSourceImage(t *testing.T) {
	targets := []string{
		// The production targets MA2 puts behind the remote path.
		"tart-macos", "tart-linux-arm", "qemu-windows-arm",
		// Already-remote non-incus targets.
		"libvirt", "hyperv", "wsl", "lima", "utm",
		// Not in any table: proves the default branch, not a per-target case.
		"some-future-backend",
	}
	for _, target := range targets {
		t.Run(target, func(t *testing.T) {
			b, fs, closeFn := newFakeBackend(t, target, 0)
			defer closeFn()
			const image = "ghcr.io/metacraft-labs/macos-tart-runner:tahoe-nix-v1"
			if _, err := b.Create(context.Background(),
				CreateArgs{Name: "job-7", SourceImage: image}); err != nil {
				t.Fatalf("Create: %v", err)
			}
			// --baseline still names the INSTANCE; the image rides on
			// --source-image (and on incus's --base-image alias). Pinning the
			// whole vector is what keeps the two from being confused again.
			want := []string{
				"run", "--ephemeral", "--backend", target, "--baseline", "job-7",
				"--base-image", image, "--source-image", image,
				"--keep", "--log-format", "json",
			}
			if !reflect.DeepEqual(fs.execArgv[0], want) {
				t.Fatalf("target %q create argv=%v want exact %v", target, fs.execArgv[0], want)
			}
		})
	}
}

// GATE t_vmharness_image_is_honoured — incus keeps its own alias. The fix must
// not regress the one target that resolves its image from --base-image; the
// recipe sends both and each backend reads the flag it understands.
func TestVMHarnessImageIsHonouredRemoteRecipeKeepsIncusAlias(t *testing.T) {
	b, fs, closeFn := newFakeBackend(t, "incus", 0)
	defer closeFn()
	if _, err := b.Create(context.Background(),
		CreateArgs{Name: "job-9", SourceImage: "runner-linux"}); err != nil {
		t.Fatalf("Create: %v", err)
	}
	// --base-image must still come FIRST and still carry the image: incus is
	// the one backend that reads it, so a "fix" that replaced the alias rather
	// than adding beside it would break the currently-green lane.
	want := []string{
		"run", "--ephemeral", "--backend", "incus", "--baseline", "job-9",
		"--base-image", "runner-linux", "--source-image", "runner-linux",
		"--keep", "--log-format", "json",
	}
	if !reflect.DeepEqual(fs.execArgv[0], want) {
		t.Fatalf("incus create argv=%v want exact %v", fs.execArgv[0], want)
	}
}

// GATE t_vmharness_image_is_honoured — where the image flags sit relative to
// the Incus capability grants. ephemeralRecipe declares a fixed flag order, and
// MA0's --source-image is an insertion INTO that order, so the interaction has
// to be pinned rather than left to the two changes' separate tests: upstream's
// capability test passes no image, and the tests above pass an image with the
// grants off. Contract: image pair (base, source) first, then nesting, then
// nested KVM, then the lifecycle/logging suffix.
func TestVMHarnessImageIsHonouredRemoteRecipeOrdersImageFlagsBeforeIncusGrants(t *testing.T) {
	b, fs, closeFn := newFakeBackend(t, "incus", 0)
	defer closeFn()
	b.IncusSecurityNesting = true
	b.IncusNestedKvm = true
	if _, err := b.Create(context.Background(),
		CreateArgs{Name: "job-cap-img", SourceImage: "runner-linux"}); err != nil {
		t.Fatalf("Create: %v", err)
	}
	want := []string{
		"run", "--ephemeral", "--backend", "incus", "--baseline", "job-cap-img",
		"--base-image", "runner-linux", "--source-image", "runner-linux",
		"--incus-security-nesting", "--incus-nested-kvm",
		"--keep", "--log-format", "json",
	}
	if !reflect.DeepEqual(fs.execArgv[0], want) {
		t.Fatalf("incus create argv with image + both grants=%v want exact %v", fs.execArgv[0], want)
	}
	// Delete isolation holds with an image configured too: teardown names the
	// instance and carries neither an image nor a capability flag.
	if err := b.Delete(context.Background(), "job-cap-img"); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	wantDelete := []string{"ephemeral-destroy", "--backend", "incus", "--baseline", "job-cap-img", "--log-format", "json"}
	if !reflect.DeepEqual(fs.execArgv[1], wantDelete) {
		t.Fatalf("delete argv=%v want exact image- and capability-free argv %v", fs.execArgv[1], wantDelete)
	}
}

// GATE t_vmharness_image_is_honoured — the negative half of assertion (b).
// With no configured image there is nothing to forward, and an empty
// --source-image would be worse than its absence: it would look configured.
// This is also where the "identical to the RB1/RB2 path" property is still
// literally true: no image configured, grants off, so the vector is the
// pre-MA0, pre-capability one unchanged.
func TestVMHarnessImageIsHonouredRemoteRecipeOmitsImageFlagsWhenUnset(t *testing.T) {
	b, fs, closeFn := newFakeBackend(t, "tart-macos", 0)
	defer closeFn()
	if _, err := b.Create(context.Background(), CreateArgs{Name: "job-8"}); err != nil {
		t.Fatalf("Create: %v", err)
	}
	argv := fs.execArgv[0]
	if hasFlag(argv, "--source-image") || hasFlag(argv, "--base-image") {
		t.Fatalf("create argv carries an image flag with no image set: %v", argv)
	}
	want := []string{
		"run", "--ephemeral", "--backend", "tart-macos", "--baseline", "job-8",
		"--keep", "--log-format", "json",
	}
	if !reflect.DeepEqual(argv, want) {
		t.Fatalf("image-less create argv=%v want exact pre-MA0 argv %v", argv, want)
	}
}

func TestRemoteCreateNonZeroExitFails(t *testing.T) {
	b, _, closeFn := newFakeBackend(t, "noop", 7)
	defer closeFn()
	if _, err := b.Create(context.Background(), CreateArgs{Name: "x"}); err == nil {
		t.Fatal("Create with worker exit 7 should error")
	}
}

func TestRemoteDeleteNonZeroIsAnError(t *testing.T) {
	// REVERSED from the RB1 contract, which treated a non-zero teardown exit as
	// idempotent success. `ephemeral-destroy` exits 0 for an absent instance,
	// so a non-zero exit means the teardown did NOT complete and the guest may
	// still exist; swallowing it leaked STOPPED containers on the GPU hosts.
	// See TestRemoteDeleteSurfacesFailedTeardown for the full lifecycle.
	b, _, closeFn := newFakeBackend(t, "noop", 5)
	defer closeFn()
	if err := b.Delete(context.Background(), "x"); err == nil {
		t.Fatal("Delete with teardown exit 5 must fail")
	}
}

func TestRemoteWrongTokenRejected(t *testing.T) {
	b, _, closeFn := newFakeBackend(t, "noop", 0)
	defer closeFn()
	b.Client.Token = "WRONG"
	ctx := context.Background()

	_, err := b.Create(ctx, CreateArgs{Name: "x"})
	if err == nil {
		t.Fatal("Create with wrong token should fail")
	}
	// Delete surfaces the auth error too (does NOT swallow it as idempotent).
	if err := b.Delete(ctx, "x"); err == nil {
		t.Fatal("Delete with wrong token should surface the auth error")
	}
	// Get enumerates over /v1/exec and must surface the 401.
	if _, err := b.Get(ctx, "x"); err == nil {
		t.Fatal("Get with wrong token should fail")
	}
	// And it is specifically a ServeAuthError.
	if _, err := b.Client.Info(ctx); err == nil {
		t.Fatal("Info with wrong token should fail")
	} else if _, ok := err.(*ServeAuthError); !ok {
		t.Fatalf("want *ServeAuthError, got %T: %v", err, err)
	}
}

func TestServeClientExecStreamEvents(t *testing.T) {
	fs := &fakeServe{exitCode: 0}
	srv := httptest.NewServer(fs.handler())
	defer srv.Close()
	c := NewServeClient(strings.TrimPrefix(srv.URL, "http://"), testToken, 0)

	var logs []string
	code, err := c.ExecStream(context.Background(), []string{"probe"}, func(ev ExecEvent) {
		if ev.Kind == "log" {
			logs = append(logs, ev.Line)
		}
	})
	if err != nil {
		t.Fatalf("ExecStream: %v", err)
	}
	if code != 0 {
		t.Fatalf("exit=%d want 0", code)
	}
	if len(logs) != 2 || !strings.HasPrefix(logs[0], "line-a") {
		t.Fatalf("streamed logs=%v", logs)
	}
}

func TestGetOnAHostWithoutEnumerationIsNotRunning(t *testing.T) {
	// REVERSED: Get used to report ANY name as "running" whenever /v1/info
	// answered. The fake daemon here prints no ephemeral-list result, so Get
	// must fail rather than invent a running instance.
	b, _, closeFn := newFakeBackend(t, "noop", 0)
	defer closeFn()
	if inst, err := b.Get(context.Background(), "garm-r-9"); err == nil {
		t.Fatalf("Get invented %+v without an enumeration", inst)
	}
}

func hasFlag(argv []string, flag string) bool {
	for _, a := range argv {
		if a == flag {
			return true
		}
	}
	return false
}
