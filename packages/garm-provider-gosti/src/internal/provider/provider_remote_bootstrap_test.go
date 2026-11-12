// Mock justification: a local httptest server stands in for the remote serve
// daemon. It receives the real wire request (argv + user_data) produced by the
// real CreateInstance -> RemoteBackend -> ServeClient path, so the test asserts
// exactly the bootstrap bytes a remote guest would be handed, without a VM, a
// serve host or a network. GARM's own install-script wrapper is rendered from
// the vendored upstream template fixture (testdata/garm-upstream), not mocked.
package provider

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	commonParams "github.com/cloudbase/garm-provider-common/params"

	"github.com/metacraft-labs/garm-provider-gosti/internal/config"
)

const (
	remoteControllerMetadataURL = "http://100.64.0.1:9997/api/v1/metadata"
	remoteControllerCallbackURL = "http://100.64.0.1:9997/api/v1/callbacks"
	remoteGuestMetadataURL      = "https://garm.example.test/api/v1/metadata"
	remoteGuestCallbackURL      = "https://garm.example.test/api/v1/callbacks"
)

// remoteCreateUserData drives CreateInstance for a remote provider against a
// fake serve daemon and returns the user_data the daemon received.
func remoteCreateUserData(t *testing.T, targetBackend string, osType commonParams.OSType, toolsOS string) string {
	t.Helper()
	var (
		mu       sync.Mutex
		userData string
	)
	serve := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/exec" {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		var request struct {
			UserData string `json:"userData"`
		}
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Errorf("decode exec request: %v", err)
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		mu.Lock()
		if request.UserData != "" {
			userData = request.UserData
		}
		mu.Unlock()
		w.Header().Set("Content-Type", "application/x-ndjson")
		_, _ = w.Write([]byte("{\"v\":\"1\",\"type\":\"exit\",\"code\":0}\n"))
	}))
	defer serve.Close()

	p, err := NewWithConfig(&config.Config{
		Backend:          config.BackendRemote,
		GuestMetadataURL: remoteGuestMetadataURL,
		GuestCallbackURL: remoteGuestCallbackURL,
		Remote: &config.RemoteConfig{
			Endpoint:      strings.TrimPrefix(serve.URL, "http://"),
			TargetBackend: targetBackend,
			AuthToken:     "test-token",
			GuestOS:       string(osType),
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	params := commonParams.BootstrapInstance{
		Name:             "garm-remote-1",
		RepoURL:          "https://github.com/example-org/example-repo",
		CallbackURL:      remoteControllerCallbackURL,
		MetadataURL:      remoteControllerMetadataURL,
		InstanceToken:    "instance-token",
		OSType:           osType,
		OSArch:           commonParams.Arm64,
		Image:            "golden",
		Labels:           []string{"self-hosted", string(osType), "arm64"},
		JitConfigEnabled: true,
		Tools: []commonParams.RunnerApplicationDownload{{
			OS:             strptr(toolsOS),
			Architecture:   strptr("arm64"),
			DownloadURL:    strptr("https://example.invalid/actions-runner-" + toolsOS + "-arm64.tar.gz"),
			Filename:       strptr("actions-runner-" + toolsOS + "-arm64.tar.gz"),
			SHA256Checksum: strptr(""),
		}},
	}
	// GARM hands every pool without its own template its install-script
	// wrapper, rendered with the CONTROLLER's URLs.
	params = withGarmWrapper(t, params, garmWrapper(t, commonParams.Linux, remoteControllerMetadataURL, remoteControllerCallbackURL))
	if _, err := p.CreateInstance(context.Background(), params); err != nil {
		t.Fatalf("CreateInstance: %v", err)
	}
	mu.Lock()
	defer mu.Unlock()
	if userData == "" {
		t.Fatal("serve daemon received no user_data")
	}
	return userData
}

// A remote tart-linux-arm guest boots on another host and may reach the
// controller only through the guest URL overrides. It must get the complete,
// self-contained Tart Linux script (no second-stage install-script fetch,
// which GARM renders server-side with the controller's URLs), and every URL in
// it must be an override.
func TestRemoteTartLinuxRendersCompleteScriptWithGuestURLs(t *testing.T) {
	text := remoteCreateUserData(t, "tart-linux-arm", commonParams.Linux, "linux")
	for _, want := range []string{
		"CALLBACK_URL='" + remoteGuestCallbackURL + "'",
		"METADATA_URL='" + remoteGuestMetadataURL + "'",
		`get_metadata_file "credentials/runner"`,
		`exec sudo -u "$RUNNER_USER" -H ./run.sh`,
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("remote tart-linux-arm bootstrap missing %q:\n%s", want, text)
		}
	}
	for _, unwanted := range []string{"install-script", "100.64.0.1"} {
		if strings.Contains(text, unwanted) {
			t.Fatalf("remote tart-linux-arm bootstrap contains %q:\n%s", unwanted, text)
		}
	}
}

// The mapping is for tart-linux-arm only: a remote Linux incus guest keeps
// the upstream renderer, which (with GARM's wrapper) is the wrapper itself.
func TestRemoteIncusLinuxKeepsUpstreamRenderer(t *testing.T) {
	text := remoteCreateUserData(t, "incus", commonParams.Linux, "linux")
	if !strings.Contains(text, "install-script") {
		t.Fatalf("remote incus bootstrap no longer uses GARM's wrapper:\n%s", text)
	}
	if strings.Contains(text, `exec sudo -u "$RUNNER_USER" -H ./run.sh`) {
		t.Fatalf("remote incus bootstrap took the Tart foreground path:\n%s", text)
	}
}

// A remote tart-macos guest already got the complete macOS script (selected
// by OS type); it must still, with the overrides.
func TestRemoteTartMacOSStillRendersCompleteScriptWithGuestURLs(t *testing.T) {
	text := remoteCreateUserData(t, "tart-macos", commonParams.OSType("macos"), "osx")
	if strings.Contains(text, "install-script") || strings.Contains(text, "100.64.0.1") {
		t.Fatalf("remote tart-macos bootstrap fetches a second stage or names the controller URL:\n%s", text)
	}
	if !strings.Contains(text, remoteGuestMetadataURL) || !strings.Contains(text, remoteGuestCallbackURL) {
		t.Fatalf("remote tart-macos bootstrap lacks the guest URL overrides:\n%s", text)
	}
}
