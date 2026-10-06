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

package agentharbor

// The local-sandbox runner payload: the script the provider hands an
// agent-harbor sandbox job as stdin.
//
// LAYERING. agent-harbor is a generic "run this payload in a sandbox, report
// its lifecycle and exit status" service and knows nothing about GitHub
// runners. Everything runner-specific lives HERE: fetching the JIT
// credentials from GARM, laying out the runner's state the way NixOS does,
// exec'ing the runner, and (provider.go) what its exit status means to GARM.
//
// WHY THE NIX RUNNER. The upstream actions/runner tarball cannot start on a
// NixOS ah host: its scripts hard-code #!/bin/bash and it expects FHS
// libraries (ICU, ...) that its apt-based installdependencies.sh would
// install, which a rootless sandbox cannot run. The host's persistent runners
// never had that problem because they run nixpkgs' `github-runner` through the
// NixOS `services.github-runners` module. This payload does exactly what that
// module's unit does, minus systemd:
//
//	module (nixos/modules/services/continuous-integration/github-runner)   payload
//	StateDirectory  = RUNNER_ROOT (credentials)                            $PWD/runner
//	workDir         = HOME, WorkingDirectory                               $PWD/work
//	LogsDirectory   (_diag)                                                $PWD/logs
//	ExecStartPre configure: Runner.Listener configure ... --ephemeral      JIT: credentials fetched from GARM instead
//	                        --disableupdate (registration token path)      non-JIT: the same configure call
//	ExecStartPre setup-work-dirs: link credentials + _diag into workDir    the same links
//	path = bash coreutils git gnutar gzip nix + extraPackages              [runner].path (rendered by services.garm)
//	ExecStart = <github-runner>/bin/Runner.Listener run --startuptype service   exec'd, so its exit status is the job's
//
// The payload downloads nothing: the runner is the host's store path, the same
// package (and so the same version) the host's systemd runners use.
//
// VERSION GUARD. The cached-runner guard (internal/provider) exists because a
// golden image can carry a stale downloaded runner. Here nothing is cached or
// downloaded, so the guard becomes the persistent runners' rule instead: infra's
// actions-runner pin check (check-runner-version.sh) calls a version stale at
// MAX_MINOR_LAG (2) minor releases behind the newest; GitHub then soon refuses
// to dispatch to it. The provider applies the same rule to the version GARM
// offers (the newest release) at CreateInstance and refuses the launch, rather
// than letting a runner register as idle and die later. The payload
// additionally checks that the package at `listener` really is `version`, so a
// config/package drift fails closed before any registration.

import (
	"bytes"
	"fmt"
	"path"
	"sort"
	"strconv"
	"strings"
	"text/template"

	commonParams "github.com/cloudbase/garm-provider-common/params"

	"github.com/metacraft-labs/garm-provider-vmharness/internal/provider"
)

// runnerVersion is a parsed actions/runner x.y.z.
type runnerVersion struct{ major, minor, patch int }

func parseRunnerVersion(s string) (runnerVersion, bool) {
	parts := strings.Split(strings.TrimPrefix(strings.TrimSpace(s), "v"), ".")
	if len(parts) != 3 {
		return runnerVersion{}, false
	}
	var v [3]int
	for i, p := range parts {
		n, err := strconv.Atoi(p)
		if err != nil || n < 0 {
			return runnerVersion{}, false
		}
		v[i] = n
	}
	return runnerVersion{v[0], v[1], v[2]}, true
}

// checkNixRunnerFresh applies the pin check's minor-lag rule to the Nix
// runner (installed) against the version GARM offers (the newest release).
// No derivable offered version disables the check, as in the cached-runner
// guard: the guard must never be the reason a valid launch fails.
func checkNixRunnerFresh(installed, offered string, maxMinorLag int) error {
	inst, ok := parseRunnerVersion(installed)
	if !ok {
		return fmt.Errorf("the configured Nix runner version %q is not x.y.z", installed)
	}
	off, ok := parseRunnerVersion(offered)
	if !ok {
		return nil
	}
	lag := 0
	switch {
	case off.major > inst.major:
		lag = maxMinorLag // any major behind is stale
	case off.major == inst.major && off.minor > inst.minor:
		lag = off.minor - inst.minor
	}
	if lag >= maxMinorLag {
		return fmt.Errorf("the host's Nix github-runner %s is %d minor release(s) behind the %s GitHub offers (stale at %d, the actions-runner pin check's rule); GitHub refuses deprecated runners, so bump the github-runner package the host's systemd runners use", installed, lag, offered, maxMinorLag)
	}
	return nil
}

type nixRunnerPayloadData struct {
	CallbackURL       string
	MetadataURL       string
	CallbackToken     string
	RepoURL           string
	RunnerName        string
	RunnerLabels      string
	GitHubRunnerGroup string
	UseJITConfig      bool
	EnableBootDebug   bool

	Listener       string
	DepsJSON       string
	RunnerVersion  string
	OfferedVersion string
	Path           string
	Env            [][2]string

	PayloadFailureExit int
}

// PayloadFailureExit is the payload's exit status when it fails before
// exec'ing the runner (sysexits EX_CONFIG), distinct from every
// Runner.Listener return code.
const PayloadFailureExit = 78

// renderNixRunnerPayload renders the sandbox payload for one runner.
func renderNixRunnerPayload(bootstrap commonParams.BootstrapInstance, tools commonParams.RunnerApplicationDownload, runner NixRunnerConfig) ([]byte, error) {
	if bootstrap.OSType != commonParams.Linux {
		return nil, fmt.Errorf("the sandbox payload supports linux only, not %q", bootstrap.OSType)
	}
	pkg := path.Dir(path.Dir(runner.Listener))
	data := nixRunnerPayloadData{
		CallbackURL:       bootstrap.CallbackURL,
		MetadataURL:       bootstrap.MetadataURL,
		CallbackToken:     bootstrap.InstanceToken,
		RepoURL:           bootstrap.RepoURL,
		RunnerName:        bootstrap.Name,
		RunnerLabels:      strings.Join(bootstrap.Labels, ","),
		GitHubRunnerGroup: bootstrap.GitHubRunnerGroup,
		UseJITConfig:      bootstrap.JitConfigEnabled,
		EnableBootDebug:   bootstrap.UserDataOptions.EnableBootDebug,
		Listener:          runner.Listener,
		DepsJSON:          pkg + "/lib/github-runner/Runner.Listener.deps.json",
		RunnerVersion:     runner.Version,
		OfferedVersion:    provider.OfferedRunnerVersion(tools),
		Path:              strings.Join(runner.Path, ":"),

		PayloadFailureExit: PayloadFailureExit,
	}
	for _, k := range sortedKeys(runner.Env) {
		data.Env = append(data.Env, [2]string{k, runner.Env[k]})
	}
	tpl, err := template.New("nix-runner-payload").Funcs(template.FuncMap{"shell": provider.ShellQuote}).Parse(nixRunnerPayloadTemplate)
	if err != nil {
		return nil, err
	}
	var buf bytes.Buffer
	if err := tpl.Execute(&buf, data); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// nixRunnerPayloadTemplate: see the file comment. The runner is exec'd, so the
// job's command status (ah's commandExitCode/commandSignal) IS the runner's
// exit status; the payload's own failures exit PayloadFailureExit after
// reporting `failed` to GARM. provider.go maps both onto GARM statuses.
const nixRunnerPayloadTemplate = `set -euo pipefail
{{- if .EnableBootDebug }}
set -x
{{- end }}
{{- if .Path }}
export PATH={{ shell .Path }}
{{- end }}

CALLBACK_URL={{ shell .CallbackURL }}
METADATA_URL={{ shell .MetadataURL }}
BEARER_TOKEN={{ shell .CallbackToken }}
RUNNER_LISTENER={{ shell .Listener }}
RUNNER_VERSION={{ shell .RunnerVersion }}

# The services.github-runners directories, inside the per-job workspace that
# agent-harbor deletes when the job ends.
JOB_DIR="$PWD"
STATE_DIRECTORY="$JOB_DIR/runner"
WORK_DIRECTORY="$JOB_DIR/work"
LOGS_DIRECTORY="$JOB_DIR/logs"

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
	echo "garm-provider-agentharbor payload: $1" >&2
	exit {{ .PayloadFailureExit }}
}

get_metadata_file() {
	curl --retry 5 --retry-delay 5 --retry-connrefused --fail -s \
		-X GET -H 'Accept: application/json' \
		-H "Authorization: Bearer ${BEARER_TOKEN}" \
		"${METADATA_URL}/$1" -o "$2"
}

send_system_info() {
	os_name=""
	os_version=""
	if [ -f /etc/os-release ]; then
		os_name=$(sed -n 's/^NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/os-release)
		os_version=$(sed -n 's/^VERSION_ID="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/os-release)
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

[ -n "$METADATA_URL" ] || fail "missing metadata URL"

# The package must be the version the provider was configured with (and the
# version guard judged); a drift fails closed before registering.
[ -x "$RUNNER_LISTENER" ] || fail "the Nix runner $RUNNER_LISTENER is not executable in the sandbox"
# nixpkgs builds from source, so its deps.json says x.y.z.0; release tarballs
# say x.y.z.
installed_version=$(sed -n 's|.*"Runner\.Listener/\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)\(\.[0-9][0-9]*\)\{0,1\}".*|\1|p' {{ shell .DepsJSON }} 2>/dev/null | head -n 1) || installed_version=""
[ "$installed_version" = "$RUNNER_VERSION" ] || fail "the Nix runner at $RUNNER_LISTENER is ${installed_version:-of unknown version}, not the configured $RUNNER_VERSION"
status "using the Nix github-runner $RUNNER_VERSION{{ if .OfferedVersion }} (GitHub offers {{ .OfferedVersion }}){{ end }}"

mkdir -p "$STATE_DIRECTORY" "$WORK_DIRECTORY" "$LOGS_DIRECTORY"
export HOME="$WORK_DIRECTORY"
export RUNNER_ROOT="$STATE_DIRECTORY"
# A systemd service has no user session, so the systemd runners see no
# XDG_RUNTIME_DIR or session bus. The sandbox job may inherit the ah host
# user's (hidden and read-only inside the sandbox), and tools that honour
# it (just, for one) then fail; mirror the service environment.
unset XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS
{{- range .Env }}
export {{ index . 0 }}={{ shell (index . 1) }}
{{- end }}

status "configuring runner"
{{- if .UseJITConfig }}
get_metadata_file "credentials/runner" "$STATE_DIRECTORY/.runner" || fail "failed to get runner file"
get_metadata_file "credentials/credentials" "$STATE_DIRECTORY/.credentials" || fail "failed to get credentials file"
get_metadata_file "credentials/credentials_rsaparams" "$STATE_DIRECTORY/.credentials_rsaparams" || fail "failed to get credentials_rsaparams file"
chmod 600 "$STATE_DIRECTORY/.credentials" "$STATE_DIRECTORY/.credentials_rsaparams"
{{- else }}
GITHUB_TOKEN=$(curl --retry 5 --retry-delay 5 --retry-connrefused --fail -s \
	-X GET -H 'Accept: application/json' \
	-H "Authorization: Bearer ${BEARER_TOKEN}" \
	"${METADATA_URL}/runner-registration-token/") || fail "failed to get registration token"
"$RUNNER_LISTENER" configure --unattended --disableupdate --ephemeral \
	--work "$WORK_DIRECTORY" \
	--url {{ shell .RepoURL }} \
	--name {{ shell .RunnerName }} \
	--labels {{ shell .RunnerLabels }} --no-default-labels \
	{{- if .GitHubRunnerGroup }}
	--runnergroup {{ shell .GitHubRunnerGroup }} \
	{{- end }}
	--token "$GITHUB_TOKEN" || fail "failed to configure runner"
unset GITHUB_TOKEN
{{- end }}

# setup-work-dirs: _diag and the credentials, linked into the work directory.
ln -sfn "$LOGS_DIRECTORY" "$WORK_DIRECTORY/_diag"
ln -sf "$STATE_DIRECTORY/.runner" "$STATE_DIRECTORY/.credentials" "$STATE_DIRECTORY/.credentials_rsaparams" "$WORK_DIRECTORY/"

send_system_info
call_status '{"status":"idle","message":"runner configured"}'
cd "$WORK_DIRECTORY"
unset BEARER_TOKEN
exec "$RUNNER_LISTENER" run --startuptype service
`

func sortedKeys(m map[string]string) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
