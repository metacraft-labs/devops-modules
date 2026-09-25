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

// Cached-runner version guard.
//
// GitHub refuses to deliver jobs to deprecated actions/runner releases ("Runner
// version vX is deprecated and cannot receive messages"). Goldens that pre-stage
// a runner at the runner home make every bootstrap template skip the download,
// because all of them -- GARM upstream's Windows and Linux templates and this
// provider's own ones -- only test whether the runner is PRESENT, never which
// version it is. One stale golden therefore kills every clone made from it.
//
// The guard compares the version GARM OFFERS (derived from the tools entry it
// hands us) with the version INSTALLED in the guest (read from
// bin/Runner.Listener.deps.json, without executing the runner) and, on
// mismatch (or an unreadable version):
//
//   - GARM upstream Windows: removes the whole runner dir, so upstream's own
//     download branch fires (Windows has no dependency-install step);
//   - GARM upstream Linux: downloads the offered runner and replaces bin/ and
//     externals/ in place, so upstream continues down its cached-runner branch
//     and does NOT run installdependencies.sh (apt) on every job whenever
//     GitHub ships a runner newer than the golden's;
//   - this provider's own templates: removes run.sh/run.cmd, bin/ and
//     externals/, so their download branch fires and the extract overwrites.
//
// The match is exact, trading cache hit rate for correctness: while a runner
// newer than the golden's exists, each job downloads it. When no offered
// version can be derived the guard is omitted entirely: it must never be the
// reason a bootstrap fails.

import (
	"bytes"
	"fmt"
	"regexp"
	"strings"

	"github.com/cloudbase/garm-provider-common/cloudconfig"
	"github.com/cloudbase/garm-provider-common/defaults"
	commonParams "github.com/cloudbase/garm-provider-common/params"
)

var runnerVersionRe = regexp.MustCompile(`\d+\.\d+\.\d+`)

// offeredRunnerVersion derives the actions/runner version GARM is offering from
// the tools entry: the archive file name first (eg
// actions-runner-win-x64-2.337.0.zip), then the download URL. The last match is
// used so that digits earlier in the name (eg an arch suffix) cannot win.
// Returns "" when no version is derivable, which disables the guard.
func offeredRunnerVersion(tools commonParams.RunnerApplicationDownload) string {
	for _, s := range []string{tools.GetFilename(), tools.GetDownloadURL()} {
		if m := runnerVersionRe.FindAllString(s, -1); len(m) > 0 {
			return m[len(m)-1]
		}
	}
	return ""
}

// Anchors in GARM upstream's rendered default templates (vendored
// garm-provider-common cloudconfig). The guard is injected immediately before
// them, so it runs after the runner dir variable is set and before upstream's
// "is a cached runner present?" decision.
const (
	upstreamWindowsRunnerDirLine = `$runnerDir = "C:\actions-runner"`
	upstreamWindowsGuardAnchor   = `# Check if a cached runner is available`
	upstreamLinuxGuardAnchor     = `if [ ! -d "$RUN_HOME" ];then`
)

// bashGuardMode selects what the POSIX-shell guard does on a version mismatch.
type bashGuardMode int

const (
	// bashDiscardPayload removes run.sh, bin/ and externals/ (for templates whose
	// download branch is keyed on run.sh), keeping other files such as .env.
	bashDiscardPayload bashGuardMode = iota
	// bashReplaceInPlace downloads the offered runner itself and replaces bin/
	// and externals/ in place, keeping the runner home, so the enclosing
	// template continues down its "cached runner" branch. Used for GARM
	// upstream's Linux template, whose not-present branch would otherwise also
	// run `installdependencies.sh` (apt, with retries) on every job whenever
	// GitHub ships a runner newer than the golden's.
	bashReplaceInPlace
)

// bashRunnerDownload is what bashReplaceInPlace needs to fetch the offered
// runner (mirroring upstream's own download: same curl flags, optional
// temp-token header) and whom to hand the result to.
type bashRunnerDownload struct {
	URL               string
	TempDownloadToken string
	SHA256Checksum    string
	Owner             string // user:group for chown -R
}

// bashRunnerVersionGuard renders a POSIX-sh snippet (safe under `set -eu` and
// `set -o pipefail`) that inspects the runner at the directory named by the
// shell variable runHomeVar. statusFn/failFn are the enclosing template's
// status and fatal-error functions (each takes one message argument; messages
// avoid double quotes because some of those functions splice them into JSON
// unescaped). dl is only used by bashReplaceInPlace.
func bashRunnerVersionGuard(offered, runHomeVar, statusFn, failFn string, mode bashGuardMode, dl bashRunnerDownload) string {
	h := `$` + runHomeVar
	readVersion := func(indent string) string {
		return indent + `GARM_CACHED_RUNNER_VERSION=""
` + indent + `if [ -f "` + h + `/bin/Runner.Listener.deps.json" ]; then
` + indent + `	GARM_CACHED_RUNNER_VERSION=$(sed -n 's|.*"Runner\.Listener/\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)".*|\1|p' "` + h + `/bin/Runner.Listener.deps.json" 2>/dev/null | head -n 1) || GARM_CACHED_RUNNER_VERSION=""
` + indent + `fi
`
	}
	var present, action, verb string
	switch mode {
	case bashReplaceInPlace:
		present = `[ -d "` + h + `" ]`
		verb = "replacing runner binaries in place"
		header := `""`
		if dl.TempDownloadToken != "" {
			header = shellQuote("Authorization: Bearer " + dl.TempDownloadToken)
		}
		checksum := ""
		if dl.SHA256Checksum != "" {
			checksum = `	printf '%s  %s\n' ` + shellQuote(dl.SHA256Checksum) + ` "$GARM_RUNNER_ARCHIVE" | sha256sum -c - >/dev/null 2>&1 || { rm -f "$GARM_RUNNER_ARCHIVE"; ` + failFn + ` "runner $GARM_OFFERED_RUNNER_VERSION checksum mismatch"; }
`
		}
		action = `	GARM_RUNNER_OWNER=` + shellQuote(dl.Owner) + `
	GARM_RUNNER_ARCHIVE=$(mktemp "${TMPDIR:-/tmp}/garm-actions-runner.XXXXXX") || ` + failFn + ` "failed to create a temp file for runner $GARM_OFFERED_RUNNER_VERSION"
	curl --retry 5 --retry-delay 5 --retry-connrefused --fail -sS -L -H ` + header + ` -o "$GARM_RUNNER_ARCHIVE" ` + shellQuote(dl.URL) + ` || { rm -f "$GARM_RUNNER_ARCHIVE"; ` + failFn + ` "failed to download runner $GARM_OFFERED_RUNNER_VERSION to replace the cached runner"; }
` + checksum + `	rm -rf "` + h + `/bin" "` + h + `/externals" 2>/dev/null || sudo -n rm -rf "` + h + `/bin" "` + h + `/externals" || { rm -f "$GARM_RUNNER_ARCHIVE"; ` + failFn + ` "failed to remove stale runner binaries in ` + h + `"; }
	tar xf "$GARM_RUNNER_ARCHIVE" -C "` + h + `"/ 2>/dev/null || sudo -n tar xf "$GARM_RUNNER_ARCHIVE" -C "` + h + `"/ || { rm -f "$GARM_RUNNER_ARCHIVE"; ` + failFn + ` "failed to extract runner $GARM_OFFERED_RUNNER_VERSION over ` + h + `"; }
	rm -f "$GARM_RUNNER_ARCHIVE"
	chown -R "$GARM_RUNNER_OWNER" "` + h + `" 2>/dev/null || sudo -n chown -R "$GARM_RUNNER_OWNER" "` + h + `" || ` + failFn + ` "failed to change owner of ` + h + ` to $GARM_RUNNER_OWNER"
` + readVersion("	") + `	if [ "$GARM_CACHED_RUNNER_VERSION" != "$GARM_OFFERED_RUNNER_VERSION" ]; then
		` + failFn + ` "runner archive installed version ${GARM_CACHED_RUNNER_VERSION:-unknown}, not the offered $GARM_OFFERED_RUNNER_VERSION"
	fi
`
	default:
		present = `[ -x "` + h + `/run.sh" ]`
		verb = "discarding cached runner"
		paths := `"` + h + `/run.sh" "` + h + `/bin" "` + h + `/externals"`
		action = `	rm -rf ` + paths + ` 2>/dev/null || sudo -n rm -rf ` + paths + ` || ` + failFn + ` "failed to discard cached runner in ` + h + `"
`
	}
	return `# garm-provider-vmharness: cached-runner version guard. GitHub rejects
# deprecated runner releases, so a runner pre-staged in the image is only
# reused when it is exactly the version GARM offers.
GARM_OFFERED_RUNNER_VERSION=` + shellQuote(offered) + `
if ` + present + `; then
` + readVersion("	") + `	if [ "$GARM_CACHED_RUNNER_VERSION" != "$GARM_OFFERED_RUNNER_VERSION" ]; then
		` + statusFn + ` "cached runner ${GARM_CACHED_RUNNER_VERSION:-unknown} in ` + h + ` != offered $GARM_OFFERED_RUNNER_VERSION; ` + verb + `"
` + indentLines(action, "	") + `	else
		echo "cached runner $GARM_CACHED_RUNNER_VERSION matches offered version"
	fi
fi
`
}

func indentLines(text, indent string) string {
	var b strings.Builder
	for _, l := range strings.SplitAfter(text, "\n") {
		if strings.TrimSpace(l) != "" {
			b.WriteString(indent)
		}
		b.WriteString(l)
	}
	return b.String()
}

// powershellRunnerVersionGuard is the PowerShell counterpart of
// bashRunnerVersionGuard. It is safe under $ErrorActionPreference = 'Stop': a
// missing or unreadable deps.json is caught and treated as unknown. statusCall
// and failCall render a statement reporting the given PowerShell
// double-quoted-string message.
func powershellRunnerVersionGuard(offered, runHomeVar string, statusCall, failCall func(msg string) string, discardWholeDir bool) string {
	present := `Test-Path -LiteralPath $` + runHomeVar + ` -PathType Container`
	discard := `Remove-Item -LiteralPath $` + runHomeVar + ` -Recurse -Force -ErrorAction Stop`
	if !discardWholeDir {
		present = `Test-Path -LiteralPath (Join-Path $` + runHomeVar + ` 'run.cmd')`
		discard = `foreach ($garmStale in @('run.cmd', 'bin', 'externals')) {
				$garmStalePath = Join-Path $` + runHomeVar + ` $garmStale
				if (Test-Path -LiteralPath $garmStalePath) {
					Remove-Item -LiteralPath $garmStalePath -Recurse -Force -ErrorAction Stop
				}
			}`
	}
	return `# garm-provider-vmharness: cached-runner version guard. GitHub rejects
# deprecated runner releases, so a runner pre-staged in the image is only
# reused when it is exactly the version GARM offers.
$garmOfferedRunnerVersion = ` + powershellQuote(offered) + `
if (` + present + `) {
	$garmCachedRunnerVersion = ''
	try {
		$garmDepsPath = Join-Path (Join-Path $` + runHomeVar + ` 'bin') 'Runner.Listener.deps.json'
		if (Test-Path -LiteralPath $garmDepsPath -PathType Leaf) {
			$garmDeps = Get-Content -LiteralPath $garmDepsPath -Raw -ErrorAction Stop
			$garmMatch = [regex]::Match([string]$garmDeps, '"Runner\.Listener/(\d+\.\d+\.\d+)"')
			if ($garmMatch.Success) {
				$garmCachedRunnerVersion = $garmMatch.Groups[1].Value
			}
		}
	} catch {
		$garmCachedRunnerVersion = ''
	}
	if ($garmCachedRunnerVersion -ne $garmOfferedRunnerVersion) {
		$garmShownVersion = if ($garmCachedRunnerVersion) { $garmCachedRunnerVersion } else { 'unknown' }
		` + statusCall(`cached runner $garmShownVersion in ${`+runHomeVar+`} != offered $garmOfferedRunnerVersion; discarding cached runner`) + `
		try {
			` + discard + `
		} catch {
			` + failCall(`failed to discard cached runner in ${`+runHomeVar+`}: $($_.Exception.Message)`) + `
		}
	} else {
		Write-Host "cached runner $garmCachedRunnerVersion matches offered version"
	}
}
`
}

// ownBashRunnerVersionGuard / ownPowershellRunnerVersionGuard render the guard
// for this provider's own templates (keyed on run.sh / run.cmd), or "" when no
// offered version is derivable.
func ownBashRunnerVersionGuard(tools commonParams.RunnerApplicationDownload) string {
	offered := offeredRunnerVersion(tools)
	if offered == "" {
		return ""
	}
	return bashRunnerVersionGuard(offered, "RUN_HOME", "status", "fail", bashDiscardPayload, bashRunnerDownload{})
}

func ownPowershellRunnerVersionGuard(tools commonParams.RunnerApplicationDownload) string {
	offered := offeredRunnerVersion(tools)
	if offered == "" {
		return ""
	}
	return powershellRunnerVersionGuard(offered, "RunHome",
		func(msg string) string { return `Send-Status -Status 'installing' -Message "` + msg + `"` },
		func(msg string) string { return `Fail-Install "` + msg + `"` },
		false)
}

// injectBeforeAnchor inserts snippet (re-indented to the anchor's indentation)
// immediately before the single line whose trimmed content equals anchor. When
// prevLine is non-empty, the line before the anchor must trim to it. Anything
// other than exactly one match is an error: a vendored-upstream bump that moves
// the anchor must fail loudly rather than silently drop the guard.
func injectBeforeAnchor(script []byte, anchor, prevLine, snippet string) ([]byte, error) {
	lines := strings.SplitAfter(string(script), "\n")
	at := -1
	for i, line := range lines {
		if strings.TrimSpace(line) == anchor {
			if at >= 0 {
				return nil, fmt.Errorf("runner version guard: anchor %q found more than once in upstream runner install script", anchor)
			}
			at = i
		}
	}
	if at < 0 {
		return nil, fmt.Errorf("runner version guard: anchor %q not found in upstream runner install script", anchor)
	}
	if prevLine != "" && (at == 0 || strings.TrimSpace(lines[at-1]) != prevLine) {
		return nil, fmt.Errorf("runner version guard: anchor %q is not preceded by %q in upstream runner install script", anchor, prevLine)
	}
	anchorLine := lines[at]
	indent := anchorLine[:len(anchorLine)-len(strings.TrimLeft(anchorLine, " \t"))]
	var buf bytes.Buffer
	for _, l := range lines[:at] {
		buf.WriteString(l)
	}
	for _, l := range strings.SplitAfter(snippet, "\n") {
		if l == "" {
			continue
		}
		if strings.TrimSpace(l) != "" {
			buf.WriteString(indent)
		}
		buf.WriteString(l)
	}
	for _, l := range lines[at:] {
		buf.WriteString(l)
	}
	return buf.Bytes(), nil
}

// guardUpstreamRunnerInstallScript injects the version guard into a script
// rendered by GARM upstream's DEFAULT template. A pool-supplied
// runner_install_template is left untouched (its author owns its cache logic),
// as is any script when no offered version is derivable.
func guardUpstreamRunnerInstallScript(bootstrapParams commonParams.BootstrapInstance, tools commonParams.RunnerApplicationDownload, script []byte) ([]byte, error) {
	offered := offeredRunnerVersion(tools)
	if offered == "" {
		return script, nil
	}
	specs, err := cloudconfig.GetSpecs(bootstrapParams)
	if err != nil {
		return nil, fmt.Errorf("reading extra specs: %w", err)
	}
	if len(specs.RunnerInstallTemplate) > 0 {
		return script, nil
	}
	switch bootstrapParams.OSType {
	case commonParams.Windows:
		snippet := powershellRunnerVersionGuard(offered, "runnerDir",
			func(msg string) string { return `Update-GarmStatus -CallbackURL $CallbackURL -Message "` + msg + `"` },
			func(msg string) string { return `Throw "` + msg + `"` },
			true)
		return injectBeforeAnchor(script, upstreamWindowsGuardAnchor, upstreamWindowsRunnerDirLine, snippet)
	case commonParams.Linux:
		snippet := bashRunnerVersionGuard(offered, "RUN_HOME", "sendStatus", "fail", bashReplaceInPlace, bashRunnerDownload{
			URL:               tools.GetDownloadURL(),
			TempDownloadToken: tools.GetTempDownloadToken(),
			SHA256Checksum:    tools.GetSHA256Checksum(),
			Owner:             defaults.DefaultUser + ":" + defaults.DefaultUser,
		})
		return injectBeforeAnchor(script, upstreamLinuxGuardAnchor, "", snippet)
	}
	return script, nil
}
