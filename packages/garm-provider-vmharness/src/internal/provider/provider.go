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

// Package provider implements GARM's v0.1.1 external-provider interface for the
// vmharness backend. It is STATELESS: no lifecycle state is persisted here —
// GARM's DB owns it — and every query recomputes from the libvirt backend via
// the domain <metadata> tags (controller_id / pool_id / name).
package provider

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"text/template"
	"time"

	"github.com/cloudbase/garm-provider-common/cloudconfig"
	garmErrors "github.com/cloudbase/garm-provider-common/errors"
	commonExecution "github.com/cloudbase/garm-provider-common/execution/common"
	commonParams "github.com/cloudbase/garm-provider-common/params"

	"github.com/metacraft-labs/garm-provider-vmharness/internal/backend"
	"github.com/metacraft-labs/garm-provider-vmharness/internal/config"
	"github.com/metacraft-labs/garm-provider-vmharness/internal/version"
)

// Provider implements executionv011.ExternalProvider.
type Provider struct {
	cfg     *config.Config
	backend backend.Backend
}

// New builds a Provider from the config file path GARM passes via
// GARM_PROVIDER_CONFIG_FILE.
func New(configFile string) (*Provider, error) {
	cfg, err := config.Parse(configFile)
	if err != nil {
		return nil, err
	}
	return NewWithConfig(cfg)
}

// NewWithConfig builds a Provider from an already-parsed config, wiring the
// backend the config selects. Exposed for tests.
func NewWithConfig(cfg *config.Config) (*Provider, error) {
	if cfg.Remote != nil && (cfg.Remote.IncusSecurityNesting || cfg.Remote.IncusNestedKvm) &&
		(cfg.Backend != config.BackendRemote || cfg.Remote.TargetBackend != string(config.BackendIncus)) {
		return nil, fmt.Errorf("remote Incus capabilities require backend %q with target backend %q", config.BackendRemote, config.BackendIncus)
	}
	var b backend.Backend
	switch cfg.Backend {
	case config.BackendLibvirt:
		b = &backend.VirshBackend{
			VirshPath:         cfg.VirshPath,
			URI:               cfg.LibvirtURI,
			VMHarnessPath:     cfg.VMHarnessPath,
			PoolDir:           cfg.PoolDir,
			QemuImgPath:       cfg.QemuImgPath,
			UEFILoader:        cfg.UEFILoader,
			UEFINVRAMTemplate: cfg.UEFINVRAMTemplate,
			MemoryMB:          cfg.MemoryMB,
			VCPUs:             cfg.VCPUs,
			CurrentMemoryMB:   cfg.CurrentMemoryMB,
		}
	case config.BackendIncus:
		b = &backend.IncusBackend{
			IncusCmd:       strings.Fields(cfg.IncusPath),
			Bridge:         cfg.IncusBridge,
			IPv4CIDR:       cfg.IncusIPv4CIDR,
			IPv4Gateway:    cfg.IncusIPv4Gateway,
			RangeStart:     incusRangeStart(cfg),
			RangeEnd:       incusRangeEnd(cfg),
			Nameservers:    cfg.IncusNameservers,
			GpuPassthrough: cfg.IncusGpuPassthrough,

			ShareHostNixStore:        cfg.IncusShareHostNixStore,
			ReprobuildStore:          cfg.IncusReprobuildStore,
			ReprobuildStoreGuestPath: cfg.IncusReprobuildStoreGuestPath,
			SecurityNesting:          cfg.IncusSecurityNesting,
			NestedKvm:                cfg.IncusNestedKvm,
			LimitsCPU:                cfg.IncusLimitsCPU,
		}
	case config.BackendTartLinuxArm:
		b = &backend.VMHarnessRunBackend{
			VMHarnessPath: cfg.VMHarnessPath,
			BackendID:     string(config.BackendTartLinuxArm),
			GuestOS:       "linux",
			StateDir:      cfg.StateDir,
		}
	case config.BackendTartMacos:
		b = &backend.VMHarnessRunBackend{
			VMHarnessPath: cfg.VMHarnessPath,
			BackendID:     string(config.BackendTartMacos),
			GuestOS:       "macos",
			StateDir:      cfg.StateDir,
		}
	case config.BackendUtmWindowsArm:
		b = &backend.VMHarnessRunBackend{
			VMHarnessPath: cfg.VMHarnessPath,
			BackendID:     string(config.BackendUtmWindowsArm),
			GuestOS:       "windows",
			StateDir:      cfg.StateDir,
		}
	case config.BackendQemuWindowsArm:
		b = &backend.VMHarnessRunBackend{
			VMHarnessPath: cfg.VMHarnessPath,
			BackendID:     string(config.BackendQemuWindowsArm),
			GuestOS:       "windows",
			StateDir:      cfg.StateDir,
		}
	case config.BackendRemote:
		// RB1 remote-target mode: an RPC client to a remote `vm-harness serve`
		// daemon instead of a local-exec backend. The bearer token is resolved
		// at construction from the inline value / token file / env (agenix /
		// LoadCredential friendly); a stateless RemoteBackend then drives the
		// remote lifecycle over the RA1 protocol.
		if cfg.Remote == nil {
			return nil, fmt.Errorf("backend %q requires a [remote] section", cfg.Backend)
		}
		token, err := cfg.Remote.ResolveToken()
		if err != nil {
			return nil, err
		}
		b = &backend.RemoteBackend{
			Client: backend.NewServeClient(
				cfg.Remote.Endpoint, token,
				time.Duration(cfg.Remote.RequestTimeoutSec)*time.Second),
			TargetBackend:        cfg.Remote.TargetBackend,
			GuestOS:              cfg.Remote.GuestOS,
			IncusSecurityNesting: cfg.Remote.IncusSecurityNesting,
			IncusNestedKvm:       cfg.Remote.IncusNestedKvm,
		}
	default:
		return nil, fmt.Errorf("unsupported backend %q", cfg.Backend)
	}
	return &Provider{cfg: cfg, backend: b}, nil
}

// incusRangeStart/End default the static-IP allocation range to the .200-.250
// host block of the configured /24 when the operator did not set explicit
// bounds (keeps single-image pools configuration-light while staying clear of
// the low DHCP block and the gateway).
func incusRangeStart(cfg *config.Config) string {
	if cfg.IncusIPv4RangeStart != "" {
		return cfg.IncusIPv4RangeStart
	}
	return subnetHost(cfg.IncusIPv4CIDR, 200)
}

func incusRangeEnd(cfg *config.Config) string {
	if cfg.IncusIPv4RangeEnd != "" {
		return cfg.IncusIPv4RangeEnd
	}
	return subnetHost(cfg.IncusIPv4CIDR, 250)
}

// subnetHost returns the a.b.c.<host> address for the /24 the CIDR names.
func subnetHost(cidr string, host int) string {
	base := cidr
	if i := strings.LastIndex(base, "/"); i >= 0 {
		base = base[:i]
	}
	parts := strings.Split(base, ".")
	if len(parts) != 4 {
		return ""
	}
	return fmt.Sprintf("%s.%s.%s.%d", parts[0], parts[1], parts[2], host)
}

// osTypeToParams maps a backend Instance to a commonParams.ProviderInstance.
func toProviderInstance(inst backend.Instance) commonParams.ProviderInstance {
	osType := commonParams.Windows
	// The incus/Linux path tags os_name "linux"; the libvirt/Windows path
	// tags "windows". The Tart macOS path reports "macos"; garm-provider-common
	// carries OSType as a string alias, so preserve that value even though this
	// vendored version only declares Linux/Windows constants.
	if strings.EqualFold(inst.OSName, "linux") {
		osType = commonParams.Linux
	} else if strings.EqualFold(inst.OSName, "macos") || strings.EqualFold(inst.OSName, "darwin") {
		osType = commonParams.OSType("macos")
	}
	osArch := commonParams.Amd64
	if strings.EqualFold(inst.OSArch, "arm64") || strings.EqualFold(inst.OSArch, "aarch64") {
		osArch = commonParams.Arm64
	}
	pi := commonParams.ProviderInstance{
		ProviderID: inst.ProviderID,
		Name:       inst.Name,
		OSType:     osType,
		OSName:     inst.OSName,
		OSVersion:  inst.OSVersion,
		OSArch:     osArch,
		Status:     commonParams.InstanceStatus(inst.Status),
	}
	for _, addr := range inst.Addresses {
		pi.Addresses = append(pi.Addresses, commonParams.Address{
			Address: addr,
			Type:    commonParams.PrivateAddress,
		})
	}
	if pi.Status == "" {
		pi.Status = commonParams.InstanceStatusUnknown
	}
	return pi
}

// pickTools selects the runner tools matching the bootstrap's OS/arch.
func pickTools(bootstrapParams commonParams.BootstrapInstance) (commonParams.RunnerApplicationDownload, error) {
	wantOS := "win"
	switch bootstrapParams.OSType {
	case commonParams.Linux:
		wantOS = "linux"
	case commonParams.Windows:
		wantOS = "win"
	case commonParams.OSType("macos"):
		wantOS = "osx"
	}
	wantArch := "x64"
	switch bootstrapParams.OSArch {
	case commonParams.Arm64:
		wantArch = "arm64"
	case commonParams.Arm:
		wantArch = "arm"
	}
	for _, t := range bootstrapParams.Tools {
		if t.GetOS() == wantOS && t.GetArchitecture() == wantArch {
			return t, nil
		}
	}
	return commonParams.RunnerApplicationDownload{}, fmt.Errorf("no tools for os=%s arch=%s", wantOS, wantArch)
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'"
}

func powershellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}

const macosRunnerInstallTemplate = `#!/bin/sh
set -eu

CALLBACK_URL={{ shell .CallbackURL }}
METADATA_URL={{ shell .MetadataURL }}
BEARER_TOKEN={{ shell .CallbackToken }}
RUN_HOME="$HOME/actions-runner"

# Cirrus' Apple-silicon base already contains Homebrew, GitHub CLI, and Git
# LFS, but non-login SSH sessions omit Homebrew from PATH. Keep those tools
# visible to the runner and expose the guest-local Nix profile installed below.
export PATH="/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:${PATH}"

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

if [ -z "$METADATA_URL" ]; then
	fail "missing metadata URL"
fi

status "preparing macOS runner toolchain"
command -v gh >/dev/null 2>&1 || fail "GitHub CLI is missing from the macOS image"
command -v git-lfs >/dev/null 2>&1 || fail "Git LFS is missing from the macOS image"

# The macOS backend deliberately does not attach the host's read-only
# /nix/store. Install Nix into the ephemeral guest so actions that use the
# standard Determinate setup detect a healthy, writable daemon-backed store.
if ! command -v nix >/dev/null 2>&1; then
	status "installing guest-local Nix"
	nix_installer="$(mktemp "${TMPDIR:-/tmp}/nix-installer.XXXXXX")"
	curl --proto '=https' --tlsv1.2 --retry 5 --retry-delay 5 --retry-connrefused --fail -sSL \
		https://install.determinate.systems/nix -o "$nix_installer" || fail "failed to download Nix installer"
	# Select the macOS planner explicitly. The generic planner currently defaults
	# to an encrypted APFS volume, whose post-create mount fails in cloned Tart
	# guests. These VMs are ephemeral, so the macOS planner's unencrypted volume
	# is both sufficient and reliably mountable.
	sh "$nix_installer" install macos --no-confirm --prefer-upstream-nix --encrypt false || fail "failed to install guest-local Nix"
	rm -f "$nix_installer"
fi
command -v nix >/dev/null 2>&1 || fail "Nix is unavailable after installation"

mkdir -p "$RUN_HOME"
cd "$RUN_HOME"

if [ ! -x ./run.sh ]; then
	status "downloading tools from {{ .DownloadURL }}"
	tmp_archive="$(mktemp "${TMPDIR:-/tmp}/actions-runner.XXXXXX")"
	temp_header=""
	if [ -n {{ shell .TempDownloadToken }} ]; then
		temp_header="Authorization: Bearer {{ .TempDownloadToken }}"
	fi
	curl --retry 5 --retry-delay 5 --retry-connrefused --fail -L \
		-H "$temp_header" -o "$tmp_archive" {{ shell .DownloadURL }} || fail "failed to download tools"
	{{- if .SHA256Checksum }}
	printf '%s  %s\n' {{ shell .SHA256Checksum }} "$tmp_archive" | shasum -a 256 -c - || fail "runner checksum mismatch"
	{{- end }}
	status "extracting runner"
	tar xzf "$tmp_archive" -C "$RUN_HOME" || fail "failed to extract runner"
	rm -f "$tmp_archive"
fi

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
attempt=1
while :; do
	errout="$(mktemp "${TMPDIR:-/tmp}/runner-config.XXXXXX")"
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
		fail "failed to configure runner: $last_err"
	fi
	status "failed to configure runner, retrying"
	attempt=$((attempt + 1))
	sleep 5
done
{{- end }}

call_status '{"status":"idle","message":"runner configured"}'
exec ./run.sh
`

const linuxForegroundRunnerInstallTemplate = `#!/bin/bash
set -e
set -o pipefail
{{- if .EnableBootDebug }}
set -x
{{- end }}

CALLBACK_URL={{ shell .CallbackURL }}
METADATA_URL={{ shell .MetadataURL }}
BEARER_TOKEN={{ shell .CallbackToken }}
RUNNER_USER="runner"
RUNNER_GROUP="runner"
RUNNER_HOME="/home/${RUNNER_USER}"
RUN_HOME="${RUNNER_HOME}/actions-runner"

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

if [ "$(id -u)" -ne 0 ]; then
	exec sudo -E bash "$0" "$@"
fi
if [ -z "$METADATA_URL" ]; then
	fail "missing metadata URL"
fi
if ! getent group "$RUNNER_GROUP" >/dev/null 2>&1; then
	groupadd "$RUNNER_GROUP"
fi
if ! id -u "$RUNNER_USER" >/dev/null 2>&1; then
	useradd -m -s /bin/bash -g "$RUNNER_GROUP" "$RUNNER_USER"
fi
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$RUNNER_USER" > "/etc/sudoers.d/90-garm-${RUNNER_USER}"
chmod 0440 "/etc/sudoers.d/90-garm-${RUNNER_USER}"
mkdir -p "$RUN_HOME"

if [ ! -x "$RUN_HOME/run.sh" ]; then
	status "downloading tools from {{ .DownloadURL }}"
	tmp_archive="$(mktemp /tmp/actions-runner.XXXXXX)"
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

chown "$RUNNER_USER:$RUNNER_GROUP" -R "$RUNNER_HOME" || fail "failed to change runner home owner"
status "installing dependencies"
cd "$RUN_HOME"
attempt=1
while :; do
	if ./bin/installdependencies.sh; then
		break
	fi
	if [ "$attempt" -ge 5 ]; then
		fail "failed to install dependencies after $attempt attempts"
	fi
	status "failed to install dependencies, retrying"
	attempt=$((attempt + 1))
	sleep 15
done

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
	errout="$(mktemp /tmp/runner-config.XXXXXX)"
	if sudo -u "$RUNNER_USER" -H "$RUN_HOME/config.sh" --unattended --url {{ shell .RepoURL }} --token "$GITHUB_TOKEN" \
		{{- if .GitHubRunnerGroup }} --runnergroup {{ shell .GitHubRunnerGroup }}{{- end }} \
		--name {{ shell .RunnerName }} --labels {{ shell .RunnerLabels }} --no-default-labels --ephemeral 2>"$errout"; then
		rm -f "$errout"
		break
	fi
	last_err="$(cat "$errout")"
	rm -f "$errout"
	sudo -u "$RUNNER_USER" -H "$RUN_HOME/config.sh" remove --token "$GITHUB_TOKEN" >/dev/null 2>&1 || true
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

chown "$RUNNER_USER:$RUNNER_GROUP" -R "$RUNNER_HOME" || fail "failed to change runner home owner"
send_system_info
call_status '{"status":"idle","message":"runner configured"}'
cd "$RUN_HOME"
exec sudo -u "$RUNNER_USER" -H ./run.sh
`

const windowsForegroundRunnerInstallTemplate = `#ps1_sysnative
$ErrorActionPreference = 'Stop'

$CallbackURL={{ ps .CallbackURL }}
$MetadataURL={{ ps .MetadataURL }}
$BearerToken={{ ps .CallbackToken }}
$RunHome='C:\actions-runner'
$DownloadURL={{ ps .DownloadURL }}
$TempDownloadToken={{ ps .TempDownloadToken }}
$SHA256Checksum={{ ps .SHA256Checksum }}

function Get-CallbackStatusURL {
	if ($CallbackURL.EndsWith('/status') -or $CallbackURL.EndsWith('/status/')) {
		return $CallbackURL
	}
	return "$CallbackURL/status"
}

function Get-CallbackBaseURL {
	if ($CallbackURL.EndsWith('/status/')) {
		return $CallbackURL.Substring(0, $CallbackURL.Length - 8)
	}
	if ($CallbackURL.EndsWith('/status')) {
		return $CallbackURL.Substring(0, $CallbackURL.Length - 7)
	}
	return $CallbackURL.TrimEnd('/')
}

function Invoke-GarmCallback {
	param([string]$Path, [string]$Body)
	$baseURL = Get-CallbackBaseURL
	$uri = "$baseURL/$Path"
	Invoke-WebRequest -UseBasicParsing -Method Post -Uri $uri -Headers @{Accept='application/json'; Authorization="Bearer $BearerToken"} -ContentType 'application/json' -Body $Body | Out-Null
}

function Send-Status {
	param([string]$Status, [string]$Message)
	$body = @{
		status = $Status
		message = $Message
	} | ConvertTo-Json -Compress
	Invoke-WebRequest -UseBasicParsing -Method Post -Uri (Get-CallbackStatusURL) -Headers @{Accept='application/json'; Authorization="Bearer $BearerToken"} -ContentType 'application/json' -Body $body | Out-Null
}

function Fail-Install {
	param([string]$Message)
	try {
		Send-Status -Status 'failed' -Message $Message
	} catch {
		Write-Host "failed to report install failure: $($_.Exception.Message)"
	}
	Write-Host $Message
	exit 1
}

function Invoke-FileDownload {
	param(
		[string]$Uri,
		[hashtable]$Headers=@{},
		[string]$Destination,
		[int]$MaxAttempts=5
	)
	for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
		try {
			Remove-Item -Force $Destination -ErrorAction SilentlyContinue
			Invoke-WebRequest -UseBasicParsing -Method Get -Uri $Uri -Headers $Headers -OutFile $Destination
			return
		} catch {
			Remove-Item -Force $Destination -ErrorAction SilentlyContinue
			if ($attempt -ge $MaxAttempts) {
				throw
			}
			$delay = [Math]::Min(30, [Math]::Pow(2, $attempt))
			Write-Host "download attempt $attempt failed for $Uri; retrying in $delay seconds: $($_.Exception.Message)"
			Start-Sleep -Seconds $delay
		}
	}
}

function Get-MetadataFile {
	param([string]$Path, [string]$Destination)
	Invoke-FileDownload -Uri "$MetadataURL/$Path" -Headers @{Accept='application/json'; Authorization="Bearer $BearerToken"} -Destination $Destination
}

function Send-SystemInfo {
	try {
		$os = Get-CimInstance -ClassName Win32_OperatingSystem
		$osName = if ($os.Caption) { $os.Caption } else { 'windows' }
		$osVersion = if ($os.Version) { $os.Version } else { '' }
		$body = @{
			os_name = $osName
			os_version = $osVersion
			agent_id = $null
		} | ConvertTo-Json -Compress
		Invoke-GarmCallback -Path 'system-info/' -Body $body
	} catch {
		Write-Host "failed to send system info: $($_.Exception.Message)"
	}
}

# The eph-win-x64 golden ships neither git nor bash. That breaks two
# separate things, and only one of them can be fixed by a workflow step:
#
#   * every 'shell: bash' step dies with "bash: command not found";
#   * actions/checkout finds no git and silently degrades to a REST-API zip
#     download, which has no submodules, no history, and no LFS.
#
# The second is why this belongs HERE rather than in a workflow. actions/
# checkout is normally the first step of a job, so no action of ours runs
# before it -- but this template does. It executes in the guest during
# provisioning, before Runner.Listener is started, so the PATH it sets is
# inherited by the runner process and therefore by every step of the job,
# including checkout.
#
# The image itself remains the right long-term home for these tools (see
# guest-recipes/windows-x64-base/cloudbase-init-golden.md); this template
# stays correct either way, because it installs only when the tools are
# absent and otherwise just verifies. When a golden that ships git lands,
# this becomes a cheap assertion rather than a download.
#
# The pin below is the same PortableGit the persistent win-ci-vm-001 runner
# already uses (infra machines/server/_win-ci-vm-001/system_windows_runner.nim);
# keeping one pin for both Windows runner classes means one thing to bump.
# PortableGit rather than MinGit: MinGit satisfies actions/checkout and still
# leaves every bash step dead, which is exactly the half-fix to avoid.
$PortableGitVersion = '2.47.1'
$PortableGitName = "PortableGit-$PortableGitVersion-64-bit.7z.exe"
$PortableGitUrl = "https://github.com/git-for-windows/git/releases/download/v$PortableGitVersion.windows.1/$PortableGitName"
$PortableGitSha256 = '4f3f21f4effcb659566883ee1ed3ae403e5b3d7a0699cee455f6cd765e1ac39c'
$PortableGitInstallDir = 'C:\PortableGit'

function Test-RunnerToolchain {
	$git = Get-Command git -ErrorAction SilentlyContinue
	if ($null -eq $git) {
		return $false
	}
	$bash = Get-Command bash -ErrorAction SilentlyContinue
	if ($null -eq $bash) {
		return $false
	}
	# A bash.exe that is the WSL stub in System32 is worse than none: it is on
	# PATH, it launches, and it fails only once a step tries to use it.
	if ($bash.Source -like "$env:SystemRoot\System32\*") {
		return $false
	}
	return $true
}

function Add-RunnerPathEntry {
	param([string]$Entry)
	if (-not (Test-Path -LiteralPath $Entry -PathType Container)) {
		Fail-Install "refusing to add a non-directory to PATH: $Entry"
	}
	$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
	$entries = @()
	if (-not [string]::IsNullOrWhiteSpace($machinePath)) {
		$entries = $machinePath.Split(';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
	}
	if ($entries -notcontains $Entry) {
		$updated = (@($Entry) + $entries) -join ';'
		[Environment]::SetEnvironmentVariable('Path', $updated, 'Machine')
	}
	# The machine PATH alone does not reach this already-running process, and
	# run.cmd inherits from this process. Set both.
	$env:PATH = "$Entry;$env:PATH"
}

function Install-RunnerToolchain {
	Send-Status -Status 'installing' -Message 'installing git and Git Bash'
	$archive = Join-Path $env:TEMP $PortableGitName
	Invoke-FileDownload -Uri $PortableGitUrl -Destination $archive
	$actualHash = (Get-FileHash -Algorithm SHA256 -Path $archive).Hash.ToLowerInvariant()
	if ($actualHash -ne $PortableGitSha256.ToLowerInvariant()) {
		Remove-Item -Force $archive -ErrorAction SilentlyContinue
		Fail-Install "PortableGit checksum mismatch: expected $PortableGitSha256 got $actualHash"
	}
	Remove-Item -Recurse -Force $PortableGitInstallDir -ErrorAction SilentlyContinue
	# PortableGit ships as a 7-Zip self-extractor; -y -o<dir> extracts silently.
	$process = Start-Process -FilePath $archive -ArgumentList '-y', "-o$PortableGitInstallDir" -Wait -PassThru -NoNewWindow
	Remove-Item -Force $archive -ErrorAction SilentlyContinue
	if ($process.ExitCode -ne 0) {
		Fail-Install "PortableGit extraction failed with exit code $($process.ExitCode)"
	}
	foreach ($sub in @('cmd', 'bin')) {
		Add-RunnerPathEntry (Join-Path $PortableGitInstallDir $sub)
	}
}

function Initialize-RunnerToolchain {
	if (-not (Test-RunnerToolchain)) {
		Install-RunnerToolchain
	}
	# Verify what is actually present rather than trusting either branch above.
	# An install that reported success but left the tools unusable is the same
	# silent-no-op class this whole block exists to end, so prove both tools
	# RUN -- Get-Command only proves a file was found.
	if (-not (Test-RunnerToolchain)) {
		Fail-Install 'git and Git Bash are still not on PATH after provisioning'
	}
	try {
		$gitVersion = (& git --version 2>&1 | Out-String).Trim()
	} catch {
		Fail-Install "git is on PATH but not executable: $($_.Exception.Message)"
	}
	try {
		$bashVersion = (& bash --version 2>&1 | Select-Object -First 1 | Out-String).Trim()
	} catch {
		Fail-Install "bash is on PATH but not executable: $($_.Exception.Message)"
	}
	if ([string]::IsNullOrWhiteSpace($gitVersion)) {
		Fail-Install 'git --version produced no output'
	}
	if ([string]::IsNullOrWhiteSpace($bashVersion)) {
		Fail-Install 'bash --version produced no output'
	}
	Write-Host "runner toolchain verified: $gitVersion"
	Write-Host "runner toolchain verified: $bashVersion"
	# git-lfs lives in PortableGit's cmd\ and its mingw bin\, but the golden put
	# only bin\ on PATH -- bin\ has bash/sh/git yet no git-lfs.exe. Because git
	# pre-exists, Install-RunnerToolchain never ran, so those dirs were never
	# added. actions/checkout with lfs:true then fails before fetching. Put the
	# directory that actually holds git-lfs.exe on PATH.
	#
	# THE MINGW DIRECTORY IS ARCH-SPECIFIC, and getting it wrong aborts the
	# instance rather than degrading it -- the check below is fatal. Git for
	# Windows names the directory after the toolchain that built it: mingw64\ on
	# x86_64, clangarm64\ on ARM64. Measured in the pinned
	# PortableGit-2.55.0.4-arm64 archive the Windows-ARM golden is provisioned
	# from, clangarm64/bin/git-lfs.exe is the only copy and there is no mingw64\
	# at all, so an x64-only candidate list takes the entire eph-win-arm64 lane
	# down. Keep both names.
	if ($null -eq (Get-Command git-lfs -ErrorAction SilentlyContinue)) {
		$gitSrc = (Get-Command git).Source
		$gitDir = Split-Path -Parent $gitSrc
		if ($gitDir -like '*\bin' -or $gitDir -like '*\cmd') {
			$root = Split-Path -Parent $gitDir
		} else {
			$root = $gitDir
		}
		$candidates = @(
			(Join-Path $root 'cmd'),
			(Join-Path $root 'clangarm64\bin'),
			(Join-Path $root 'mingw64\bin'),
			(Join-Path $PortableGitInstallDir 'cmd'),
			(Join-Path $PortableGitInstallDir 'clangarm64\bin'),
			(Join-Path $PortableGitInstallDir 'mingw64\bin')
		)
		foreach ($cand in $candidates) {
			if (Test-Path -LiteralPath (Join-Path $cand 'git-lfs.exe')) {
				Add-RunnerPathEntry $cand
				break
			}
		}
	}
	if ($null -eq (Get-Command git-lfs -ErrorAction SilentlyContinue)) {
		Fail-Install 'git-lfs is not on PATH after provisioning (golden may need a git-lfs retrofit)'
	}
	try {
		$gitLfsVersion = (& git-lfs version 2>&1 | Out-String).Trim()
	} catch {
		Fail-Install "git-lfs is on PATH but not executable: $($_.Exception.Message)"
	}
	if ([string]::IsNullOrWhiteSpace($gitLfsVersion)) {
		Fail-Install 'git-lfs version produced no output'
	}
	Write-Host "runner toolchain verified: $gitLfsVersion"
}

if ([string]::IsNullOrWhiteSpace($MetadataURL)) {
	Fail-Install 'missing metadata URL'
}
if ([string]::IsNullOrWhiteSpace($CallbackURL)) {
	Fail-Install 'missing callback URL'
}

New-Item -ItemType Directory -Force -Path $RunHome | Out-Null
Set-Location $RunHome

# Before the runner exists, and therefore before any job step -- including
# actions/checkout, which runs before any action of ours and is the reason this
# cannot be solved by a workflow step.
Initialize-RunnerToolchain

if (-not (Test-Path (Join-Path $RunHome 'run.cmd'))) {
	Send-Status -Status 'installing' -Message "downloading tools from {{ .DownloadURL }}"
	$archive = Join-Path $env:TEMP {{ ps .FileName }}
	$headers = @{}
	if (-not [string]::IsNullOrWhiteSpace($TempDownloadToken)) {
		$headers['Authorization'] = "Bearer $TempDownloadToken"
	}
	Invoke-FileDownload -Uri $DownloadURL -Headers $headers -Destination $archive
	{{- if .SHA256Checksum }}
	$actualHash = (Get-FileHash -Algorithm SHA256 -Path $archive).Hash.ToLowerInvariant()
	if ($actualHash -ne $SHA256Checksum.ToLowerInvariant()) {
		Fail-Install "runner checksum mismatch: $actualHash"
	}
	{{- end }}
	Send-Status -Status 'installing' -Message 'extracting runner'
	Expand-Archive -Path $archive -DestinationPath $RunHome -Force
	Remove-Item -Force $archive
}

Send-Status -Status 'installing' -Message 'configuring runner'
{{- if .UseJITConfig }}
Send-Status -Status 'installing' -Message 'downloading JIT credentials'
Get-MetadataFile -Path 'credentials/runner' -Destination (Join-Path $RunHome '.runner')
Get-MetadataFile -Path 'credentials/credentials' -Destination (Join-Path $RunHome '.credentials')
$rsaParamsPath = Join-Path $RunHome '.credentials_rsaparams'
$rsaParamsTmp = [System.IO.Path]::GetTempFileName()
try {
	Add-Type -AssemblyName System.Security
	Invoke-FileDownload -Uri "$MetadataURL/credentials/credentials_rsaparams" -Headers @{Accept='application/json'; Authorization="Bearer $BearerToken"} -Destination $rsaParamsTmp
	$rsaBytes = [System.IO.File]::ReadAllBytes($rsaParamsTmp)
	$protectedBytes = [System.Security.Cryptography.ProtectedData]::Protect($rsaBytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
	[System.IO.File]::WriteAllBytes($rsaParamsPath, $protectedBytes)
} finally {
	Remove-Item -Force $rsaParamsTmp -ErrorAction SilentlyContinue
}
{{- else }}
Fail-Install 'non-JIT Windows vm-harness runners are not supported'
{{- end }}

Send-SystemInfo
Send-Status -Status 'idle' -Message 'runner configured'

Set-Location $RunHome
& "$env:ComSpec" /d /c run.cmd
$runnerExitCode = $LASTEXITCODE
if ($null -eq $runnerExitCode) {
	$runnerExitCode = 0
}
if ($runnerExitCode -ne 0) {
	Fail-Install "runner exited with code $runnerExitCode"
}
`

type runnerInstallTemplateData struct {
	FileName          string
	DownloadURL       string
	TempDownloadToken string
	SHA256Checksum    string
	MetadataURL       string
	RepoURL           string
	RunnerName        string
	RunnerLabels      string
	CallbackURL       string
	CallbackToken     string
	GitHubRunnerGroup string
	UseJITConfig      bool
	EnableBootDebug   bool
}

func runnerInstallTemplateDataFrom(bootstrapParams commonParams.BootstrapInstance, tools commonParams.RunnerApplicationDownload, runnerName string) runnerInstallTemplateData {
	return runnerInstallTemplateData{
		FileName:          tools.GetFilename(),
		DownloadURL:       tools.GetDownloadURL(),
		TempDownloadToken: tools.GetTempDownloadToken(),
		SHA256Checksum:    tools.GetSHA256Checksum(),
		MetadataURL:       bootstrapParams.MetadataURL,
		RepoURL:           bootstrapParams.RepoURL,
		RunnerName:        runnerName,
		RunnerLabels:      strings.Join(bootstrapParams.Labels, ","),
		CallbackURL:       bootstrapParams.CallbackURL,
		CallbackToken:     bootstrapParams.InstanceToken,
		GitHubRunnerGroup: bootstrapParams.GitHubRunnerGroup,
		UseJITConfig:      bootstrapParams.JitConfigEnabled,
		EnableBootDebug:   bootstrapParams.UserDataOptions.EnableBootDebug,
	}
}

func renderRunnerInstallTemplate(name, text string, data runnerInstallTemplateData) ([]byte, error) {
	tpl, err := template.New(name).Funcs(template.FuncMap{
		"shell": shellQuote,
		"ps":    powershellQuote,
	}).Parse(text)
	if err != nil {
		return nil, err
	}
	var buf bytes.Buffer
	if err := tpl.Execute(&buf, data); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func renderMacOSRunnerInstallScript(bootstrapParams commonParams.BootstrapInstance, tools commonParams.RunnerApplicationDownload, runnerName string) ([]byte, error) {
	if tools.GetFilename() == "" {
		return nil, fmt.Errorf("missing tools filename")
	}
	if tools.GetDownloadURL() == "" {
		return nil, fmt.Errorf("missing tools download URL")
	}
	return renderRunnerInstallTemplate("macos-runner-install", macosRunnerInstallTemplate, runnerInstallTemplateDataFrom(bootstrapParams, tools, runnerName))
}

func renderLinuxRunnerInstallScript(bootstrapParams commonParams.BootstrapInstance, tools commonParams.RunnerApplicationDownload, runnerName string) ([]byte, error) {
	if tools.GetFilename() == "" {
		return nil, fmt.Errorf("missing tools filename")
	}
	if tools.GetDownloadURL() == "" {
		return nil, fmt.Errorf("missing tools download URL")
	}
	return renderRunnerInstallTemplate("linux-foreground-runner-install", linuxForegroundRunnerInstallTemplate, runnerInstallTemplateDataFrom(bootstrapParams, tools, runnerName))
}

func renderWindowsRunnerInstallScript(bootstrapParams commonParams.BootstrapInstance, tools commonParams.RunnerApplicationDownload, runnerName string) ([]byte, error) {
	if !bootstrapParams.JitConfigEnabled {
		return nil, fmt.Errorf("non-JIT Windows vm-harness runners are not supported")
	}
	if tools.GetFilename() == "" {
		return nil, fmt.Errorf("missing tools filename")
	}
	if tools.GetDownloadURL() == "" {
		return nil, fmt.Errorf("missing tools download URL")
	}
	return renderRunnerInstallTemplate("windows-foreground-runner-install", windowsForegroundRunnerInstallTemplate, runnerInstallTemplateDataFrom(bootstrapParams, tools, runnerName))
}

func isVMHarnessWindowsBackend(backendKind config.BackendKind) bool {
	return backendKind == config.BackendQemuWindowsArm || backendKind == config.BackendUtmWindowsArm
}

func renderRunnerBootstrapForBackend(backendKind config.BackendKind, bootstrapParams commonParams.BootstrapInstance, tools commonParams.RunnerApplicationDownload, runnerName string) ([]byte, error) {
	if bootstrapParams.OSType == commonParams.OSType("macos") {
		return renderMacOSRunnerInstallScript(bootstrapParams, tools, runnerName)
	}
	if backendKind == config.BackendTartLinuxArm && bootstrapParams.OSType == commonParams.Linux {
		return renderLinuxRunnerInstallScript(bootstrapParams, tools, runnerName)
	}
	if isVMHarnessWindowsBackend(backendKind) && bootstrapParams.OSType == commonParams.Windows {
		return renderWindowsRunnerInstallScript(bootstrapParams, tools, runnerName)
	}
	script, err := cloudconfig.GetRunnerInstallScript(bootstrapParams, tools, runnerName)
	if err != nil {
		return nil, err
	}
	return script, nil
}

func replaceURLInBytes(data []byte, oldURL, newURL string) []byte {
	if oldURL == "" || newURL == "" || oldURL == newURL {
		return data
	}
	return bytes.ReplaceAll(data, []byte(oldURL), []byte(newURL))
}

func replaceURLInString(data, oldURL, newURL string) string {
	if oldURL == "" || newURL == "" || oldURL == newURL {
		return data
	}
	return strings.ReplaceAll(data, oldURL, newURL)
}

func rewriteCloudConfigSpecURLs(raw json.RawMessage, oldMetadataURL, newMetadataURL, oldCallbackURL, newCallbackURL string) json.RawMessage {
	if len(raw) == 0 {
		return raw
	}
	var spec map[string]json.RawMessage
	if err := json.Unmarshal(raw, &spec); err != nil {
		return raw
	}

	if value, ok := spec["runner_install_template"]; ok {
		var script []byte
		if err := json.Unmarshal(value, &script); err == nil {
			script = replaceURLInBytes(script, oldMetadataURL, newMetadataURL)
			script = replaceURLInBytes(script, oldCallbackURL, newCallbackURL)
			if encoded, err := json.Marshal(script); err == nil {
				spec["runner_install_template"] = encoded
			}
		}
	}
	if value, ok := spec["pre_install_scripts"]; ok {
		var scripts map[string][]byte
		if err := json.Unmarshal(value, &scripts); err == nil {
			for name, script := range scripts {
				script = replaceURLInBytes(script, oldMetadataURL, newMetadataURL)
				script = replaceURLInBytes(script, oldCallbackURL, newCallbackURL)
				scripts[name] = script
			}
			if encoded, err := json.Marshal(scripts); err == nil {
				spec["pre_install_scripts"] = encoded
			}
		}
	}
	if value, ok := spec["extra_context"]; ok {
		var extraContext map[string]string
		if err := json.Unmarshal(value, &extraContext); err == nil {
			for key, value := range extraContext {
				value = replaceURLInString(value, oldMetadataURL, newMetadataURL)
				value = replaceURLInString(value, oldCallbackURL, newCallbackURL)
				extraContext[key] = value
			}
			if encoded, err := json.Marshal(extraContext); err == nil {
				spec["extra_context"] = encoded
			}
		}
	}

	rewritten, err := json.Marshal(spec)
	if err != nil {
		return raw
	}
	return rewritten
}

func applyGuestURLOverrides(bootstrapParams commonParams.BootstrapInstance, cfg *config.Config) commonParams.BootstrapInstance {
	if cfg == nil {
		return bootstrapParams
	}
	originalMetadataURL := bootstrapParams.MetadataURL
	originalCallbackURL := bootstrapParams.CallbackURL
	if cfg.GuestMetadataURL != "" {
		bootstrapParams.MetadataURL = cfg.GuestMetadataURL
	}
	if cfg.GuestCallbackURL != "" {
		bootstrapParams.CallbackURL = cfg.GuestCallbackURL
	}
	bootstrapParams.ExtraSpecs = rewriteCloudConfigSpecURLs(
		bootstrapParams.ExtraSpecs,
		originalMetadataURL,
		bootstrapParams.MetadataURL,
		originalCallbackURL,
		bootstrapParams.CallbackURL,
	)
	return bootstrapParams
}

// CreateInstance renders the runner bootstrap and asks the backend to
// materialise a per-job domain tagged with the controller/pool identity.
func (p *Provider) CreateInstance(ctx context.Context, bootstrapParams commonParams.BootstrapInstance) (commonParams.ProviderInstance, error) {
	controllerID := os.Getenv("GARM_CONTROLLER_ID")
	bootstrapParams = applyGuestURLOverrides(bootstrapParams, p.cfg)

	golden := p.cfg.ResolveImage(bootstrapParams.Image)
	osName := golden.OSName
	if osName == "" {
		osName = string(bootstrapParams.OSType)
	}

	// Render the runner bootstrap (Windows PowerShell / Linux shell) using
	// GARM's own template so the guest installs + JIT-registers the runner. The
	// injection of this into the guest is the M3 config-drive path; we render it
	// here and carry it through the backend seam.
	var bootstrap []byte
	if tools, err := pickTools(bootstrapParams); err == nil {
		script, serr := renderRunnerBootstrapForBackend(p.cfg.Backend, bootstrapParams, tools, bootstrapParams.Name)
		if serr != nil {
			return commonParams.ProviderInstance{}, fmt.Errorf("rendering runner bootstrap: %w", serr)
		}
		bootstrap = script
	}
	// NOTE: if no matching tools are supplied (eg the hermetic gate uses a
	// minimal bootstrap), the domain is still created; the M3 milestone makes
	// tool selection mandatory once real injection lands.

	inst, err := p.backend.Create(ctx, backend.CreateArgs{
		Name:         bootstrapParams.Name,
		ControllerID: controllerID,
		PoolID:       bootstrapParams.PoolID,
		SourceImage:  golden.SourceImage,
		OSName:       osName,
		OSVersion:    golden.OSVersion,
		OSArch:       string(bootstrapParams.OSArch),
		Flavor:       bootstrapParams.Flavor,
		Network:      p.cfg.Network,
		Bootstrap:    bootstrap,
	})
	if err != nil {
		return commonParams.ProviderInstance{
			Name:          bootstrapParams.Name,
			OSType:        bootstrapParams.OSType,
			Status:        commonParams.InstanceError,
			ProviderFault: []byte(err.Error()),
		}, err
	}
	pi := toProviderInstance(inst)
	// CreateInstance must report a running instance (GARM's ValidateResult
	// requires provider_id + a status). The backend started the domain.
	if pi.Status == "" || pi.Status == commonParams.InstanceStatusUnknown {
		pi.Status = commonParams.InstanceRunning
	}
	if pi.OSType == "" {
		pi.OSType = bootstrapParams.OSType
	}
	return pi, nil
}

// DeleteInstance destroys + undefines the domain. Idempotent: returns
// garmErrors.ErrNotFound (=> exit 30) only when the harness should signal
// not-found; a genuinely-absent domain is treated as success.
// sweeper is implemented by backends that can reclaim ephemeral resources
// leaked by hard-killed launchers (see VMHarnessRunBackend.Sweep). Delete is
// per-instance and self-cleaning; the sweep opportunistically mops up orphans
// from prior runs that crashed before their own Delete could fire, so leaks do
// not accumulate across the fleet without needing a separate daemon.
type sweeper interface {
	Sweep(ctx context.Context)
}

func (p *Provider) DeleteInstance(ctx context.Context, instance string) error {
	if err := p.backend.Delete(ctx, instance); err != nil {
		if errors.Is(err, garmErrors.ErrNotFound) {
			// Absence during delete is success (idempotent).
			return nil
		}
		return err
	}
	// After a successful delete, opportunistically reclaim any leaked orphans
	// from previously crashed runs. Best-effort; never affects the delete result.
	if s, ok := p.backend.(sweeper); ok {
		s.Sweep(ctx)
	}
	return nil
}

// GetInstance recomputes one domain's view from the backend.
func (p *Provider) GetInstance(ctx context.Context, instance string) (commonParams.ProviderInstance, error) {
	inst, err := p.backend.Get(ctx, instance)
	if err != nil {
		return commonParams.ProviderInstance{}, err
	}
	return toProviderInstance(inst), nil
}

// ListInstances recomputes all domains for a pool from the backend.
func (p *Provider) ListInstances(ctx context.Context, poolID string) ([]commonParams.ProviderInstance, error) {
	insts, err := p.backend.List(ctx, poolID)
	if err != nil {
		return nil, err
	}
	out := make([]commonParams.ProviderInstance, 0, len(insts))
	for _, inst := range insts {
		out = append(out, toProviderInstance(inst))
	}
	return out, nil
}

// RemoveAllInstances removes every domain tagged with the controller ID.
func (p *Provider) RemoveAllInstances(ctx context.Context) error {
	controllerID := os.Getenv("GARM_CONTROLLER_ID")
	insts, err := p.backend.ListByController(ctx, controllerID)
	if err != nil {
		return err
	}
	for _, inst := range insts {
		if derr := p.backend.Delete(ctx, inst.Name); derr != nil && !errors.Is(derr, garmErrors.ErrNotFound) {
			return derr
		}
	}
	return nil
}

// Stop shuts a domain down.
func (p *Provider) Stop(ctx context.Context, instance string, force bool) error {
	return p.backend.Stop(ctx, instance, force)
}

// Start boots a domain.
func (p *Provider) Start(ctx context.Context, instance string) error {
	return p.backend.Start(ctx, instance)
}

// GetVersion returns the provider version.
func (p *Provider) GetVersion(ctx context.Context) string {
	return version.Version
}

// GetSupportedInterfaceVersions returns the GARM external-provider interface
// versions this provider implements.
func (p *Provider) GetSupportedInterfaceVersions(ctx context.Context) []string {
	return []string{commonExecution.Version011}
}

// ValidatePoolInfo validates that a pool's image/flavor and provider config are
// usable by this provider.
func (p *Provider) ValidatePoolInfo(ctx context.Context, image string, flavor string, providerConfig string, extraspecs string) error {
	if image == "" {
		return fmt.Errorf("image is required")
	}
	// Ensure the resolved golden source is non-empty (either mapped or the raw
	// image identifier is used directly).
	if p.cfg.ResolveImage(image).SourceImage == "" {
		return fmt.Errorf("image %q does not resolve to a golden source", image)
	}
	if extraspecs != "" && extraspecs != "{}" {
		var probe map[string]any
		if err := json.Unmarshal([]byte(extraspecs), &probe); err != nil {
			return fmt.Errorf("invalid extra_specs: %w", err)
		}
	}
	return nil
}

// GetConfigJSONSchema returns the JSON schema for the provider config file.
func (p *Provider) GetConfigJSONSchema(ctx context.Context) (string, error) {
	return configJSONSchema, nil
}

// GetExtraSpecsJSONSchema returns the JSON schema for per-pool extra specs.
func (p *Provider) GetExtraSpecsJSONSchema(ctx context.Context) (string, error) {
	return extraSpecsJSONSchema, nil
}
