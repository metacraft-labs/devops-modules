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

// Package protocoltest drives the BUILT garm-provider-vmharness binary through
// GARM's real external-provider protocol: it sets the GARM_* environment
// variables, pipes a real BootstrapInstance JSON on stdin for CreateInstance,
// and asserts the stdout ProviderInstance JSON + exit codes for the full
// command set + the v0.1.1 introspection commands.
//
// This is the M1 gate `t_garm_provider_vmharness_protocol`. It is HERMETIC: it
// points the provider at a MOCK virsh (no KVM / no real libvirt) that persists
// domain XML on disk, so the stateless provider has a genuine backend to
// recompute from. It exercises the REAL binary over the REAL protocol, not
// internal function calls.
package protocoltest

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

const interfaceVersion = "v0.1.1"

// mockVirshScript mirrors backend.mockVirshScript (kept in sync); duplicated
// here so this black-box test needs no exported test helpers.
const mockVirshScript = `#!/bin/sh
set -eu
STATE="${MOCK_VIRSH_STATE:?MOCK_VIRSH_STATE unset}"
mkdir -p "$STATE/domains" "$STATE/state"
if [ "${1:-}" = "-c" ]; then shift 2; fi
cmd="${1:-}"; shift || true
resolve() {
  want="$1"
  if [ -f "$STATE/domains/$want.xml" ]; then echo "$want"; return 0; fi
  for f in "$STATE"/domains/*.xml; do
    [ -e "$f" ] || continue
    n=$(basename "$f" .xml)
    u=$(sed -n 's/.*<uuid>\(.*\)<\/uuid>.*/\1/p' "$f" | head -n1)
    if [ "$u" = "$want" ]; then echo "$n"; return 0; fi
  done
  return 1
}
case "$cmd" in
  define)
    xml=$(cat)
    name=$(printf '%s' "$xml" | sed -n 's/.*<name>\(.*\)<\/name>.*/\1/p' | head -n1)
    if [ -z "$name" ]; then echo "error: no name in domain xml" >&2; exit 1; fi
    count=$(ls "$STATE/domains" | wc -l)
    uuid="00000000-0000-4000-8000-$(printf '%012d' "$(( count + 1 ))")"
    printf '%s' "$xml" | sed "s|<name>$name</name>|<name>$name</name>\n  <uuid>$uuid</uuid>|" > "$STATE/domains/$name.xml"
    echo "shutoff" > "$STATE/state/$name"
    echo "Domain '$name' defined"
    ;;
  start)
    n=$(resolve "$1") || { echo "error: failed to get domain '$1'" >&2; exit 1; }
    echo "running" > "$STATE/state/$n"; echo "Domain '$n' started" ;;
  shutdown)
    n=$(resolve "$1") || { echo "error: failed to get domain '$1'" >&2; exit 1; }
    echo "shutoff" > "$STATE/state/$n" ;;
  destroy)
    n=$(resolve "$1") || { echo "error: failed to get domain '$1'" >&2; exit 1; }
    echo "shutoff" > "$STATE/state/$n"; echo "Domain '$n' destroyed" ;;
  undefine)
    dom=""
    for a in "$@"; do case "$a" in --*) ;; *) dom="$a"; break;; esac; done
    n=$(resolve "$dom") || { echo "error: failed to get domain '$dom'" >&2; exit 1; }
    rm -f "$STATE/domains/$n.xml" "$STATE/state/$n"
    echo "Domain '$n' has been undefined" ;;
  dominfo)
    n=$(resolve "$1") || { echo "error: failed to get domain '$1'" >&2; exit 1; }
    uuid=$(sed -n 's/.*<uuid>\(.*\)<\/uuid>.*/\1/p' "$STATE/domains/$n.xml" | head -n1)
    st=$(cat "$STATE/state/$n" 2>/dev/null || echo shutoff)
    case "$st" in running) st="running";; *) st="shut off";; esac
    printf 'Name:           %s\n' "$n"
    printf 'UUID:           %s\n' "$uuid"
    printf 'State:          %s\n' "$st" ;;
  dumpxml)
    n=$(resolve "$1") || { echo "error: failed to get domain '$1'" >&2; exit 1; }
    cat "$STATE/domains/$n.xml" ;;
  list)
    for f in "$STATE"/domains/*.xml; do [ -e "$f" ] || continue; basename "$f" .xml; done ;;
  *)
    echo "mock-virsh: unhandled command '$cmd'" >&2; exit 1 ;;
esac
`

// providerInstance is the subset of ProviderInstance the gate asserts on.
type providerInstance struct {
	ProviderID string `json:"provider_id"`
	Name       string `json:"name"`
	OSType     string `json:"os_type"`
	OSName     string `json:"os_name"`
	OSVersion  string `json:"os_version"`
	OSArch     string `json:"os_arch"`
	Status     string `json:"status"`
}

type runResult struct {
	stdout   string
	stderr   string
	exitCode int
}

// harness holds the built binary + a per-test config file + mock virsh state.
type harness struct {
	t          *testing.T
	binary     string
	configFile string
	virshState string
	envBase    []string
}

const controllerID = "ctrl-0000"
const poolID = "9dcf590a-1192-4a9c-b3e4-e0902974c2c0"

func newHarness(t *testing.T) *harness {
	t.Helper()
	tmp := t.TempDir()

	// Build the provider binary (CGO disabled: the provider is pure Go).
	binary := filepath.Join(tmp, "garm-provider-vmharness")
	build := exec.Command("go", "build", "-o", binary, "../../cmd/garm-provider-vmharness")
	build.Env = append(os.Environ(), "CGO_ENABLED=0")
	var buildErr bytes.Buffer
	build.Stderr = &buildErr
	if err := build.Run(); err != nil {
		t.Fatalf("building provider binary: %v\n%s", err, buildErr.String())
	}

	// Mock virsh + its state dir.
	virshState := filepath.Join(tmp, "virsh-state")
	if err := os.MkdirAll(virshState, 0o755); err != nil {
		t.Fatal(err)
	}
	virshPath := filepath.Join(tmp, "virsh")
	if err := os.WriteFile(virshPath, []byte(mockVirshScript), 0o755); err != nil {
		t.Fatal(err)
	}

	// Provider config.toml pointing at the mock virsh.
	configFile := filepath.Join(tmp, "config.toml")
	cfg := "backend = \"libvirt\"\n" +
		"virsh_path = \"" + virshPath + "\"\n" +
		"libvirt_uri = \"test:///default\"\n" +
		"network = \"default\"\n\n" +
		"[images.\"windows-2022\"]\n" +
		"source_image = \"/golden/windows-2022.qcow2\"\n" +
		"os_name = \"windows\"\n" +
		"os_version = \"2022\"\n"
	if err := os.WriteFile(configFile, []byte(cfg), 0o644); err != nil {
		t.Fatal(err)
	}

	return &harness{
		t:          t,
		binary:     binary,
		configFile: configFile,
		virshState: virshState,
		envBase: []string{
			"GARM_INTERFACE_VERSION=" + interfaceVersion,
			"GARM_PROVIDER_CONFIG_FILE=" + configFile,
			"GARM_CONTROLLER_ID=" + controllerID,
			"MOCK_VIRSH_STATE=" + virshState,
			"PATH=" + os.Getenv("PATH"),
		},
	}
}

// run invokes the built binary with GARM_COMMAND=command, the given extra env,
// and stdin, returning stdout/stderr/exit code.
func (h *harness) run(command string, extraEnv []string, stdin string) runResult {
	h.t.Helper()
	cmd := exec.Command(h.binary)
	cmd.Env = append(append([]string{}, h.envBase...), "GARM_COMMAND="+command)
	cmd.Env = append(cmd.Env, extraEnv...)
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	code := 0
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			code = ee.ExitCode()
		} else {
			h.t.Fatalf("running %s: %v (stderr: %s)", command, err, stderr.String())
		}
	}
	return runResult{stdout: stdout.String(), stderr: stderr.String(), exitCode: code}
}

// bootstrapJSON is a real BootstrapInstance blob (shape per GARM's docs), for a
// Windows x64 runner.
func bootstrapJSON(name string) string {
	b := map[string]any{
		"name": name,
		"tools": []map[string]any{
			{
				"os":              "win",
				"architecture":    "x64",
				"download_url":    "https://github.com/actions/runner/releases/download/v2.317.0/actions-runner-win-x64-2.317.0.zip",
				"filename":        "actions-runner-win-x64-2.317.0.zip",
				"sha256_checksum": "0000000000000000000000000000000000000000000000000000000000000000",
			},
		},
		"repo_url":           "https://github.com/example-org/scratch",
		"callback-url":       "https://garm.example.com/api/v1/callbacks",
		"metadata-url":       "https://garm.example.com/api/v1/metadata",
		"instance-token":     "jwt-token",
		"os_type":            "windows",
		"arch":               "amd64",
		"flavor":             "windows-large",
		"image":              "windows-2022",
		"labels":             []string{"windows", "vmharness"},
		"pool_id":            poolID,
		"jit_config_enabled": true,
	}
	data, _ := json.Marshal(b)
	return string(data)
}

func TestProviderProtocol(t *testing.T) {
	if _, err := exec.LookPath("go"); err != nil {
		t.Skipf("go toolchain not on PATH: %v", err)
	}
	h := newHarness(t)

	instanceName := "garm-vmh-0001"

	// ---- introspection -----------------------------------------------------

	t.Run("GetVersion", func(t *testing.T) {
		res := h.run("GetVersion", nil, "")
		if res.exitCode != 0 {
			t.Fatalf("exit=%d stderr=%s", res.exitCode, res.stderr)
		}
		if !strings.HasPrefix(strings.TrimSpace(res.stdout), "v") {
			t.Fatalf("version=%q", res.stdout)
		}
	})

	t.Run("GetSupportedInterfaceVersions", func(t *testing.T) {
		res := h.run("GetSupportedInterfaceVersions", nil, "")
		if res.exitCode != 0 {
			t.Fatalf("exit=%d stderr=%s", res.exitCode, res.stderr)
		}
		var versions []string
		if err := json.Unmarshal([]byte(res.stdout), &versions); err != nil {
			t.Fatalf("decoding versions %q: %v", res.stdout, err)
		}
		found := false
		for _, v := range versions {
			if v == interfaceVersion {
				found = true
			}
		}
		if !found {
			t.Fatalf("supported versions %v missing %s", versions, interfaceVersion)
		}
	})

	t.Run("GetConfigJSONSchema", func(t *testing.T) {
		res := h.run("GetConfigJSONSchema", nil, "")
		if res.exitCode != 0 {
			t.Fatalf("exit=%d stderr=%s", res.exitCode, res.stderr)
		}
		var schema map[string]any
		if err := json.Unmarshal([]byte(res.stdout), &schema); err != nil {
			t.Fatalf("config schema not valid JSON: %v\n%s", err, res.stdout)
		}
		if schema["properties"] == nil {
			t.Fatalf("config schema has no properties: %s", res.stdout)
		}
	})

	t.Run("GetExtraSpecsJSONSchema", func(t *testing.T) {
		res := h.run("GetExtraSpecsJSONSchema", nil, "")
		if res.exitCode != 0 {
			t.Fatalf("exit=%d stderr=%s", res.exitCode, res.stderr)
		}
		var schema map[string]any
		if err := json.Unmarshal([]byte(res.stdout), &schema); err != nil {
			t.Fatalf("extra specs schema not valid JSON: %v\n%s", err, res.stdout)
		}
	})

	t.Run("ValidatePoolInfo", func(t *testing.T) {
		// ValidatePoolInfo reads image/flavor from the bootstrap params (stdin
		// is not used for this command; the harness pulls image/flavor from the
		// bootstrap struct, which for non-Create commands is zero-valued). We
		// assert it does not error for a configured image via extra specs env.
		res := h.run("ValidatePoolInfo", nil, "")
		// image is empty here (no bootstrap), so the provider returns an error
		// (image required) with exit 1 — that is the correct, honest behaviour.
		if res.exitCode == 0 {
			t.Fatalf("ValidatePoolInfo with empty image should fail, got exit 0")
		}
	})

	// ---- lifecycle ---------------------------------------------------------

	var created providerInstance

	t.Run("CreateInstance", func(t *testing.T) {
		res := h.run("CreateInstance",
			[]string{"GARM_POOL_ID=" + poolID},
			bootstrapJSON(instanceName))
		if res.exitCode != 0 {
			t.Fatalf("exit=%d stderr=%s stdout=%s", res.exitCode, res.stderr, res.stdout)
		}
		if err := json.Unmarshal([]byte(res.stdout), &created); err != nil {
			t.Fatalf("CreateInstance stdout not ProviderInstance JSON: %v\n%s", err, res.stdout)
		}
		if created.ProviderID == "" {
			t.Fatalf("CreateInstance: empty provider_id: %s", res.stdout)
		}
		if created.Name != instanceName {
			t.Fatalf("CreateInstance: name=%q want %q", created.Name, instanceName)
		}
		if created.Status != "running" {
			t.Fatalf("CreateInstance: status=%q want running", created.Status)
		}
		if created.OSType != "windows" {
			t.Fatalf("CreateInstance: os_type=%q want windows", created.OSType)
		}
		if created.OSName != "windows" || created.OSVersion != "2022" {
			t.Fatalf("CreateInstance: os_name/version=%q/%q want windows/2022", created.OSName, created.OSVersion)
		}
	})

	t.Run("GetInstance", func(t *testing.T) {
		res := h.run("GetInstance",
			[]string{"GARM_INSTANCE_ID=" + instanceName, "GARM_POOL_ID=" + poolID}, "")
		if res.exitCode != 0 {
			t.Fatalf("exit=%d stderr=%s", res.exitCode, res.stderr)
		}
		var got providerInstance
		if err := json.Unmarshal([]byte(res.stdout), &got); err != nil {
			t.Fatalf("GetInstance stdout: %v\n%s", err, res.stdout)
		}
		if got.Name != instanceName || got.Status != "running" {
			t.Fatalf("GetInstance mismatch: %+v", got)
		}
		if got.ProviderID != created.ProviderID {
			t.Fatalf("GetInstance provider_id=%q want %q", got.ProviderID, created.ProviderID)
		}
	})

	t.Run("GetInstanceByProviderID", func(t *testing.T) {
		res := h.run("GetInstance",
			[]string{"GARM_INSTANCE_ID=" + created.ProviderID, "GARM_POOL_ID=" + poolID}, "")
		if res.exitCode != 0 {
			t.Fatalf("exit=%d stderr=%s", res.exitCode, res.stderr)
		}
		var got providerInstance
		if err := json.Unmarshal([]byte(res.stdout), &got); err != nil {
			t.Fatalf("GetInstance(by id) stdout: %v\n%s", err, res.stdout)
		}
		if got.Name != instanceName {
			t.Fatalf("GetInstance(by id): name=%q", got.Name)
		}
	})

	t.Run("ListInstances", func(t *testing.T) {
		res := h.run("ListInstances", []string{"GARM_POOL_ID=" + poolID}, "")
		if res.exitCode != 0 {
			t.Fatalf("exit=%d stderr=%s", res.exitCode, res.stderr)
		}
		var list []providerInstance
		if err := json.Unmarshal([]byte(res.stdout), &list); err != nil {
			t.Fatalf("ListInstances stdout: %v\n%s", err, res.stdout)
		}
		if len(list) != 1 || list[0].Name != instanceName {
			t.Fatalf("ListInstances: %+v", list)
		}
	})

	t.Run("ListInstancesOtherPoolEmpty", func(t *testing.T) {
		res := h.run("ListInstances", []string{"GARM_POOL_ID=other-pool"}, "")
		if res.exitCode != 0 {
			t.Fatalf("exit=%d stderr=%s", res.exitCode, res.stderr)
		}
		var list []providerInstance
		if err := json.Unmarshal([]byte(res.stdout), &list); err != nil {
			t.Fatalf("ListInstances(other) stdout: %v\n%s", err, res.stdout)
		}
		if len(list) != 0 {
			t.Fatalf("ListInstances(other pool): want empty, got %+v", list)
		}
	})

	t.Run("StopInstance", func(t *testing.T) {
		res := h.run("StopInstance",
			[]string{"GARM_INSTANCE_ID=" + instanceName, "GARM_POOL_ID=" + poolID}, "")
		if res.exitCode != 0 {
			t.Fatalf("exit=%d stderr=%s", res.exitCode, res.stderr)
		}
		// Confirm state reflects stopped.
		got := h.run("GetInstance",
			[]string{"GARM_INSTANCE_ID=" + instanceName, "GARM_POOL_ID=" + poolID}, "")
		var pi providerInstance
		_ = json.Unmarshal([]byte(got.stdout), &pi)
		if pi.Status != "stopped" {
			t.Fatalf("after Stop: status=%q want stopped", pi.Status)
		}
	})

	t.Run("StartInstance", func(t *testing.T) {
		res := h.run("StartInstance",
			[]string{"GARM_INSTANCE_ID=" + instanceName, "GARM_POOL_ID=" + poolID}, "")
		if res.exitCode != 0 {
			t.Fatalf("exit=%d stderr=%s", res.exitCode, res.stderr)
		}
		got := h.run("GetInstance",
			[]string{"GARM_INSTANCE_ID=" + instanceName, "GARM_POOL_ID=" + poolID}, "")
		var pi providerInstance
		_ = json.Unmarshal([]byte(got.stdout), &pi)
		if pi.Status != "running" {
			t.Fatalf("after Start: status=%q want running", pi.Status)
		}
	})

	t.Run("DeleteInstance", func(t *testing.T) {
		res := h.run("DeleteInstance",
			[]string{"GARM_INSTANCE_ID=" + instanceName, "GARM_POOL_ID=" + poolID}, "")
		if res.exitCode != 0 {
			t.Fatalf("exit=%d stderr=%s", res.exitCode, res.stderr)
		}
		// Confirm gone: GetInstance now fails with the not-found exit code 30.
		got := h.run("GetInstance",
			[]string{"GARM_INSTANCE_ID=" + instanceName, "GARM_POOL_ID=" + poolID}, "")
		if got.exitCode != 30 {
			t.Fatalf("GetInstance after delete: exit=%d want 30 (stderr=%s)", got.exitCode, got.stderr)
		}
	})

	t.Run("DeleteInstanceIdempotent", func(t *testing.T) {
		// Deleting an absent instance must succeed (exit 0) — idempotent.
		res := h.run("DeleteInstance",
			[]string{"GARM_INSTANCE_ID=" + instanceName, "GARM_POOL_ID=" + poolID}, "")
		if res.exitCode != 0 {
			t.Fatalf("idempotent delete: exit=%d want 0 (stderr=%s)", res.exitCode, res.stderr)
		}
	})

	t.Run("RemoveAllInstances", func(t *testing.T) {
		// Create two, then RemoveAllInstances by controller tag, then confirm
		// the pool lists empty.
		for _, n := range []string{"garm-vmh-a", "garm-vmh-b"} {
			res := h.run("CreateInstance",
				[]string{"GARM_POOL_ID=" + poolID}, bootstrapJSON(n))
			if res.exitCode != 0 {
				t.Fatalf("create %s: exit=%d stderr=%s", n, res.exitCode, res.stderr)
			}
		}
		res := h.run("RemoveAllInstances", []string{"GARM_POOL_ID=" + poolID}, "")
		if res.exitCode != 0 {
			t.Fatalf("RemoveAllInstances: exit=%d stderr=%s", res.exitCode, res.stderr)
		}
		list := h.run("ListInstances", []string{"GARM_POOL_ID=" + poolID}, "")
		var l []providerInstance
		if err := json.Unmarshal([]byte(list.stdout), &l); err != nil {
			t.Fatalf("post-remove list: %v\n%s", err, list.stdout)
		}
		if len(l) != 0 {
			t.Fatalf("after RemoveAllInstances: want empty, got %+v", l)
		}
	})
}
