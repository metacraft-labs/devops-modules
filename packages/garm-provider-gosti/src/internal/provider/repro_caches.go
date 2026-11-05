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

// Reprobuild binary-cache client trust for ephemeral Windows guests.
//
// The reprobuild client is default-untrusted: a cache URL tells it where to
// ask, not whom to trust, so a guest substitutes nothing until it is handed a
// `caches.conf` naming the cache and its trusted producer public keys. The
// persistent SSH-bootstrapped Windows runner gets that file from infra's
// `mkCachesConf` (services/github-runners/windows.nix) through bootstrap.sh.
// An ephemeral guest boots from a config drive instead, so this file carries
// the SAME rendered bytes onto that path (reprobuild-pm
// milestones/Warm-Runners-And-Layered-CI-Images.milestones.org, WR4,
// "Integration clarification: read-only native client configuration",
// approved 2026-11-04):
//
//   - the operator points `guest_repro_caches_conf_file` at the rendered
//     file on the provider host; the provider reads it on EVERY CreateInstance,
//     so a key rotation reaches the next guest without a provider restart;
//   - the bootstrap writes it to `guest_repro_caches_conf_path` in the guest
//     and exports REPRO_CACHES_CONFIG to the runner and to every job child;
//   - nothing else is delivered: no REPRO_BINARY_CACHE_URL, and no publisher
//     key or certificate. The guest is a consumer only, and the transport it
//     is pointed at is GET/HEAD-only (infra's guest bridge listener).
//
// How the variable reaches the runner differs by template, because the runner
// is started differently:
//
//   - every Windows bootstrap gets a prelude, right after its `#ps1_sysnative`
//     line, that writes the file and sets REPRO_CACHES_CONFIG for the
//     bootstrap process and machine-wide. This provider's own foreground
//     template (Windows-ARM) starts run.cmd as a child of that process, so the
//     runner and its jobs inherit it.
//   - GARM upstream's template (x64) registers the runner as a Windows
//     SERVICE. A service gets the Service Control Manager's environment, which
//     is read at boot and does not see a machine variable set afterwards. So
//     the variable also goes into the runner's `.env` file, which the runner
//     reads at startup and applies to its jobs
//     (https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/using-a-proxy-server-with-self-hosted-runners#using-a-env-file-to-set-the-proxy-configuration).
//     It is appended immediately before upstream creates the service, which is
//     after upstream's own (proxy-only) `.env` Set-Content.
//
// Failure policy: a guest whose caches.conf cannot be written runs exactly as
// it would without this feature (every cache lookup misses and the job builds
// from source), so a write failure is reported in the bootstrap log and never
// fails the bootstrap. A provider-side failure to READ the configured file is
// different: it is an operator misconfiguration on the host, and CreateInstance
// refuses rather than silently dropping trust the operator asked for.

import (
	"encoding/base64"
	"fmt"
	"os"
	"strings"

	commonParams "github.com/cloudbase/garm-provider-common/params"
)

const (
	// DefaultGuestReproCachesConfPath is where the guest copy is written when
	// the operator does not choose a path. It is the same fixed,
	// profile-independent root the persistent Windows runner uses for the
	// client (infra windows.nix binaryCacheCachesConfPath: the guest's admin
	// profile intermittently fails to load, so nothing may use %LOCALAPPDATA%).
	DefaultGuestReproCachesConfPath = `C:\dev-deps\repro\caches.conf`

	reproCachesConfigEnv = "REPRO_CACHES_CONFIG"

	// maxGuestReproCachesConfBytes bounds what is embedded in the config-drive
	// user data. A caches.conf is a few hundred bytes; anything near this size
	// is not one.
	maxGuestReproCachesConfBytes = 64 << 10

	windowsUserDataHeader = "#ps1_sysnative"

	reproCachesPreludeMarker = "# garm-provider-gosti: reprobuild binary-cache client trust (caches.conf)."

	// The line in GARM upstream's Windows install script right before it
	// creates the runner service (both the stored github_windows template
	// GARM >= 0.2 serves and the garm-provider-common default carry it once).
	upstreamWindowsServiceNameAnchor = `$serviceNameFile = (Join-Path $runnerDir ".service")`

	reproCachesEnvSpliceMarker = "# garm-provider-gosti: hand REPRO_CACHES_CONFIG to the runner service through its .env file."
)

// loadGuestReproCachesConf reads the operator-rendered caches.conf. An empty
// path means the feature is off.
func loadGuestReproCachesConf(path string) ([]byte, error) {
	if path == "" {
		return nil, nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading guest_repro_caches_conf_file: %w", err)
	}
	if len(strings.TrimSpace(string(data))) == 0 {
		return nil, fmt.Errorf("guest_repro_caches_conf_file %q is empty", path)
	}
	if len(data) > maxGuestReproCachesConfBytes {
		return nil, fmt.Errorf("guest_repro_caches_conf_file %q is %d bytes, over the %d-byte limit", path, len(data), maxGuestReproCachesConfBytes)
	}
	return data, nil
}

// windowsReproCachesPrelude renders the PowerShell that writes the guest copy
// and exports REPRO_CACHES_CONFIG. The file travels base64-encoded so no byte
// of it can end a quoted string or a here-string.
func windowsReproCachesPrelude(conf []byte, guestPath string) string {
	encoded := base64.StdEncoding.EncodeToString(conf)
	return reproCachesPreludeMarker + `
# Written for every job, so a trust change on the host reaches the next guest.
# A failure here leaves the guest without a cache (every lookup misses and the
# job builds from source); it never fails the bootstrap.
$garmReproCachesConfPath = ` + powershellQuote(guestPath) + `
try {
	$garmReproCachesConfBytes = [System.Convert]::FromBase64String(` + powershellQuote(encoded) + `)
	$garmReproCachesConfDir = [System.IO.Path]::GetDirectoryName($garmReproCachesConfPath)
	if ($garmReproCachesConfDir) { [System.IO.Directory]::CreateDirectory($garmReproCachesConfDir) | Out-Null }
	[System.IO.File]::WriteAllBytes($garmReproCachesConfPath, $garmReproCachesConfBytes)
	$env:` + reproCachesConfigEnv + ` = $garmReproCachesConfPath
	[Environment]::SetEnvironmentVariable('` + reproCachesConfigEnv + `', $garmReproCachesConfPath, 'Machine')
	Write-Output "reprobuild caches.conf written to $garmReproCachesConfPath"
} catch {
	Write-Output "reprobuild caches.conf not provisioned: $($_.Exception.Message)"
}
`
}

// reproCachesDotEnvLine is the PowerShell statement that appends the variable
// to the runner's .env file, for the service-mode template.
func reproCachesDotEnvLine(guestPath string) string {
	return `Add-Content -Path (Join-Path $runnerDir ".env") -Value ` + powershellQuote(reproCachesConfigEnv+"="+guestPath)
}

// injectAfterWindowsHeader inserts snippet right after the user data's
// `#ps1_sysnative` line, which cloudbase-init needs to stay first.
func injectAfterWindowsHeader(script []byte, snippet string) ([]byte, error) {
	text := string(script)
	nl := strings.IndexByte(text, '\n')
	first := text
	rest := ""
	if nl >= 0 {
		first, rest = text[:nl+1], text[nl+1:]
	}
	if strings.TrimSpace(first) != windowsUserDataHeader {
		return nil, fmt.Errorf("guest caches.conf: Windows bootstrap does not start with %q", windowsUserDataHeader)
	}
	if !strings.HasSuffix(first, "\n") {
		first += "\n"
	}
	return []byte(first + snippet + rest), nil
}

// powershellWrapperReproCachesSplice is the step inserted into GARM's
// install-script wrapper, between its fetch of the served install script and
// its run of it. In the guest it adds reproCachesDotEnvLine immediately before
// upstream's service creation, only when that anchor occurs exactly once.
func powershellWrapperReproCachesSplice(guestPath string) string {
	return reproCachesEnvSpliceMarker + `
try {
	$garmEnvLines = [System.IO.File]::ReadAllLines($installScript)
	$garmEnvAt = -1
	$garmEnvHits = 0
	for ($garmEnvI = 0; $garmEnvI -lt $garmEnvLines.Length; $garmEnvI++) {
		if ($garmEnvLines[$garmEnvI].Trim() -eq ` + powershellQuote(upstreamWindowsServiceNameAnchor) + `) {
			$garmEnvHits++
			$garmEnvAt = $garmEnvI
		}
	}
	if ($garmEnvHits -eq 1) {
		$garmEnvIndent = [regex]::Match($garmEnvLines[$garmEnvAt], '^\s*').Value
		$garmEnvOut = New-Object System.Collections.Generic.List[string]
		for ($garmEnvI = 0; $garmEnvI -lt $garmEnvAt; $garmEnvI++) { $garmEnvOut.Add($garmEnvLines[$garmEnvI]) }
		$garmEnvOut.Add($garmEnvIndent + ` + powershellQuote(reproCachesDotEnvLine(guestPath)) + `)
		for ($garmEnvI = $garmEnvAt; $garmEnvI -lt $garmEnvLines.Length; $garmEnvI++) { $garmEnvOut.Add($garmEnvLines[$garmEnvI]) }
		[System.IO.File]::WriteAllLines($installScript, $garmEnvOut.ToArray())
		Write-Output "REPRO_CACHES_CONFIG spliced into the served install script's runner .env"
	} else {
		Write-Output "REPRO_CACHES_CONFIG not handed to the runner service: the served install script has no single service-creation step"
	}
} catch {
	Write-Output "REPRO_CACHES_CONFIG not handed to the runner service: $($_.Exception.Message)"
}
`
}

// applyGuestReproCaches adds the guest caches.conf delivery to a rendered
// Windows bootstrap. conf == nil (the feature off) returns the script
// unchanged, byte for byte, as does any non-Windows guest.
func applyGuestReproCaches(script []byte, osType commonParams.OSType, ownTemplate bool, conf []byte, guestPath string) ([]byte, error) {
	if conf == nil || osType != commonParams.Windows || len(script) == 0 {
		return script, nil
	}
	if guestPath == "" {
		guestPath = DefaultGuestReproCachesConfPath
	}
	out, err := injectAfterWindowsHeader(script, windowsReproCachesPrelude(conf, guestPath))
	if err != nil {
		return nil, err
	}
	if ownTemplate {
		// The foreground runner inherits the prelude's $env: no service.
		return out, nil
	}
	if isGarmInstallScriptWrapper(commonParams.Windows, out) {
		out, err = injectBeforeAnchor(out, garmWindowsWrapperAnchor, "", powershellWrapperReproCachesSplice(guestPath))
	} else {
		// garm-provider-common's own default template, rendered in full here.
		// A custom template without the anchor is refused: the operator asked
		// for the runner to see REPRO_CACHES_CONFIG, and it would not.
		out, err = injectBeforeAnchor(out, upstreamWindowsServiceNameAnchor, "", reproCachesDotEnvLine(guestPath)+"\n")
	}
	if err != nil {
		return nil, fmt.Errorf("guest caches.conf: %w", err)
	}
	return out, nil
}
