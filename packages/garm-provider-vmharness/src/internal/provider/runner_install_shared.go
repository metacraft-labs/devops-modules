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

package provider

// Runner-install surface shared with sibling providers in this Go module.
//
// garm-provider-agentharbor (cmd/garm-provider-agentharbor) launches runners
// through agent-harbor's direct sandbox-launch REST API instead of a VM
// backend. It must hand the sandbox the SAME JIT runner-install scripts this
// provider renders (GARM upstream's cloudconfig template plus the cached-runner
// version guard, and this package's own templates), so the templates live
// here once and are exported through the thin wrappers below rather than
// copied.

import (
	"fmt"

	commonParams "github.com/cloudbase/garm-provider-common/params"

	"github.com/metacraft-labs/garm-provider-vmharness/internal/config"
)

// PickTools selects the runner tools entry matching the bootstrap's OS/arch.
func PickTools(bootstrapParams commonParams.BootstrapInstance) (commonParams.RunnerApplicationDownload, error) {
	return pickTools(bootstrapParams)
}

// RenderUpstreamRunnerInstallScript renders GARM upstream's default runner
// install script (garm-provider-common cloudconfig, honouring a pool's
// `runner_install_template` extra spec) with the cached-runner version guard
// injected. The script expects root in a full guest OS (it creates the runner
// user and runs installdependencies.sh), so it suits VM substrates.
func RenderUpstreamRunnerInstallScript(bootstrapParams commonParams.BootstrapInstance, tools commonParams.RunnerApplicationDownload, runnerName string) ([]byte, error) {
	return renderRunnerBootstrapForBackend(config.BackendIncus, bootstrapParams, tools, runnerName)
}

// ApplyGuestURLOverrides replaces the metadata/callback URLs GARM hands the
// runner (and every occurrence inside the pool's cloudconfig extra specs) with
// the guest-reachable ones. Empty overrides leave the originals untouched.
func ApplyGuestURLOverrides(bootstrapParams commonParams.BootstrapInstance, metadataURL, callbackURL string) commonParams.BootstrapInstance {
	return applyGuestURLOverrides(bootstrapParams, &config.Config{
		GuestMetadataURL: metadataURL,
		GuestCallbackURL: callbackURL,
	})
}

// RenderLinuxSandboxRunnerInstallScript renders the rootless Linux runner
// install script for sandbox substrates (see linuxSandboxRunnerInstallTemplate).
func RenderLinuxSandboxRunnerInstallScript(bootstrapParams commonParams.BootstrapInstance, tools commonParams.RunnerApplicationDownload, runnerName string) ([]byte, error) {
	if bootstrapParams.OSType != commonParams.Linux {
		return nil, fmt.Errorf("the sandbox runner template supports linux only, not %q", bootstrapParams.OSType)
	}
	if tools.GetFilename() == "" {
		return nil, fmt.Errorf("missing tools filename")
	}
	if tools.GetDownloadURL() == "" {
		return nil, fmt.Errorf("missing tools download URL")
	}
	return renderRunnerInstallTemplate("linux-sandbox-runner-install", linuxSandboxRunnerInstallTemplate, runnerInstallTemplateDataFrom(bootstrapParams, tools, runnerName))
}

// linuxSandboxRunnerInstallTemplate is linuxForegroundRunnerInstallTemplate
// minus everything that needs root. An agent-harbor `local-sandbox` job runs as
// the ah service user in a static, default-deny sandbox whose only writable
// directory is the job's fresh per-job workspace (its working directory), so
// the script cannot create a runner user, write /etc/sudoers.d or run the
// runner's apt-based installdependencies.sh. It installs the runner inside the
// workspace instead; ah deletes the workspace when the job ends, which is what
// makes the runner leave no residue. The runner's native dependencies (ICU,
// etc.) must therefore already be available to the sandbox from the host.
//
// The runner is ephemeral (a JIT config, or --ephemeral), so run.sh serves one
// job and exits; the sandbox job then exits and ah frees it.
const linuxSandboxRunnerInstallTemplate = `#!/bin/bash
set -e
set -o pipefail
{{- if .EnableBootDebug }}
set -x
{{- end }}

CALLBACK_URL={{ shell .CallbackURL }}
METADATA_URL={{ shell .MetadataURL }}
BEARER_TOKEN={{ shell .CallbackToken }}
RUN_HOME="${PWD}/actions-runner"

call_status() {
	payload="$1"
	case "$CALLBACK_URL" in
		*/status|*/status/) status_url="$CALLBACK_URL" ;;
		*) status_url="${CALLBACK_URL}/status" ;;
	esac
	curl --retry 5 --retry-delay 5 --retry-connrefused --fail -s \
		-X POST -d "$payload" \
		-H 'Accept: application/json' \
		-H "Authorization: Bearer ${BEARER_TOKEN}" \
		"$status_url" >/dev/null || true
}

status() {
	msg=$(printf '%s' "$1" | sed 's/"/\\"/g')
	call_status "{\"status\":\"installing\",\"message\":\"$msg\"}"
}

fail() {
	msg=$(printf '%s' "$1" | sed 's/"/\\"/g')
	call_status "{\"status\":\"failed\",\"message\":\"$msg\"}"
	exit 1
}

get_metadata_file() {
	path="$1"
	dest="$2"
	curl --retry 5 --retry-delay 5 --retry-connrefused --fail -s \
		-X GET -H 'Accept: application/json' \
		-H "Authorization: Bearer ${BEARER_TOKEN}" \
		"${METADATA_URL}/${path}" -o "$dest"
}

send_system_info() {
	os_name=""
	os_version=""
	if [ -f /etc/os-release ]; then
		. /etc/os-release
		os_name="${NAME:-}"
		os_version="${VERSION_ID:-}"
	fi
	base_url="$CALLBACK_URL"
	case "$base_url" in
		*/status) base_url="${base_url%/status}" ;;
		*/status/) base_url="${base_url%/status/}" ;;
	esac
	curl --retry 5 --retry-delay 5 --retry-connrefused --fail -s \
		-X POST -d "{\"os_name\":\"${os_name}\",\"os_version\":\"${os_version}\",\"agent_id\":null}" \
		-H 'Accept: application/json' \
		-H "Authorization: Bearer ${BEARER_TOKEN}" \
		"${base_url}/system-info/" >/dev/null || true
}

if [ -z "$METADATA_URL" ]; then
	fail "missing metadata URL"
fi
mkdir -p "$RUN_HOME"

{{ .BashRunnerVersionGuard }}
if [ ! -x "$RUN_HOME/run.sh" ]; then
	status "downloading tools from {{ .DownloadURL }}"
	tmp_archive="$(mktemp "${RUN_HOME}.archive.XXXXXX")"
	temp_header=""
	if [ -n {{ shell .TempDownloadToken }} ]; then
		temp_header="Authorization: Bearer {{ .TempDownloadToken }}"
	fi
	curl --retry 5 --retry-delay 5 --retry-connrefused --fail -L \
		-H "$temp_header" -o "$tmp_archive" {{ shell .DownloadURL }} || fail "failed to download tools"
	{{- if .SHA256Checksum }}
	printf '%s  %s\n' {{ shell .SHA256Checksum }} "$tmp_archive" | sha256sum -c - || fail "runner checksum mismatch"
	{{- end }}
	status "extracting runner"
	tar xf "$tmp_archive" -C "$RUN_HOME"/ || fail "failed to extract runner"
	rm -f "$tmp_archive"
fi

cd "$RUN_HOME"
status "configuring runner"
{{- if .UseJITConfig }}
status "downloading JIT credentials"
get_metadata_file "credentials/runner" "$RUN_HOME/.runner" || fail "failed to get runner file"
get_metadata_file "credentials/credentials" "$RUN_HOME/.credentials" || fail "failed to get credentials file"
get_metadata_file "credentials/credentials_rsaparams" "$RUN_HOME/.credentials_rsaparams" || fail "failed to get credentials_rsaparams file"
{{- else }}
GITHUB_TOKEN=$(curl --retry 5 --retry-delay 5 --retry-connrefused --fail -s \
	-X GET -H 'Accept: application/json' \
	-H "Authorization: Bearer ${BEARER_TOKEN}" \
	"${METADATA_URL}/runner-registration-token/") || fail "failed to get registration token"
set +e
attempt=1
while :; do
	errout="$(mktemp "${RUN_HOME}.config-err.XXXXXX")"
	if ./config.sh --unattended --url {{ shell .RepoURL }} --token "$GITHUB_TOKEN" \
		{{- if .GitHubRunnerGroup }} --runnergroup {{ shell .GitHubRunnerGroup }}{{- end }} \
		--name {{ shell .RunnerName }} --labels {{ shell .RunnerLabels }} --no-default-labels --ephemeral 2>"$errout"; then
		rm -f "$errout"
		break
	fi
	last_err="$(cat "$errout")"
	rm -f "$errout"
	./config.sh remove --token "$GITHUB_TOKEN" >/dev/null 2>&1 || true
	if [ "$attempt" -ge 5 ]; then
		set -e
		fail "failed to configure runner: $last_err"
	fi
	status "failed to configure runner, retrying"
	attempt=$((attempt + 1))
	sleep 5
done
set -e
{{- end }}

send_system_info
call_status '{"status":"idle","message":"runner configured"}'
exec ./run.sh
`
