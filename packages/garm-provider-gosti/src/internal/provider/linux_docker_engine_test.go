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

// No mocks: these tests render the real templates. The fragment's runtime
// behaviour (download, units, `docker run` as the runner user) needs a
// systemd guest and the network, and is exercised outside `go test` in an
// Incus container and, after deployment, by infra's m3 ARM self-test.
package provider

import (
	"os/exec"
	"regexp"
	"strings"
	"testing"

	commonParams "github.com/cloudbase/garm-provider-common/params"

	"github.com/metacraft-labs/garm-provider-gosti/internal/config"
)

func linuxArmBootstrapParams(labels ...string) commonParams.BootstrapInstance {
	return commonParams.BootstrapInstance{
		Name:             "garm-linux-docker-1",
		RepoURL:          "https://github.com/example-org/example-repo",
		CallbackURL:      "https://garm.example.test/api/v1/callbacks",
		MetadataURL:      "https://garm.example.test/api/v1/metadata",
		InstanceToken:    "instance-token",
		OSType:           commonParams.Linux,
		OSArch:           commonParams.Arm64,
		Labels:           labels,
		JitConfigEnabled: true,
		Tools: []commonParams.RunnerApplicationDownload{
			{
				OS:             strptr("linux"),
				Architecture:   strptr("arm64"),
				DownloadURL:    strptr("https://example.invalid/linux.tar.gz"),
				Filename:       strptr("actions-runner-linux-arm64.tar.gz"),
				SHA256Checksum: strptr(""),
			},
		},
	}
}

func renderLinuxBootstrapFor(t *testing.T, backend config.BackendKind) string {
	t.Helper()
	params := linuxArmBootstrapParams("self-hosted", "linux", "arm64")
	tools, err := pickTools(params)
	if err != nil {
		t.Fatal(err)
	}
	script, err := renderRunnerBootstrapForBackend(backend, params, tools, params.Name)
	if err != nil {
		t.Fatal(err)
	}
	return string(script)
}

// Every eph-linux-arm64 guest must get a Docker Engine its runner user can
// reach (fleet policy: container support is universal), installed before the
// runner registers and starts.
func TestTartLinuxBootstrapProvisionsDockerEngine(t *testing.T) {
	text := renderLinuxBootstrapFor(t, config.BackendTartLinuxArm)

	if !strings.Contains(text, linuxDockerEngineSetup) {
		t.Fatalf("tart-linux-arm bootstrap does not contain the Docker Engine setup:\n%s", text)
	}
	for _, want := range []string{
		`usermod -aG docker "$RUNNER_USER"`,
		"SocketGroup=docker",
		"systemctl enable --now containerd.service docker.socket docker.service",
		`sudo -u "$RUNNER_USER" -H docker info`,
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("tart-linux-arm bootstrap missing %q", want)
		}
	}

	setup := strings.Index(text, "\nensure_docker_engine\n")
	deps := strings.Index(text, "./bin/installdependencies.sh")
	creds := strings.Index(text, `get_metadata_file "credentials/runner"`)
	run := strings.Index(text, `exec sudo -u "$RUNNER_USER" -H ./run.sh`)
	if setup < 0 || deps < 0 || creds < 0 || run < 0 {
		t.Fatalf("missing an anchor (setup=%d deps=%d creds=%d run=%d):\n%s", setup, deps, creds, run, text)
	}
	// After the runner's own apt dependencies (no concurrent dpkg), before the
	// JIT credentials are written: a guest whose Docker setup fails is marked
	// failed without ever registering a runner.
	if !(deps < setup && setup < creds && creds < run) {
		t.Fatalf("Docker setup out of order (deps=%d setup=%d creds=%d run=%d)", deps, setup, creds, run)
	}
}

// A central-GARM remote tart-linux-arm guest (m3-tart-linux) is rendered by
// the same template, so it gets Docker too.
func TestRemoteTartLinuxBootstrapProvisionsDockerEngine(t *testing.T) {
	text := remoteCreateUserData(t, "tart-linux-arm", commonParams.Linux, "linux")
	if !strings.Contains(text, linuxDockerEngineSetup) {
		t.Fatalf("remote tart-linux-arm bootstrap does not contain the Docker Engine setup:\n%s", text)
	}
}

// The fragment is for the Tart Linux class only. Incus guests get Docker from
// their golden image (and run unprivileged, where this setup would be wrong),
// and macOS/Windows guests are not Linux.
func TestDockerEngineSetupIsTartLinuxOnly(t *testing.T) {
	text := renderLinuxBootstrapFor(t, config.BackendIncus)
	if strings.Contains(text, "ensure_docker_engine") {
		t.Fatalf("non-Tart Linux bootstrap must not carry the Tart Docker setup:\n%s", text)
	}
}

// The pinned version and both checksums are well formed, and the version is
// the one the eph-linux-x64 golden bakes (gosti
// guest-recipes/linux-x64-runner/build-runner-image.sh DOCKER_VERSION default).
func TestDockerEnginePinIsWellFormed(t *testing.T) {
	for _, re := range []string{
		`(?m)^DOCKER_ENGINE_VERSION="27\.5\.1"$`,
		`(?m)^DOCKER_ENGINE_SHA256_AARCH64="[0-9a-f]{64}"$`,
		`(?m)^DOCKER_ENGINE_SHA256_X86_64="[0-9a-f]{64}"$`,
	} {
		if !regexp.MustCompile(re).MatchString(linuxDockerEngineSetup) {
			t.Fatalf("Docker Engine pin does not match %s", re)
		}
	}
}

// The whole rendered script, Docker fragment included, must parse as bash.
func TestTartLinuxBootstrapIsValidBash(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash not available")
	}
	text := renderLinuxBootstrapFor(t, config.BackendTartLinuxArm)
	cmd := exec.Command(bash, "-n")
	cmd.Stdin = strings.NewReader(text)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("bash -n rejected the tart-linux-arm bootstrap: %v\n%s", err, out)
	}
}
