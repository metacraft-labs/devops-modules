package provider

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"sort"
	"strings"
	"testing"

	commonParams "github.com/cloudbase/garm-provider-common/params"

	"github.com/metacraft-labs/garm-provider-vmharness/internal/backend"
	"github.com/metacraft-labs/garm-provider-vmharness/internal/config"
)

func TestRemoteIncusCapabilitiesReachBackend(t *testing.T) {
	p, err := NewWithConfig(&config.Config{
		Backend: config.BackendRemote,
		Remote: &config.RemoteConfig{
			Endpoint:             "runner.example.test:8873",
			TargetBackend:        "incus",
			AuthToken:            "test-token",
			GuestOS:              "linux",
			IncusSecurityNesting: true,
			IncusNestedKvm:       true,
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	b, ok := p.backend.(*backend.RemoteBackend)
	if !ok {
		t.Fatalf("backend type=%T want *backend.RemoteBackend", p.backend)
	}
	if !b.IncusSecurityNesting || !b.IncusNestedKvm {
		t.Fatalf("remote Incus grants were not propagated: %+v", b)
	}
}

func TestRemoteIncusResourceLimitsReachBackend(t *testing.T) {
	p, err := NewWithConfig(&config.Config{
		Backend: config.BackendRemote,
		Remote: &config.RemoteConfig{
			Endpoint:            "runner.example.test:8873",
			TargetBackend:       "incus",
			AuthToken:           "test-token",
			GuestOS:             "linux",
			IncusLimitsCPU:      6,
			IncusLimitsMemoryMB: 16384,
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	b, ok := p.backend.(*backend.RemoteBackend)
	if !ok {
		t.Fatalf("backend type=%T want *backend.RemoteBackend", p.backend)
	}
	if b.IncusLimitsCPU != 6 || b.IncusLimitsMemoryMB != 16384 {
		t.Fatalf("remote Incus resource limits were not propagated: %+v", b)
	}
}

func TestRemoteIncusResourceLimitsRejectNonIncusTargets(t *testing.T) {
	for _, target := range []string{"libvirt", "noop"} {
		t.Run(target, func(t *testing.T) {
			cfg := &config.Config{
				Backend: config.BackendRemote,
				Remote: &config.RemoteConfig{
					Endpoint:       "runner.example.test:8873",
					TargetBackend:  target,
					AuthToken:      "test-token",
					IncusLimitsCPU: 6,
				},
			}
			if _, err := NewWithConfig(cfg); err == nil {
				t.Fatalf("provider construction accepted Incus resource limits for target %q", target)
			}
			if err := cfg.Validate(); err == nil {
				t.Fatalf("config validation accepted Incus resource limits for target %q", target)
			}
		})
	}
}

func TestRemoteIncusCapabilitiesRejectNonIncusConstruction(t *testing.T) {
	for _, tc := range []struct {
		name          string
		backend       config.BackendKind
		targetBackend string
		nesting       bool
		nestedKvm     bool
	}{
		{name: "nesting on remote libvirt target", backend: config.BackendRemote, targetBackend: "libvirt", nesting: true},
		{name: "nested KVM on remote noop target", backend: config.BackendRemote, targetBackend: "noop", nestedKvm: true},
		{name: "nesting on local provider", backend: config.BackendLibvirt, targetBackend: "incus", nesting: true},
		{name: "nested KVM on local provider", backend: config.BackendLibvirt, targetBackend: "incus", nestedKvm: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := NewWithConfig(&config.Config{
				Backend: tc.backend,
				Remote: &config.RemoteConfig{
					Endpoint:             "runner.example.test:8873",
					TargetBackend:        tc.targetBackend,
					AuthToken:            "test-token",
					IncusSecurityNesting: tc.nesting,
					IncusNestedKvm:       tc.nestedKvm,
				},
			})
			if err == nil {
				t.Fatalf("provider construction accepted a remote Incus grant for backend=%q target=%q", tc.backend, tc.targetBackend)
			}
			if !strings.Contains(err.Error(), `backend "remote" with target backend "incus"`) {
				t.Fatalf("construction error is not actionable: %v", err)
			}
		})
	}
}

func TestRemoteIncusCapabilitiesCannotComeFromExtraSpecs(t *testing.T) {
	var gotArgv []string
	serve := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/exec" {
			t.Errorf("serve path=%q want /v1/exec", r.URL.Path)
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		var request struct {
			Argv []string `json:"argv"`
		}
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Errorf("decode exec request: %v", err)
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		gotArgv = append([]string(nil), request.Argv...)
		w.Header().Set("Content-Type", "application/x-ndjson")
		_, _ = w.Write([]byte("{\"v\":\"1\",\"type\":\"exit\",\"code\":0}\n"))
	}))
	defer serve.Close()

	p, err := NewWithConfig(&config.Config{
		Backend: config.BackendRemote,
		Remote: &config.RemoteConfig{
			Endpoint:      strings.TrimPrefix(serve.URL, "http://"),
			TargetBackend: "incus",
			AuthToken:     "test-token",
		},
	})
	if err != nil {
		t.Fatal(err)
	}

	// These names pre-date remote mode in the permissive extra_specs schema,
	// but the provider does not consume them. Drive the real CreateInstance ->
	// RemoteBackend -> HTTP wire path and require the prior exact argv so hostile
	// pool data cannot mutate the provider-admin grants that are its sole source.
	_, err = p.CreateInstance(context.Background(), commonParams.BootstrapInstance{
		Name:       "pool-hostile",
		Image:      "runner-linux",
		OSType:     commonParams.Linux,
		OSArch:     commonParams.Amd64,
		ExtraSpecs: json.RawMessage(`{"incus_security_nesting":true,"incus_nested_kvm":true,"incus_device_path":"/dev/mem"}`),
	})
	if err != nil {
		t.Fatalf("CreateInstance with pre-existing permissive extra_specs: %v", err)
	}
	// DELIBERATE VECTOR CHANGE (MA0): `--source-image runner-linux` is inserted
	// immediately after `--base-image runner-linux` because ephemeralRecipe now
	// sends both image aliases (incus reads --base-image; every other target
	// resolves its golden from --source-image). It carries the SAME pool-declared
	// image the prior vector did, so this test's property is untouched: hostile
	// extra_specs still cannot add, remove or alter a single argument, and no
	// `--incus-*` grant appears.
	wantArgv := []string{
		"run", "--ephemeral", "--backend", "incus", "--baseline", "pool-hostile",
		"--base-image", "runner-linux", "--source-image", "runner-linux",
		"--keep", "--log-format", "json",
	}
	if !reflect.DeepEqual(gotArgv, wantArgv) {
		t.Fatalf("hostile pool extra_specs changed remote argv=%v want exact %v", gotArgv, wantArgv)
	}
	b, ok := p.backend.(*backend.RemoteBackend)
	if !ok {
		t.Fatalf("backend type=%T want *backend.RemoteBackend", p.backend)
	}
	if b.IncusSecurityNesting || b.IncusNestedKvm {
		t.Fatalf("pool extra_specs escalated remote provider grants: %+v", b)
	}
}

func TestConfigSchemaPinsRemoteIncusCapabilityBoundary(t *testing.T) {
	var schema struct {
		Properties map[string]struct {
			Properties map[string]struct {
				Type    string          `json:"type"`
				Default json.RawMessage `json:"default"`
			} `json:"properties"`
			AdditionalProperties json.RawMessage `json:"additionalProperties"`
		} `json:"properties"`
	}
	if err := json.Unmarshal([]byte(configJSONSchema), &schema); err != nil {
		t.Fatal(err)
	}
	remote, ok := schema.Properties["remote"]
	if !ok {
		t.Fatal("config schema has no remote object")
	}
	if string(remote.AdditionalProperties) != "false" {
		t.Fatalf("remote schema additionalProperties=%s want false", remote.AdditionalProperties)
	}
	wantKeys := []string{
		"auth_token",
		"auth_token_env",
		"auth_token_file",
		"endpoint",
		"guest_os",
		"incus_limits_cpu",
		"incus_limits_memory_mb",
		"incus_nested_kvm",
		"incus_security_nesting",
		"request_timeout_sec",
		"target_backend",
	}
	gotKeys := make([]string, 0, len(remote.Properties))
	for key := range remote.Properties {
		gotKeys = append(gotKeys, key)
	}
	sort.Strings(gotKeys)
	if !reflect.DeepEqual(gotKeys, wantKeys) {
		t.Fatalf("remote schema keys=%v want exact closed surface %v", gotKeys, wantKeys)
	}
	for _, key := range []string{"incus_security_nesting", "incus_nested_kvm"} {
		prop, ok := remote.Properties[key]
		if !ok {
			t.Fatalf("remote schema missing %q", key)
		}
		if prop.Type != "boolean" || string(prop.Default) != "false" {
			t.Fatalf("remote schema %q=%+v want boolean default false", key, prop)
		}
	}
	// The resource caps are integers that default to 0 (= no cap), so an
	// operator who sets nothing keeps the pre-limits create argv.
	for _, key := range []string{"incus_limits_cpu", "incus_limits_memory_mb"} {
		prop, ok := remote.Properties[key]
		if !ok {
			t.Fatalf("remote schema missing %q", key)
		}
		if prop.Type != "integer" || string(prop.Default) != "0" {
			t.Fatalf("remote schema %q=%+v want integer default 0", key, prop)
		}
	}
}
